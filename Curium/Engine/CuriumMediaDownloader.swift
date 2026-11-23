import AVFoundation
import CuriumEngineContract
import Foundation
import os

/// Authenticated request metadata captured from the active browser tab and profile
/// for direct media fetches, HLS playlist inspection, and segment downloads.
struct CuriumMediaRequestContext: Equatable, Sendable {
    let cookieHeader: String?
    let userAgent: String?
    let referrer: URL?
    let origin: String?
    let proxy: CuriumProxyConfig

    init(
        cookieHeader: String? = nil,
        userAgent: String? = nil,
        referrer: URL? = nil,
        origin: String? = nil,
        proxy: CuriumProxyConfig = .system
    ) {
        self.cookieHeader = cookieHeader
        self.userAgent = userAgent
        self.referrer = referrer
        self.origin = origin
        self.proxy = proxy
    }
}

enum CuriumMediaDownloadError: LocalizedError, Equatable, Sendable {
    case disallowedURLScheme(String)
    case blockedPrivateNetworkHost(String)
    case invalidHTTPResponse
    case httpStatusError(Int)
    case responseTooLarge(maxBytes: Int)
    case byteRangeMismatch(expected: Int, actual: Int)
    case liveStreamUnsupported
    case drmUnsupported(String)
    case emptyPlaylist
    case invalidAESKeyLength(Int)
    case audioMuxFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .disallowedURLScheme(let detail):
            return "Blocked unsupported media URL scheme (\(detail))."
        case .blockedPrivateNetworkHost(let host):
            return "Blocked private or local network target (\(host)) from a public page."
        case .invalidHTTPResponse:
            return "Server returned an invalid HTTP response."
        case .httpStatusError(let code):
            return "Media server responded with HTTP \(code)."
        case .responseTooLarge(let maxBytes):
            return "Response exceeded the \(maxBytes)-byte safety limit."
        case .byteRangeMismatch(let expected, let actual):
            return "Server returned \(actual) bytes for a \(expected)-byte HLS range request."
        case .liveStreamUnsupported:
            return "Live HLS streams cannot be downloaded while broadcasting."
        case .drmUnsupported(let method):
            return "DRM-protected stream (\(method)) cannot be downloaded."
        case .emptyPlaylist:
            return "No downloadable media segments were found in the HLS playlist."
        case .invalidAESKeyLength(let count):
            return "AES-128 key response had invalid length (\(count) bytes; expected 16)."
        case .audioMuxFailed(let detail):
            return "Failed to combine separate HLS audio track: \(detail)"
        case .cancelled:
            return "Download was cancelled."
        }
    }
}

/// Ephemeral, proxy-aware, scheme-guarded networking primitives for Media Radar & downloads.
enum CuriumMediaNetworking {
    private static let keyHTTPSEnable = "HTTPSEnable"
    private static let keyHTTPSProxy = "HTTPSProxy"
    private static let keyHTTPSPort = "HTTPSPort"
    private static let keyHTTPEnable = "HTTPEnable"
    private static let keyHTTPProxy = "HTTPProxy"
    private static let keyHTTPPort = "HTTPPort"
    private static let keySOCKSEnable = "SOCKSEnable"
    private static let keySOCKSProxy = "SOCKSProxy"
    private static let keySOCKSPort = "SOCKSPort"
    private static let keyExceptionsList = "ExceptionsList"
    private static let keyExcludeSimpleHostnames = "ExcludeSimpleHostnames"

    enum RedirectValidationResult: Equatable, Sendable {
        case allowed(URLRequest, needsCookieRefresh: Bool)
        case rejectedScheme(String)
        case rejectedPrivateNetwork(String)
    }

    /// Scheme-, host-, and directory-path-scoped cookie cache (RFC 6265) with coalesced
    /// `@MainActor` lookups so large CDN playlists hop once per scope while never leaking
    /// `Secure` cookies over plaintext `http://` or across diverging paths.
    actor HostCookieCache {
        struct ScopeKey: Hashable, Sendable {
            let scheme: String
            let host: String
            let directoryPath: String
        }

        private let baseScope: ScopeKey?
        private let baseCookie: String?
        private let provider: (@MainActor @Sendable (URL) async -> String?)?
        private var resolvedByScope: [ScopeKey: String?] = [:]
        private var inFlightByScope: [ScopeKey: Task<String?, Never>] = [:]

        init(
            baseURL: URL?,
            baseCookie: String?,
            provider: (@MainActor @Sendable (URL) async -> String?)?
        ) {
            self.baseScope = baseURL.flatMap(Self.scopeKey(for:))
            self.baseCookie = baseCookie
            self.provider = provider
        }

        nonisolated static func scopeKey(for url: URL) -> ScopeKey? {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased(),
                  !host.isEmpty else {
                return nil
            }
            let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath
                ?? url.path(percentEncoded: true)
            let normalizedPath = normalizeDotSegments(in: rawPath)
            let directoryPath: String
            if normalizedPath.isEmpty || !normalizedPath.hasPrefix("/") {
                directoryPath = "/"
            } else if normalizedPath.hasSuffix("/") {
                directoryPath = normalizedPath
            } else if let lastSlash = normalizedPath.lastIndex(of: "/") {
                directoryPath = String(normalizedPath[...lastSlash])
            } else {
                directoryPath = "/"
            }
            return ScopeKey(scheme: scheme, host: host, directoryPath: directoryPath)
        }

        /// Deterministically resolves `.` and `..` path segments per RFC 3986 §5.2.4 so
        /// path-traversal URLs (e.g. `/private/v1/../../public/seg.ts`) normalize to `/public/seg.ts`
        /// across all Foundation `URL` implementations.
        private nonisolated static func normalizeDotSegments(in rawPath: String) -> String {
            guard !rawPath.isEmpty else { return "/" }
            let hadTrailingSlash = rawPath.hasSuffix("/") || rawPath.hasSuffix("/.") || rawPath.hasSuffix("/..")
            var stack: [Substring] = []
            for segment in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
                if segment == "." {
                    continue
                } else if segment == ".." {
                    if !stack.isEmpty {
                        stack.removeLast()
                    }
                } else {
                    stack.append(segment)
                }
            }
            if stack.isEmpty {
                return "/"
            }
            let joined = "/" + stack.joined(separator: "/")
            return hadTrailingSlash ? joined + "/" : joined
        }

