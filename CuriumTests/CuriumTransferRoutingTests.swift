import CryptoKit
import CuriumEngineContract
import Darwin
import Foundation
import Testing
import UIKit
import os

// MARK: - Deterministic Loopback HTTP/1.1 Server for Transfer Routing Tests

private final class RoutingLoopbackServer: @unchecked Sendable {
    enum Behavior: Sendable {
        /// Standard multi-lane `206 Partial Content` byte-range file server.
        case range206(payload: Data, eTag: String?, contentDisposition: String?, uniformDelayMicrosPer64K: useconds_t)
        /// Returns `403 Forbidden` to probe/range requests (simulating single-use token / WAF).
        case status403
        /// Returns `200 OK` without byte-range support.
        case status200NoRange(payload: Data, delayMicrosPer64K: useconds_t = 0)
        /// Serves an fMP4 HLS `.m3u8` playlist + init + segments.
        case hlsFMP4(playlistPath: String, initMap: Data, segments: [Data])
    }

    struct Stats: Sendable {
        var totalRequests = 0
        var probeRequests = 0
        var rangeRequests = 0
        var receivedCookies: [String] = []
        var receivedPaths: [String] = []
    }

    private struct MutableState: Sendable {
        var behavior: Behavior
        var stats = Stats()
        var isStopped = false
    }

    let port: UInt16
    private let listenFD: Int32
    private let state: OSAllocatedUnfairLock<MutableState>
    private let acceptQueue = DispatchQueue(label: "curium.test.routing.accept")
    private let workerQueue = DispatchQueue(label: "curium.test.routing.worker", attributes: .concurrent)

    init(behavior: Behavior) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
            Darwin.close(fd)
            throw err
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw err
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &boundAddr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &boundLen)
            }
        }) == 0 else {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw err
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.state = OSAllocatedUnfairLock(initialState: MutableState(behavior: behavior))

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        stop()
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func setBehavior(_ behavior: Behavior) {
        state.withLock { $0.behavior = behavior }
    }

    func snapshotStats() -> Stats {
        state.withLock { $0.stats }
    }

    func stop() {
        let shouldClose = state.withLock { s -> Bool in
            if s.isStopped { return false }
            s.isStopped = true
            return true
        }
        if shouldClose {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
        }
    }

    private func acceptLoop() {
        while true {
            if state.withLock({ $0.isStopped }) { return }
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenFD, sockPtr, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            workerQueue.async { [weak self] in
                self?.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.close(fd) }
        guard let rawHeaders = readRequestHeaders(fd: fd),
              let text = String(data: rawHeaders, encoding: .utf8) else {
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let rangeHeader = headers["range"]
        let cookieHeader = headers["cookie"]
        let isProbe = (rangeHeader == "bytes=0-0")

        let behavior: Behavior = state.withLock { s in
            s.stats.totalRequests += 1
            s.stats.receivedPaths.append(path)
            if isProbe { s.stats.probeRequests += 1 }
            if rangeHeader != nil && !isProbe { s.stats.rangeRequests += 1 }
            if let cookie = cookieHeader {
                s.stats.receivedCookies.append(cookie)
            }
            return s.behavior
        }

        switch behavior {
        case .status403:
            let body = Data("Forbidden".utf8)
            let resp = "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            sendAll(fd: fd, data: Data(resp.utf8) + body)

        case .status200NoRange(let payload, let delayMicros):
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            sendAll(fd: fd, data: Data(resp.utf8))
            sendChunkedWithDelay(fd: fd, slice: payload, delayMicrosPer64K: delayMicros)

        case .range206(let payload, let eTag, let contentDisposition, let delayMicros):
            let total = payload.count
            var extra = ""
            if let eTag { extra += "ETag: \(eTag)\r\n" }
            if let contentDisposition { extra += "Content-Disposition: \(contentDisposition)\r\n" }

            if let rangeHeader, let (start, end) = parseRange(rangeHeader, total: total) {
                let slice = payload[start...end]
                let resp = "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes \(start)-\(end)/\(total)\r\nContent-Length: \(slice.count)\r\n\(extra)Connection: close\r\n\r\n"
                sendAll(fd: fd, data: Data(resp.utf8))
                sendChunkedWithDelay(fd: fd, slice: Data(slice), delayMicrosPer64K: isProbe ? 0 : delayMicros)
            } else {
                let resp = "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: application/octet-stream\r\nContent-Length: \(total)\r\n\(extra)Connection: close\r\n\r\n"
                sendAll(fd: fd, data: Data(resp.utf8))
                sendChunkedWithDelay(fd: fd, slice: payload, delayMicrosPer64K: delayMicros)
            }

        case .hlsFMP4(let playlistPath, let initMap, let segments):
            if path == playlistPath {
                var m3u8 = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"/init.mp4\"\n"
                for idx in segments.indices {
                    m3u8 += "#EXTINF:4.0,\n/seg\(idx).m4s\n"
                }
                m3u8 += "#EXT-X-ENDLIST\n"
                let body = Data(m3u8.utf8)
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                sendAll(fd: fd, data: Data(resp.utf8) + body)
            } else if path == "/init.mp4" {
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(initMap.count)\r\nConnection: close\r\n\r\n"
                sendAll(fd: fd, data: Data(resp.utf8) + initMap)
            } else if path.hasPrefix("/seg"), path.hasSuffix(".m4s") {
                let numStr = path.dropFirst(4).dropLast(4)
                if let idx = Int(numStr), segments.indices.contains(idx) {
                    let seg = segments[idx]
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: video/iso.segment\r\nContent-Length: \(seg.count)\r\nConnection: close\r\n\r\n"
                    sendAll(fd: fd, data: Data(resp.utf8) + seg)
                    return
                }
                let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                sendAll(fd: fd, data: Data(resp.utf8))
            } else {
                let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                sendAll(fd: fd, data: Data(resp.utf8))
            }
        }
    }

    private func parseRange(_ header: String, total: Int) -> (Int, Int)? {
        guard header.lowercased().hasPrefix("bytes="), total > 0 else { return nil }
        let spec = header.dropFirst(6)
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]), start >= 0, start < total else { return nil }
        let end = bounds[1].isEmpty ? (total - 1) : min(total - 1, Int(bounds[1]) ?? (total - 1))
        guard end >= start else { return nil }
        return (start, end)
    }

    private func readRequestHeaders(fd: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let delimiter = Data("\r\n\r\n".utf8)
        while data.count < 65_536 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.range(of: delimiter) != nil {
                return data
            }
        }
        return data.isEmpty ? nil : data
    }

    private func sendChunkedWithDelay(fd: Int32, slice: Data, delayMicrosPer64K: useconds_t) {
        guard delayMicrosPer64K > 0 else {
            sendAll(fd: fd, data: slice)
            return
        }
        let step = 64 * 1024
        var offset = 0
        while offset < slice.count {
            if state.withLock({ $0.isStopped }) { return }
            let end = min(slice.count, offset + step)
            let chunk = slice.subdata(in: offset..<end)
            if !sendAll(fd: fd, data: chunk) { return }
            offset = end
            if offset < slice.count {
                usleep(delayMicrosPer64K)
            }
        }
    }

    @discardableResult
    private func sendAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }
}

