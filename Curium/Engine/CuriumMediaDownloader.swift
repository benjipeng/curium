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
    case invalidHTTPResponse
    case httpStatusError(Int)
    case responseTooLarge(maxBytes: Int)
    case liveStreamUnsupported
    case drmUnsupported(String)
    case emptyPlaylist
    case invalidAESKeyLength(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .disallowedURLScheme(let detail):
            return "Blocked unsupported media URL scheme (\(detail))."
        case .invalidHTTPResponse:
            return "Server returned an invalid HTTP response."
        case .httpStatusError(let code):
            return "Media server responded with HTTP \(code)."
        case .responseTooLarge(let maxBytes):
            return "Response exceeded the \(maxBytes)-byte safety limit."
        case .liveStreamUnsupported:
            return "Live HLS streams cannot be downloaded while broadcasting."
        case .drmUnsupported(let method):
            return "DRM-protected stream (\(method)) cannot be downloaded."
        case .emptyPlaylist:
            return "No downloadable media segments were found in the HLS playlist."
        case .invalidAESKeyLength(let count):
            return "AES-128 key response had invalid length (\(count) bytes; expected 16)."
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

    /// Maps `CuriumProxyConfig` to a `URLSessionConfiguration.connectionProxyDictionary`.
    /// - `.system`: returns `nil` (inherits OS proxy configuration).
    /// - `.direct`: returns `[:]` (explicitly bypasses system proxy).
    /// - `.fixed`: parses `http://`, `https://`, `socks5://` / `socks://` / `socks4://`
    ///   and Chromium `scheme=host:port` clauses so fixed-proxy profiles never leak real IP.
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

                // Use the first valid proxy server in a comma-separated fallback chain.
                for rawEntry in uriList.split(separator: ",", omittingEmptySubsequences: true) {
                    let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !entry.isEmpty, entry.lowercased() != "direct://" else { continue }
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
                for token in tokens {
                    if token.lowercased() == "<local>" {
                        dict[keyExcludeSimpleHostnames] = 1
                    } else {
                        exceptions.append(token)
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
            }

            return dict
        }
    }

    static func makeEphemeralSession(
        proxy: CuriumProxyConfig,
        delegate: (any URLSessionDelegate)? = nil
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        if let proxyDict = proxyDictionary(for: proxy) {
            config.connectionProxyDictionary = proxyDict
        }
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    static func makeRequest(
        url: URL,
        context: CuriumMediaRequestContext,
        byteRange: (length: Int, offset: Int?)? = nil
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
        if let referrer = context.referrer, CuriumHLSParser.isAllowedHTTPURL(referrer) {
            request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let origin = context.origin?.trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty,
           origin.lowercased() != "null" {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let byteRange, byteRange.length > 0 {
            let start = max(0, byteRange.offset ?? 0)
            let end = start + byteRange.length - 1
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }
        return request
    }

    /// Fetches and parses an HLS Master or Media playlist over an ephemeral, scheme-guarded session.
    static func inspectHLS(
        url: URL,
        context: CuriumMediaRequestContext
    ) async throws -> CuriumHLSMasterInspection {
        guard CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumMediaDownloadError.disallowedURLScheme(url.scheme ?? "unknown")
        }
        let coordinator = BoundedFetchCoordinator()
        let session = makeEphemeralSession(proxy: context.proxy, delegate: coordinator)
        defer { session.finishTasksAndInvalidate() }

        let request = makeRequest(url: url, context: context)
        let (data, finalURL) = try await coordinator.fetchData(
            request: request,
            session: session,
            maxBytes: CuriumHLSParser.maxPlaylistBytes
        )
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return try CuriumHLSParser.parseMasterOrMedia(text: text, baseURL: finalURL)
    }

    // MARK: - Proxy Parsing Helpers

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
                kind = (targetPrefix == "http") ? .httpOnly : (targetPrefix == "https" ? .httpsOnly : .httpAndHTTPS)
                defaultPort = 443
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

    fileprivate static func sanitizeRedirectRequest(
        _ proposed: URLRequest,
        originalHost: String?
    ) -> URLRequest? {
        guard let targetURL = proposed.url,
              CuriumHLSParser.isAllowedHTTPURL(targetURL) else {
            return nil
        }
        var sanitized = proposed
        sanitized.httpShouldHandleCookies = false
        // RFC 6265 host-only cookie safety: strip Cookie on any host mismatch (including subdomains).
        let targetHost = targetURL.host?.lowercased()
        if originalHost == nil || targetHost != originalHost {
            sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return sanitized
    }
}

// MARK: - Bounded Fetch Coordinator (Playlists, Keys, Segments)

private final class BoundedFetchCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct ActiveFetch {
        let originalHost: String?
        let maxBytes: Int
        var data = Data()
        var finalURL: URL
        var overrideError: (any Error)?
        var continuation: CheckedContinuation<(Data, URL), any Error>?
    }

    private let state = OSAllocatedUnfairLock<[Int: ActiveFetch]>(initialState: [:])

    func fetchData(
        request: URLRequest,
        session: URLSession,
        maxBytes: Int
    ) async throws -> (Data, URL) {
        guard let url = request.url, CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumMediaDownloadError.disallowedURLScheme(request.url?.scheme ?? "unknown")
        }

        let dataTask = session.dataTask(with: request)
        let taskID = dataTask.taskIdentifier
        let requestHost = url.host?.lowercased()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { map in
                    map[taskID] = ActiveFetch(
                        originalHost: requestHost,
                        maxBytes: maxBytes,
                        data: Data(),
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
        let originalHost = state.withLock { $0[task.taskIdentifier]?.originalHost }
        guard let sanitized = CuriumMediaNetworking.sanitizeRedirectRequest(request, originalHost: originalHost),
              let targetURL = sanitized.url else {
            state.withLock { map in
                map[task.taskIdentifier]?.overrideError = CuriumMediaDownloadError.disallowedURLScheme(
                    request.url?.scheme ?? "unknown"
                )
            }
            task.cancel()
            completionHandler(nil)
            return
        }
        state.withLock { map in
            map[task.taskIdentifier]?.finalURL = targetURL
        }
        completionHandler(sanitized)
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
        if let responseURL = http.url {
            guard CuriumHLSParser.isAllowedHTTPURL(responseURL) else {
                state.withLock { map in
                    map[dataTask.taskIdentifier]?.overrideError = CuriumMediaDownloadError.disallowedURLScheme(
                        responseURL.scheme ?? "unknown"
                    )
                }
                completionHandler(.cancel)
                return
            }
            state.withLock { map in
                map[dataTask.taskIdentifier]?.finalURL = responseURL
            }
        }

        let maxBytes = state.withLock { $0[dataTask.taskIdentifier]?.maxBytes ?? Int.max }
        if http.expectedContentLength > Int64(maxBytes) {
            state.withLock { map in
                map[dataTask.taskIdentifier]?.overrideError = CuriumMediaDownloadError.responseTooLarge(maxBytes: maxBytes)
            }
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

// MARK: - Authenticated Direct Media Download Task

@MainActor
final class CuriumDirectMediaDownloadTask: NSObject, CrIOSDownloadTaskV1 {
    let downloadID: String
    let sourceTabID: String?
    let originalURL: URL?
    let suggestedFilename: String
    let mimeType: String?
    private let context: CuriumMediaRequestContext

    private(set) var totalBytes: Int64
    private(set) var receivedBytes: Int64 = 0
    private(set) var state: CrIOSDownloadState = .pending

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
        context: CuriumMediaRequestContext
    ) {
        self.downloadID = downloadID
        self.sourceTabID = sourceTabID
        self.originalURL = url
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.totalBytes = expectedBytes > 0 ? expectedBytes : -1
        self.context = context
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

        self.destinationURL = destinationURL
        self.completionHandler = completion
        self.state = .inProgress
        self.receivedBytes = 0

        let coordinator = DirectDownloadCoordinator(
            destinationURL: destinationURL,
            originalHost: url.host?.lowercased(),
            onProgress: { [weak self] received, expected in
                Task { @MainActor [weak self] in
                    guard let self, self.state == .inProgress else { return }
                    self.receivedBytes = received
                    if expected > 0 {
                        self.totalBytes = expected
                    }
                }
            },
            onFinished: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleCoordinatorResult(result)
                }
            }
        )
        self.coordinator = coordinator

        let session = CuriumMediaNetworking.makeEphemeralSession(proxy: context.proxy, delegate: coordinator)
        let request = CuriumMediaNetworking.makeRequest(url: url, context: context)
        let downloadTask = session.downloadTask(with: request)
        coordinator.attach(session: session, task: downloadTask)
        downloadTask.resume()
    }

    func cancel() {
        guard state == .pending || state == .inProgress else { return }
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
        coordinator = nil
        switch result {
        case .success(let (savedURL, finalBytes)):
            guard state == .inProgress else {
                try? FileManager.default.removeItem(at: savedURL)
                return
            }
            if finalBytes > 0 {
                receivedBytes = finalBytes
                totalBytes = finalBytes
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
        var cancelled = false
        var completed = false
        var movedSuccessfully = false
        var finalByteCount: Int64 = 0
        var recordedError: (any Error)?
    }

    private let destinationURL: URL
    private let originalHost: String?
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onFinished: @Sendable (Result<(URL, Int64), any Error>) -> Void
    private let lock = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())

    init(
        destinationURL: URL,
        originalHost: String?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinished: @escaping @Sendable (Result<(URL, Int64), any Error>) -> Void
    ) {
        self.destinationURL = destinationURL
        self.originalHost = originalHost
        self.onProgress = onProgress
        self.onFinished = onFinished
        super.init()
    }

    func attach(session: URLSession, task: URLSessionDownloadTask) {
        lock.withLock { state in
            state.session = session
            state.task = task
        }
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
        guard let sanitized = CuriumMediaNetworking.sanitizeRedirectRequest(request, originalHost: originalHost) else {
            lock.withLock { state in
                state.recordedError = CuriumMediaDownloadError.disallowedURLScheme(
                    request.url?.scheme ?? "unknown"
                )
            }
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(sanitized)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let cancelled = lock.withLock { $0.cancelled }
        guard !cancelled else { return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
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
        if let finalURL = http.url, !CuriumHLSParser.isAllowedHTTPURL(finalURL) {
            lock.withLock { $0.recordedError = CuriumMediaDownloadError.disallowedURLScheme(finalURL.scheme ?? "unknown") }
            return
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
    private nonisolated static let maxSegmentBytes = 256 * 1024 * 1024
    private nonisolated static let maxKeyBytes = 1024

    let downloadID: String
    let sourceTabID: String?
    let originalURL: URL?
    let audioPlaylistURL: URL?
    let suggestedFilename: String
    let mimeType: String?
    private let context: CuriumMediaRequestContext
    private let cookieProvider: (@MainActor @Sendable (URL) async -> String?)?

    private(set) var totalBytes: Int64 = -1
    private(set) var receivedBytes: Int64 = 0
    private(set) var state: CrIOSDownloadState = .pending

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
        suggestedFilename: String,
        mimeType: String? = nil,
        context: CuriumMediaRequestContext,
        cookieProvider: (@MainActor @Sendable (URL) async -> String?)? = nil
    ) {
        self.downloadID = downloadID
        self.sourceTabID = sourceTabID
        self.originalURL = playlistURL
        self.audioPlaylistURL = audioPlaylistURL
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
        if let audioPlaylistURL, !CuriumHLSParser.isAllowedHTTPURL(audioPlaylistURL) {
            state = .failed
            completion(nil, CuriumMediaDownloadError.disallowedURLScheme(audioPlaylistURL.scheme ?? "unknown"))
            return
        }

        state = .inProgress
        receivedBytes = 0
        totalBytes = -1
        completionHandler = completion

        let baseContext = context
        let initialAudioURL = audioPlaylistURL
        let provider = cookieProvider

        runnerTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let (savedURL, finalBytes) = try await Self.executeDownload(
                    playlistURL: playlistURL,
                    explicitAudioURL: initialAudioURL,
                    destinationURL: destinationURL,
                    baseContext: baseContext,
                    cookieProvider: provider,
                    onProgress: { [weak self] received, estimatedTotal in
                        Task { @MainActor [weak self] in
                            guard let self, self.state == .inProgress else { return }
                            self.receivedBytes = received
                            self.totalBytes = estimatedTotal
                        }
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
                    self.receivedBytes = finalBytes
                    self.totalBytes = finalBytes
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

    /// Per-host cookie cache with exact-host matching (never forwards host-only cookies to
    /// subdomains) and coalesced `@MainActor` lookups so large CDN playlists hop once per host.
    private actor HostCookieCache {
        private let baseHost: String?
        private let baseCookie: String?
        private let provider: (@MainActor @Sendable (URL) async -> String?)?
        private var resolvedByHost: [String: String?] = [:]
        private var inFlightByHost: [String: Task<String?, Never>] = [:]

        init(
            baseHost: String?,
            baseCookie: String?,
            provider: (@MainActor @Sendable (URL) async -> String?)?
        ) {
            self.baseHost = baseHost
            self.baseCookie = baseCookie
            self.provider = provider
        }

        func cookieHeader(for url: URL) async -> String? {
            guard let targetHost = url.host?.lowercased(), !targetHost.isEmpty else {
                return nil
            }
            if let baseHost, targetHost == baseHost {
                return baseCookie
            }
            if let cached = resolvedByHost[targetHost] {
                return cached
            }
            if let existingTask = inFlightByHost[targetHost] {
                return await existingTask.value
            }
            guard let provider else {
                resolvedByHost[targetHost] = nil
                return nil
            }
            let lookupTask = Task<String?, Never> {
                await provider(url)
            }
            inFlightByHost[targetHost] = lookupTask
            let resolved = await lookupTask.value
            inFlightByHost.removeValue(forKey: targetHost)
            resolvedByHost[targetHost] = resolved
            return resolved
        }
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

        // Dedicated staging directory beside destinationURL — always deleted in `defer`.
        let stagingDir = destinationDir.appending(
            path: ".curium-hls-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingDir)
        }

        let coordinator = BoundedFetchCoordinator()
        let session = CuriumMediaNetworking.makeEphemeralSession(proxy: baseContext.proxy, delegate: coordinator)
        defer {
            session.invalidateAndCancel()
        }

        let cookieCache = HostCookieCache(
            baseHost: playlistURL.host?.lowercased(),
            baseCookie: baseContext.cookieHeader,
            provider: cookieProvider
        )

        try Task.checkCancellation()

        // 1. Fetch & parse initial playlist; if master, automatically select highest variant.
        let (initialData, resolvedInitialURL) = try await fetchAuthorizedData(
            url: playlistURL,
            byteRange: nil,
            maxBytes: CuriumHLSParser.maxPlaylistBytes,
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

        // 2. Download & assemble primary video/muxed track.
        let videoStagingDir = stagingDir.appending(path: "video", directoryHint: .isDirectory)
        let videoExt = mediaPlaylist.isFMP4 ? "mp4" : "ts"
        let assembledVideoURL = stagingDir.appending(path: "primary.\(videoExt)", directoryHint: .notDirectory)

        try await downloadAndAssembleTrack(
            playlist: mediaPlaylist,
            trackStagingDir: videoStagingDir,
            outputURL: assembledVideoURL,
            baseContext: baseContext,
            cookieCache: cookieCache,
            session: session,
            coordinator: coordinator,
            onProgress: onProgress
        )

        try Task.checkCancellation()

        // 3. Optional separate audio rendition (fMP4 passthrough mux with graceful fallback to video-only).
        var readyArtifactURL = assembledVideoURL
        var finalExpectedExtension = videoExt

        if let audioURL = audioURLToMux, CuriumHLSParser.isAllowedHTTPURL(audioURL) {
            if let muxedURL = await attemptSeparateAudioMux(
                audioPlaylistURL: audioURL,
                videoTrackURL: assembledVideoURL,
                stagingDir: stagingDir,
                baseContext: baseContext,
                cookieCache: cookieCache,
                session: session,
                coordinator: coordinator
            ) {
                readyArtifactURL = muxedURL
                finalExpectedExtension = "mp4"
            }
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

    private nonisolated static func downloadAndAssembleTrack(
        playlist: CuriumHLSMediaPlaylist,
        trackStagingDir: URL,
        outputURL: URL,
        baseContext: CuriumMediaRequestContext,
        cookieCache: HostCookieCache,
        session: URLSession,
        coordinator: BoundedFetchCoordinator,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
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
                    if keyCache[keyURL] == nil {
                        let (keyData, _) = try await fetchWithRetries(
                            url: keyURL,
                            byteRange: nil,
                            maxBytes: maxKeyBytes,
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

        for segment in segments {
            try Task.checkCancellation()
            if let mapURL = segment.mapURL {
                let mapKey = MapCacheKey(segment: segment, mapURL: mapURL)
                if mapKey != lastMapKey, let mapBytes = mapCache[mapKey] {
                    try writer.write(contentsOf: mapBytes)
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
            }
            try? reader.close()
            try? fm.removeItem(at: segFileURL)
        }
        try writer.synchronize()
    }

    private nonisolated static func attemptSeparateAudioMux(
        audioPlaylistURL: URL,
        videoTrackURL: URL,
        stagingDir: URL,
        baseContext: CuriumMediaRequestContext,
        cookieCache: HostCookieCache,
        session: URLSession,
        coordinator: BoundedFetchCoordinator
    ) async -> URL? {
        do {
            try Task.checkCancellation()
            let (audioPlaylistData, resolvedAudioURL) = try await fetchAuthorizedData(
                url: audioPlaylistURL,
                byteRange: nil,
                maxBytes: CuriumHLSParser.maxPlaylistBytes,
                baseContext: baseContext,
                cookieCache: cookieCache,
                session: session,
                coordinator: coordinator
            )
            let audioText = String(data: audioPlaylistData, encoding: .utf8)
                ?? String(data: audioPlaylistData, encoding: .isoLatin1)
                ?? ""
            let audioPlaylist = try CuriumHLSParser.parseMediaPlaylist(text: audioText, baseURL: resolvedAudioURL)
            guard !audioPlaylist.isLiveStream,
                  !audioPlaylist.segments.isEmpty else {
                return nil
            }
            if case .unsupportedDRM = audioPlaylist.encryptionSummary {
                return nil
            }

            let audioExt = audioPlaylist.isFMP4 ? "m4a" : "ts"
            let audioStagingDir = stagingDir.appending(path: "audio", directoryHint: .isDirectory)
            let audioTrackURL = stagingDir.appending(path: "audio.\(audioExt)", directoryHint: .notDirectory)

            try await downloadAndAssembleTrack(
                playlist: audioPlaylist,
                trackStagingDir: audioStagingDir,
                outputURL: audioTrackURL,
                baseContext: baseContext,
                cookieCache: cookieCache,
                session: session,
                coordinator: coordinator,
                onProgress: nil
            )

            let muxedURL = stagingDir.appending(path: "muxed.mp4", directoryHint: .notDirectory)
            try await muxFMP4Tracks(videoURL: videoTrackURL, audioURL: audioTrackURL, outputURL: muxedURL)
            return muxedURL
        } catch {
            // Graceful fallback: keep the already-downloaded video track if muxing fails.
            return nil
        }
    }

    private nonisolated static func muxFMP4Tracks(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let sourceVideo = videoTracks.first, let sourceAudio = audioTracks.first else {
            throw CuriumMediaDownloadError.emptyPlaylist
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let composition = AVMutableComposition()

        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let compAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CuriumMediaDownloadError.emptyPlaylist
        }

        try compVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideo,
            at: .zero
        )
        let effectiveAudioDuration = audioDuration > .zero ? min(audioDuration, videoDuration) : videoDuration
        try compAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: effectiveAudioDuration),
            of: sourceAudio,
            at: .zero
        )

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw CuriumMediaDownloadError.emptyPlaylist
        }
        try await exporter.export(to: outputURL, as: .mp4)
    }

    private nonisolated static func fetchWithRetries(
        url: URL,
        byteRange: (length: Int, offset: Int?)?,
        maxBytes: Int,
        baseContext: CuriumMediaRequestContext,
        cookieCache: HostCookieCache,
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
                    baseContext: baseContext,
                    cookieCache: cookieCache,
                    session: session,
                    coordinator: coordinator
                )
            } catch let error as CancellationError {
                throw error
            } catch let error as CuriumMediaDownloadError {
                switch error {
                case .disallowedURLScheme, .responseTooLarge, .cancelled, .drmUnsupported, .liveStreamUnsupported:
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
        baseContext: CuriumMediaRequestContext,
        cookieCache: HostCookieCache,
        session: URLSession,
        coordinator: BoundedFetchCoordinator
    ) async throws -> (Data, URL) {
        guard CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumMediaDownloadError.disallowedURLScheme(url.scheme ?? "unknown")
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
        return try await coordinator.fetchData(request: request, session: session, maxBytes: maxBytes)
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
            try fm.moveItem(at: artifactURL, to: requestedDestination)
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
        try fm.moveItem(at: artifactURL, to: uniqueURL)
        return uniqueURL
    }
}