        func cookieHeader(for url: URL) async -> String? {
            guard let targetScope = Self.scopeKey(for: url) else {
                return nil
            }
            if let baseScope, targetScope == baseScope {
                return baseCookie
            }
            if let cached = resolvedByScope[targetScope] {
                return cached
            }
            if let existingTask = inFlightByScope[targetScope] {
                return await existingTask.value
            }
            guard let provider else {
                resolvedByScope[targetScope] = nil
                return nil
            }
            let lookupTask = Task<String?, Never> {
                await provider(url)
            }
            inFlightByScope[targetScope] = lookupTask
            let resolved = await lookupTask.value
            inFlightByScope.removeValue(forKey: targetScope)
            resolvedByScope[targetScope] = resolved
            return resolved
        }
    }

    /// Maps `CuriumProxyConfig` to a `URLSessionConfiguration.connectionProxyDictionary`.
    /// - `.system`: returns `nil` (inherits OS proxy configuration).
    /// - `.direct`: returns `[:]` (explicitly bypasses system proxy).
    /// - `.fixed`: parses `http://`, `socks5://` / `socks://` / `socks4://` and Chromium
    ///   `scheme=host:port` clauses. Fails closed (`127.0.0.1:1`) on `https://` proxy schemes
    ///   (CFNetwork `HTTPSProxy` is plaintext HTTP `CONNECT`, not TLS-to-proxy) and blackholes
    ///   any unconfigured HTTP or HTTPS slot when `SOCKSEnable == nil` so fixed-proxy profiles
    ///   never leak real IP. Strips/honors Chromium's `<-loopback>` directive.
    static func proxyDictionary(for proxy: CuriumProxyConfig) -> [AnyHashable: Any]? {
        switch proxy {
        case .system:
            return nil
        case .direct:
            return [:]
        case .fixed(let rules, let bypassRules):
            var dict: [AnyHashable: Any] = [:]
            let clauses = rules.split(separator: ";", omittingEmptySubsequences: true)

            for rawClause in clauses {
                let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clause.isEmpty else { continue }

                let targetPrefix: String?
                let uriList: String
                if let eqIdx = clause.firstIndex(of: "=") {
                    targetPrefix = clause[..<eqIdx]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    uriList = String(clause[clause.index(after: eqIdx)...])
                } else {
                    targetPrefix = nil
                    uriList = clause
                }

                // Use the first valid proxy server in a comma-separated fallback chain,
                // failing closed on explicit `https://` TLS-to-proxy schemes rather than
                // downgrading them to plaintext CFNetwork HTTP `CONNECT` or a fallback entry.
                for rawEntry in uriList.split(separator: ",", omittingEmptySubsequences: true) {
                    let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                    let loweredEntry = entry.lowercased()
                    guard !entry.isEmpty, loweredEntry != "direct://" else { continue }
                    if loweredEntry.hasPrefix("https://") {
                        break
                    }
                    guard let parsed = parseProxyEndpoint(entry, targetPrefix: targetPrefix) else { continue }

                    switch parsed.kind {
                    case .socks:
                        if dict[keySOCKSEnable] == nil {
                            dict[keySOCKSEnable] = 1
                            dict[keySOCKSProxy] = parsed.host
                            dict[keySOCKSPort] = parsed.port
                        }
                    case .httpOnly:
                        if dict[keyHTTPEnable] == nil {
                            dict[keyHTTPEnable] = 1
                            dict[keyHTTPProxy] = parsed.host
                            dict[keyHTTPPort] = parsed.port
                        }
                    case .httpsOnly:
                        if dict[keyHTTPSEnable] == nil {
                            dict[keyHTTPSEnable] = 1
                            dict[keyHTTPSProxy] = parsed.host
                            dict[keyHTTPSPort] = parsed.port
                        }
                    case .httpAndHTTPS:
                        if dict[keyHTTPEnable] == nil {
                            dict[keyHTTPEnable] = 1
                            dict[keyHTTPProxy] = parsed.host
                            dict[keyHTTPPort] = parsed.port
                        }
                        if dict[keyHTTPSEnable] == nil {
                            dict[keyHTTPSEnable] = 1
                            dict[keyHTTPSProxy] = parsed.host
                            dict[keyHTTPSPort] = parsed.port
                        }
                    }
                    break
                }
            }

            if let bypassRules {
                let tokens = bypassRules
                    .split { $0 == "," || $0 == ";" }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                var exceptions: [String] = []
                var forceProxyLoopback = false
                for token in tokens {
                    let lowered = token.lowercased()
                    if lowered == "<local>" {
                        dict[keyExcludeSimpleHostnames] = 1
                    } else if lowered == "<-loopback>" {
                        forceProxyLoopback = true
                    } else {
                        exceptions.append(token)
                    }
                }
                if forceProxyLoopback {
                    exceptions.removeAll { token in
                        let lowered = token.lowercased()
                        return lowered == "localhost"
                            || lowered.hasPrefix("localhost:")
                            || lowered == "127.0.0.1"
                            || lowered == "::1"
                            || lowered == "[::1]"
                            || lowered.hasPrefix("[::1]:")
                            || lowered.hasPrefix("::1/")
                            || lowered.hasPrefix("127.")
                            || lowered.hasSuffix(".localhost")
                    }
                }
                if !exceptions.isEmpty {
                    dict[keyExceptionsList] = exceptions
                }
            }

            if dict[keySOCKSEnable] == nil && dict[keyHTTPEnable] == nil && dict[keyHTTPSEnable] == nil {
                // Fail closed: never degrade a fixed-proxy profile to direct (real-IP) egress.
                dict[keySOCKSEnable] = 1
                dict[keySOCKSProxy] = "127.0.0.1"
                dict[keySOCKSPort] = 1
            } else if dict[keySOCKSEnable] == nil {
                // Without a SOCKS catch-all, blackhole any unconfigured HTTP or HTTPS slot
                // so single-scheme rules never egress the uncovered scheme over the real IP.
                if dict[keyHTTPEnable] == nil {
                    dict[keyHTTPEnable] = 1
                    dict[keyHTTPProxy] = "127.0.0.1"
                    dict[keyHTTPPort] = 1
                }
                if dict[keyHTTPSEnable] == nil {
                    dict[keyHTTPSEnable] = 1
                    dict[keyHTTPSProxy] = "127.0.0.1"
                    dict[keyHTTPSPort] = 1
                }
            }

            return dict
        }
    }

    static func makeEphemeralSession(
        proxy: CuriumProxyConfig,
        delegate: (any URLSessionDelegate)? = nil,
        timeoutIntervalForResource: TimeInterval = 60 * 60
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = timeoutIntervalForResource
        if let proxyDict = proxyDictionary(for: proxy) {
            config.connectionProxyDictionary = proxyDict
        }
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    static func makeRequest(
        url: URL,
        context: CuriumMediaRequestContext,
        byteRange: (length: Int, offset: Int?)? = nil,
        includeOrigin: Bool = true
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false

        if let cookie = context.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let userAgent = context.userAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referrer = context.referrer,
           CuriumHLSParser.isAllowedHTTPURL(referrer),
           !isHTTPSDowngrade(from: referrer, to: url) {
            request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if includeOrigin,
           let origin = context.origin?.trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty,
           origin.lowercased() != "null" {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let byteRange, byteRange.length > 0 {
            let start = max(0, byteRange.offset ?? 0)
            let (endInclusive, overflow) = start.addingReportingOverflow(byteRange.length - 1)
            if !overflow {
                request.setValue("bytes=\(start)-\(endInclusive)", forHTTPHeaderField: "Range")
            }
        }
        return request
    }

    /// Fetches and parses an HLS Master or Media playlist over an ephemeral, scheme- & SSRF-guarded session.
    static func inspectHLS(
        url: URL,
        context: CuriumMediaRequestContext,
        cookieProvider: (@MainActor @Sendable (URL) async -> String?)? = nil
    ) async throws -> CuriumHLSMasterInspection {
        guard CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumMediaDownloadError.disallowedURLScheme(url.scheme ?? "unknown")
        }
        if let referrer = context.referrer,
           !CuriumHLSParser.isAllowedTargetURL(url, originatingURL: referrer) {
            throw CuriumMediaDownloadError.blockedPrivateNetworkHost(url.host ?? "private")
        }
        if let originURL = originURL(from: context.origin),
           !CuriumHLSParser.isAllowedTargetURL(url, originatingURL: originURL) {
            throw CuriumMediaDownloadError.blockedPrivateNetworkHost(url.host ?? "private")
        }
        let cookieCache = HostCookieCache(
            baseURL: url,
            baseCookie: context.cookieHeader,
            provider: cookieProvider
        )
        let coordinator = BoundedFetchCoordinator()
        let session = makeEphemeralSession(proxy: context.proxy, delegate: coordinator)
        defer { session.finishTasksAndInvalidate() }

        let request = makeRequest(url: url, context: context)
        let originatingHostIsPublic = isOriginatingHostPublic(
            url: url,
            referrer: context.referrer,
            origin: context.origin
        )
        let cookieResolver: (@Sendable (URL) async -> String?)? = cookieProvider == nil
            ? nil
            : { @Sendable targetURL in
                await cookieCache.cookieHeader(for: targetURL)
            }
        let (data, finalURL) = try await coordinator.fetchData(
            request: request,
            session: session,
            maxBytes: CuriumHLSParser.maxPlaylistBytes,
            originatingHostIsPublic: originatingHostIsPublic,
            cookieResolver: cookieResolver
        )
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return try CuriumHLSParser.parseMasterOrMedia(text: text, baseURL: finalURL)
    }

    /// Validates an HTTP response body for an `EXT-X-BYTERANGE` request:
    /// - `206 Partial Content`: requires exact length match (and matching `Content-Range` if present).
    /// - `200 OK`: slices `[start ..< start + length]` and fails closed if truncated or out-of-bounds.
    static func validateByteRangeResponse(
        data: Data,
        statusCode: Int,
        contentRangeHeader: String? = nil,
        byteRange: (length: Int, offset: Int?)
    ) throws -> Data {
        let expectedLength = byteRange.length
        guard expectedLength > 0 else {
            throw CuriumMediaDownloadError.byteRangeMismatch(expected: expectedLength, actual: data.count)
        }
        let start = max(0, byteRange.offset ?? 0)
        let (endExclusive, overflow) = start.addingReportingOverflow(expectedLength)
        guard !overflow else {
            throw CuriumMediaDownloadError.byteRangeMismatch(expected: expectedLength, actual: data.count)
        }

        if statusCode == 206 {
            if let contentRangeHeader,
               let parsed = parseContentRangeHeader(contentRangeHeader) {
                let (advertisedLength, lenOverflow) = (parsed.end - parsed.start).addingReportingOverflow(1)
                guard !lenOverflow, parsed.start == start, advertisedLength == expectedLength else {
                    throw CuriumMediaDownloadError.byteRangeMismatch(
                        expected: expectedLength,
                        actual: lenOverflow ? Int.max : max(0, advertisedLength)
                    )
                }
            }
            guard data.count == expectedLength else {
                throw CuriumMediaDownloadError.byteRangeMismatch(expected: expectedLength, actual: data.count)
            }
            return data
        }

        if statusCode == 200 {
            guard endExclusive <= data.count else {
                throw CuriumMediaDownloadError.byteRangeMismatch(
                    expected: expectedLength,
                    actual: max(0, data.count - start)
                )
            }
            return Data(data[start..<endExclusive])
        }

        throw CuriumMediaDownloadError.byteRangeMismatch(expected: expectedLength, actual: data.count)
    }

    // MARK: - Proxy Parsing & Redirect Helpers

    private enum ProxyEndpointKind {
        case socks
        case httpOnly
        case httpsOnly
        case httpAndHTTPS
    }

    private struct ParsedProxyEndpoint {
        let kind: ProxyEndpointKind
        let host: String
        let port: Int
    }

    private static func parseProxyEndpoint(
        _ entry: String,
        targetPrefix: String?
    ) -> ParsedProxyEndpoint? {
        if let targetPrefix,
           targetPrefix != "http" && targetPrefix != "https" && targetPrefix != "socks" {
            return nil
        }

        let scheme: String?
        let hostPort: Substring
        if let sepRange = entry.range(of: "://") {
            scheme = entry[..<sepRange.lowerBound].lowercased()
            hostPort = entry[sepRange.upperBound...]
        } else {
            scheme = nil
            hostPort = Substring(entry)
        }

        guard !hostPort.isEmpty, !hostPort.contains("/") else { return nil }

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

        let kind: ProxyEndpointKind
        let defaultPort: Int
        if let scheme {
            switch scheme {
            case "socks", "socks4", "socks5":
                kind = .socks
                defaultPort = 1080
            case "https":
                // CFNetwork's `HTTPSProxy` configures a plaintext HTTP `CONNECT` proxy, not TLS-to-proxy.
                // Fail closed rather than downgrading an explicit `https://` TLS proxy to cleartext.
                return nil
            case "http":
                kind = (targetPrefix == "http") ? .httpOnly : (targetPrefix == "https" ? .httpsOnly : .httpAndHTTPS)
                defaultPort = 80
            default:
                return nil
            }
        } else {
            switch targetPrefix {
            case "socks":
                kind = .socks
                defaultPort = 1080
            case "http":
                kind = .httpOnly
                defaultPort = 80
            case "https":
                kind = .httpsOnly
                defaultPort = 443
            case nil:
                kind = .httpAndHTTPS
                defaultPort = 80
            default:
                return nil
            }
        }

        let resolvedPort: Int
        if let portStr {
            guard let parsed = Int(portStr), (1...65535).contains(parsed) else { return nil }
            resolvedPort = parsed
        } else {
            resolvedPort = defaultPort
        }

        return ParsedProxyEndpoint(kind: kind, host: host, port: resolvedPort)
    }

    static func originURL(from rawOrigin: String?) -> URL? {
        guard let trimmed = rawOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.lowercased() != "null",
              let parsed = URL(string: trimmed),
              CuriumHLSParser.isAllowedHTTPURL(parsed) else {
            return nil
        }
        return parsed
    }

    static func isOriginatingHostPublic(url: URL, referrer: URL?, origin: String? = nil) -> Bool {
        if let referrer, CuriumHLSParser.isAllowedHTTPURL(referrer), !CuriumHLSParser.isPrivateOrLocalURL(referrer) {
            return true
        }
        if let originURL = originURL(from: origin), !CuriumHLSParser.isPrivateOrLocalURL(originURL) {
            return true
        }
        return CuriumHLSParser.isAllowedHTTPURL(url) && !CuriumHLSParser.isPrivateOrLocalURL(url)
    }

    private static func isHTTPSDowngrade(from sourceURL: URL, to targetURL: URL) -> Bool {
        sourceURL.scheme?.lowercased() == "https" && targetURL.scheme?.lowercased() == "http"
    }

    private static func parseContentRangeHeader(_ raw: String) -> (start: Int, end: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard let rangePart = body.split(separator: "/", maxSplits: 1).first else { return nil }
        let bounds = rangePart.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1]),
              start >= 0,
              end >= start else {
            return nil
        }
        return (start, end)
    }

    static func validateAndSanitizeRedirectRequest(
        _ proposed: URLRequest,
        from previousURL: URL?,
        originatingHostIsPublic: Bool
    ) -> RedirectValidationResult {
        guard let targetURL = proposed.url,
              CuriumHLSParser.isAllowedHTTPURL(targetURL) else {
            return .rejectedScheme(proposed.url?.scheme ?? "unknown")
        }
        if originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(targetURL) {
            return .rejectedPrivateNetwork(targetURL.host ?? "private")
        }

        var sanitized = proposed
        sanitized.httpShouldHandleCookies = false

        // Strip Referer across https -> http downgrades (checking both previous hop and Referer header).
        if targetURL.scheme?.lowercased() == "http" {
            if let previousURL, previousURL.scheme?.lowercased() == "https" {
                sanitized.setValue(nil, forHTTPHeaderField: "Referer")
            } else if let refHeader = sanitized.value(forHTTPHeaderField: "Referer"),
                      let refURL = URL(string: refHeader),
                      refURL.scheme?.lowercased() == "https" {
                sanitized.setValue(nil, forHTTPHeaderField: "Referer")
            }
        }

        // RFC 6265 cookie safety: keep existing Cookie only on exact (scheme, host, directoryPath)
        // match; strip and trigger cookieProvider refresh across host, scheme, or path changes.
        let prevScope = previousURL.flatMap(HostCookieCache.scopeKey(for:))
        let nextScope = HostCookieCache.scopeKey(for: targetURL)
        if prevScope == nil || prevScope != nextScope {
            sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
            return .allowed(sanitized, needsCookieRefresh: true)
        }
        return .allowed(sanitized, needsCookieRefresh: false)
    }

    static func sanitizeRedirectRequest(
        _ proposed: URLRequest,
        from previousURL: URL?,
        originatingHostIsPublic: Bool,
        cookieResolver: (@Sendable (URL) async -> String?)? = nil
    ) async -> RedirectValidationResult {
        let initial = validateAndSanitizeRedirectRequest(
            proposed,
            from: previousURL,
            originatingHostIsPublic: originatingHostIsPublic
        )
        guard case .allowed(var sanitized, let needsCookieRefresh) = initial else {
            return initial
        }
        if needsCookieRefresh, let cookieResolver, let targetURL = sanitized.url {
            if let refreshed = await cookieResolver(targetURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !refreshed.isEmpty {
                sanitized.setValue(refreshed, forHTTPHeaderField: "Cookie")
            }
        }
        return .allowed(sanitized, needsCookieRefresh: false)
    }
}