// MARK: - Lightweight Test Doubles for Routing Tests

@MainActor
private final class RoutingMockTabHost: NSObject, CrIOSTabHostingV1 {
    let tabID: String
    var extensionTabID: Int32 = 1
    let webView = UIView()
    var scrollView: UIScrollView?
    var currentURL: URL?
    var title = "Test Tab"
    var isLoading = false
    var estimatedProgress = 1.0
    var canGoBack = false
    var canGoForward = false
    var usesDesktopUserAgent = false
    var pageCanvasColor: UIColor?
    var isWebFullscreen = false
    var effectiveUserAgent: String? = "CuriumTestUA/27.2"

    init(tabID: String = "routing-tab-1", url: URL? = nil) {
        self.tabID = tabID
        self.currentURL = url
        super.init()
    }

    func load(_ url: URL) { currentURL = url }
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stopLoading() {}
    func setUsesDesktopUserAgent(_ desktop: Bool) { usesDesktopUserAgent = desktop }
    func presentFindInPage() {}
    func setPageZoomScale(_ scale: CGFloat) {}
    func takeSnapshot(completion: @escaping @MainActor (UIImage?) -> Void) { completion(nil) }
}

@MainActor
private final class RoutingMockBrowserHost: NSObject, CrIOSBrowserHostV1 {
    weak var delegate: (any CrIOSBrowserHostDelegateV1)?
    var tabs: [any CrIOSTabHostingV1] = []
    var activeTab: (any CrIOSTabHostingV1)?
    var cookieHeaderProvider: (@MainActor (URL, String) -> String?)?

    func createTab(with url: URL?, activate: Bool) -> (any CrIOSTabHostingV1)? {
        let tab = RoutingMockTabHost(tabID: UUID().uuidString, url: url)
        tabs.append(tab)
        if activate { activeTab = tab }
        return tab
    }

    func activateTab(withID tabID: String) -> Bool {
        guard let found = tabs.first(where: { $0.tabID == tabID }) else { return false }
        activeTab = found
        return true
    }

    func closeTab(withID tabID: String) -> Bool {
        tabs.removeAll { $0.tabID == tabID }
        if activeTab?.tabID == tabID { activeTab = tabs.first }
        return true
    }

    func clearBrowsingData(
        of types: CrIOSBrowsingDataTypes,
        modifiedSince date: Date,
        completion: @escaping @MainActor ((any Error)?) -> Void
    ) {
        completion(nil)
    }

    func cookieHeader(
        for url: URL,
        inTabWithID tabID: String,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        completion(cookieHeaderProvider?(url, tabID))
    }
}

@MainActor
private final class RoutingMockDownloadTask: NSObject, CrIOSDownloadTaskV1 {
    let downloadID: String
    let sourceTabID: String?
    let originalURL: URL?
    let suggestedFilename: String
    let mimeType: String?
    var isExplicitDownload: Bool
    var isMainFrame: Bool
    var httpMethod: String
    var totalBytes: Int64
    var receivedBytes: Int64 = 0
    var state: CrIOSDownloadState = .pending

    var payloadToWrite: Data
    var simulatedChunkCount: Int
    var simulatedStepDelayMs: UInt64
    var holdInProgressUntilCancelled: Bool

    private(set) var startCallCount = 0
    private(set) var cancelCount = 0
    private var pendingCompletion: (@MainActor (URL?, (any Error)?) -> Void)?
    private var streamingTask: Task<Void, Never>?

    init(
        downloadID: String = UUID().uuidString,
        sourceTabID: String? = "routing-tab-1",
        originalURL: URL?,
        suggestedFilename: String,
        mimeType: String? = "application/octet-stream",
        isExplicitDownload: Bool = true,
        isMainFrame: Bool = true,
        httpMethod: String = "GET",
        totalBytes: Int64 = -1,
        payloadToWrite: Data = Data("blink-fallback-bytes".utf8),
        simulatedChunkCount: Int = 1,
        simulatedStepDelayMs: UInt64 = 0,
        holdInProgressUntilCancelled: Bool = false
    ) {
        self.downloadID = downloadID
        self.sourceTabID = sourceTabID
        self.originalURL = originalURL
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.isExplicitDownload = isExplicitDownload
        self.isMainFrame = isMainFrame
        self.httpMethod = httpMethod
        self.totalBytes = totalBytes
        self.payloadToWrite = payloadToWrite
        self.simulatedChunkCount = max(1, simulatedChunkCount)
        self.simulatedStepDelayMs = simulatedStepDelayMs
        self.holdInProgressUntilCancelled = holdInProgressUntilCancelled
        super.init()
    }

    func start(
        withDestinationURL destinationURL: URL,
        completion: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) {
        startCallCount += 1
        state = .inProgress

        if holdInProgressUntilCancelled {
            pendingCompletion = completion
            return
        }

        if simulatedStepDelayMs == 0 && simulatedChunkCount <= 1 {
            do {
                try payloadToWrite.write(to: destinationURL, options: .atomic)
                receivedBytes = Int64(payloadToWrite.count)
                if totalBytes <= 0 { totalBytes = Int64(payloadToWrite.count) }
                state = .completed
                completion(destinationURL, nil)
            } catch {
                state = .failed
                completion(nil, error)
            }
            return
        }

        pendingCompletion = completion
        let payload = payloadToWrite
        let steps = simulatedChunkCount
        let delayMs = simulatedStepDelayMs
        streamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let chunkSize = max(1, payload.count / steps)
            var written = 0
            for step in 0..<steps {
                if Task.isCancelled || self.state == .cancelled { return }
                if delayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
                if Task.isCancelled || self.state == .cancelled { return }
                written = (step == steps - 1) ? payload.count : min(payload.count, (step + 1) * chunkSize)
                self.receivedBytes = Int64(written)
            }
            do {
                try payload.write(to: destinationURL, options: .atomic)
                self.state = .completed
                let done = self.pendingCompletion
                self.pendingCompletion = nil
                done?(destinationURL, nil)
            } catch {
                self.state = .failed
                let done = self.pendingCompletion
                self.pendingCompletion = nil
                done?(nil, error)
            }
        }
    }

    func cancel() {
        cancelCount += 1
        state = .cancelled
        streamingTask?.cancel()
        streamingTask = nil
        let done = pendingCompletion
        pendingCompletion = nil
        done?(nil, CancellationError())
    }
}

