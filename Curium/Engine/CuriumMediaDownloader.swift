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

    // MARK: - Origin & Redirect Helpers

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
}

// MARK: - Bounded Playlist Fetch Coordinator

private final class BoundedFetchCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct ActiveFetch {
        let originatingHostIsPublic: Bool
        let maxBytes: Int
        let cookieResolver: (@Sendable (URL) async -> String?)?
        var data = Data()
        var currentURL: URL
        var finalURL: URL
        var overrideError: (any Error)?
        var continuation: CheckedContinuation<(Data, URL), any Error>?
    }

    private let state = OSAllocatedUnfairLock<[Int: ActiveFetch]>(initialState: [:])

    func fetchData(
        request: URLRequest,
        session: URLSession,
        maxBytes: Int,
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
                        cookieResolver: cookieResolver,
                        data: Data(),
                        currentURL: url,
                        finalURL: url,
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

            if http.expectedContentLength > Int64(entry.maxBytes) {
                let err = CuriumMediaDownloadError.responseTooLarge(maxBytes: entry.maxBytes)
                entry.overrideError = err
                map[dataTask.taskIdentifier] = entry
                return err
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
        continuation.resume(returning: (completed.data, completed.finalURL))
    }
}