// MARK: - Bounded Fetch Coordinator (Playlists, Keys, Segments)

private final class BoundedFetchCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct ActiveFetch {
        let originatingHostIsPublic: Bool
        let maxBytes: Int
        let expectedByteRange: (length: Int, offset: Int?)?
        let cookieResolver: (@Sendable (URL) async -> String?)?
        var data = Data()
        var currentURL: URL
        var finalURL: URL
        var statusCode: Int = 0
        var contentRangeHeader: String?
        var overrideError: (any Error)?
        var continuation: CheckedContinuation<(Data, URL), any Error>?
    }

    private let state = OSAllocatedUnfairLock<[Int: ActiveFetch]>(initialState: [:])

    func fetchData(
        request: URLRequest,
        session: URLSession,
        maxBytes: Int,
        expectedByteRange: (length: Int, offset: Int?)? = nil,
        originatingHostIsPublic: Bool = false,
        cookieResolver: (@Sendable (URL) async -> String?)? = nil
    ) async throws -> (Data, URL) {
        guard let url = request.url, CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumMediaDownloadError.disallowedURLScheme(request.url?.scheme ?? "unknown")
        }
        if originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(url) {
            throw CuriumMediaDownloadError.blockedPrivateNetworkHost(url.host ?? "private")
        }

        let dataTask = session.dataTask(with: request)
        let taskID = dataTask.taskIdentifier

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { map in
                    map[taskID] = ActiveFetch(
                        originatingHostIsPublic: originatingHostIsPublic,
                        maxBytes: maxBytes,
                        expectedByteRange: expectedByteRange,
                        cookieResolver: cookieResolver,
                        data: Data(),
                        currentURL: url,
                        finalURL: url,
                        statusCode: 0,
                        contentRangeHeader: nil,
                        overrideError: nil,
                        continuation: continuation
                    )
                }
                dataTask.resume()
            }
        } onCancel: {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let snapshot = state.withLock { map -> (URL?, Bool, (@Sendable (URL) async -> String?)?)? in
            guard let entry = map[task.taskIdentifier] else { return nil }
            return (response.url ?? entry.currentURL, entry.originatingHostIsPublic, entry.cookieResolver)
        }
        guard let (previousURL, originatingHostIsPublic, cookieResolver) = snapshot else {
            completionHandler(nil)
            return
        }

        let validation = CuriumMediaNetworking.validateAndSanitizeRedirectRequest(
            request,
            from: previousURL,
            originatingHostIsPublic: originatingHostIsPublic
        )
        switch validation {
        case .rejectedScheme(let scheme):
            state.withLock { map in
                map[task.taskIdentifier]?.overrideError = CuriumMediaDownloadError.disallowedURLScheme(scheme)
            }
            task.cancel()
            completionHandler(nil)

        case .rejectedPrivateNetwork(let host):
            state.withLock { map in
                map[task.taskIdentifier]?.overrideError = CuriumMediaDownloadError.blockedPrivateNetworkHost(host)
            }
            task.cancel()
            completionHandler(nil)

        case .allowed(let sanitized, let needsCookieRefresh):
            guard let targetURL = sanitized.url else {
                task.cancel()
                completionHandler(nil)
                return
            }
            guard needsCookieRefresh, let resolver = cookieResolver else {
                state.withLock { map in
                    map[task.taskIdentifier]?.currentURL = targetURL
                    map[task.taskIdentifier]?.finalURL = targetURL
                }
                completionHandler(sanitized)
                return
            }
            let taskID = task.taskIdentifier
            Task { [weak self] in
                guard let self else {
                    completionHandler(nil)
                    return
                }
                var updated = sanitized
                if let refreshed = await resolver(targetURL)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !refreshed.isEmpty {
                    updated.setValue(refreshed, forHTTPHeaderField: "Cookie")
                }
                let stillActive = self.state.withLock { map -> Bool in
                    guard map[taskID] != nil else { return false }
                    map[taskID]?.currentURL = targetURL
                    map[taskID]?.finalURL = targetURL
                    return true
                }
                completionHandler(stillActive ? updated : nil)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            state.withLock { map in
                map[dataTask.taskIdentifier]?.overrideError = CuriumMediaDownloadError.invalidHTTPResponse
            }
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            state.withLock { map in
                map[dataTask.taskIdentifier]?.overrideError = CuriumMediaDownloadError.httpStatusError(http.statusCode)
            }
            completionHandler(.cancel)
            return
        }

        let responseCheckError: (any Error)? = state.withLock { map -> (any Error)? in
            guard var entry = map[dataTask.taskIdentifier] else { return nil }
            if let responseURL = http.url {
                guard CuriumHLSParser.isAllowedHTTPURL(responseURL) else {
                    let err = CuriumMediaDownloadError.disallowedURLScheme(responseURL.scheme ?? "unknown")
                    entry.overrideError = err
                    map[dataTask.taskIdentifier] = entry
                    return err
                }
                if entry.originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(responseURL) {
                    let err = CuriumMediaDownloadError.blockedPrivateNetworkHost(responseURL.host ?? "private")
                    entry.overrideError = err
                    map[dataTask.taskIdentifier] = entry
                    return err
                }
                entry.currentURL = responseURL
                entry.finalURL = responseURL
            }

            entry.statusCode = http.statusCode
            entry.contentRangeHeader = http.value(forHTTPHeaderField: "Content-Range")

            if http.expectedContentLength > Int64(entry.maxBytes) {
                let err = CuriumMediaDownloadError.responseTooLarge(maxBytes: entry.maxBytes)
                entry.overrideError = err
                map[dataTask.taskIdentifier] = entry
                return err
            }

            if let byteRange = entry.expectedByteRange {
                if http.statusCode == 206 {
                    if http.expectedContentLength >= 0 && http.expectedContentLength != Int64(byteRange.length) {
                        let err = CuriumMediaDownloadError.byteRangeMismatch(
                            expected: byteRange.length,
                            actual: Int(min(Int64(Int.max), http.expectedContentLength))
                        )
                        entry.overrideError = err
                        map[dataTask.taskIdentifier] = entry
                        return err
                    }
                } else if http.statusCode == 200 {
                    let start = max(0, byteRange.offset ?? 0)
                    let (endExclusive, overflow) = start.addingReportingOverflow(byteRange.length)
                    if overflow || (http.expectedContentLength >= 0 && http.expectedContentLength < Int64(endExclusive)) {
                        let actualAvail = http.expectedContentLength >= 0
                            ? max(0, Int(min(Int64(Int.max), http.expectedContentLength)) - start)
                            : 0
                        let err = CuriumMediaDownloadError.byteRangeMismatch(expected: byteRange.length, actual: actualAvail)
                        entry.overrideError = err
                        map[dataTask.taskIdentifier] = entry
                        return err
                    }
                } else {
                    let err = CuriumMediaDownloadError.byteRangeMismatch(expected: byteRange.length, actual: 0)
                    entry.overrideError = err
                    map[dataTask.taskIdentifier] = entry
                    return err
                }
            }

            map[dataTask.taskIdentifier] = entry
            return nil
        }

        if responseCheckError != nil {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = state.withLock { map -> Bool in
            guard var entry = map[dataTask.taskIdentifier] else { return false }
            if entry.data.count + data.count > entry.maxBytes {
                entry.overrideError = CuriumMediaDownloadError.responseTooLarge(maxBytes: entry.maxBytes)
                map[dataTask.taskIdentifier] = entry
                return true
            }
            entry.data.append(data)
            map[dataTask.taskIdentifier] = entry
            return false
        }
        if exceeded {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completed = state.withLock { map -> ActiveFetch? in
            map.removeValue(forKey: task.taskIdentifier)
        }
        guard let completed, let continuation = completed.continuation else { return }

        if let overrideError = completed.overrideError {
            continuation.resume(throwing: overrideError)
            return
        }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
            return
        }
        if let byteRange = completed.expectedByteRange {
            do {
                let validated = try CuriumMediaNetworking.validateByteRangeResponse(
                    data: completed.data,
                    statusCode: completed.statusCode,
                    contentRangeHeader: completed.contentRangeHeader,
                    byteRange: byteRange
                )
                continuation.resume(returning: (validated, completed.finalURL))
            } catch {
                continuation.resume(throwing: error)
            }
            return
        }
        continuation.resume(returning: (completed.data, completed.finalURL))
    }
}

// MARK: - Authenticated Direct Media Download Task

@MainActor
final class CuriumDirectMediaDownloadTask: NSObject, CrIOSDownloadTaskV1 {
    nonisolated static let resourceTimeoutInterval: TimeInterval = 86_400

    let downloadID: String
    let sourceTabID: String?
    let originalURL: URL?
    let suggestedFilename: String
    let mimeType: String?
    private let context: CuriumMediaRequestContext
    private let cookieProvider: (@MainActor @Sendable (URL) async -> String?)?

    private var settledTotalBytes: Int64
    private var settledReceivedBytes: Int64 = 0
    private(set) var state: CrIOSDownloadState = .pending

    var totalBytes: Int64 {
        if let coordinator, state == .inProgress {
            let expected = coordinator.progressSnapshot().expected
            return expected > 0 ? expected : settledTotalBytes
        }
        return settledTotalBytes
    }

    var receivedBytes: Int64 {
        if let coordinator, state == .inProgress {
            return coordinator.progressSnapshot().received
        }
        return settledReceivedBytes
    }

    var isExplicitDownload: Bool { true }
    var isMainFrame: Bool { true }
    var httpMethod: String { "GET" }

    private var destinationURL: URL?
    private var completionHandler: (@MainActor (URL?, (any Error)?) -> Void)?
    private var coordinator: DirectDownloadCoordinator?

    init(
        downloadID: String = UUID().uuidString,
        sourceTabID: String? = nil,
        url: URL,
        suggestedFilename: String,
        mimeType: String? = nil,
        expectedBytes: Int64 = -1,
        context: CuriumMediaRequestContext,
        cookieProvider: (@MainActor @Sendable (URL) async -> String?)? = nil
    ) {
        self.downloadID = downloadID
        self.sourceTabID = sourceTabID
        self.originalURL = url
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.settledTotalBytes = expectedBytes > 0 ? expectedBytes : -1
        self.context = context
        self.cookieProvider = cookieProvider
        super.init()
    }

    func start(
        withDestinationURL destinationURL: URL,
        completion: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) {
        guard state == .pending else {
            completion(nil, CuriumMediaDownloadError.cancelled)
            return
        }
        guard let url = originalURL, CuriumHLSParser.isAllowedHTTPURL(url) else {
            state = .failed
            completion(nil, CuriumMediaDownloadError.disallowedURLScheme(originalURL?.scheme ?? "unknown"))
            return
        }
        if let referrer = context.referrer,
           !CuriumHLSParser.isAllowedTargetURL(url, originatingURL: referrer) {
            state = .failed
            completion(nil, CuriumMediaDownloadError.blockedPrivateNetworkHost(url.host ?? "private"))
            return
        }
        if let originURL = CuriumMediaNetworking.originURL(from: context.origin),
           !CuriumHLSParser.isAllowedTargetURL(url, originatingURL: originURL) {
            state = .failed
            completion(nil, CuriumMediaDownloadError.blockedPrivateNetworkHost(url.host ?? "private"))
            return
        }

        self.destinationURL = destinationURL
        self.completionHandler = completion
        self.state = .inProgress
        self.settledReceivedBytes = 0

        let originatingHostIsPublic = CuriumMediaNetworking.isOriginatingHostPublic(
            url: url,
            referrer: context.referrer,
            origin: context.origin
        )
        let provider = cookieProvider
        let cookieCache = provider.map {
            CuriumMediaNetworking.HostCookieCache(
                baseURL: url,
                baseCookie: context.cookieHeader,
                provider: $0
            )
        }

        let coordinator = DirectDownloadCoordinator(
            destinationURL: destinationURL,
            initialURL: url,
            originatingHostIsPublic: originatingHostIsPublic,
            cookieResolver: cookieCache.map { cache in
                { @Sendable targetURL in
                    await cache.cookieHeader(for: targetURL)
                }
            },
            onFinished: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleCoordinatorResult(result)
                }
            }
        )
        self.coordinator = coordinator

        let session = CuriumMediaNetworking.makeEphemeralSession(
            proxy: context.proxy,
            delegate: coordinator,
            timeoutIntervalForResource: Self.resourceTimeoutInterval
        )
        // Direct <video>/<audio> fetches are non-CORS; omit `Origin:` so strict S3/CDN WAFs accept them.
        let request = CuriumMediaNetworking.makeRequest(
            url: url,
            context: context,
            includeOrigin: false
        )
        let downloadTask = session.downloadTask(with: request)
        coordinator.attach(session: session, task: downloadTask)
        downloadTask.resume()
    }

    func cancel() {
        guard state == .pending || state == .inProgress else { return }
        if let coordinator {
            let snap = coordinator.progressSnapshot()
            settledReceivedBytes = snap.received
            if snap.expected > 0 {
                settledTotalBytes = snap.expected
            }
        }
        state = .cancelled
        let activeCoordinator = coordinator
        coordinator = nil
        activeCoordinator?.cancel()

        if let destinationURL {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        finishOnce(savedURL: nil, error: CuriumMediaDownloadError.cancelled)
    }

    private func handleCoordinatorResult(_ result: Result<(URL, Int64), any Error>) {
        if let coordinator {
            let snap = coordinator.progressSnapshot()
            settledReceivedBytes = snap.received
            if snap.expected > 0 {
                settledTotalBytes = snap.expected
            }
        }
        coordinator = nil
        switch result {
        case .success(let (savedURL, finalBytes)):
            guard state == .inProgress else {
                try? FileManager.default.removeItem(at: savedURL)
                return
            }
            if finalBytes > 0 {
                settledReceivedBytes = finalBytes
                settledTotalBytes = finalBytes
            }
            state = .completed
            finishOnce(savedURL: savedURL, error: nil)
        case .failure(let error):
            if state == .cancelled || error is CancellationError {
                state = .cancelled
                finishOnce(savedURL: nil, error: CuriumMediaDownloadError.cancelled)
            } else {
                state = .failed
                finishOnce(savedURL: nil, error: error)
            }
        }
    }

    private func finishOnce(savedURL: URL?, error: (any Error)?) {
        guard let completion = completionHandler else { return }
        completionHandler = nil
        completion(savedURL, error)
    }
}

