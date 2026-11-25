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

    /// Fetches and parses an HLS Master or Media playlist over a pooled, proxy-aware,
    /// scheme- & SSRF-guarded session (`allowFailover = false` + authenticated fixed proxies).
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
        let lease = CuriumProxySessionPool.acquireSessionLease(
            for: .streamProber,
            proxy: context.proxy,
            targetURL: url
        )
        defer { lease.release() }

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
            session: lease.session,
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

        // Delegate scheme, SSRF, cross-origin auth (`Cookie`, `Authorization`, `Proxy-Authorization`),
        // `httpShouldHandleCookies = false`, and HTTPS->HTTP downgrade (`Referer`/`Origin`)
        // sanitization to the shared `CrossOriginRedirectAuthStripper`.
        let decision = CrossOriginRedirectAuthStripper.evaluateRedirect(
            from: previousURL,
            to: proposed,
            originatingURL: nil
        )
        switch decision {
        case .rejectDisallowedScheme(let scheme):
            return .rejectedScheme(scheme)
        case .rejectPrivateNetwork(let host):
            return .rejectedPrivateNetwork(host)
        case .allow(var sanitized, let crossOriginNeedsRefresh):
            // RFC 6265 cookie safety: keep existing Cookie only on exact (scheme, host, directoryPath)
            // match; strip and trigger cookieProvider refresh across host, scheme, port, or path changes.
            let prevScope = previousURL.flatMap(HostCookieCache.scopeKey(for:))
            let nextScope = HostCookieCache.scopeKey(for: targetURL)
            if crossOriginNeedsRefresh || prevScope == nil || prevScope != nextScope {
                sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
                return .allowed(sanitized, needsCookieRefresh: true)
            }
            return .allowed(sanitized, needsCookieRefresh: false)
        }
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
        try Task.checkCancellation()
        guard let url = request.url, CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumMediaDownloadError.disallowedURLScheme(request.url?.scheme ?? "unknown")
        }
        if originatingHostIsPublic && CuriumHLSParser.isPrivateOrLocalURL(url) {
            throw CuriumMediaDownloadError.blockedPrivateNetworkHost(url.host ?? "private")
        }

        let dataTask = session.dataTask(with: request)
        dataTask.delegate = self
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

