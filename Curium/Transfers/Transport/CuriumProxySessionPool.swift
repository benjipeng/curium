import CFNetwork
import Darwin
import Foundation
import Network
import OSLog
import os

/// Security rejections surfaced when an HTTP 3xx redirect violates scheme or SSRF rules.
enum CuriumTransferRedirectError: LocalizedError, Sendable, Equatable {
    case disallowedURLScheme(String)
    case blockedPrivateNetworkHost(String)

    var errorDescription: String? {
        switch self {
        case .disallowedURLScheme(let scheme):
            return "Blocked redirect to unsupported URL scheme (\(scheme))."
        case .blockedPrivateNetworkHost(let host):
            return "Blocked redirect to private or local network host (\(host))."
        }
    }
}

/// Shared `URLSessionTaskDelegate` and pure policy helper that:
/// 1. Strips `Cookie`, `Authorization`, and `Proxy-Authorization` whenever an HTTP 3xx redirect
///    crosses scheme, host, or port boundaries.
/// 2. Strips `Referer` and `Origin` across `https -> http` downgrades.
/// 3. Enforces `CuriumHLSParser.isAllowedHTTPURL` and `CuriumHLSParser.isAllowedTargetURL`
///    SSRF private-LAN guards on every redirect hop.
final class CrossOriginRedirectAuthStripper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = CrossOriginRedirectAuthStripper()

    enum RedirectDecision: Equatable, Sendable {
        case allow(URLRequest, needsCookieRefresh: Bool)
        case rejectDisallowedScheme(String)
        case rejectPrivateNetwork(String)
    }

    private static let authHeaderNames: Set<String> = [
        "cookie",
        "authorization",
        "proxy-authorization",
    ]

    let originatingURL: URL?
    let cookieResolver: (@Sendable (URL) async -> String?)?
    private let blockedErrors = OSAllocatedUnfairLock<[Int: CuriumTransferRedirectError]>(initialState: [:])

    init(
        originatingURL: URL? = nil,
        cookieResolver: (@Sendable (URL) async -> String?)? = nil
    ) {
        self.originatingURL = originatingURL
        self.cookieResolver = cookieResolver
        super.init()
    }

    static func isSameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let s1 = lhs.scheme?.lowercased(),
              let s2 = rhs.scheme?.lowercased(),
              s1 == s2,
              let h1 = normalizedHost(lhs),
              let h2 = normalizedHost(rhs),
              h1 == h2 else {
            return false
        }
        let p1 = lhs.port ?? defaultPort(forScheme: s1)
        let p2 = rhs.port ?? defaultPort(forScheme: s2)
        return p1 == p2
    }

    static func isHTTPSDowngrade(from sourceURL: URL?, to destinationURL: URL?) -> Bool {
        sourceURL?.scheme?.lowercased() == "https"
            && destinationURL?.scheme?.lowercased() == "http"
    }

    /// Strips origin-bound credentials (`Cookie`, `Authorization`, `Proxy-Authorization`, plus
    /// `Referer`/`Origin` on `https -> http` downgrades) whenever `destinationURL` crosses origins.
    static func stripCrossOriginAuthHeaders(
        from headers: [String: String],
        sourceURL: URL?,
        destinationURL: URL?
    ) -> [String: String] {
        guard !isSameOrigin(sourceURL, destinationURL) else {
            return headers
        }
        let downgrade = isHTTPSDowngrade(from: sourceURL, to: destinationURL)
        return headers.filter { key, _ in
            let lower = key.lowercased()
            if authHeaderNames.contains(lower) {
                return false
            }
            if downgrade && (lower == "referer" || lower == "origin") {
                return false
            }
            return true
        }
    }

    /// Evaluates a proposed 3xx redirect request against scheme, SSRF, cross-origin auth,
    /// and HTTPS-downgrade policies.
    static func evaluateRedirect(
        from previousURL: URL?,
        to proposed: URLRequest,
        originatingURL: URL? = nil
    ) -> RedirectDecision {
        guard let targetURL = proposed.url,
              CuriumHLSParser.isAllowedHTTPURL(targetURL) else {
            return .rejectDisallowedScheme(proposed.url?.scheme ?? "unknown")
        }

        if let originatingURL,
           !CuriumHLSParser.isAllowedTargetURL(targetURL, originatingURL: originatingURL) {
            return .rejectPrivateNetwork(targetURL.host ?? "private")
        }
        if let previousURL,
           !CuriumHLSParser.isAllowedTargetURL(targetURL, originatingURL: previousURL) {
            return .rejectPrivateNetwork(targetURL.host ?? "private")
        }

        var sanitized = proposed
        sanitized.httpShouldHandleCookies = false

        let sameOrigin = isSameOrigin(previousURL, targetURL)
        if !sameOrigin {
            stripHeaderFields(authHeaderNames, from: &sanitized)
            sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
            sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }

        let downgradedHop = isHTTPSDowngrade(from: previousURL, to: targetURL)
        let targetIsPlaintextHTTP = targetURL.scheme?.lowercased() == "http"
        if downgradedHop {
            stripHeaderFields(["referer", "origin"], from: &sanitized)
            sanitized.setValue(nil, forHTTPHeaderField: "Referer")
            sanitized.setValue(nil, forHTTPHeaderField: "Origin")
        } else if targetIsPlaintextHTTP {
            if let ref = sanitized.value(forHTTPHeaderField: "Referer"),
               let refURL = URL(string: ref),
               refURL.scheme?.lowercased() == "https" {
                stripHeaderFields(["referer"], from: &sanitized)
                sanitized.setValue(nil, forHTTPHeaderField: "Referer")
            }
            if let origin = sanitized.value(forHTTPHeaderField: "Origin"),
               let originURL = URL(string: origin),
               originURL.scheme?.lowercased() == "https" {
                stripHeaderFields(["origin"], from: &sanitized)
                sanitized.setValue(nil, forHTTPHeaderField: "Origin")
            }
        }

        return .allow(sanitized, needsCookieRefresh: !sameOrigin)
    }

    /// Convenience wrapper returning the sanitized `URLRequest` when permitted, or `nil` when blocked.
    static func sanitizedRedirectRequest(
        from sourceURL: URL?,
        to request: URLRequest,
        originatingURL: URL? = nil
    ) -> URLRequest? {
        switch evaluateRedirect(from: sourceURL, to: request, originatingURL: originatingURL) {
        case .allow(let sanitized, _):
            return sanitized
        case .rejectDisallowedScheme, .rejectPrivateNetwork:
            return nil
        }
    }

    func takeBlockedError(for taskIdentifier: Int) -> CuriumTransferRedirectError? {
        blockedErrors.withLock { map in
            map.removeValue(forKey: taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let originHop = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
        let decision = Self.evaluateRedirect(
            from: originHop,
            to: request,
            originatingURL: originatingURL
        )
        switch decision {
        case .rejectDisallowedScheme(let scheme):
            blockedErrors.withLock { $0[task.taskIdentifier] = .disallowedURLScheme(scheme) }
            task.cancel()
            completionHandler(nil)

        case .rejectPrivateNetwork(let host):
            blockedErrors.withLock { $0[task.taskIdentifier] = .blockedPrivateNetworkHost(host) }
            task.cancel()
            completionHandler(nil)

        case .allow(let sanitized, let needsCookieRefresh):
            if needsCookieRefresh, let cookieResolver, let targetURL = sanitized.url {
                Task {
                    var updated = sanitized
                    if let cookie = await cookieResolver(targetURL)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !cookie.isEmpty {
                        updated.setValue(cookie, forHTTPHeaderField: "Cookie")
                    }
                    completionHandler(updated)
                }
            } else {
                completionHandler(sanitized)
            }
        }
    }

    private static func normalizedHost(_ url: URL) -> String? {
        guard let raw = url.host()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func stripHeaderFields(_ lowercaseNames: Set<String>, from request: inout URLRequest) {
        guard let existing = request.allHTTPHeaderFields else { return }
        for key in existing.keys where lowercaseNames.contains(key.lowercased()) {
            request.setValue(nil, forHTTPHeaderField: key)
        }
    }
}

/// Unifies Curium's per-profile `CuriumProxyConfig` (`.system`, `.direct`, `.fixed`) with
/// `CFNetworkCopySystemProxySettings()`, `inet_pton` CIDR bypass matching, and iOS 17+/27.2
/// `Network.ProxyConfiguration(..., allowFailover: false)` to prevent QUIC/HTTP3 UDP proxy bypass.
///
/// Uses reference-counted `SessionLease` pooling so proxy rotations never invalidate an in-flight
/// multi-lane download mid-transfer.
enum CuriumProxySessionPool {
    /// Parsed IPv4 or IPv6 CIDR block backed by `inet_pton` bitmask matching.
    struct CIDRBlock: Equatable, Hashable, Sendable {
        enum Address: Equatable, Hashable, Sendable {
            case ipv4(UInt32)
            case ipv6(UInt64, UInt64)
        }

        let network: Address
        let prefixLength: UInt8

        static func parse(_ raw: String) -> CIDRBlock? {
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let prefix = UInt8(parts[1]) else {
                return nil
            }
            let ipPart = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if let v4 = parseIPv4(ipPart), prefix <= 32 {
                let mask = ipv4Mask(prefix)
                return CIDRBlock(network: .ipv4(v4 & mask), prefixLength: prefix)
            }
            if let (hi, lo) = parseIPv6(ipPart), prefix <= 128 {
                let (mHi, mLo) = ipv6Mask(prefix)
                return CIDRBlock(network: .ipv6(hi & mHi, lo & mLo), prefixLength: prefix)
            }
            return nil
        }

        func contains(ipString: String) -> Bool {
            let trimmed = ipString.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\r\n"))
            switch network {
            case .ipv4(let net):
                guard let ip = Self.parseIPv4(trimmed) else { return false }
                let mask = Self.ipv4Mask(prefixLength)
                return (ip & mask) == net
            case .ipv6(let netHi, let netLo):
                guard let (hi, lo) = Self.parseIPv6(trimmed) else { return false }
                let (mHi, mLo) = Self.ipv6Mask(prefixLength)
                return (hi & mHi) == netHi && (lo & mLo) == netLo
            }
        }

        /// True only when the entire CIDR block is strictly within RFC1918, loopback, link-local,
        /// or IPv6 ULA/loopback/link-local space.
        var isStrictlyPrivateOrLocal: Bool {
            switch network {
            case .ipv4(let net):
                let privateRanges: [(UInt32, UInt8)] = [
                    (0x7F00_0000, 8),   // 127.0.0.0/8 loopback
                    (0x0A00_0000, 8),   // 10.0.0.0/8 RFC1918
                    (0xAC10_0000, 12),  // 172.16.0.0/12 RFC1918
                    (0xC0A8_0000, 16),  // 192.168.0.0/16 RFC1918
                    (0xA9FE_0000, 16),  // 169.254.0.0/16 link-local
                ]
                return privateRanges.contains { base, minPrefix in
                    prefixLength >= minPrefix && (net & Self.ipv4Mask(minPrefix)) == base
                }
            case .ipv6(let netHi, let netLo):
                if prefixLength == 128 && netHi == 0 && netLo == 1 {
                    return true // ::1/128 loopback
                }
                if prefixLength >= 7 && (netHi & 0xFE00_0000_0000_0000) == 0xFC00_0000_0000_0000 {
                    return true // fc00::/7 ULA
                }
                if prefixLength >= 10 && (netHi & 0xFFC0_0000_0000_0000) == 0xFE80_0000_0000_0000 {
                    return true // fe80::/10 link-local
                }
                return false
            }
        }

        private static func ipv4Mask(_ prefix: UInt8) -> UInt32 {
            prefix == 0 ? 0 : (~UInt32(0) << (32 - UInt32(prefix)))
        }

        private static func ipv6Mask(_ prefix: UInt8) -> (UInt64, UInt64) {
            if prefix == 0 { return (0, 0) }
            if prefix <= 64 {
                return (~UInt64(0) << (64 - UInt64(prefix)), 0)
            }
            return (~UInt64(0), ~UInt64(0) << (128 - UInt64(prefix)))
        }

        private static func parseIPv4(_ str: String) -> UInt32? {
            var addr = in_addr()
            guard str.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
            return UInt32(bigEndian: addr.s_addr)
        }

        private static func parseIPv6(_ str: String) -> (UInt64, UInt64)? {
            var addr = in6_addr()
            guard str.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
            return withUnsafeBytes(of: &addr) { raw in
                var hi: UInt64 = 0
                var lo: UInt64 = 0
                for i in 0..<8 { hi = (hi << 8) | UInt64(raw[i]) }
                for i in 8..<16 { lo = (lo << 8) | UInt64(raw[i]) }
                return (hi, lo)
            }
        }
    }

    struct ProxyDescriptor: Equatable, Hashable, Sendable {
        enum Kind: String, Equatable, Hashable, Sendable {
            case httpConnect
            case socks5
        }

        let kind: Kind
        let host: String
        let port: UInt16
        let username: String?
        let password: String?
        let excludedDomains: [String]
        let excludedCIDRs: [CIDRBlock]
        let excludeSimpleHostnames: Bool

        init(
            kind: Kind,
            host: String,
            port: UInt16,
            username: String? = nil,
            password: String? = nil,
            excludedDomains: [String],
            excludedCIDRs: [CIDRBlock] = [],
            excludeSimpleHostnames: Bool = false
        ) {
            self.kind = kind
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.excludedDomains = excludedDomains
            self.excludedCIDRs = excludedCIDRs
            self.excludeSimpleHostnames = excludeSimpleHostnames
        }

        /// Returns `true` when `url` matches an excluded domain, simple hostname, or CIDR block.
        func shouldBypass(url: URL) -> Bool {
            guard let rawHost = url.host()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !rawHost.isEmpty else {
                return false
            }
            let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if excludeSimpleHostnames && !host.contains(".") && !host.contains(":") {
                return true
            }
            for domain in excludedDomains {
                if host == domain || host.hasSuffix(".\(domain)") {
                    return true
                }
            }
            for cidr in excludedCIDRs {
                if cidr.contains(ipString: host) {
                    return true
                }
            }
            return false
        }
    }

    enum SessionProfile: Hashable, Sendable {
        case rangeTransfer
        case hlsStream
        case streamProber
    }

    /// Reference-counted lease keeping a pooled `URLSession` valid for the entire transfer lifetime.
    final class SessionLease: @unchecked Sendable {
        let session: URLSession
        let descriptor: ProxyDescriptor?
        let isDirectBypass: Bool
        private let releaseAction: @Sendable () -> Void
        private let released = OSAllocatedUnfairLock(initialState: false)

        init(
            session: URLSession,
            descriptor: ProxyDescriptor? = nil,
            isDirectBypass: Bool = false,
            onRelease: @escaping @Sendable () -> Void = {}
        ) {
            self.session = session
            self.descriptor = descriptor
            self.isDirectBypass = isDirectBypass
            self.releaseAction = onRelease
        }

        func release() {
            let shouldRelease = released.withLock { already -> Bool in
                if already { return false }
                already = true
                return true
            }
            if shouldRelease {
                releaseAction()
            }
        }

        deinit {
            release()
        }
    }

    private final class ManagedSession: @unchecked Sendable {
        let descriptor: ProxyDescriptor?
        let explicitDirect: Bool
        let session: URLSession
        var activeLeases: Int = 0
        var isRetired: Bool = false
        var didInvalidate: Bool = false

        init(descriptor: ProxyDescriptor?, explicitDirect: Bool, session: URLSession) {
            self.descriptor = descriptor
            self.explicitDirect = explicitDirect
            self.session = session
        }
    }

    private struct PoolKey: Hashable, Sendable {
        let profile: SessionProfile
        let configKey: String
        let isDirectBypass: Bool
    }

    private struct ResolvedSessionPlan: Equatable, Sendable {
        let descriptor: ProxyDescriptor?
        let explicitDirect: Bool
        let isDirectBypass: Bool
    }

    private static let logger = Logger(subsystem: "com.appautomaton.curium", category: "transfers.proxy")
    private static let sessionPoolLock = OSAllocatedUnfairLock<[PoolKey: ManagedSession]>(initialState: [:])
    private static let failClosedDescriptor = ProxyDescriptor(
        kind: .socks5,
        host: "127.0.0.1",
        port: 1,
        excludedDomains: [],
        excludedCIDRs: [],
        excludeSimpleHostnames: false
    )

    // MARK: - System Proxy Settings Resolution

    /// Pure parser for a `CFNetworkCopySystemProxySettings()` dictionary.
    static func resolveSystemDescriptor(from settings: [String: Any]) -> ProxyDescriptor? {
        func isEnabled(_ key: String) -> Bool {
            if let num = settings[key] as? NSNumber { return num.intValue != 0 }
            if let flag = settings[key] as? Bool { return flag }
            return false
        }
        func parsePort(_ key: String) -> UInt16? {
            guard let raw = (settings[key] as? NSNumber)?.intValue,
                  raw >= 1, raw <= 65535 else {
                return nil
            }
            return UInt16(raw)
        }
        func parseHost(_ key: String) -> String? {
            guard let raw = (settings[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }
            return raw
        }
        func hasAuth(_ key: String) -> Bool {
            guard let raw = (settings[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !raw.isEmpty
        }

        // Never override dynamic PAC scripts or Keychain-authenticated corporate proxies.
        if isEnabled("ProxyAutoConfigEnable") {
            return nil
        }

        let httpsOn = isEnabled("HTTPSEnable")
        let httpOn = isEnabled("HTTPEnable")
        let socksOn = isEnabled("SOCKSEnable")

        let resolved: (ProxyDescriptor.Kind, String, UInt16)? = {
            if httpsOn || httpOn {
                if httpsOn && httpOn {
                    guard let httpsHost = parseHost("HTTPSProxy"),
                          let httpsPort = parsePort("HTTPSPort"),
                          let httpHost = parseHost("HTTPProxy"),
                          let httpPort = parsePort("HTTPPort"),
                          httpsHost.lowercased() == httpHost.lowercased(),
                          httpsPort == httpPort,
                          !hasAuth("HTTPSUser"),
                          !hasAuth("HTTPUser") else {
                        return nil
                    }
                    return (.httpConnect, httpsHost, httpsPort)
                }
                if httpsOn,
                   let host = parseHost("HTTPSProxy"),
                   let port = parsePort("HTTPSPort"),
                   !hasAuth("HTTPSUser") {
                    return (.httpConnect, host, port)
                }
                if httpOn,
                   let host = parseHost("HTTPProxy"),
                   let port = parsePort("HTTPPort"),
                   !hasAuth("HTTPUser") {
                    return (.httpConnect, host, port)
                }
                return nil
            }
            if socksOn,
               let host = parseHost("SOCKSProxy"),
               let port = parsePort("SOCKSPort"),
               !hasAuth("SOCKSUser") {
                return (.socks5, host, port)
            }
            return nil
        }()

        guard let (kind, host, port) = resolved else { return nil }
        let proxyIsLoopback = isLoopbackHost(host)

        var excluded: [String] = ["localhost", "127.0.0.1", "::1", "local"]
        var seen = Set(excluded)
        var excludedCIDRs: [CIDRBlock] = []
        var excludeSimpleHostnames = isEnabled("ExcludeSimpleHostnames")

        if let rawList = settings["ExceptionsList"] as? [String] {
            for entry in rawList {
                var clean = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if clean.isEmpty { continue }
                if clean == "<local>" {
                    excludeSimpleHostnames = true
                    continue
                }
                if clean.contains("/") {
                    guard let cidr = CIDRBlock.parse(clean) else { return nil }
                    guard proxyIsLoopback && cidr.isStrictlyPrivateOrLocal else { return nil }
                    if !excludedCIDRs.contains(cidr) {
                        excludedCIDRs.append(cidr)
                    }
                    continue
                }
                while clean.hasPrefix("*.") {
                    clean = String(clean.dropFirst(2))
                }
                while clean.hasPrefix(".") {
                    clean = String(clean.dropFirst())
                }
                if !clean.isEmpty, seen.insert(clean).inserted {
                    excluded.append(clean)
                }
            }
        }

        return ProxyDescriptor(
            kind: kind,
            host: host,
            port: port,
            excludedDomains: excluded,
            excludedCIDRs: excludedCIDRs,
            excludeSimpleHostnames: excludeSimpleHostnames
        )
    }

    static func currentSystemDescriptor() -> ProxyDescriptor? {
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return resolveSystemDescriptor(from: raw)
    }

    // MARK: - Fixed Profile Proxy Resolution

    /// Resolves a `CuriumProxyConfig.fixed(rules:bypassRules:)` profile rule into a fail-closed
    /// `ProxyDescriptor` (or marks `isBypassed == true` when `targetURL` matches `bypassRules`).
    static func resolveFixedDescriptor(
        rules: String,
        bypassRules: String?,
        targetURL: URL? = nil
    ) -> (descriptor: ProxyDescriptor, isBypassed: Bool) {
        let bypass = parseBypassRules(bypassRules)

        var socksEndpoint: (host: String, port: UInt16, user: String?, pass: String?)?
        var httpEndpoint: (host: String, port: UInt16, user: String?, pass: String?)?
        var httpsEndpoint: (host: String, port: UInt16, user: String?, pass: String?)?

        for rawClause in rules.split(separator: ";", omittingEmptySubsequences: true) {
            let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clause.isEmpty else { continue }

            let targetPrefix: String?
            let uriList: String
            if let eqIdx = clause.firstIndex(of: "=") {
                targetPrefix = clause[..<eqIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                uriList = String(clause[clause.index(after: eqIdx)...])
            } else {
                targetPrefix = nil
                uriList = clause
            }

            for rawEntry in uriList.split(separator: ",", omittingEmptySubsequences: true) {
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowered = entry.lowercased()
                guard !entry.isEmpty, lowered != "direct://" else { continue }
                // Fail closed on explicit `https://` TLS-to-proxy schemes (not supported as cleartext CONNECT).
                if lowered.hasPrefix("https://") {
                    break
                }
                guard let parsed = parseFixedProxyEndpoint(entry, targetPrefix: targetPrefix) else { continue }
                switch parsed.slot {
                case .socks:
                    if socksEndpoint == nil {
                        socksEndpoint = (parsed.host, parsed.port, parsed.username, parsed.password)
                    }
                case .httpOnly:
                    if httpEndpoint == nil {
                        httpEndpoint = (parsed.host, parsed.port, parsed.username, parsed.password)
                    }
                case .httpsOnly:
                    if httpsEndpoint == nil {
                        httpsEndpoint = (parsed.host, parsed.port, parsed.username, parsed.password)
                    }
                case .httpAndHTTPS:
                    if httpEndpoint == nil {
                        httpEndpoint = (parsed.host, parsed.port, parsed.username, parsed.password)
                    }
                    if httpsEndpoint == nil {
                        httpsEndpoint = (parsed.host, parsed.port, parsed.username, parsed.password)
                    }
                }
                break
            }
        }

        let targetScheme = targetURL?.scheme?.lowercased()
        let selected: (ProxyDescriptor.Kind, String, UInt16, String?, String?)? = {
            if targetScheme == "http" {
                if let ep = httpEndpoint { return (.httpConnect, ep.host, ep.port, ep.user, ep.pass) }
                if let ep = socksEndpoint { return (.socks5, ep.host, ep.port, ep.user, ep.pass) }
                return nil
            }
            if targetScheme == "https" {
                if let ep = httpsEndpoint { return (.httpConnect, ep.host, ep.port, ep.user, ep.pass) }
                if let ep = socksEndpoint { return (.socks5, ep.host, ep.port, ep.user, ep.pass) }
                return nil
            }
            if let ep = httpsEndpoint ?? httpEndpoint {
                return (.httpConnect, ep.host, ep.port, ep.user, ep.pass)
            }
            if let ep = socksEndpoint {
                return (.socks5, ep.host, ep.port, ep.user, ep.pass)
            }
            return nil
        }()

        let descriptor: ProxyDescriptor
        if let (kind, host, port, user, pass) = selected {
            descriptor = ProxyDescriptor(
                kind: kind,
                host: host,
                port: port,
                username: user,
                password: pass,
                excludedDomains: bypass.excludedDomains,
                excludedCIDRs: bypass.excludedCIDRs,
                excludeSimpleHostnames: bypass.excludeSimpleHostnames
            )
        } else {
            // Fail closed: never degrade a fixed-proxy profile to real-IP direct egress.
            descriptor = failClosedDescriptor
        }

        let isBypassed = targetURL.map { descriptor.shouldBypass(url: $0) } ?? false
        return (descriptor, isBypassed)
    }

    // MARK: - Network.ProxyConfiguration Builder

    /// Builds `Network.ProxyConfiguration` with `allowFailover = false` to block QUIC/HTTP3 bypass.
    static func makeProxyConfigurations(for descriptor: ProxyDescriptor?) -> [ProxyConfiguration] {
        guard let descriptor,
              let nwPort = NWEndpoint.Port(rawValue: descriptor.port) else {
            return []
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(descriptor.host), port: nwPort)
        var config: ProxyConfiguration
        switch descriptor.kind {
        case .httpConnect:
            config = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .socks5:
            config = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        config.allowFailover = false
        config.excludedDomains = descriptor.excludedDomains
        if let username = descriptor.username, let password = descriptor.password {
            config.applyCredential(username: username, password: password)
        }
        return [config]
    }

    // MARK: - Session Acquisition

    /// Acquires a reference-counted pooled `SessionLease` honoring `proxy`, OS proxy settings,
    /// CIDR/domain bypass rules, and `allowFailover = false`.
    static func acquireSessionLease(
        for profile: SessionProfile,
        proxy: CuriumProxyConfig = .system,
        targetURL: URL? = nil,
        systemSettingsOverride: [String: Any]? = nil
    ) -> SessionLease {
        let plan = resolvePlan(
            proxy: proxy,
            targetURL: targetURL,
            systemSettingsOverride: systemSettingsOverride
        )
        let poolKey = PoolKey(
            profile: profile,
            configKey: configPoolKey(for: proxy, targetURL: targetURL),
            isDirectBypass: plan.isDirectBypass
        )

        let (entry, immediateRetire): (ManagedSession, URLSession?) = sessionPoolLock.withLock { pool in
            if let cached = pool[poolKey],
               cached.descriptor == plan.descriptor,
               cached.explicitDirect == plan.explicitDirect {
                cached.activeLeases += 1
                return (cached, nil)
            }
            let cfg = makeConfiguration(for: profile, plan: plan)
            let fresh = ManagedSession(
                descriptor: plan.descriptor,
                explicitDirect: plan.explicitDirect,
                session: URLSession(configuration: cfg)
            )
            fresh.activeLeases = 1

            var toInvalidate: URLSession?
            if let displaced = pool[poolKey] {
                displaced.isRetired = true
                if displaced.activeLeases == 0 && !displaced.didInvalidate {
                    displaced.didInvalidate = true
                    toInvalidate = displaced.session
                }
            }
            pool[poolKey] = fresh
            return (fresh, toInvalidate)
        }
        immediateRetire?.finishTasksAndInvalidate()

        return SessionLease(
            session: entry.session,
            descriptor: entry.descriptor,
            isDirectBypass: plan.isDirectBypass
        ) {
            let retiredSession: URLSession? = sessionPoolLock.withLock { _ in
                entry.activeLeases = max(0, entry.activeLeases - 1)
                if entry.isRetired && entry.activeLeases == 0 && !entry.didInvalidate {
                    entry.didInvalidate = true
                    return entry.session
                }
                return nil
            }
            retiredSession?.finishTasksAndInvalidate()
        }
    }

    /// Creates a non-pooled ephemeral `URLSession` applying the exact same proxy & bypass policy.
    /// Caller owns calling `finishTasksAndInvalidate()` or `invalidateAndCancel()`.
    static func makeOneShotSession(
        for profile: SessionProfile,
        proxy: CuriumProxyConfig = .system,
        targetURL: URL? = nil,
        delegate: (any URLSessionDelegate)? = nil,
        systemSettingsOverride: [String: Any]? = nil
    ) -> URLSession {
        let plan = resolvePlan(
            proxy: proxy,
            targetURL: targetURL,
            systemSettingsOverride: systemSettingsOverride
        )
        let cfg = makeConfiguration(for: profile, plan: plan)
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Private Helpers

    private static func resolvePlan(
        proxy: CuriumProxyConfig,
        targetURL: URL?,
        systemSettingsOverride: [String: Any]?
    ) -> ResolvedSessionPlan {
        switch proxy {
        case .direct:
            return ResolvedSessionPlan(descriptor: nil, explicitDirect: true, isDirectBypass: true)

        case .system:
            let sysDescriptor: ProxyDescriptor?
            if let override = systemSettingsOverride {
                sysDescriptor = resolveSystemDescriptor(from: override)
            } else {
                sysDescriptor = currentSystemDescriptor()
            }
            let bypassed = targetURL.flatMap { sysDescriptor?.shouldBypass(url: $0) } ?? false
            if bypassed {
                return ResolvedSessionPlan(descriptor: nil, explicitDirect: true, isDirectBypass: true)
            }
            return ResolvedSessionPlan(descriptor: sysDescriptor, explicitDirect: false, isDirectBypass: false)

        case .fixed(let rules, let bypassRules):
            let resolved = resolveFixedDescriptor(
                rules: rules,
                bypassRules: bypassRules,
                targetURL: targetURL
            )
            if resolved.isBypassed {
                return ResolvedSessionPlan(descriptor: nil, explicitDirect: true, isDirectBypass: true)
            }
            return ResolvedSessionPlan(
                descriptor: resolved.descriptor,
                explicitDirect: false,
                isDirectBypass: false
            )
        }
    }

    private static func makeConfiguration(
        for profile: SessionProfile,
        plan: ResolvedSessionPlan
    ) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData

        switch profile {
        case .rangeTransfer:
            cfg.httpMaximumConnectionsPerHost = 32
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60 * 60 * 6
            cfg.waitsForConnectivity = true
        case .hlsStream:
            cfg.httpMaximumConnectionsPerHost = 24
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60 * 60 * 6
            cfg.waitsForConnectivity = true
        case .streamProber:
            cfg.httpMaximumConnectionsPerHost = 8
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 15
            cfg.waitsForConnectivity = false
        }

        if plan.explicitDirect {
            cfg.proxyConfigurations = []
            cfg.connectionProxyDictionary = [:]
        } else {
            let proxyConfigs = makeProxyConfigurations(for: plan.descriptor)
            if !proxyConfigs.isEmpty {
                cfg.proxyConfigurations = proxyConfigs
            }
        }
        return cfg
    }

    private static func configPoolKey(for proxy: CuriumProxyConfig, targetURL: URL?) -> String {
        switch proxy {
        case .system:
            return "system"
        case .direct:
            return "direct"
        case .fixed(let rules, let bypassRules):
            let scheme = targetURL?.scheme?.lowercased() ?? "any"
            return "fixed|\(scheme)|\(rules)|\(bypassRules ?? "")"
        }
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let clean = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\r\n")).lowercased()
        if clean == "localhost" || clean == "::1" { return true }
        return CIDRBlock.parse("127.0.0.0/8")?.contains(ipString: clean) == true
    }

    private struct ParsedBypassRules {
        var excludedDomains: [String]
        var excludedCIDRs: [CIDRBlock]
        var excludeSimpleHostnames: Bool
    }

    private static func parseBypassRules(_ rawBypass: String?) -> ParsedBypassRules {
        var domains: [String] = ["localhost", "127.0.0.1", "::1"]
        var cidrs: [CIDRBlock] = []
        var excludeSimple = false
        var forceProxyLoopback = false

        if let rawBypass {
            let tokens = rawBypass
                .split { $0 == "," || $0 == ";" }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for token in tokens {
                let lowered = token.lowercased()
                if lowered == "<local>" {
                    excludeSimple = true
                } else if lowered == "<-loopback>" {
                    forceProxyLoopback = true
                } else if lowered.contains("/"), let cidr = CIDRBlock.parse(lowered) {
                    if !cidrs.contains(cidr) {
                        cidrs.append(cidr)
                    }
                } else {
                    var clean = lowered
                    while clean.hasPrefix("*.") {
                        clean = String(clean.dropFirst(2))
                    }
                    while clean.hasPrefix(".") {
                        clean = String(clean.dropFirst())
                    }
                    clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    if !clean.isEmpty, !domains.contains(clean) {
                        domains.append(clean)
                    }
                }
            }
        }

        if forceProxyLoopback {
            domains.removeAll { isLoopbackHost($0) || $0.hasSuffix(".localhost") }
            cidrs.removeAll { cidr in
                cidr.contains(ipString: "127.0.0.1") || cidr.contains(ipString: "::1")
            }
        }

        return ParsedBypassRules(
            excludedDomains: domains,
            excludedCIDRs: cidrs,
            excludeSimpleHostnames: excludeSimple
        )
    }

    private enum FixedProxySlot {
        case socks
        case httpOnly
        case httpsOnly
        case httpAndHTTPS
    }

    private struct ParsedFixedProxy {
        let slot: FixedProxySlot
        let host: String
        let port: UInt16
        let username: String?
        let password: String?
    }

    private static func parseFixedProxyEndpoint(
        _ entry: String,
        targetPrefix: String?
    ) -> ParsedFixedProxy? {
        if let targetPrefix,
           targetPrefix != "http" && targetPrefix != "https" && targetPrefix != "socks" {
            return nil
        }

        let scheme: String?
        let authority: Substring
        if let sepRange = entry.range(of: "://") {
            scheme = entry[..<sepRange.lowerBound].lowercased()
            authority = entry[sepRange.upperBound...]
        } else {
            scheme = nil
            authority = Substring(entry)
        }

        guard !authority.isEmpty, !authority.contains("/") else { return nil }

        let username: String?
        let password: String?
        let hostPort: Substring
        if let atIdx = authority.lastIndex(of: "@") {
            let userInfo = authority[..<atIdx]
            hostPort = authority[authority.index(after: atIdx)...]
            if let colonIdx = userInfo.firstIndex(of: ":") {
                let rawUser = String(userInfo[..<colonIdx])
                let rawPass = String(userInfo[userInfo.index(after: colonIdx)...])
                username = rawUser.removingPercentEncoding ?? rawUser
                password = rawPass.removingPercentEncoding ?? rawPass
            } else {
                let rawUser = String(userInfo)
                username = rawUser.removingPercentEncoding ?? rawUser
                password = ""
            }
        } else {
            username = nil
            password = nil
            hostPort = authority
        }

        let host: String
        let portStr: Substring?
        if hostPort.hasPrefix("[") {
            guard let closeIdx = hostPort.firstIndex(of: "]") else { return nil }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closeIdx])
            let rest = hostPort[hostPort.index(after: closeIdx)...]
            if rest.isEmpty {
                portStr = nil
            } else if rest.hasPrefix(":") {
                portStr = rest.dropFirst()
            } else {
                return nil
            }
        } else if let colonIdx = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colonIdx])
            portStr = hostPort[hostPort.index(after: colonIdx)...]
            if host.contains(":") { return nil }
        } else {
            host = String(hostPort)
            portStr = nil
        }

        guard !host.isEmpty else { return nil }

        let slot: FixedProxySlot
        let defaultPort: UInt16
        if let scheme {
            switch scheme {
            case "socks", "socks4", "socks5":
                slot = .socks
                defaultPort = 1080
            case "http":
                slot = (targetPrefix == "http") ? .httpOnly : (targetPrefix == "https" ? .httpsOnly : .httpAndHTTPS)
                defaultPort = 80
            default:
                return nil
            }
        } else {
            switch targetPrefix {
            case "socks":
                slot = .socks
                defaultPort = 1080
            case "http":
                slot = .httpOnly
                defaultPort = 80
            case "https":
                slot = .httpsOnly
                defaultPort = 443
            case nil:
                slot = .httpAndHTTPS
                defaultPort = 80
            default:
                return nil
            }
        }

        let port: UInt16
        if let portStr {
            guard let parsed = UInt16(portStr), parsed >= 1 else { return nil }
            port = parsed
        } else {
            port = defaultPort
        }

        return ParsedFixedProxy(
            slot: slot,
            host: host,
            port: port,
            username: username,
            password: password
        )
    }
}