private final class DirectDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct MutableState {
        var session: URLSession?
        var task: URLSessionDownloadTask?
        var currentURL: URL
        var cancelled = false
        var completed = false
        var movedSuccessfully = false
        var receivedBytes: Int64 = 0
        var expectedBytes: Int64 = -1
        var finalByteCount: Int64 = 0
        var recordedError: (any Error)?
    }

    private let destinationURL: URL
    private let originatingHostIsPublic: Bool
    private let cookieResolver: (@Sendable (URL) async -> String?)?
    private let onFinished: @Sendable (Result<(URL, Int64), any Error>) -> Void
    private let lock: OSAllocatedUnfairLock<MutableState>

    init(
        destinationURL: URL,
        initialURL: URL,
        originatingHostIsPublic: Bool,
        cookieResolver: (@Sendable (URL) async -> String?)?,
        onFinished: @escaping @Sendable (Result<(URL, Int64), any Error>) -> Void
    ) {
        self.destinationURL = destinationURL
        self.originatingHostIsPublic = originatingHostIsPublic
        self.cookieResolver = cookieResolver
        self.onFinished = onFinished
        self.lock = OSAllocatedUnfairLock(initialState: MutableState(currentURL: initialURL))
        super.init()
    }

    func attach(session: URLSession, task: URLSessionDownloadTask) {
        lock.withLock { state in
            state.session = session
            state.task = task
        }
    }

    func progressSnapshot() -> (received: Int64, expected: Int64) {
        lock.withLock { ($0.receivedBytes, $0.expectedBytes) }
    }

    func cancel() {
        let (session, task) = lock.withLock { state -> (URLSession?, URLSessionDownloadTask?) in
            state.cancelled = true
            let pair = (state.session, state.task)
            state.session = nil
            state.task = nil
            return pair
        }
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let (cancelled, previousURL) = lock.withLock { state in
            (state.cancelled, response.url ?? state.currentURL)
        }
        guard !cancelled else {
            completionHandler(nil)
            return
        }

        let validation = CuriumMediaNetworking.validateAndSanitizeRedirectRequest(
            request,
            from: previousURL,
            originatingHostIsPublic: originatingHostIsPublic
        )
        switch validation {
        case .rejectedScheme(let scheme):
            lock.withLock { state in
                state.recordedError = CuriumMediaDownloadError.disallowedURLScheme(scheme)
            }
            task.cancel()
            completionHandler(nil)

        case .rejectedPrivateNetwork(let host):
            lock.withLock { state in
                state.recordedError = CuriumMediaDownloadError.blockedPrivateNetworkHost(host)
            }
            task.cancel()
            completionHandler(nil)

        case .allowed(let sanitized, let needsCookieRefresh):
            guard let targetURL = sanitized.url else {
                task.cancel()
                completionHandler(nil)
                return
            }
            guard needsCookieRefresh, let resolver = cookieResolver else {
                lock.withLock { $0.currentURL = targetURL }
                completionHandler(sanitized)
                return
            }
            Task { [weak self] in
                guard let self else {
                    completionHandler(nil)
                    return
                }
                var updated = sanitized
                if let refreshed = await resolver(targetURL)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !refreshed.isEmpty {
                    updated.setValue(refreshed, forHTTPHeaderField: "Cookie")
                }
                let stillActive = self.lock.withLock { state -> Bool in
                    guard !state.cancelled, !state.completed else { return false }
                    state.currentURL = targetURL
                    return true
                }
                completionHandler(stillActive ? updated : nil)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.withLock { state in
            guard !state.cancelled else { return }
            state.receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                state.expectedBytes = totalBytesExpectedToWrite
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let cancelled = lock.withLock { $0.cancelled }
        guard !cancelled else { return }

        guard let http = downloadTask.response as? HTTPURLResponse else {
            lock.withLock { $0.recordedError = CuriumMediaDownloadError.invalidHTTPResponse }
            return
        }
        guard (200...299).contains(http.statusCode) else {
            lock.withLock { $0.recordedError = CuriumMediaDownloadError.httpStatusError(http.statusCode) }
            return
        }
        if let finalURL = http.url {
            if !CuriumHLSParser.isAllowedHTTPURL(finalURL) {
                lock.withLock { $0.recordedError = CuriumMediaDownloadError.disallowedURLScheme(finalURL.scheme ?? "unknown") }
                return
            }
            if originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(finalURL) {
                lock.withLock { $0.recordedError = CuriumMediaDownloadError.blockedPrivateNetworkHost(finalURL.host ?? "private") }
                return
            }
        }

        let fm = FileManager.default
        do {
            let parent = destinationURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)
            let attrs = try? fm.attributesOfItem(atPath: destinationURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            lock.withLock { state in
                state.movedSuccessfully = true
                state.finalByteCount = size
            }
        } catch {
            lock.withLock { $0.recordedError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        session.finishTasksAndInvalidate()
        let outcome: Result<(URL, Int64), any Error>? = lock.withLock { state in
            guard !state.completed else { return nil }
            state.completed = true
            state.session = nil
            state.task = nil

            if state.cancelled || (error as NSError?)?.code == NSURLErrorCancelled {
                return .failure(CancellationError())
            }
            if let recorded = state.recordedError {
                return .failure(recorded)
            }
            if let error {
                return .failure(error)
            }
            guard state.movedSuccessfully else {
                return .failure(CuriumMediaDownloadError.invalidHTTPResponse)
            }
            return .success((destinationURL, state.finalByteCount))
        }

        guard let outcome else { return }
        if case .failure = outcome {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        onFinished(outcome)
    }
}

// MARK: - Authenticated HLS Media Download Task (Pure Swift + CommonCrypto + AVFoundation)

@MainActor
final class CuriumHLSMediaDownloadTask: NSObject, CrIOSDownloadTaskV1 {
    nonisolated static let maxConcurrentSegments = 4
    private nonisolated static let maxSegmentRetries = 2
    nonisolated static let maxSegmentBytes = 64 * 1024 * 1024
    private nonisolated static let maxKeyBytes = 1024

    let downloadID: String
    let sourceTabID: String?
    let originalURL: URL?
    let audioPlaylistURL: URL?
    let masterPlaylistURL: URL?
    let suggestedFilename: String
    let mimeType: String?
    private let context: CuriumMediaRequestContext
    private let cookieProvider: (@MainActor @Sendable (URL) async -> String?)?

    private let progressLock = OSAllocatedUnfairLock<(received: Int64, total: Int64)>(initialState: (0, -1))
    private(set) var state: CrIOSDownloadState = .pending

    var totalBytes: Int64 {
        progressLock.withLock { $0.total }
    }

    var receivedBytes: Int64 {
        progressLock.withLock { $0.received }
    }

    var isExplicitDownload: Bool { true }
    var isMainFrame: Bool { true }
    var httpMethod: String { "GET" }

    private var runnerTask: Task<Void, Never>?
    private var completionHandler: (@MainActor (URL?, (any Error)?) -> Void)?

    init(
        downloadID: String = UUID().uuidString,
        sourceTabID: String? = nil,
        playlistURL: URL,
        audioPlaylistURL: URL? = nil,
        masterPlaylistURL: URL? = nil,
        suggestedFilename: String,
        mimeType: String? = nil,
        context: CuriumMediaRequestContext,
        cookieProvider: (@MainActor @Sendable (URL) async -> String?)? = nil
    ) {
        self.downloadID = downloadID
        self.sourceTabID = sourceTabID
        self.originalURL = playlistURL
        self.audioPlaylistURL = audioPlaylistURL
        self.masterPlaylistURL = masterPlaylistURL
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.context = context
        self.cookieProvider = cookieProvider
        super.init()
    }

    func start(
        withDestinationURL destinationURL: URL,
        completion: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) {
        guard state == .pending else {
            completion(nil, CuriumMediaDownloadError.cancelled)
            return
        }
        guard let playlistURL = originalURL, CuriumHLSParser.isAllowedHTTPURL(playlistURL) else {
            state = .failed
            completion(nil, CuriumMediaDownloadError.disallowedURLScheme(originalURL?.scheme ?? "unknown"))
            return
        }
        let originURL = CuriumMediaNetworking.originURL(from: context.origin)
        if let referrer = context.referrer,
           !CuriumHLSParser.isAllowedTargetURL(playlistURL, originatingURL: referrer) {
            state = .failed
            completion(nil, CuriumMediaDownloadError.blockedPrivateNetworkHost(playlistURL.host ?? "private"))
            return
        }
        if let originURL,
           !CuriumHLSParser.isAllowedTargetURL(playlistURL, originatingURL: originURL) {
            state = .failed
            completion(nil, CuriumMediaDownloadError.blockedPrivateNetworkHost(playlistURL.host ?? "private"))
            return
        }
        if let audioPlaylistURL {
            guard CuriumHLSParser.isAllowedHTTPURL(audioPlaylistURL) else {
                state = .failed
                completion(nil, CuriumMediaDownloadError.disallowedURLScheme(audioPlaylistURL.scheme ?? "unknown"))
                return
            }
            if !CuriumHLSParser.isAllowedTargetURL(audioPlaylistURL, originatingURL: playlistURL)
                || (context.referrer != nil && !CuriumHLSParser.isAllowedTargetURL(audioPlaylistURL, originatingURL: context.referrer))
                || (originURL != nil && !CuriumHLSParser.isAllowedTargetURL(audioPlaylistURL, originatingURL: originURL)) {
                state = .failed
                completion(nil, CuriumMediaDownloadError.blockedPrivateNetworkHost(audioPlaylistURL.host ?? "private"))
                return
            }
        }

        state = .inProgress
        progressLock.withLock { $0 = (0, -1) }
        completionHandler = completion

        let baseContext = context
        let initialAudioURL = audioPlaylistURL
        let provider = cookieProvider
        let progressBox = progressLock

        runnerTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let (savedURL, finalBytes) = try await Self.executeDownload(
                    playlistURL: playlistURL,
                    explicitAudioURL: initialAudioURL,
                    destinationURL: destinationURL,
                    baseContext: baseContext,
                    cookieProvider: provider,
                    onProgress: { received, estimatedTotal in
                        progressBox.withLock { $0 = (received, estimatedTotal) }
                    }
                )
                await MainActor.run { [weak self] in
                    guard let self else {
                        try? FileManager.default.removeItem(at: savedURL)
                        return
                    }
                    guard self.state == .inProgress else {
                        try? FileManager.default.removeItem(at: savedURL)
                        return
                    }
                    self.progressLock.withLock { $0 = (finalBytes, finalBytes) }
                    self.state = .completed
                    self.runnerTask = nil
                    self.finishOnce(savedURL: savedURL, error: nil)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.state = .cancelled
                    self.runnerTask = nil
                    self.finishOnce(savedURL: nil, error: CuriumMediaDownloadError.cancelled)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.state == .cancelled {
                        self.runnerTask = nil
                        self.finishOnce(savedURL: nil, error: CuriumMediaDownloadError.cancelled)
                        return
                    }
                    self.state = .failed
                    self.runnerTask = nil
                    self.finishOnce(savedURL: nil, error: error)
                }
            }
        }
    }

    func cancel() {
        guard state == .pending || state == .inProgress else { return }
        state = .cancelled
        runnerTask?.cancel()
        runnerTask = nil
        finishOnce(savedURL: nil, error: CuriumMediaDownloadError.cancelled)
    }

    private func finishOnce(savedURL: URL?, error: (any Error)?) {
        guard let completion = completionHandler else { return }
        completionHandler = nil
        completion(savedURL, error)
    }

    // MARK: - Off-Main Pipeline

    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private struct MapFetchKey: Hashable, Sendable {
        let url: URL
        let length: Int?
        let offset: Int?
    }

    private struct MapCacheKey: Hashable, Sendable {
        let url: URL
        let length: Int?
        let offset: Int?
        let encryptionKeyURL: URL?
        let encryptionIV: Data?
        let drmMethod: String?

        init(segment: CuriumHLSSegment, mapURL: URL) {
            self.url = mapURL
            self.length = segment.mapByteRange?.length
            self.offset = segment.mapByteRange?.offset
            switch segment.mapEncryption {
            case .none:
                self.encryptionKeyURL = nil
                self.encryptionIV = nil
                self.drmMethod = nil
            case .aes128(let keyURL, let iv):
                self.encryptionKeyURL = keyURL
                self.encryptionIV = iv
                self.drmMethod = nil
            case .unsupportedDRM(let method):
                self.encryptionKeyURL = nil
                self.encryptionIV = nil
                self.drmMethod = method
            }
        }
    }

    /// Selects the container extension for an assembled separate HLS audio rendition:
    /// `.m4a` for fMP4, packed RFC 8216 §3.4 extensions (`.aac`/`.ac3`/`.ec3`/`.mp3`)
    /// when detected from segment URLs, otherwise `.ts`.
    nonisolated static func preferredAudioTrackExtension(for playlist: CuriumHLSMediaPlaylist) -> String {
        if playlist.isFMP4 {
            return "m4a"
        }
        let packedExtensions: Set<String> = ["aac", "ac3", "ec3", "mp3"]
        for segment in playlist.segments {
            let ext = segment.url.pathExtension.lowercased()
            if ext == "adts" {
                return "aac"
            }
            if packedExtensions.contains(ext) {
                return ext
            }
        }
        return "ts"
    }

    private nonisolated static func executeDownload(
        playlistURL: URL,
        explicitAudioURL: URL?,
        destinationURL: URL,
        baseContext: CuriumMediaRequestContext,
        cookieProvider: (@MainActor @Sendable (URL) async -> String?)?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, Int64) {
        let fm = FileManager.default
        let destinationDir = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: destinationDir.path) {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }

        // Stage HLS work strictly under `<Caches>/CuriumDownloadStaging/<UUID>/` so crashes,
        // Jetsam, or LiveContainer guest switches never leak multi-GB hidden folders inside
        // durable `Documents/Curium/Downloads/`.
        let stagedSession = try CuriumDownloadStorage.makeDownloadStagingDestination(filename: "hls-staging")
        let stagingDir = stagedSession.sessionDirectory
        defer {
            CuriumDownloadStorage.removeDownloadStagingDirectory(stagingDir)
        }

        let coordinator = BoundedFetchCoordinator()
        let session = CuriumMediaNetworking.makeEphemeralSession(proxy: baseContext.proxy, delegate: coordinator)
        defer {
            session.invalidateAndCancel()
        }

        let cookieCache = CuriumMediaNetworking.HostCookieCache(
            baseURL: playlistURL,
            baseCookie: baseContext.cookieHeader,
            provider: cookieProvider
        )
        let originatingHostIsPublic = CuriumMediaNetworking.isOriginatingHostPublic(
            url: playlistURL,
            referrer: baseContext.referrer,
            origin: baseContext.origin
        )

        try Task.checkCancellation()

        // 1. Fetch & parse initial playlist; if master, automatically select highest variant.
        let (initialData, resolvedInitialURL) = try await fetchAuthorizedData(
            url: playlistURL,
            byteRange: nil,
            maxBytes: CuriumHLSParser.maxPlaylistBytes,
            originatingHostIsPublic: originatingHostIsPublic,
            baseContext: baseContext,
            cookieCache: cookieCache,
            session: session,
            coordinator: coordinator
        )
        let initialText = String(data: initialData, encoding: .utf8)
            ?? String(data: initialData, encoding: .isoLatin1)
            ?? ""
        let inspection = try CuriumHLSParser.parseMasterOrMedia(text: initialText, baseURL: resolvedInitialURL)

        let mediaPlaylist: CuriumHLSMediaPlaylist
        var audioURLToMux = explicitAudioURL

        if inspection.isMasterPlaylist {
            if case .unsupportedDRM(let method) = inspection.encryption {
                throw CuriumMediaDownloadError.drmUnsupported(method)
            }
            guard let chosenVariant = inspection.variants.first else {
                throw CuriumMediaDownloadError.emptyPlaylist
            }
            if audioURLToMux == nil {
                audioURLToMux = chosenVariant.audioURI
            }
            let (variantData, resolvedVariantURL) = try await fetchAuthorizedData(
                url: chosenVariant.url,
                byteRange: nil,
                maxBytes: CuriumHLSParser.maxPlaylistBytes,
                originatingHostIsPublic: originatingHostIsPublic,
                baseContext: baseContext,
                cookieCache: cookieCache,
                session: session,
                coordinator: coordinator
            )
            let variantText = String(data: variantData, encoding: .utf8)
                ?? String(data: variantData, encoding: .isoLatin1)
                ?? ""
            mediaPlaylist = try CuriumHLSParser.parseMediaPlaylist(text: variantText, baseURL: resolvedVariantURL)
        } else {
            mediaPlaylist = try CuriumHLSParser.parseMediaPlaylist(text: initialText, baseURL: resolvedInitialURL)
        }

        if case .unsupportedDRM(let method) = mediaPlaylist.encryptionSummary {
            throw CuriumMediaDownloadError.drmUnsupported(method)
        }
        guard !mediaPlaylist.isLiveStream else {
            throw CuriumMediaDownloadError.liveStreamUnsupported
        }
        guard !mediaPlaylist.segments.isEmpty else {
            throw CuriumMediaDownloadError.emptyPlaylist
        }

        let hasSeparateAudio = audioURLToMux != nil
        if let audioURL = audioURLToMux {
            guard CuriumHLSParser.isAllowedHTTPURL(audioURL) else {
                throw CuriumMediaDownloadError.disallowedURLScheme(audioURL.scheme ?? "unknown")
            }
            if originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(audioURL) {
                throw CuriumMediaDownloadError.blockedPrivateNetworkHost(audioURL.host ?? "private")
            }
        }

        // 2. Download & assemble primary video/muxed track.
        let videoStagingDir = stagingDir.appending(path: "video", directoryHint: .isDirectory)
        let videoExt = mediaPlaylist.isFMP4 ? "mp4" : "ts"
        let assembledVideoURL = stagingDir.appending(path: "primary.\(videoExt)", directoryHint: .notDirectory)

        let videoProgress: @Sendable (Int64, Int64) -> Void = { received, estimated in
            if hasSeparateAudio {
                let scaledTotal = max(received + 1, Int64((Double(max(estimated, 1)) * 1.30).rounded()))
                onProgress(received, scaledTotal)
            } else {
                onProgress(received, estimated)
            }
        }

        let assembledVideoBytes = try await downloadAndAssembleTrack(
            playlist: mediaPlaylist,
            trackStagingDir: videoStagingDir,
            outputURL: assembledVideoURL,
            originatingHostIsPublic: originatingHostIsPublic,
            baseContext: baseContext,
            cookieCache: cookieCache,
            session: session,
            coordinator: coordinator,
            onProgress: videoProgress
        )
        try? fm.removeItem(at: videoStagingDir)

        try Task.checkCancellation()

        // 3. Separate audio rendition: download, combine progress, mux cleanly, and surface failures
        // (never silently discard audio or swallow CancellationError to emit a mute video).
        var readyArtifactURL = assembledVideoURL
        var finalExpectedExtension = videoExt

        if let audioURL = audioURLToMux {
            let muxedURL = try await downloadAndMuxSeparateAudio(
                audioPlaylistURL: audioURL,
                videoTrackURL: assembledVideoURL,
                videoBytes: assembledVideoBytes,
                stagingDir: stagingDir,
                originatingHostIsPublic: originatingHostIsPublic,
                baseContext: baseContext,
                cookieCache: cookieCache,
                session: session,
                coordinator: coordinator,
                onProgress: onProgress
            )
            // Immediately reclaim primary video staging bytes once muxed output is complete.
            try? fm.removeItem(at: assembledVideoURL)
            readyArtifactURL = muxedURL
            finalExpectedExtension = "mp4"
        }

        try Task.checkCancellation()

        // 4. Commit cleanly to destinationURL (holding a unique reservation across move when aligning extension).
        let finalDestinationURL = try commitAlignedArtifact(
            from: readyArtifactURL,
            requestedDestination: destinationURL,
            expectedExtension: finalExpectedExtension
        )

        let attrs = try? fm.attributesOfItem(atPath: finalDestinationURL.path)
        let finalByteCount = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return (finalDestinationURL, finalByteCount)
    }

    @discardableResult
    private nonisolated static func downloadAndAssembleTrack(
        playlist: CuriumHLSMediaPlaylist,
        trackStagingDir: URL,
        outputURL: URL,
        originatingHostIsPublic: Bool,
        baseContext: CuriumMediaRequestContext,
        cookieCache: CuriumMediaNetworking.HostCookieCache,
        session: URLSession,
        coordinator: BoundedFetchCoordinator,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: trackStagingDir, withIntermediateDirectories: true)

        // Prefetch & cache unique AES-128 keys for both media segments and #EXT-X-MAP init sections.
        var keyCache: [URL: Data] = [:]
        for segment in playlist.segments {
            try Task.checkCancellation()
            for encryption in [segment.encryption, segment.mapEncryption] {
                switch encryption {
                case .none:
                    break
                case .unsupportedDRM(let method):
                    throw CuriumMediaDownloadError.drmUnsupported(method)
                case .aes128(let keyURL, _):
                    guard CuriumHLSParser.isAllowedHTTPURL(keyURL) else {
                        throw CuriumMediaDownloadError.disallowedURLScheme(keyURL.scheme ?? "unknown")
                    }
                    if originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(keyURL) {
                        throw CuriumMediaDownloadError.blockedPrivateNetworkHost(keyURL.host ?? "private")
                    }
                    if keyCache[keyURL] == nil {
                        let (keyData, _) = try await fetchWithRetries(
                            url: keyURL,
                            byteRange: nil,
                            maxBytes: maxKeyBytes,
                            originatingHostIsPublic: originatingHostIsPublic,
                            baseContext: baseContext,
                            cookieCache: cookieCache,
                            session: session,
                            coordinator: coordinator
                        )
                        guard keyData.count == 16 else {
                            throw CuriumMediaDownloadError.invalidAESKeyLength(keyData.count)
                        }
                        keyCache[keyURL] = keyData
                    }
                }
            }
        }

        // Prefetch, decrypt (RFC 8216 §4.3.2.5), & cache unique #EXT-X-MAP init segments.
        var rawMapCache: [MapFetchKey: Data] = [:]
        var mapCache: [MapCacheKey: Data] = [:]
        for segment in playlist.segments {
            try Task.checkCancellation()
            guard let mapURL = segment.mapURL else { continue }
            guard CuriumHLSParser.isAllowedHTTPURL(mapURL) else {
                throw CuriumMediaDownloadError.disallowedURLScheme(mapURL.scheme ?? "unknown")
            }
            if originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(mapURL) {
                throw CuriumMediaDownloadError.blockedPrivateNetworkHost(mapURL.host ?? "private")
            }
            let cacheKey = MapCacheKey(segment: segment, mapURL: mapURL)
            if mapCache[cacheKey] == nil {
                let fetchKey = MapFetchKey(
                    url: mapURL,
                    length: segment.mapByteRange?.length,
                    offset: segment.mapByteRange?.offset
                )
                let rawMapData: Data
                if let cachedRaw = rawMapCache[fetchKey] {
                    rawMapData = cachedRaw
                } else {
                    let (fetched, _) = try await fetchWithRetries(
                        url: mapURL,
                        byteRange: segment.mapByteRange,
                        maxBytes: maxSegmentBytes,
                        originatingHostIsPublic: originatingHostIsPublic,
                        baseContext: baseContext,
                        cookieCache: cookieCache,
                        session: session,
                        coordinator: coordinator
                    )
                    rawMapCache[fetchKey] = fetched
                    rawMapData = fetched
                }

                switch segment.mapEncryption {
                case .none:
                    mapCache[cacheKey] = rawMapData
                case .unsupportedDRM(let method):
                    throw CuriumMediaDownloadError.drmUnsupported(method)
                case .aes128(let keyURL, let explicitIV):
                    guard let keyData = keyCache[keyURL] else {
                        throw CuriumMediaDownloadError.invalidAESKeyLength(0)
                    }
                    let iv = CuriumHLSParser.resolveIV(
                        explicitIV: explicitIV,
                        mediaSequence: segment.mediaSequence
                    )
                    mapCache[cacheKey] = try CuriumHLSParser.decryptAES128CBC(
                        rawMapData,
                        key: keyData,
                        iv: iv
                    )
                }
            }
        }
        // Release raw init-map buffers immediately before concurrent segment downloads begin.
        rawMapCache.removeAll(keepingCapacity: false)

        let immutableKeys = keyCache
        let segments = playlist.segments
        let totalSegments = segments.count
        var completedSegments = 0
        var downloadedBytes: Int64 = 0
        onProgress?(0, Int64(totalSegments))

        // Bounded-concurrency segment download (maxConcurrent = 4) directly into staging files.
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var nextIndex = 0

            func enqueueSegment(_ segment: CuriumHLSSegment) {
                let segFileURL = trackStagingDir.appending(
                    path: "seg-\(segment.index).bin",
                    directoryHint: .notDirectory
                )
                group.addTask {
                    try Task.checkCancellation()
                    let (rawBytes, _) = try await fetchWithRetries(
                        url: segment.url,
                        byteRange: segment.byteRange,
                        maxBytes: maxSegmentBytes,
                        originatingHostIsPublic: originatingHostIsPublic,
                        baseContext: baseContext,
                        cookieCache: cookieCache,
                        session: session,
                        coordinator: coordinator
                    )
                    try Task.checkCancellation()

                    let payload: Data
                    switch segment.encryption {
                    case .none:
                        payload = rawBytes
                    case .unsupportedDRM(let method):
                        throw CuriumMediaDownloadError.drmUnsupported(method)
                    case .aes128(let keyURL, let explicitIV):
                        guard let keyData = immutableKeys[keyURL] else {
                            throw CuriumMediaDownloadError.invalidAESKeyLength(0)
                        }
                        let iv = CuriumHLSParser.resolveIV(
                            explicitIV: explicitIV,
                            mediaSequence: segment.mediaSequence
                        )
                        payload = try CuriumHLSParser.decryptAES128CBC(rawBytes, key: keyData, iv: iv)
                    }

                    try payload.write(to: segFileURL, options: .atomic)
                    return Int64(payload.count)
                }
            }

            let initialCount = min(maxConcurrentSegments, totalSegments)
            while nextIndex < initialCount {
                enqueueSegment(segments[nextIndex])
                nextIndex += 1
            }

            while let segBytes = try await group.next() {
                completedSegments += 1
                downloadedBytes += segBytes
                let estimatedTotal: Int64
                if completedSegments >= totalSegments {
                    estimatedTotal = max(downloadedBytes, 1)
                } else {
                    let average = Double(downloadedBytes) / Double(completedSegments)
                    estimatedTotal = max(downloadedBytes + 1, Int64((average * Double(totalSegments)).rounded()))
                }
                onProgress?(downloadedBytes, estimatedTotal)

                if nextIndex < totalSegments {
                    enqueueSegment(segments[nextIndex])
                    nextIndex += 1
                }
            }
        }

        try Task.checkCancellation()

        // Stream ordered segments into outputURL, prepending #EXT-X-MAP init bytes on changes.
        fm.createFile(atPath: outputURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: outputURL)
        defer { try? writer.close() }

        var lastMapKey: MapCacheKey?
        let copyChunkBytes = 256 * 1024
        var writtenBytes: Int64 = 0

        for segment in segments {
            try Task.checkCancellation()
            if let mapURL = segment.mapURL {
                let mapKey = MapCacheKey(segment: segment, mapURL: mapURL)
                if mapKey != lastMapKey, let mapBytes = mapCache[mapKey] {
                    try writer.write(contentsOf: mapBytes)
                    writtenBytes += Int64(mapBytes.count)
                    lastMapKey = mapKey
                }
            }

            let segFileURL = trackStagingDir.appending(
                path: "seg-\(segment.index).bin",
                directoryHint: .notDirectory
            )
            let reader = try FileHandle(forReadingFrom: segFileURL)
            while true {
                guard let chunk = try reader.read(upToCount: copyChunkBytes), !chunk.isEmpty else {
                    break
                }
                try writer.write(contentsOf: chunk)
                writtenBytes += Int64(chunk.count)
            }
            try? reader.close()
            try? fm.removeItem(at: segFileURL)
        }
        mapCache.removeAll(keepingCapacity: false)
        try writer.synchronize()
        return max(writtenBytes, downloadedBytes)
    }

    private nonisolated static func downloadAndMuxSeparateAudio(
        audioPlaylistURL: URL,
        videoTrackURL: URL,
        videoBytes: Int64,
        stagingDir: URL,
        originatingHostIsPublic: Bool,
        baseContext: CuriumMediaRequestContext,
        cookieCache: CuriumMediaNetworking.HostCookieCache,
        session: URLSession,
        coordinator: BoundedFetchCoordinator,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let (audioPlaylistData, resolvedAudioURL) = try await fetchAuthorizedData(
            url: audioPlaylistURL,
            byteRange: nil,
            maxBytes: CuriumHLSParser.maxPlaylistBytes,
            originatingHostIsPublic: originatingHostIsPublic,
            baseContext: baseContext,
            cookieCache: cookieCache,
            session: session,
            coordinator: coordinator
        )
        let audioText = String(data: audioPlaylistData, encoding: .utf8)
            ?? String(data: audioPlaylistData, encoding: .isoLatin1)
            ?? ""
        let audioPlaylist = try CuriumHLSParser.parseMediaPlaylist(text: audioText, baseURL: resolvedAudioURL)
        if case .unsupportedDRM(let method) = audioPlaylist.encryptionSummary {
            throw CuriumMediaDownloadError.drmUnsupported(method)
        }
        guard !audioPlaylist.isLiveStream else {
            throw CuriumMediaDownloadError.liveStreamUnsupported
        }
        guard !audioPlaylist.segments.isEmpty else {
            throw CuriumMediaDownloadError.emptyPlaylist
        }

        let fm = FileManager.default
        let audioExt = preferredAudioTrackExtension(for: audioPlaylist)
        let audioStagingDir = stagingDir.appending(path: "audio", directoryHint: .isDirectory)
        let audioTrackURL = stagingDir.appending(path: "audio.\(audioExt)", directoryHint: .notDirectory)
        defer {
            try? fm.removeItem(at: audioStagingDir)
            try? fm.removeItem(at: audioTrackURL)
        }

        let audioBytes = try await downloadAndAssembleTrack(
            playlist: audioPlaylist,
            trackStagingDir: audioStagingDir,
            outputURL: audioTrackURL,
            originatingHostIsPublic: originatingHostIsPublic,
            baseContext: baseContext,
            cookieCache: cookieCache,
            session: session,
            coordinator: coordinator,
            onProgress: { audioReceived, audioEstimated in
                let combinedReceived = videoBytes + audioReceived
                let combinedBase = videoBytes + max(audioEstimated, audioReceived, 1)
                let combinedTotal = max(combinedReceived + 1, Int64((Double(combinedBase) * 1.06).rounded()))
                onProgress(combinedReceived, combinedTotal)
            }
        )
        try? fm.removeItem(at: audioStagingDir)

        try Task.checkCancellation()

        let muxedURL = stagingDir.appending(path: "muxed.mp4", directoryHint: .notDirectory)
        let combinedTrackBytes = max(1, videoBytes + audioBytes)
        let muxTotal = max(combinedTrackBytes + 1, Int64((Double(combinedTrackBytes) * 1.06).rounded()))
        let muxHeadroom = max(0, muxTotal - combinedTrackBytes - 1)
        onProgress(combinedTrackBytes, muxTotal)

        try await muxFMP4Tracks(
            videoURL: videoTrackURL,
            audioURL: audioTrackURL,
            outputURL: muxedURL,
            onProgress: { fraction in
                let clamped = min(1.0, max(0.0, Double(fraction)))
                let extra = Int64((Double(muxHeadroom) * clamped).rounded())
                onProgress(min(muxTotal - 1, combinedTrackBytes + extra), muxTotal)
            }
        )
        return muxedURL
    }

    nonisolated static func muxFMP4Tracks(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        onProgress: (@Sendable (Float) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw CuriumMediaDownloadError.audioMuxFailed(error.localizedDescription)
        }

        guard let sourceVideo = videoTracks.first else {
            throw CuriumMediaDownloadError.audioMuxFailed("No readable video track found in primary stream.")
        }
        guard let sourceAudio = audioTracks.first else {
            throw CuriumMediaDownloadError.audioMuxFailed("No readable audio track found in separate audio stream.")
        }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let compAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CuriumMediaDownloadError.audioMuxFailed("Unable to allocate composition tracks.")
        }

        do {
            let videoTimeRange = try await sourceVideo.load(.timeRange)
            let audioTimeRange = try await sourceAudio.load(.timeRange)
            let videoTransform = try await sourceVideo.load(.preferredTransform)

            let effectiveVideoRange: CMTimeRange
            if videoTimeRange.isValid && !videoTimeRange.isEmpty && videoTimeRange.duration > .zero {
                effectiveVideoRange = videoTimeRange
            } else {
                let videoDuration = try await videoAsset.load(.duration)
                guard videoDuration.isNumeric && videoDuration > .zero else {
                    throw CuriumMediaDownloadError.audioMuxFailed("Video track has zero duration.")
                }
                effectiveVideoRange = CMTimeRange(start: .zero, duration: videoDuration)
            }

            let effectiveAudioRange: CMTimeRange
            if audioTimeRange.isValid && !audioTimeRange.isEmpty && audioTimeRange.duration > .zero {
                let clampedDuration = min(audioTimeRange.duration, effectiveVideoRange.duration)
                effectiveAudioRange = CMTimeRange(start: audioTimeRange.start, duration: clampedDuration)
            } else {
                let audioDuration = try await audioAsset.load(.duration)
                let clampedDuration = (audioDuration.isNumeric && audioDuration > .zero)
                    ? min(audioDuration, effectiveVideoRange.duration)
                    : effectiveVideoRange.duration
                effectiveAudioRange = CMTimeRange(start: .zero, duration: clampedDuration)
            }

            let baseStart = CMTimeMinimum(effectiveVideoRange.start, effectiveAudioRange.start)
            let videoInsertAt = CMTimeMaximum(.zero, CMTimeSubtract(effectiveVideoRange.start, baseStart))
            let audioInsertAt = CMTimeMaximum(.zero, CMTimeSubtract(effectiveAudioRange.start, baseStart))

            try compVideo.insertTimeRange(effectiveVideoRange, of: sourceVideo, at: videoInsertAt)
            compVideo.preferredTransform = videoTransform
            try compAudio.insertTimeRange(effectiveAudioRange, of: sourceAudio, at: audioInsertAt)
        } catch let error as CancellationError {
            throw error
        } catch let error as CuriumMediaDownloadError {
            throw error
        } catch {
            throw CuriumMediaDownloadError.audioMuxFailed(error.localizedDescription)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw CuriumMediaDownloadError.audioMuxFailed("Passthrough MP4 export session unavailable.")
        }

        let box = ExportSessionBox(exporter)
        let progressPoller: Task<Void, Never>? = onProgress.map { callback in
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    callback(box.session.progress)
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
                }
            }
        }
        defer { progressPoller?.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await box.session.export(to: outputURL, as: .mp4)
            } onCancel: {
                box.session.cancelExport()
            }
            try Task.checkCancellation()
            onProgress?(1.0)
        } catch let error as CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if Task.isCancelled {
                throw CancellationError()
            }
            throw CuriumMediaDownloadError.audioMuxFailed(error.localizedDescription)
        }
    }

    private nonisolated static func fetchWithRetries(
        url: URL,
        byteRange: (length: Int, offset: Int?)?,
        maxBytes: Int,
        originatingHostIsPublic: Bool,
        baseContext: CuriumMediaRequestContext,
        cookieCache: CuriumMediaNetworking.HostCookieCache,
        session: URLSession,
        coordinator: BoundedFetchCoordinator
    ) async throws -> (Data, URL) {
        var lastError: any Error = CuriumMediaDownloadError.invalidHTTPResponse
        for attempt in 0...maxSegmentRetries {
            try Task.checkCancellation()
            do {
                return try await fetchAuthorizedData(
                    url: url,
                    byteRange: byteRange,
                    maxBytes: maxBytes,
                    originatingHostIsPublic: originatingHostIsPublic,
                    baseContext: baseContext,
                    cookieCache: cookieCache,
                    session: session,
                    coordinator: coordinator
                )
            } catch let error as CancellationError {
                throw error
            } catch let error as CuriumMediaDownloadError {
                switch error {
                case .disallowedURLScheme, .blockedPrivateNetworkHost, .responseTooLarge,
                     .byteRangeMismatch, .cancelled, .drmUnsupported, .liveStreamUnsupported:
                    throw error
                case .httpStatusError(let code) where (400...499).contains(code) && code != 408 && code != 429:
                    throw error
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }

            if attempt < maxSegmentRetries {
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw lastError
    }

    private nonisolated static func fetchAuthorizedData(
        url: URL,
        byteRange: (length: Int, offset: Int?)?,
        maxBytes: Int,
        originatingHostIsPublic: Bool,
        baseContext: CuriumMediaRequestContext,
        cookieCache: CuriumMediaNetworking.HostCookieCache,
        session: URLSession,
        coordinator: BoundedFetchCoordinator
    ) async throws -> (Data, URL) {
        guard CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumMediaDownloadError.disallowedURLScheme(url.scheme ?? "unknown")
        }
        if originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(url) {
            throw CuriumMediaDownloadError.blockedPrivateNetworkHost(url.host ?? "private")
        }

        let resolvedCookie = await cookieCache.cookieHeader(for: url)
        let perRequestContext = CuriumMediaRequestContext(
            cookieHeader: resolvedCookie,
            userAgent: baseContext.userAgent,
            referrer: baseContext.referrer,
            origin: baseContext.origin,
            proxy: baseContext.proxy
        )
        let request = CuriumMediaNetworking.makeRequest(
            url: url,
            context: perRequestContext,
            byteRange: byteRange
        )
        return try await coordinator.fetchData(
            request: request,
            session: session,
            maxBytes: maxBytes,
            expectedByteRange: byteRange,
            originatingHostIsPublic: originatingHostIsPublic,
            cookieResolver: { targetURL in
                await cookieCache.cookieHeader(for: targetURL)
            }
        )
    }

    private nonisolated static func commitAlignedArtifact(
        from artifactURL: URL,
        requestedDestination: URL,
        expectedExtension: String
    ) throws -> URL {
        let fm = FileManager.default
        let currentExt = requestedDestination.pathExtension.lowercased()
        if currentExt == expectedExtension.lowercased() {
            if fm.fileExists(atPath: requestedDestination.path) {
                try fm.removeItem(at: requestedDestination)
            }
            try moveOrCopyItem(from: artifactURL, to: requestedDestination, fileManager: fm)
            return requestedDestination
        }

        let stem = (requestedDestination.lastPathComponent as NSString).deletingPathExtension
        let nextFilename = CuriumDownloadStorage.sanitizedFilename(
            "\(stem).\(expectedExtension)",
            fallback: "Video.\(expectedExtension)"
        )
        let dir = requestedDestination.deletingLastPathComponent()
        let uniqueURL = try CuriumDownloadStorage.uniqueDownloadDestination(filename: nextFilename, in: dir)
        defer {
            CuriumDownloadStorage.releaseDownloadReservation(at: uniqueURL)
        }
        try moveOrCopyItem(from: artifactURL, to: uniqueURL, fileManager: fm)
        return uniqueURL
    }

    private nonisolated static func moveOrCopyItem(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager fm: FileManager
    ) throws {
        do {
            try fm.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            // Cross-volume boundary (e.g. Caches -> App Group / external volume): copy then unlink.
            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: sourceURL, to: destinationURL)
            try? fm.removeItem(at: sourceURL)
        }
    }
}