private actor RoutingCommitGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEnteredAndWaitForRelease() async {
        entered = true
        for w in enteredWaiters { w.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { cont in
            releaseWaiters.append(cont)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { cont in
            enteredWaiters.append(cont)
        }
    }

    func release() {
        released = true
        for w in releaseWaiters { w.resume() }
        releaseWaiters.removeAll()
    }
}

// MARK: - Helpers

private func makeRoutingSandbox(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeSyntheticPayload(bytes: Int) -> Data {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { raw in
        guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for i in 0..<bytes {
            ptr[i] = UInt8((i &* 31 &+ (i >> 7)) & 0xFF)
        }
    }
    return data
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeMinimalFMP4Box(fourCC: String, bodySize: Int) -> Data {
    let totalSize = UInt32(8 + bodySize)
    var data = Data()
    var be = totalSize.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    data.append(Data(fourCC.utf8.prefix(4)))
    data.append(Data(repeating: 0x42, count: bodySize))
    return data
}

@MainActor
private func waitForCondition(
    timeoutSeconds: Double = 6.0,
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return predicate()
}

// MARK: - Wave 2A Transfer Coordinator & Routing Test Suite

@Suite("Wave 2A: CuriumTransferCoordinator Routing, Storage, Keep-Alive & Relaunch")
struct CuriumTransferRoutingTests {
    @Test("Non-destructive Blink GET upgrade cancels mock on 206 >= 512 KiB and completes via multi-lane Range")
    @MainActor
    func blinkGETUpgradeToMultiLaneRange() async throws {
        let sandbox = try makeRoutingSandbox("curium-route-upgrade")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let stagingRoot = sandbox.appending(path: "Staging", directoryHint: .isDirectory)
        let dbURL = sandbox.appending(path: "Transfers/transfers.sqlite3", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        let payload = makeSyntheticPayload(bytes: 768 * 1024)
        let expectedSHA = sha256Hex(payload)
        let server = try RoutingLoopbackServer(
            behavior: .range206(
                payload: payload,
                eTag: "\"curium-upgrade-v1\"",
                contentDisposition: "attachment; filename=\"archive.bin\"",
                uniformDelayMicrosPer64K: 0
            )
        )
        defer { server.stop() }

        let targetURL = server.url(path: "/archive.bin")
        let host = RoutingMockBrowserHost()
        let tab = RoutingMockTabHost(tabID: "t-up", url: server.url(path: "/page"))
        host.tabs = [tab]
        host.activeTab = tab

        let store = CuriumBrowserStore(
            host: host,
            downloadsRoot: downloadsRoot,
            restoreSession: false,
            transferDatabaseURL: dbURL,
            transferStagingRoot: stagingRoot
        )
        await store.waitForTransferHydration()

        let blinkMock = RoutingMockDownloadTask(
            downloadID: "blink-upgrade-1",
            sourceTabID: "t-up",
            originalURL: targetURL,
            suggestedFilename: "archive.bin",
            mimeType: "application/octet-stream",
            httpMethod: "GET",
            totalBytes: -1,
            payloadToWrite: Data("should-never-run".utf8)
        )
        store.browserHost(host, didCreateDownload: blinkMock)

        let item = try #require(store.downloads.first)
        #expect(item.phase == .pendingConfirmation)
        #expect(store.activeDownloadBanner?.id == item.id)

        await store.startDownload(item)

        // Probe succeeded with 206 >= 512 KiB: Blink task was cancelled without starting, and Range engine finished bit-exact.
        #expect(blinkMock.cancelCount == 1)
        #expect(blinkMock.startCallCount == 0)
        #expect(item.phase == .completed)
        #expect(item.state == .completed)
        #expect(item.transportKind == .multiLaneRange)
        #expect(item.knownTotalBytes == Int64(payload.count))
        #expect(item.totalBytes == Int64(payload.count))
        #expect(!item.slices.isEmpty)
        #expect(item.eTag == "\"curium-upgrade-v1\"")

        let savedURL = try #require(item.savedURL)
        #expect(savedURL.deletingLastPathComponent().standardizedFileURL == downloadsRoot.standardizedFileURL)
        let savedData = try Data(contentsOf: savedURL)
        #expect(sha256Hex(savedData) == expectedSHA)

        let stats = server.snapshotStats()
        #expect(stats.probeRequests >= 1)
        #expect(stats.rangeRequests >= 1)
    }

    @Test("Non-destructive Blink fallback preserves download on 403, 200-no-range, and POST while emitting live speed and .saving phase")
    @MainActor
    func blinkFallbackPreservesDownloadAndEmitsTelemetryAndSavingPhase() async throws {
        let sandbox = try makeRoutingSandbox("curium-route-fallback")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let stagingRoot = sandbox.appending(path: "Staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        let host = RoutingMockBrowserHost()
        let tab = RoutingMockTabHost(tabID: "t-fb", url: URL(string: "http://127.0.0.1/"))
        host.tabs = [tab]
        host.activeTab = tab

        let store = CuriumBrowserStore(
            host: host,
            downloadsRoot: downloadsRoot,
            restoreSession: false,
            transferStagingRoot: stagingRoot
        )

        // 1. Probe returns 403 (single-use nonce): Blink task MUST NOT be cancelled, emits live speed/bytes & .saving phase!
        let server403 = try RoutingLoopbackServer(behavior: .status403)
        defer { server403.stop() }

        let payload403 = makeSyntheticPayload(bytes: 600 * 1024)
        let blink403 = RoutingMockDownloadTask(
            downloadID: "blink-403",
            sourceTabID: "t-fb",
            originalURL: server403.url(path: "/nonce-download.bin"),
            suggestedFilename: "nonce.bin",
            httpMethod: "GET",
            totalBytes: Int64(payload403.count),
            payloadToWrite: payload403,
            simulatedChunkCount: 4,
            simulatedStepDelayMs: 90
        )
        store.browserHost(host, didCreateDownload: blink403)
        let item403 = try #require(store.downloads.first { $0.id == "blink-403" })

        let commitGate = RoutingCommitGate()
        let dest403 = downloadsRoot.appending(path: "nonce.bin", directoryHint: .notDirectory)
        item403.stagedCommitHandlerOverride = { stagedURL, _ in
            await commitGate.markEnteredAndWaitForRelease()
            try FileManager.default.copyItem(at: stagedURL, to: dest403)
            return dest403
        }

        let run403 = Task { @MainActor in
            await store.startDownload(item403)
        }

        await commitGate.waitUntilEntered()
        // While committing to external/downloads folder, phase MUST be .saving and keep-alive MUST stay armed!
        #expect(item403.phase == .saving)
        #expect(item403.requiresBackgroundKeepAlive)
        #expect(store.backgroundKeepAliveActiveTaskCount >= 1)
        #expect(item403.saveDestinationLabel != nil)
        #expect(item403.receivedBytes == Int64(payload403.count))
        #expect(item403.peakSpeedBytesPerSec > 0)

        await commitGate.release()
        await run403.value

        #expect(blink403.cancelCount == 0)
        #expect(blink403.startCallCount == 1)
        #expect(item403.phase == .completed)
        #expect(item403.transportKind == .blinkNativeStream)
        #expect(try Data(contentsOf: dest403) == payload403)

        // 2. Probe returns 200 OK without Range support -> falls back to Blink without cancelling.
        let payload200 = makeSyntheticPayload(bytes: 600 * 1024)
        let server200 = try RoutingLoopbackServer(behavior: .status200NoRange(payload: payload200))
        defer { server200.stop() }

        let blink200 = RoutingMockDownloadTask(
            downloadID: "blink-200",
            sourceTabID: "t-fb",
            originalURL: server200.url(path: "/stream.bin"),
            suggestedFilename: "stream.bin",
            httpMethod: "GET",
            totalBytes: -1,
            payloadToWrite: payload200
        )
        store.browserHost(host, didCreateDownload: blink200)
        let item200 = try #require(store.downloads.first { $0.id == "blink-200" })
        await store.startDownload(item200)

        #expect(blink200.cancelCount == 0)
        #expect(blink200.startCallCount == 1)
        #expect(item200.phase == .completed)
        #expect(item200.transportKind == .blinkNativeStream)
        let saved200 = try #require(item200.savedURL)
        #expect(try Data(contentsOf: saved200) == payload200)

        // 3. POST download -> skips HTTP probe entirely (zero probe requests!) and runs BlinkNativeRunner.
        let serverPost = try RoutingLoopbackServer(
            behavior: .range206(payload: payload200, eTag: "\"post\"", contentDisposition: nil, uniformDelayMicrosPer64K: 0)
        )
        defer { serverPost.stop() }

        let postPayload = Data("generated-export-csv".utf8)
        let blinkPost = RoutingMockDownloadTask(
            downloadID: "blink-post",
            sourceTabID: "t-fb",
            originalURL: serverPost.url(path: "/export.csv"),
            suggestedFilename: "export.csv",
            httpMethod: "POST",
            totalBytes: -1,
            payloadToWrite: postPayload
        )
        store.browserHost(host, didCreateDownload: blinkPost)
        let itemPost = try #require(store.downloads.first { $0.id == "blink-post" })
        await store.startDownload(itemPost)

        #expect(serverPost.snapshotStats().totalRequests == 0)
        #expect(blinkPost.cancelCount == 0)
        #expect(blinkPost.startCallCount == 1)
        #expect(itemPost.phase == .completed)
        #expect(!itemPost.canRetry)
        let savedPost = try #require(itemPost.savedURL)
        #expect(try Data(contentsOf: savedPost) == postPayload)
    }

    @Test("listSavedDownloads filters .crdownload and .part artifacts while durable staging stays isolated")
    func incompleteArtifactsFilteredFromSavedDownloadsAndStagingIsolation() throws {
        let sandbox = try makeRoutingSandbox("curium-filter-part")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let stagingRoot = sandbox.appending(path: "Transfers/Staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        try Data("pdf-data".utf8).write(to: downloadsRoot.appending(path: "paper.pdf"))
        try Data("partial-chrome".utf8).write(to: downloadsRoot.appending(path: "movie.mp4.crdownload"))
        try Data("partial-range".utf8).write(to: downloadsRoot.appending(path: "archive.zip.part"))
        try Data("upper-chrome".utf8).write(to: downloadsRoot.appending(path: "ISO.CRDOWNLOAD"))
        try Data("upper-part".utf8).write(to: downloadsRoot.appending(path: "VIDEO.PART"))

        let legacyNested = downloadsRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyNested, withIntermediateDirectories: true)
        try Data("nested-real".utf8).write(to: legacyNested.appending(path: "notes.txt"))
        try Data("nested-part".utf8).write(to: legacyNested.appending(path: "video.part"))

        let listed = CuriumDownloadStorage.listSavedDownloads(in: downloadsRoot)
        let filenames = Set(listed.map(\.filename))
        #expect(filenames == Set(["paper.pdf", "notes.txt"]))
        #expect(!filenames.contains("movie.mp4.crdownload"))
        #expect(!filenames.contains("archive.zip.part"))
        #expect(!filenames.contains("ISO.CRDOWNLOAD"))
        #expect(!filenames.contains("VIDEO.PART"))
        #expect(!filenames.contains("video.part"))

        // Verify durable staging helpers isolate & clean cleanly.
        let transferDir = try CuriumDownloadStorage.durableTransferStagingDirectory(
            for: "transfer-abc",
            stagingRoot: stagingRoot
        )
        #expect(FileManager.default.fileExists(atPath: transferDir.path))
        let orphanDir = try CuriumDownloadStorage.durableTransferStagingDirectory(
            for: "orphan-xyz",
            stagingRoot: stagingRoot
        )
        CuriumDownloadStorage.cleanupOrphanedDurableTransferStaging(
            preservingDirectoryNames: ["transfer-abc"],
            stagingRoot: stagingRoot,
            minimumAgeSeconds: 0
        )
        #expect(FileManager.default.fileExists(atPath: transferDir.path))
        #expect(!FileManager.default.fileExists(atPath: orphanDir.path))
    }

    @Test("syncBackgroundKeepAlive stays active during .saving commit phase AND active inline PDFSession")
    @MainActor
    func backgroundKeepAliveCoversSavingPhaseAndActivePDFSession() async throws {
        let sandbox = try makeRoutingSandbox("curium-keepalive-saving-pdf")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let previewRoot = sandbox.appending(path: "PDFPreview", directoryHint: .isDirectory)
        let stagingRoot = sandbox.appending(path: "Staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)

        let host = RoutingMockBrowserHost()
        let tab = RoutingMockTabHost(tabID: "t-ka", url: URL(string: "https://docs.example/"))
        host.tabs = [tab]
        host.activeTab = tab

        let store = CuriumBrowserStore(
            host: host,
            downloadsRoot: downloadsRoot,
            pdfPreviewCacheRoot: previewRoot,
            restoreSession: false,
            transferStagingRoot: stagingRoot
        )
        #expect(store.backgroundKeepAliveActiveTaskCount == 0)

        // 1. Active inline PDFSession increments backgroundKeepAliveActiveTaskCount while loading.
        let pdfTask = RoutingMockDownloadTask(
            downloadID: "inline-pdf-ka",
            sourceTabID: "t-ka",
            originalURL: URL(string: "https://docs.example/spec.pdf"),
            suggestedFilename: "spec.pdf",
            mimeType: "application/pdf",
            isExplicitDownload: false,
            isMainFrame: true,
            httpMethod: "GET",
            totalBytes: 5_000_000,
            holdInProgressUntilCancelled: true
        )
        store.browserHost(host, didCreateDownload: pdfTask)
        #expect(store.downloads.isEmpty)
        #expect(store.activeTab?.pdfSession != nil)
        #expect(store.backgroundKeepAliveActiveTaskCount == 1)

        // 2. Concurrent download entering `.saving` raises count to 2 and keeps keep-alive alive even after task completes.
        let binTask = RoutingMockDownloadTask(
            downloadID: "saving-ka",
            sourceTabID: "t-ka",
            originalURL: URL(string: "https://docs.example/small.bin"),
            suggestedFilename: "small.bin",
            mimeType: "application/octet-stream",
            isExplicitDownload: true,
            httpMethod: "GET",
            totalBytes: 128,
            payloadToWrite: Data(repeating: 0x5A, count: 128)
        )
        store.browserHost(host, didCreateDownload: binTask)
        let binItem = try #require(store.downloads.first { $0.id == "saving-ka" })

        let gate = RoutingCommitGate()
        let dest = downloadsRoot.appending(path: "small.bin", directoryHint: .notDirectory)
        binItem.stagedCommitHandlerOverride = { stagedURL, _ in
            await gate.markEnteredAndWaitForRelease()
            try FileManager.default.copyItem(at: stagedURL, to: dest)
            return dest
        }

        let startTask = Task { @MainActor in
            await store.startDownload(binItem)
        }
        await gate.waitUntilEntered()
        #expect(binItem.phase == .saving)
        #expect(binItem.requiresBackgroundKeepAlive)
        #expect(store.backgroundKeepAliveActiveTaskCount == 2)

        await gate.release()
        await startTask.value
        #expect(binItem.phase == .completed)
        #expect(!binItem.requiresBackgroundKeepAlive)
        #expect(store.backgroundKeepAliveActiveTaskCount == 1)

        // Dismissing the loading PDF drops keep-alive back to 0.
        store.activeTab?.dismissPDFSession()
        let drained = await waitForCondition { store.backgroundKeepAliveActiveTaskCount == 0 }
        #expect(drained)
    }

    @Test("prepareForProfileSwitchAndRelaunch pauses active multi-lane transfer instead of cancelling and resumes bit-exact after cold launch")
    @MainActor
    func profileSwitchPausesInsteadOfCancellingAndResumesAfterColdLaunch() async throws {
        let sandbox = try makeRoutingSandbox("curium-relaunch-pause")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let stagingRoot = sandbox.appending(path: "Transfers/Staging", directoryHint: .isDirectory)
        let dbURL = sandbox.appending(path: "Transfers/transfers.sqlite3", directoryHint: .notDirectory)
        let fpFileURL = sandbox.appending(path: "profiles.json", directoryHint: .notDirectory)
        let sessionDir = sandbox.appending(path: "Sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        let fpStore = CuriumFingerprintStore(fileURL: fpFileURL)
        let secondProfile = try #require(
            fpStore.createProfile(fromTemplate: "macos-desktop", displayName: "Work Profile")
        )

        let payload = makeSyntheticPayload(bytes: 1_536 * 1024)
        let expectedSHA = sha256Hex(payload)
        let server = try RoutingLoopbackServer(
            behavior: .range206(
                payload: payload,
                eTag: "\"relaunch-etag-1\"",
                contentDisposition: nil,
                uniformDelayMicrosPer64K: 45_000
            )
        )
        defer { server.stop() }

        let host = RoutingMockBrowserHost()
        let tab = RoutingMockTabHost(tabID: "t-rel", url: server.url(path: "/"))
        host.tabs = [tab]
        host.activeTab = tab

        let store = CuriumBrowserStore(
            host: host,
            downloadsRoot: downloadsRoot,
            activeProfileID: "default",
            fingerprintStore: fpStore,
            sessionDirectoryOverride: sessionDir,
            restoreSession: false,
            transferDatabaseURL: dbURL,
            transferStagingRoot: stagingRoot
        )
        await store.waitForTransferHydration()

        let url = server.url(path: "/large-asset.bin")
        let item = try #require(await store.startManualDownload(
            url: url,
            suggestedFilename: "large-asset.bin",
            lanes: 4,
            includeActiveTabCookies: false
        ))

        let madeProgress = await waitForCondition(timeoutSeconds: 6.0) {
            item.phase == .downloading && item.receivedBytes >= 64 * 1024 && !item.slices.isEmpty
        }
        #expect(madeProgress)

        var relaunchCalls = 0
        let switched = await store.prepareForProfileSwitchAndRelaunch(to: secondProfile.id) {
            relaunchCalls += 1
        }
        #expect(switched)
        #expect(relaunchCalls == 1)

        // CRITICAL: Active transfer MUST be `.paused` (NOT `.cancelled`!), preserving byte-range slices!
        #expect(item.phase == .paused)
        #expect(item.state != .cancelled)
        #expect(item.canResume)
        #expect(item.receivedBytes > 0)
        #expect(!item.slices.isEmpty)

        // Speed up server after simulated process restart and hydrate into a fresh CuriumBrowserStore.
        server.setBehavior(.range206(
            payload: payload,
            eTag: "\"relaunch-etag-1\"",
            contentDisposition: nil,
            uniformDelayMicrosPer64K: 0
        ))

        let freshStore = CuriumBrowserStore(
            host: nil,
            downloadsRoot: downloadsRoot,
            activeProfileID: secondProfile.id,
            fingerprintStore: fpStore,
            sessionDirectoryOverride: sessionDir,
            restoreSession: false,
            transferDatabaseURL: dbURL,
            transferStagingRoot: stagingRoot
        )
        await freshStore.waitForTransferHydration()

        let hydrated = try #require(freshStore.downloads.first { $0.id == item.id })
        #expect(hydrated.phase == .paused)
        #expect(hydrated.canResume)
        #expect(hydrated.receivedBytes > 0)
        #expect(!hydrated.slices.isEmpty)

        // Clear Finished MUST NOT drop paused transfers!
        freshStore.clearFinishedDownloadTasks()
        #expect(freshStore.downloads.contains { $0.id == hydrated.id })

        freshStore.resumeDownload(hydrated)
        let completed = await waitForCondition(timeoutSeconds: 6.0) {
            hydrated.phase == .completed
        }
        #expect(completed)

        let savedURL = try #require(hydrated.savedURL)
        let savedData = try Data(contentsOf: savedURL)
        #expect(sha256Hex(savedData) == expectedSHA)
    }

    @Test("startManualDownload routes .m3u8 to HLS (.mp4 output) vs HTTP file to Range engine and canInheritActiveTabCookies enforces same-site only")
    @MainActor
    func manualDownloadRoutingAndSameSiteCookieInheritance() async throws {
        let sandbox = try makeRoutingSandbox("curium-manual-routing")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let stagingRoot = sandbox.appending(path: "Staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        let host = RoutingMockBrowserHost()
        let tab = RoutingMockTabHost(tabID: "t-man", url: URL(string: "https://www.example.com/watch"))
        host.tabs = [tab]
        host.activeTab = tab

        let store = CuriumBrowserStore(
            host: host,
            downloadsRoot: downloadsRoot,
            restoreSession: false,
            transferStagingRoot: stagingRoot
        )

        // 1. canInheritActiveTabCookies: strict same-site (eTLD+1) + no HTTPS -> HTTP downgrade.
        #expect(store.canInheritActiveTabCookies(for: try #require(URL(string: "https://cdn.example.com/movie.mp4"))))
        #expect(store.canInheritActiveTabCookies(for: try #require(URL(string: "https://example.com/file.zip"))))
        #expect(!store.canInheritActiveTabCookies(for: try #require(URL(string: "http://cdn.example.com/movie.mp4"))))
        #expect(!store.canInheritActiveTabCookies(for: try #require(URL(string: "https://evil.org/movie.mp4"))))
        #expect(!store.canInheritActiveTabCookies(for: try #require(URL(string: "https://notexample.com/movie.mp4"))))

        tab.currentURL = URL(string: "https://news.bbc.co.uk/story")
        #expect(store.canInheritActiveTabCookies(for: try #require(URL(string: "https://cdn.bbc.co.uk/clip.mp4"))))
        #expect(!store.canInheritActiveTabCookies(for: try #require(URL(string: "https://other.co.uk/clip.mp4"))))

        // 2. Manual `.m3u8` routes to CuriumHLSTransferEngine and ALWAYS produces `.mp4` output.
        let initMap = makeMinimalFMP4Box(fourCC: "ftyp", bodySize: 24)
        let seg0 = makeMinimalFMP4Box(fourCC: "moof", bodySize: 64)
        let seg1 = makeMinimalFMP4Box(fourCC: "mdat", bodySize: 96)
        let expectedHLSBytes = initMap + seg0 + seg1

        let hlsServer = try RoutingLoopbackServer(
            behavior: .hlsFMP4(playlistPath: "/live/index.m3u8", initMap: initMap, segments: [seg0, seg1])
        )
        defer { hlsServer.stop() }

        let hlsItem = try #require(await store.startManualDownload(
            url: hlsServer.url(path: "/live/index.m3u8"),
            suggestedFilename: "lecture.ts",
            lanes: 4,
            includeActiveTabCookies: false
        ))
        #expect(hlsItem.source == .manualURL)
        #expect(hlsItem.transportKind == .hlsRemuxMP4)
        #expect(hlsItem.filename.hasSuffix(".mp4"))

        let hlsDone = await waitForCondition(timeoutSeconds: 6.0) {
            hlsItem.phase == .completed
        }
        #expect(hlsDone)
        let savedHLS = try #require(hlsItem.savedURL)
        #expect(savedHLS.pathExtension.lowercased() == "mp4")
        #expect(try Data(contentsOf: savedHLS) == expectedHLSBytes)

        // 3. Manual HTTP file routes to Range engine with requested lanes & optional active tab cookies.
        let filePayload = makeSyntheticPayload(bytes: 640 * 1024)
        let rangeServer = try RoutingLoopbackServer(
            behavior: .range206(
                payload: filePayload,
                eTag: "\"manual-v1\"",
                contentDisposition: nil,
                uniformDelayMicrosPer64K: 0
            )
        )
        defer { rangeServer.stop() }

        let fileURL = rangeServer.url(path: "/bundle.tar")
        tab.currentURL = rangeServer.url(path: "/releases")
        #expect(store.canInheritActiveTabCookies(for: fileURL))
        host.cookieHeaderProvider = { _, _ in "session_token=curium_ok" }

        let rangeItem = try #require(await store.startManualDownload(
            url: fileURL,
            suggestedFilename: "bundle.tar",
            lanes: 4,
            includeActiveTabCookies: true
        ))
        #expect(rangeItem.source == .manualURL)
        #expect(rangeItem.transportKind == .multiLaneRange)
        #expect(rangeItem.configuredLanes == 4)

        let rangeDone = await waitForCondition(timeoutSeconds: 6.0) {
            rangeItem.phase == .completed
        }
        #expect(rangeDone)
        let savedRange = try #require(rangeItem.savedURL)
        #expect(sha256Hex(try Data(contentsOf: savedRange)) == sha256Hex(filePayload))
        #expect(rangeServer.snapshotStats().receivedCookies.contains("session_token=curium_ok"))

        // 4. removeTransfer removes the transfer item from the queue cleanly without deleting the saved file.
        store.removeTransfer(rangeItem)
        #expect(!store.downloads.contains { $0.id == rangeItem.id })
        #expect(FileManager.default.fileExists(atPath: savedRange.path))
    }

    @Test("Media Radar Direct ignores bogus subresource chunk contentLength and Media Radar HLS preserves masterPlaylistURL and .mp4 output")
    @MainActor
    func mediaRadarDirectAndHLSRouting() async throws {
        let sandbox = try makeRoutingSandbox("curium-radar-routing")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let stagingRoot = sandbox.appending(path: "Staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        let payload = makeSyntheticPayload(bytes: 640 * 1024)
        let directServer = try RoutingLoopbackServer(
            behavior: .range206(
                payload: payload,
                eTag: "\"radar-mp4\"",
                contentDisposition: nil,
                uniformDelayMicrosPer64K: 0
            )
        )
        defer { directServer.stop() }

        let initMap = makeMinimalFMP4Box(fourCC: "ftyp", bodySize: 24)
        let seg0 = makeMinimalFMP4Box(fourCC: "moof", bodySize: 64)
        let seg1 = makeMinimalFMP4Box(fourCC: "mdat", bodySize: 96)
        let hlsServer = try RoutingLoopbackServer(
            behavior: .hlsFMP4(playlistPath: "/v720/index.m3u8", initMap: initMap, segments: [seg0, seg1])
        )
        defer { hlsServer.stop() }

        let host = RoutingMockBrowserHost()
        let tab = RoutingMockTabHost(tabID: "t-radar", url: directServer.url(path: "/watch"))
        host.tabs = [tab]
        host.activeTab = tab

        let store = CuriumBrowserStore(
            host: host,
            downloadsRoot: downloadsRoot,
            restoreSession: false,
            transferStagingRoot: stagingRoot
        )

        // 1. Direct Media Radar candidate with bogus Blink chunk `contentLength: 1024` must probe true 640 KiB size via Range.
        let directURL = directServer.url(path: "/clip.mp4")
        let directCandidate = CuriumMediaCandidate(
            id: directURL.absoluteString,
            url: directURL,
            kind: .video,
            title: "Clip",
            host: "127.0.0.1",
            mimeType: "video/mp4",
            contentLength: 1024, // Bogus 206 subresource chunk size from Blink!
            resolutionLabel: "1080p",
            durationSeconds: 12,
            referrer: directServer.url(path: "/watch"),
            frameOrigin: "http://127.0.0.1:\(directServer.port)",
            effectiveUserAgent: "CuriumTestUA/27.2",
            fromDOM: false,
            fromNetwork: true
        )

        let directItem = try #require(await store.startMediaDownload(candidate: directCandidate, inTabID: "t-radar"))
        #expect(directItem.source == .mediaRadarDirect)
        // Must NOT seed knownTotalBytes with the bogus 1024 chunk length!
        #expect(directItem.knownTotalBytes != 1024)

        let directCompleted = await waitForCondition(timeoutSeconds: 6.0) {
            directItem.phase == .completed
        }
        #expect(directCompleted)
        #expect(directItem.transportKind == .multiLaneRange)
        #expect(directItem.knownTotalBytes == Int64(payload.count))
        let savedDirect = try #require(directItem.savedURL)
        #expect(sha256Hex(try Data(contentsOf: savedDirect)) == sha256Hex(payload))

        // 2. HLS Media Radar variant always saves as .mp4 and preserves `hlsMasterPlaylistURL`.
        let masterURL = hlsServer.url(path: "/master.m3u8")
        let variantURL = hlsServer.url(path: "/v720/index.m3u8")
        let hlsCandidate = CuriumMediaCandidate(
            id: masterURL.absoluteString,
            url: masterURL,
            kind: .hls,
            title: "Stream",
            host: "127.0.0.1",
            mimeType: "application/vnd.apple.mpegurl",
            contentLength: -1,
            resolutionLabel: nil,
            durationSeconds: nil,
            referrer: hlsServer.url(path: "/watch"),
            frameOrigin: "http://127.0.0.1:\(hlsServer.port)",
            effectiveUserAgent: "CuriumTestUA/27.2",
            fromDOM: false,
            fromNetwork: true
        )
        let variant = CuriumHLSVariant(
            id: variantURL.absoluteString,
            url: variantURL,
            bandwidth: 2_000_000,
            averageBandwidth: nil,
            width: 1280,
            height: 720,
            codecs: nil,
            frameRate: 30,
            audioGroupID: nil,
            audioURI: nil
        )

        let hlsItem = try #require(await store.startMediaDownload(
            candidate: hlsCandidate,
            hlsVariant: variant,
            inTabID: "t-radar"
        ))
        #expect(hlsItem.source == .mediaRadarHLS)
        #expect(hlsItem.transportKind == .hlsRemuxMP4)
        #expect(hlsItem.hlsMasterPlaylistURL == masterURL)
        #expect(hlsItem.filename.hasSuffix(".mp4"))

        let hlsCompleted = await waitForCondition(timeoutSeconds: 6.0) {
            hlsItem.phase == .completed
        }
        #expect(hlsCompleted)
        let savedHLS = try #require(hlsItem.savedURL)
        #expect(savedHLS.pathExtension.lowercased() == "mp4")
        #expect(try Data(contentsOf: savedHLS) == (initMap + seg0 + seg1))
    }

    @Test("Audit fixes: external-folder hydration survival (P1-1), pre-staged complete fast-path (P1-2), singleStream pause & meter reset (P1-3), and retained destination label (P2-1)")
    @MainActor
    func wave3AAuditHardeningRegressions() async throws {
        let sandbox = try makeRoutingSandbox("curium-wave3a-audit")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "CustomExportFolder", directoryHint: .isDirectory)
        let stagingRoot = sandbox.appending(path: "Transfers/Staging", directoryHint: .isDirectory)
        let dbURL = sandbox.appending(path: "Transfers/transfers.sqlite3", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        // Pre-populate SQLite with:
        // (a) [P1-1] Completed record whose external parent directory is unmounted/unreadable -> MUST survive cold-launch hydration!
        // (b) [P1-1] Completed record whose local mounted parent directory IS readable and file was deleted -> MUST prune!
        // (c) [P1-2] Paused HLS transfer whose remuxed `.mp4` is already complete in staging -> MUST commit with 0 network requests!
        // (d) [P1-2] Paused Range transfer whose `.part` file & slices are already complete in staging -> MUST commit with 0 network requests!
        // (e) [P1-3] Paused transfer with prior receivedBytes whose staging vanished -> MUST reset meter to 0 and emit non-zero speed on restart!
        let unmountedParent = sandbox.appending(path: "UnmountedExternalDrive/Videos", directoryHint: .isDirectory)
        let unmountedFile = unmountedParent.appending(path: "cloud-movie.mp4", directoryHint: .notDirectory)
        let deletedLocalFile = downloadsRoot.appending(path: "deleted-local.txt", directoryHint: .notDirectory)

        let zeroRequestServer = try RoutingLoopbackServer(behavior: .status403)
        defer { zeroRequestServer.stop() }

        let restartPayload = makeSyntheticPayload(bytes: 640 * 1024)
        let restartServer = try RoutingLoopbackServer(
            behavior: .range206(
                payload: restartPayload,
                eTag: "\"restart-v1\"",
                contentDisposition: nil,
                uniformDelayMicrosPer64K: 20_000
            )
        )
        defer { restartServer.stop() }

        // Prepare pre-staged complete HLS `.mp4` and Range `.part` on disk.
        let hlsStagedID = "prestaged-hls-1"
        let hlsStagingDir = try CuriumDownloadStorage.durableTransferStagingDirectory(
            for: hlsStagedID,
            stagingRoot: stagingRoot
        )
        let hlsStagedBytes = makeMinimalFMP4Box(fourCC: "ftyp", bodySize: 24)
            + makeMinimalFMP4Box(fourCC: "moof", bodySize: 64)
            + makeMinimalFMP4Box(fourCC: "mdat", bodySize: 128)
        try hlsStagedBytes.write(to: hlsStagingDir.appending(path: "ready-clip.mp4", directoryHint: .notDirectory))

        let rangeStagedID = "prestaged-range-1"
        let rangeStagingDir = try CuriumDownloadStorage.durableTransferStagingDirectory(
            for: rangeStagedID,
            stagingRoot: stagingRoot
        )
        let rangeStagedBytes = makeSyntheticPayload(bytes: 512 * 1024)
        try rangeStagedBytes.write(to: rangeStagingDir.appending(path: "ready-archive.bin.part", directoryHint: .notDirectory))

        let completedSlices = [
            CuriumByteRangeSlice(
                id: 0,
                startOffset: 0,
                currentOffset: Int64(rangeStagedBytes.count),
                endOffset: Int64(rangeStagedBytes.count - 1),
                isActiveLane: false
            ),
        ]

        do {
            let seedStore = try CuriumTransferStore(databaseURL: dbURL, installLifecycleObservers: false)
            await seedStore.upsert(CuriumTransferRecord(
                id: "external-unmounted-completed",
                source: .manualURL,
                transportKind: .multiLaneRange,
                phase: .completed,
                sourceURL: URL(string: "https://cdn.example/cloud-movie.mp4"),
                filename: "cloud-movie.mp4",
                receivedBytes: 4096,
                totalBytes: 4096,
                savedBookmarkPath: unmountedFile.path,
                completedAt: Date()
            ))
            await seedStore.upsert(CuriumTransferRecord(
                id: "local-deleted-completed",
                source: .manualURL,
                transportKind: .multiLaneRange,
                phase: .completed,
                sourceURL: URL(string: "https://cdn.example/deleted-local.txt"),
                filename: "deleted-local.txt",
                receivedBytes: 128,
                totalBytes: 128,
                savedBookmarkPath: deletedLocalFile.path,
                completedAt: Date()
            ))
            await seedStore.upsert(CuriumTransferRecord(
                id: hlsStagedID,
                source: .mediaRadarHLS,
                transportKind: .hlsRemuxMP4,
                phase: .saving,
                sourceURL: zeroRequestServer.url(path: "/never-fetched.m3u8"),
                filename: "ready-clip.mp4",
                mimeType: "video/mp4",
                receivedBytes: Int64(hlsStagedBytes.count),
                hlsCheckpoint: CuriumHLSCheckpoint(playlistURL: zeroRequestServer.url(path: "/never-fetched.m3u8")),
                stagingDirectoryName: hlsStagedID,
                stagingFileName: "ready-clip.mp4"
            ))
            await seedStore.upsert(CuriumTransferRecord(
                id: rangeStagedID,
                source: .manualURL,
                transportKind: .multiLaneRange,
                phase: .saving,
                sourceURL: zeroRequestServer.url(path: "/never-fetched.bin"),
                filename: "ready-archive.bin",
                receivedBytes: Int64(rangeStagedBytes.count),
                totalBytes: Int64(rangeStagedBytes.count),
                slices: completedSlices,
                stagingDirectoryName: rangeStagedID,
                stagingFileName: "ready-archive.bin.part"
            ))
            await seedStore.upsert(CuriumTransferRecord(
                id: "restart-meter-reset-1",
                source: .blinkDownload,
                transportKind: .blinkNativeStream,
                phase: .paused,
                sourceURL: restartServer.url(path: "/restart.bin"),
                filename: "restart.bin",
                receivedBytes: 900_000,
                totalBytes: 950_000,
                stagingDirectoryName: "restart-meter-reset-1",
                stagingFileName: "restart.bin.part"
            ))
            _ = await seedStore.checkpointTruncate()
        }

        let store = CuriumBrowserStore(
            host: nil,
            downloadsRoot: downloadsRoot,
            restoreSession: false,
            transferDatabaseURL: dbURL,
            transferStagingRoot: stagingRoot
        )
        await store.waitForTransferHydration()

        // 1. [P1-1] & [P2-1]: Unmounted external folder record survived with populated destination label; deleted local file pruned.
        let externalItem = try #require(store.downloads.first { $0.id == "external-unmounted-completed" })
        #expect(externalItem.phase == .completed)
        #expect(externalItem.saveDestinationLabel == "Videos")
        #expect(!store.downloads.contains { $0.id == "local-deleted-completed" })

        // 2. [P1-2] & [P2-1]: Pre-staged HLS `.mp4` and Range `.part` commit directly without touching the network and retain saveDestinationLabel.
        let hlsItem = try #require(store.downloads.first { $0.id == hlsStagedID })
        let rangeItem = try #require(store.downloads.first { $0.id == rangeStagedID })
        #expect(hlsItem.phase == .paused)
        #expect(rangeItem.phase == .paused)

        store.resumeDownload(hlsItem)
        store.resumeDownload(rangeItem)
        let bothCommitted = await waitForCondition(timeoutSeconds: 5.0) {
            hlsItem.phase == .completed && rangeItem.phase == .completed
        }
        #expect(bothCommitted)
        #expect(zeroRequestServer.snapshotStats().totalRequests == 0)
        #expect(hlsItem.saveDestinationLabel == "CustomExportFolder")
        #expect(rangeItem.saveDestinationLabel == "CustomExportFolder")
        #expect(try Data(contentsOf: try #require(hlsItem.savedURL)) == hlsStagedBytes)
        #expect(try Data(contentsOf: try #require(rangeItem.savedURL)) == rangeStagedBytes)

        // 3. [P1-3]: Blink-native paused transfer promotes on resume, resets meter from prior 500 KB to 0, and records positive speed!
        let restartItem = try #require(store.downloads.first { $0.id == "restart-meter-reset-1" })
        store.resumeDownload(restartItem)
        #expect(restartItem.transportKind == .multiLaneRange)
        let restartCompleted = await waitForCondition(timeoutSeconds: 6.0) {
            restartItem.phase == .completed
        }
        #expect(restartCompleted)
        #expect(restartItem.peakSpeedBytesPerSec > 0)
        #expect(restartItem.saveDestinationLabel == "CustomExportFolder")
        #expect(try Data(contentsOf: try #require(restartItem.savedURL)) == restartPayload)

        // 4. [P1-3]: Non-seekable `.singleStream` (200 OK without Range) exposes `canPause == false` while downloading.
        let singlePayload = makeSyntheticPayload(bytes: 384 * 1024)
        let singleServer = try RoutingLoopbackServer(
            behavior: .status200NoRange(payload: singlePayload, delayMicrosPer64K: 60_000)
        )
        defer { singleServer.stop() }

        let singleItem = try #require(await store.startManualDownload(
            url: singleServer.url(path: "/live-stream.bin"),
            suggestedFilename: "live-stream.bin",
            lanes: 4,
            includeActiveTabCookies: false
        ))
        let observedSingleStreamDownloading = await waitForCondition(timeoutSeconds: 5.0) {
            singleItem.phase == .downloading && singleItem.transportKind == .singleStream
        }
        #expect(observedSingleStreamDownloading)
        #expect(!singleItem.canPause)

        let singleFinished = await waitForCondition(timeoutSeconds: 6.0) {
            singleItem.phase == .completed
        }
        #expect(singleFinished)
        #expect(singleItem.saveDestinationLabel == "CustomExportFolder")
    }
}
