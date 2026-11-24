import CryptoKit
import Darwin
import Foundation
import Testing
import os

// MARK: - Deterministic Loopback HTTP/1.1 Test Server

private final class LoopbackRangeTestServer: @unchecked Sendable {
    enum Mode: Sendable {
        case range206
        case chunkedUnknownLength(chunkSize: Int, delayMicros: useconds_t)
        case weakETagHTMLProbe
        case requireCookie(expectedCookie: String)
    }

    struct Config: Sendable {
        var payload: Data
        var mode: Mode = .range206
        var eTag: String? = "\"curium-v1\""
        var lastModified: String? = "Mon, 23 Nov 2026 12:00:00 GMT"
        var contentDisposition: String? = "attachment; filename=\"fallback.bin\"; filename*=UTF-8''curium%20payload.bin"
        var contentType: String = "application/octet-stream"
        /// Number of initial non-probe Range requests that should return `503 Service Unavailable`.
        var transient503Remaining: Int = 0
        /// Optional throttle (microseconds per 32 KiB) applied to requests starting at byte 0 (creates straggler for work-stealing).
        var slowZeroStartMicrosPerChunk: useconds_t = 0
        /// Optional uniform throttle (microseconds per 64 KiB) across all Range responses (for deterministic mid-transfer pause).
        var uniformDelayMicrosPerChunk: useconds_t = 0
    }

    struct Stats: Sendable {
        var totalRequests: Int = 0
        var probeRequests: Int = 0
        var rangeRequests: Int = 0
        var injected503Count: Int = 0
        var servedStartOffsets: [Int64] = []
        var receivedCookies: [String] = []
    }

    private struct MutableState: Sendable {
        var config: Config
        var stats: Stats = Stats()
        var isStopped: Bool = false
    }

    let port: UInt16
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/download.bin")! }

    private let listenFD: Int32
    private let state: OSAllocatedUnfairLock<MutableState>
    private let acceptQueue = DispatchQueue(label: "curium.test.loopback.accept")
    private let workerQueue = DispatchQueue(label: "curium.test.loopback.worker", attributes: .concurrent)

    init(config: Config) throws {
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
        let nameRC = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &boundLen)
            }
        }
        guard nameRC == 0 else {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw err
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.state = OSAllocatedUnfairLock(initialState: MutableState(config: config))

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        stop()
    }

    func updateConfig(_ mutate: @Sendable (inout Config) -> Void) {
        state.withLock { mutate(&$0.config) }
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
            let stopped = state.withLock { $0.isStopped }
            if stopped { return }

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
        guard let rawRequest = readHTTPHeaders(fd: fd),
              let requestText = String(data: rawRequest, encoding: .utf8) else {
            return
        }

        let lines = requestText.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let rangeHeader = headers["range"]
        let ifRangeHeader = headers["if-range"]
        let cookieHeader = headers["cookie"]

        let (cfg, inject503): (Config, Bool) = state.withLock { s in
            s.stats.totalRequests += 1
            if let cookieHeader {
                s.stats.receivedCookies.append(cookieHeader)
            }
            let isProbe = (rangeHeader?.lowercased() == "bytes=0-0")
            if isProbe {
                s.stats.probeRequests += 1
                return (s.config, false)
            }
            if rangeHeader != nil {
                s.stats.rangeRequests += 1
                if s.config.transient503Remaining > 0 {
                    s.config.transient503Remaining -= 1
                    s.stats.injected503Count += 1
                    return (s.config, true)
                }
            }
            return (s.config, false)
        }

        if inject503 {
            let body = Data("Service Temporarily Unavailable".utf8)
            let responseHead = [
                "HTTP/1.1 503 Service Unavailable",
                "Retry-After: 0",
                "Content-Length: \(body.count)",
                "Connection: close",
                "",
                "",
            ].joined(separator: "\r\n")
            _ = sendAll(fd: fd, data: Data(responseHead.utf8))
            _ = sendAll(fd: fd, data: body)
            return
        }

        switch cfg.mode {
        case .weakETagHTMLProbe:
            let body = Data("<html><body>Login required</body></html>".utf8)
            var headLines = [
                "HTTP/1.1 200 OK",
                "Content-Type: text/html; charset=utf-8",
                "Content-Length: \(body.count)",
            ]
            if let eTag = cfg.eTag { headLines.append("ETag: \(eTag)") }
            if let lm = cfg.lastModified { headLines.append("Last-Modified: \(lm)") }
            headLines.append("Connection: close")
            headLines.append("")
            headLines.append("")
            _ = sendAll(fd: fd, data: Data(headLines.joined(separator: "\r\n").utf8))
            _ = sendAll(fd: fd, data: body)
            return

        case .chunkedUnknownLength(let chunkSize, let delayMicros):
            var headLines = [
                "HTTP/1.1 200 OK",
                "Content-Type: \(cfg.contentType)",
                "Transfer-Encoding: chunked",
                "Connection: close",
            ]
            if let cd = cfg.contentDisposition { headLines.append("Content-Disposition: \(cd)") }
            headLines.append("")
            headLines.append("")
            guard sendAll(fd: fd, data: Data(headLines.joined(separator: "\r\n").utf8)) else { return }

            var cursor = 0
            let total = cfg.payload.count
            while cursor < total {
                if state.withLock({ $0.isStopped }) { return }
                let end = min(total, cursor + max(1, chunkSize))
                let slice = cfg.payload[cursor..<end]
                let hexLen = String(slice.count, radix: 16)
                var frame = Data("\(hexLen)\r\n".utf8)
                frame.append(slice)
                frame.append(Data("\r\n".utf8))
                guard sendAll(fd: fd, data: frame) else { return }
                cursor = end
                if delayMicros > 0 && cursor < total {
                    usleep(delayMicros)
                }
            }
            _ = sendAll(fd: fd, data: Data("0\r\n\r\n".utf8))
            return

        case .requireCookie(let expectedCookie):
            if cookieHeader != expectedCookie {
                let body = Data("Unauthorized".utf8)
                let head = [
                    "HTTP/1.1 401 Unauthorized",
                    "Content-Length: \(body.count)",
                    "Connection: close",
                    "",
                    "",
                ].joined(separator: "\r\n")
                _ = sendAll(fd: fd, data: Data(head.utf8))
                _ = sendAll(fd: fd, data: body)
                return
            }
            serveRangePayload(fd: fd, cfg: cfg, rangeHeader: rangeHeader, ifRangeHeader: ifRangeHeader)

        case .range206:
            serveRangePayload(fd: fd, cfg: cfg, rangeHeader: rangeHeader, ifRangeHeader: ifRangeHeader)
        }
    }

    private func serveRangePayload(
        fd: Int32,
        cfg: Config,
        rangeHeader: String?,
        ifRangeHeader: String?
    ) {
        let total = Int64(cfg.payload.count)

        // RFC 9110 §13.1.5: if If-Range doesn't match current validator, return full 200 OK.
        let ifRangeMatches: Bool = {
            guard let ifRangeHeader else { return true }
            if let eTag = cfg.eTag, ifRangeHeader == eTag { return true }
            if let lm = cfg.lastModified, ifRangeHeader == lm { return true }
            return false
        }()

        if let rangeHeader,
           ifRangeMatches,
           let parsed = parseRangeHeader(rangeHeader, total: total) {
            let start = parsed.start
            let end = parsed.end
            if !(start == 0 && end == 0) {
                state.withLock { $0.stats.servedStartOffsets.append(start) }
            }
            let length = end - start + 1
            var headLines = [
                "HTTP/1.1 206 Partial Content",
                "Content-Type: \(cfg.contentType)",
                "Accept-Ranges: bytes",
                "Content-Range: bytes \(start)-\(end)/\(total)",
                "Content-Length: \(length)",
                "Connection: close",
            ]
            if let eTag = cfg.eTag { headLines.append("ETag: \(eTag)") }
            if let lm = cfg.lastModified { headLines.append("Last-Modified: \(lm)") }
            if let cd = cfg.contentDisposition { headLines.append("Content-Disposition: \(cd)") }
            headLines.append("")
            headLines.append("")
            guard sendAll(fd: fd, data: Data(headLines.joined(separator: "\r\n").utf8)) else { return }

            let chunkDelay: useconds_t
            let chunkStep: Int
            if start == 0 && end > 0 && cfg.slowZeroStartMicrosPerChunk > 0 {
                chunkDelay = cfg.slowZeroStartMicrosPerChunk
                chunkStep = 32 * 1024
            } else if cfg.uniformDelayMicrosPerChunk > 0 && end > start {
                chunkDelay = cfg.uniformDelayMicrosPerChunk
                chunkStep = 64 * 1024
            } else {
                chunkDelay = 0
                chunkStep = 256 * 1024
            }

            var cursor = Int(start)
            let stopIndex = Int(end) + 1
            while cursor < stopIndex {
                if state.withLock({ $0.isStopped }) { return }
                let next = min(stopIndex, cursor + chunkStep)
                guard sendAll(fd: fd, data: Data(cfg.payload[cursor..<next])) else { return }
                cursor = next
                if chunkDelay > 0 && cursor < stopIndex {
                    usleep(chunkDelay)
                }
            }
            return
        }

        // Full 200 OK response (no Range header or mismatched If-Range).
        var headLines = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(cfg.contentType)",
            "Accept-Ranges: bytes",
            "Content-Length: \(total)",
            "Connection: close",
        ]
        if let eTag = cfg.eTag { headLines.append("ETag: \(eTag)") }
        if let lm = cfg.lastModified { headLines.append("Last-Modified: \(lm)") }
        if let cd = cfg.contentDisposition { headLines.append("Content-Disposition: \(cd)") }
        headLines.append("")
        headLines.append("")
        guard sendAll(fd: fd, data: Data(headLines.joined(separator: "\r\n").utf8)) else { return }
        _ = sendAll(fd: fd, data: cfg.payload)
    }

    private func parseRangeHeader(_ header: String, total: Int64) -> (start: Int64, end: Int64)? {
        let lower = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix("bytes=") else { return nil }
        let spec = lower.dropFirst(6)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int64(parts[0]),
              start >= 0,
              start < total else {
            return nil
        }
        let end: Int64
        if parts[1].isEmpty {
            end = total - 1
        } else if let parsedEnd = Int64(parts[1]) {
            end = min(total - 1, parsedEnd)
        } else {
            return nil
        }
        guard end >= start else { return nil }
        return (start, end)
    }

    private func readHTTPHeaders(fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let delimiter = Data("\r\n\r\n".utf8)
        while buffer.count < 32 * 1024 {
            let rc = Darwin.recv(fd, &chunk, chunk.count, 0)
            if rc < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if rc == 0 {
                break
            }
            buffer.append(chunk, count: rc)
            if buffer.range(of: delimiter) != nil {
                return buffer
            }
        }
        return buffer.isEmpty ? nil : buffer
    }

    private func sendAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var offset = 0
            let total = rawBuffer.count
            while offset < total {
                let rc = Darwin.send(fd, base.advanced(by: offset), total - offset, 0)
                if rc < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if rc == 0 {
                    return false
                }
                offset += rc
            }
            return true
        }
    }
}

// MARK: - Synthetic Payload & Hash Helpers

private func makeSyntheticPayload(byteCount: Int, seed: UInt64 = 0xC0FFEE_2026) -> Data {
    var data = Data(count: byteCount)
    data.withUnsafeMutableBytes { rawBuffer in
        guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var state = seed
        var i = 0
        while i + 8 <= byteCount {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            for shift in 0..<8 {
                ptr[i + shift] = UInt8(truncatingIfNeeded: z >> (shift * 8))
            }
            i += 8
        }
        while i < byteCount {
            state &+= 0x9E37_79B9_7F4A_7C15
            ptr[i] = UInt8(truncatingIfNeeded: state >> 24)
            i += 1
        }
    }
    return data
}

private func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256Hex(ofFileAt url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return sha256Hex(of: data)
}

private func hasSuspendLockedXattr(at path: String) -> Bool {
    var flag: UInt8 = 0
    let size = path.withCString { cPath in
        getxattr(cPath, "com.apple.runningboard.can-suspend-locked", &flag, MemoryLayout<UInt8>.size, 0, 0)
    }
    return size == 1 && flag == 1
}

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CuriumTransferTransportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Transport Test Suite

@Suite("Curium Transfer Transport")
struct CuriumTransferTransportTests {
    @Test("8-lane Range download exercises midpoint work-stealing, recovers from transient 503, and verifies SHA-256 bit-exact")
    func multiLaneRangeWorkStealingAnd503Recovery() async throws {
        let payload = makeSyntheticPayload(byteCount: 6 * 1024 * 1024, seed: 0x1122_3344_5566_7788)
        let expectedHash = sha256Hex(of: payload)

        let server = try LoopbackRangeTestServer(config: .init(
            payload: payload,
            mode: .range206,
            eTag: "\"curium-v1\"",
            transient503Remaining: 2,
            slowZeroStartMicrosPerChunk: 22_000 // Make slice 0 a slow straggler so fast lanes steal its tail
        ))
        defer { server.stop() }

        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destURL = tempDir.appendingPathComponent("multi-lane.bin")

        let engine = CuriumRangeTransferEngine()
        let probed = try await engine.probe(url: server.baseURL, proxy: .direct)
        #expect(probed.statusCode == 206)
        #expect(probed.supportsByteRanges == true)
        #expect(probed.totalBytes == Int64(payload.count))
        #expect(probed.eTag == "\"curium-v1\"")
        #expect(probed.isHTMLResponse == false)
        #expect(probed.suggestedFilename == "curium payload.bin")

        let observedUpdates = OSAllocatedUnfairLock<[CuriumRangeProgressUpdate]>(initialState: [])
        let config = CuriumRangeEngineConfiguration(
            maxLanes: 8,
            maxWindowBytes: 2 * 1024 * 1024,
            minimumStealBytes: 128 * 1024,
            retryBaseDelaySeconds: 0.02
        )

        let finalUpdate = try await engine.download(
            url: server.baseURL,
            destinationURL: destURL,
            proxy: .direct,
            configuration: config
        ) { update in
            observedUpdates.withLock { $0.append(update) }
        }

        let stats = server.snapshotStats()
        #expect(stats.injected503Count == 2)
        #expect(finalUpdate.receivedBytes == Int64(payload.count))
        #expect(finalUpdate.totalBytes == Int64(payload.count))
        #expect(finalUpdate.activeLanes == 0)
        // Initial split creates 8 slices; work-stealing from slow slice 0 must create > 8 slices.
        #expect(finalUpdate.slices.count > 8)
        #expect(finalUpdate.slices.allSatisfy { $0.isComplete })

        let updates = observedUpdates.withLock { $0 }
        #expect(!updates.isEmpty)
        #expect(updates.contains { $0.receivedBytes > 0 && $0.totalBytes == Int64(payload.count) && !$0.slices.isEmpty })

        let actualHash = try sha256Hex(ofFileAt: destURL)
        #expect(actualHash == expectedHash)
        #expect(hasSuspendLockedXattr(at: destURL.path))
    }

    @Test("Pause -> SQLite persist -> cold-launch paused recovery -> Resume completes SHA-256 bit-exact")
    func pausePersistLaunchRecoveryAndResume() async throws {
        let payload = makeSyntheticPayload(byteCount: 4 * 1024 * 1024, seed: 0xDEAD_BEEF_CAFE_0001)
        let expectedHash = sha256Hex(of: payload)

        let server = try LoopbackRangeTestServer(config: .init(
            payload: payload,
            mode: .range206,
            eTag: "\"resume-v1\"",
            uniformDelayMicrosPerChunk: 25_000
        ))
        defer { server.stop() }

        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let stagingURL = tempDir.appendingPathComponent("staging-resume.part")
        let dbURL = tempDir.appendingPathComponent("transfers.sqlite3")

        let engine = CuriumRangeTransferEngine()
        let config = CuriumRangeEngineConfiguration(
            maxLanes: 4,
            maxWindowBytes: 1024 * 1024,
            minimumStealBytes: 256 * 1024,
            retryBaseDelaySeconds: 0.02
        )

        let latestSnapshot = OSAllocatedUnfairLock<CuriumRangeProgressUpdate?>(initialState: nil)
        let taskHolder = OSAllocatedUnfairLock<Task<CuriumRangeProgressUpdate, any Error>?>(initialState: nil)
        let didTriggerPause = OSAllocatedUnfairLock<Bool>(initialState: false)

        let downloadTask = Task<CuriumRangeProgressUpdate, any Error> {
            try await engine.download(
                url: server.baseURL,
                destinationURL: stagingURL,
                proxy: .direct,
                configuration: config
            ) { update in
                latestSnapshot.withLock { $0 = update }
                if update.receivedBytes >= 512 * 1024 {
                    let shouldCancel = didTriggerPause.withLock { already -> Bool in
                        if already { return false }
                        already = true
                        return true
                    }
                    if shouldCancel {
                        taskHolder.withLock { $0 }?.cancel()
                    }
                }
            }
        }
        taskHolder.withLock { $0 = downloadTask }

        do {
            _ = try await downloadTask.value
            Issue.record("Expected mid-transfer download task to pause via cancellation")
        } catch is CancellationError {
            // Expected cooperative pause.
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            // Also acceptable if URLSession surfaced cancelled first.
        }

        // Staging file must remain intact on disk after pause.
        #expect(FileManager.default.fileExists(atPath: stagingURL.path))

        let pausedSnapshot = try #require(latestSnapshot.withLock { $0 })
        #expect(pausedSnapshot.receivedBytes > 0)
        #expect(pausedSnapshot.receivedBytes < Int64(payload.count))
        #expect(!pausedSnapshot.slices.isEmpty)
        #expect(pausedSnapshot.slices.contains { !$0.isComplete })

        // Persist as an active `.downloading` record (simulating abrupt process termination mid-transfer)
        // alongside an active HLS record to verify both slices and hlsCheckpoint survive cold launch.
        let rangeTransferID = "transfer-range-\(UUID().uuidString)"
        let hlsTransferID = "transfer-hls-\(UUID().uuidString)"
        let hlsCheckpoint = CuriumHLSCheckpoint(
            playlistURL: URL(string: "https://cdn.example.com/live/index.m3u8")!,
            audioPlaylistURL: URL(string: "https://cdn.example.com/live/audio.m3u8")!,
            masterPlaylistURL: URL(string: "https://cdn.example.com/live/master.m3u8")!,
            completedSegments: 14,
            totalSegments: 40,
            contiguousByteOffset: 7_340_032,
            isFMP4: false,
            preloadedPlaylistText: "#EXTM3U\n"
        )

        do {
            let store = try CuriumTransferStore(databaseURL: dbURL, installLifecycleObservers: false)
            let rangeRecord = CuriumTransferRecord(
                id: rangeTransferID,
                sourceProfileID: "work",
                source: .mediaRadarDirect,
                transportKind: .multiLaneRange,
                phase: .downloading,
                sourceURL: server.baseURL,
                resolvedURL: server.baseURL,
                filename: "archive.bin",
                eTag: "\"resume-v1\"",
                receivedBytes: pausedSnapshot.receivedBytes,
                totalBytes: Int64(payload.count),
                configuredLanes: 4,
                activeLanes: 4,
                slices: pausedSnapshot.slices.map { s in
                    var active = s
                    active.isActiveLane = !s.isComplete
                    return active
                },
                stagingDirectoryName: rangeTransferID,
                stagingFileName: stagingURL.lastPathComponent
            )
            let hlsRecord = CuriumTransferRecord(
                id: hlsTransferID,
                sourceProfileID: "default",
                source: .mediaRadarHLS,
                transportKind: .hlsRemuxMP4,
                phase: .downloading,
                sourceURL: hlsCheckpoint.playlistURL,
                filename: "video.mp4",
                receivedBytes: hlsCheckpoint.contiguousByteOffset,
                totalBytes: nil,
                estimatedTotalBytes: 20_000_000,
                completedSegments: 14,
                totalSegments: 40,
                activeLanes: 6,
                hlsCheckpoint: hlsCheckpoint
            )
            await store.upsert(rangeRecord)
            await store.upsert(hlsRecord)
            #expect(await store.checkpointTruncate())
            #expect(hasSuspendLockedXattr(at: dbURL.path))
        }

        // Re-open database (cold launch) and transition interrupted active records cleanly to `.paused`.
        let relaunchedStore = try CuriumTransferStore(databaseURL: dbURL, installLifecycleObservers: false)
        let transitioned = await relaunchedStore.markInterruptedTransfersPausedOnLaunch()
        #expect(transitioned == 2)

        let recoveredRange = try #require(await relaunchedStore.record(id: rangeTransferID))
        #expect(recoveredRange.phase == .paused)
        #expect(recoveredRange.activeLanes == 0)
        #expect(recoveredRange.slices.allSatisfy { !$0.isActiveLane })
        #expect(recoveredRange.slices.map(\.currentOffset) == pausedSnapshot.slices.map(\.currentOffset))
        #expect(recoveredRange.totalBytes == Int64(payload.count))

        let recoveredHLS = try #require(await relaunchedStore.record(id: hlsTransferID))
        #expect(recoveredHLS.phase == .paused)
        #expect(recoveredHLS.activeLanes == 0)
        #expect(recoveredHLS.totalBytes == nil)
        #expect(recoveredHLS.hlsCheckpoint == hlsCheckpoint)

        // Speed up server for resume phase and resume from exact saved slices.
        server.updateConfig { $0.uniformDelayMicrosPerChunk = 0 }
        let resumedFinal = try await engine.download(
            url: server.baseURL,
            destinationURL: stagingURL,
            proxy: .direct,
            knownTotalBytes: recoveredRange.totalBytes,
            supportsRangesHint: true,
            existingSlices: recoveredRange.slices,
            ifRangeValidator: recoveredRange.ifRangeValidator,
            configuration: config
        ) { _ in }

        #expect(resumedFinal.receivedBytes == Int64(payload.count))
        #expect(resumedFinal.totalBytes == Int64(payload.count))
        #expect(resumedFinal.slices.allSatisfy { $0.isComplete })

        let actualHash = try sha256Hex(ofFileAt: stagingURL)
        #expect(actualHash == expectedHash)
    }

    @Test("Single-stream unknown-size chunked fallback emits live receivedBytes with totalBytes == nil and completes bit-exact")
    func singleStreamChunkedUnknownSizeFallback() async throws {
        let payload = makeSyntheticPayload(byteCount: 320 * 1024, seed: 0xABCD_EF01_2345_6789)
        let expectedHash = sha256Hex(of: payload)

        let server = try LoopbackRangeTestServer(config: .init(
            payload: payload,
            mode: .chunkedUnknownLength(chunkSize: 16 * 1024, delayMicros: 30_000),
            eTag: nil,
            lastModified: nil
        ))
        defer { server.stop() }

        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destURL = tempDir.appendingPathComponent("chunked.bin")

        let engine = CuriumRangeTransferEngine()
        let probed = try await engine.probe(url: server.baseURL, proxy: .direct)
        #expect(probed.statusCode == 200)
        #expect(probed.supportsByteRanges == false)
        #expect(probed.totalBytes == nil)

        let liveUpdates = OSAllocatedUnfairLock<[CuriumRangeProgressUpdate]>(initialState: [])
        let finalUpdate = try await engine.download(
            url: server.baseURL,
            destinationURL: destURL,
            proxy: .direct
        ) { update in
            liveUpdates.withLock { $0.append(update) }
        }

        let captured = liveUpdates.withLock { $0 }
        let streamingUpdates = captured.filter { $0.activeLanes == 1 }
        #expect(!streamingUpdates.isEmpty)
        #expect(streamingUpdates.contains { $0.receivedBytes > 0 && $0.totalBytes == nil })
        #expect(streamingUpdates.allSatisfy { $0.totalBytes == nil })

        #expect(finalUpdate.receivedBytes == Int64(payload.count))
        #expect(finalUpdate.activeLanes == 0)
        #expect(try sha256Hex(ofFileAt: destURL) == expectedHash)
    }

    @Test("If-Range mismatch throws remoteResourceModified and weak ETags (W/...) are filtered per RFC 9110")
    func ifRangeAndWeakETagFiltering() async throws {
        // Static strong-vs-weak ETag validation.
        #expect(CuriumTransferRecord.strongETag(from: "W/\"abc\"") == nil)
        #expect(CuriumTransferRecord.strongETag(from: "w/\"abc\"") == nil)
        #expect(CuriumTransferRecord.strongETag(from: "  \"strong-1\"  ") == "\"strong-1\"")
        #expect(CuriumRangeTransferEngine.resolveIfRangeValidator(etag: "W/\"weak\"", lastModified: "Mon, 23 Nov 2026 12:00:00 GMT") == "Mon, 23 Nov 2026 12:00:00 GMT")
        #expect(CuriumRangeTransferEngine.resolveIfRangeValidator(etag: "\"strong\"", lastModified: "Mon, 23 Nov 2026 12:00:00 GMT") == "\"strong\"")

        // Probe against weak ETag + text/html server.
        let htmlServer = try LoopbackRangeTestServer(config: .init(
            payload: Data(),
            mode: .weakETagHTMLProbe,
            eTag: "W/\"weak-html\"",
            lastModified: "Tue, 24 Nov 2026 08:00:00 GMT"
        ))
        defer { htmlServer.stop() }

        let engine = CuriumRangeTransferEngine()
        let htmlProbe = try await engine.probe(url: htmlServer.baseURL, proxy: .direct)
        #expect(htmlProbe.eTag == nil)
        #expect(htmlProbe.lastModified == "Tue, 24 Nov 2026 08:00:00 GMT")
        #expect(htmlProbe.ifRangeValidator == "Tue, 24 Nov 2026 08:00:00 GMT")
        #expect(htmlProbe.isHTMLResponse == true)
        #expect(htmlProbe.supportsByteRanges == false)

        // Live If-Range rejection when remote ETag rotated from "v1" to "v2".
        let payload = makeSyntheticPayload(byteCount: 1024 * 1024, seed: 0x42)
        let rangeServer = try LoopbackRangeTestServer(config: .init(
            payload: payload,
            mode: .range206,
            eTag: "\"v2\""
        ))
        defer { rangeServer.stop() }

        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destURL = tempDir.appendingPathComponent("ifrange.bin")

        do {
            _ = try await engine.download(
                url: rangeServer.baseURL,
                destinationURL: destURL,
                proxy: .direct,
                knownTotalBytes: Int64(payload.count),
                supportsRangesHint: true,
                ifRangeValidator: "\"v1\""
            ) { _ in }
            Issue.record("Expected remoteResourceModified when If-Range validator does not match server ETag")
        } catch let error as CuriumRangeTransferError {
            #expect(error == .remoteResourceModified)
        }
    }

    @Test("CrossOriginRedirectAuthStripper strips auth across origins, strips Referer/Origin on HTTPS downgrade, and enforces SSRF guard")
    func crossOriginRedirectAuthAndSSRF() {
        let sourceHTTPS = URL(string: "https://auth.example.com/file.bin")!
        let sameOriginURL = URL(string: "https://auth.example.com:443/cdn/file.bin")!
        let crossOriginHTTPS = URL(string: "https://cdn.other.org/file.bin")!
        let downgradeHTTP = URL(string: "http://cdn.other.org/file.bin")!
        let privateLAN = URL(string: "http://192.168.1.50/secret")!
        let loopback = URL(string: "http://127.0.0.1:8080/internal")!
        let fileScheme = URL(string: "file:///etc/passwd")!

        func makeReq(_ url: URL) -> URLRequest {
            var req = URLRequest(url: url)
            req.setValue("sid=secret", forHTTPHeaderField: "Cookie")
            req.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
            req.setValue("Basic px", forHTTPHeaderField: "Proxy-Authorization")
            req.setValue("https://auth.example.com/page", forHTTPHeaderField: "Referer")
            req.setValue("https://auth.example.com", forHTTPHeaderField: "Origin")
            req.setValue("Curium/1.0", forHTTPHeaderField: "User-Agent")
            return req
        }

        // Same origin preserves credentials.
        let sameDecision = CrossOriginRedirectAuthStripper.evaluateRedirect(
            from: sourceHTTPS,
            to: makeReq(sameOriginURL),
            originatingURL: sourceHTTPS
        )
        guard case .allow(let sameSanitized, let sameNeedsRefresh) = sameDecision else {
            Issue.record("Expected same-origin redirect to be allowed")
            return
        }
        #expect(sameNeedsRefresh == false)
        #expect(sameSanitized.value(forHTTPHeaderField: "Cookie") == "sid=secret")
        #expect(sameSanitized.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        // Cross-origin HTTPS strips Cookie, Authorization, Proxy-Authorization, keeps User-Agent/Referer.
        let crossDecision = CrossOriginRedirectAuthStripper.evaluateRedirect(
            from: sourceHTTPS,
            to: makeReq(crossOriginHTTPS),
            originatingURL: sourceHTTPS
        )
        guard case .allow(let crossSanitized, let crossNeedsRefresh) = crossDecision else {
            Issue.record("Expected cross-origin public redirect to be allowed")
            return
        }
        #expect(crossNeedsRefresh == true)
        #expect(crossSanitized.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(crossSanitized.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(crossSanitized.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(crossSanitized.value(forHTTPHeaderField: "User-Agent") == "Curium/1.0")
        #expect(crossSanitized.value(forHTTPHeaderField: "Referer") == "https://auth.example.com/page")

        // HTTPS -> HTTP downgrade additionally strips Referer and Origin.
        let downgradeDecision = CrossOriginRedirectAuthStripper.evaluateRedirect(
            from: sourceHTTPS,
            to: makeReq(downgradeHTTP),
            originatingURL: sourceHTTPS
        )
        guard case .allow(let downgradeSanitized, _) = downgradeDecision else {
            Issue.record("Expected public HTTPS->HTTP redirect to be allowed with stripped headers")
            return
        }
        #expect(downgradeSanitized.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(downgradeSanitized.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(downgradeSanitized.value(forHTTPHeaderField: "Referer") == nil)
        #expect(downgradeSanitized.value(forHTTPHeaderField: "Origin") == nil)

        // SSRF guard blocks public -> private LAN and public -> loopback redirects.
        let lanDecision = CrossOriginRedirectAuthStripper.evaluateRedirect(
            from: sourceHTTPS,
            to: makeReq(privateLAN),
            originatingURL: sourceHTTPS
        )
        #expect(lanDecision == .rejectPrivateNetwork("192.168.1.50"))

        let loopbackDecision = CrossOriginRedirectAuthStripper.evaluateRedirect(
            from: sourceHTTPS,
            to: makeReq(loopback),
            originatingURL: sourceHTTPS
        )
        #expect(loopbackDecision == .rejectPrivateNetwork("127.0.0.1"))

        // Non-HTTP scheme rejected.
        let fileDecision = CrossOriginRedirectAuthStripper.evaluateRedirect(
            from: sourceHTTPS,
            to: makeReq(fileScheme),
            originatingURL: sourceHTTPS
        )
        #expect(fileDecision == .rejectDisallowedScheme("file"))
    }

    @Test("CuriumThroughputMeter EWMA (alpha=0.35), ETA, pause exclusion, and 36-sample sparkline ring")
    func throughputMeterEWMAAndSparklineRing() {
        let t0 = ContinuousClock.now
        let meter = CuriumThroughputMeter(initialBytes: 0, startedAt: t0)

        // Tick 1 at +1.0s: 100_000 bytes -> initial EWMA = 100_000 B/s.
        let s1 = meter.record(totalBytesNow: 100_000, at: t0 + .seconds(1))
        #expect(s1 != nil)
        #expect(abs((s1?.speedBytesPerSec ?? 0) - 100_000.0) < 0.01)
        #expect(s1?.didSampleSparkline == true)
        #expect(meter.samples.count == 1)

        // Tick 2 at +2.0s: +200_000 bytes -> EWMA = 0.35 * 200_000 + 0.65 * 100_000 = 135_000 B/s.
        let s2 = meter.record(totalBytesNow: 300_000, at: t0 + .seconds(2))
        #expect(s2 != nil)
        #expect(abs((s2?.speedBytesPerSec ?? 0) - 135_000.0) < 0.01)
        #expect(abs(meter.peakSpeedBytesPerSec - 135_000.0) < 0.01)

        // ETA check: 270_000 bytes remaining at 135_000 B/s == 2.0s.
        let eta = meter.etaSeconds(remainingBytes: 270_000)
        #expect(eta != nil)
        #expect(abs((eta ?? 0) - 2.0) < 0.001)
        #expect(meter.etaSeconds(remainingBytes: nil) == nil)
        #expect(meter.etaSeconds(remainingBytes: 0) == nil)

        // Pause at +2.0s, remain paused for 30s, then resume at +32.0s.
        meter.markPaused(at: t0 + .seconds(2))
        #expect(meter.speedBytesPerSec == 0)
        #expect(meter.etaSeconds(remainingBytes: 100_000) == nil)
        #expect(abs(meter.elapsedSeconds(at: t0 + .seconds(30)) - 2.0) < 0.001)

        meter.resetForResume(currentBytes: 300_000, at: t0 + .seconds(32))
        #expect(abs(meter.elapsedSeconds(at: t0 + .seconds(33)) - 3.0) < 0.001)

        // Feed 45 samples at 0.5s intervals -> ring must cap strictly at 36 entries.
        var bytes: Int64 = 300_000
        for step in 1...45 {
            bytes += 50_000
            let ts = t0 + .seconds(32) + .milliseconds(step * 500)
            let snap = meter.record(totalBytesNow: bytes, at: ts)
            #expect(snap?.didSampleSparkline == true)
        }
        #expect(meter.samples.count == 36)
    }

    @Test("Proxy pool CIDR bypass, fail-closed fixed proxy, 1-shot 401 cookie refresh, and throttled store persistence")
    func proxyPoolCookieRefreshAndThrottledPersistence() async throws {
        // 1. Fixed proxy CIDR bypass + allowFailover == false.
        let resolvedFixed = CuriumProxySessionPool.resolveFixedDescriptor(
            rules: "http://10.20.30.40:8080",
            bypassRules: "192.168.0.0/16,*.internal.corp",
            targetURL: URL(string: "https://192.168.42.7/data.bin")!
        )
        #expect(resolvedFixed.isBypassed == true)
        #expect(resolvedFixed.descriptor.shouldBypass(url: URL(string: "https://api.internal.corp/x")!) == true)
        #expect(resolvedFixed.descriptor.shouldBypass(url: URL(string: "https://public.example.com/x")!) == false)

        let proxyConfigs = CuriumProxySessionPool.makeProxyConfigurations(for: resolvedFixed.descriptor)
        #expect(proxyConfigs.count == 1)
        #expect(proxyConfigs.first?.allowFailover == false)

        // Fail-closed fixed proxy on unsupported `https://` TLS-to-proxy scheme.
        let failClosed = CuriumProxySessionPool.resolveFixedDescriptor(
            rules: "https://proxy.example.com:443",
            bypassRules: nil,
            targetURL: URL(string: "https://public.example.com/file.bin")!
        )
        #expect(failClosed.isBypassed == false)
        #expect(failClosed.descriptor.host == "127.0.0.1")
        #expect(failClosed.descriptor.port == 1)

        // System proxy parser handles loopback private CIDR and rejects PAC / auth proxies.
        let sysSettings: [String: Any] = [
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 7890,
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 7890,
            "ExceptionsList": ["10.0.0.0/8", "*.local", "<local>"],
        ]
        let sysDescriptor = try #require(CuriumProxySessionPool.resolveSystemDescriptor(from: sysSettings))
        #expect(sysDescriptor.shouldBypass(url: URL(string: "http://10.1.2.3/test")!) == true)
        #expect(sysDescriptor.shouldBypass(url: URL(string: "http://intranet/test")!) == true)
        #expect(sysDescriptor.shouldBypass(url: URL(string: "https://1.1.1.1/test")!) == false)

        var pacSettings = sysSettings
        pacSettings["ProxyAutoConfigEnable"] = 1
        #expect(CuriumProxySessionPool.resolveSystemDescriptor(from: pacSettings) == nil)

        // 2. 1-shot cookieResolver refresh on HTTP 401.
        let payload = makeSyntheticPayload(byteCount: 600 * 1024, seed: 0x9999)
        let authServer = try LoopbackRangeTestServer(config: .init(
            payload: payload,
            mode: .requireCookie(expectedCookie: "session=fresh-token"),
            eTag: "\"auth-v1\""
        ))
        defer { authServer.stop() }

        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let authDest = tempDir.appendingPathComponent("auth.bin")
        let refreshCalls = OSAllocatedUnfairLock<Int>(initialState: 0)

        let engine = CuriumRangeTransferEngine()
        let authResult = try await engine.download(
            url: authServer.baseURL,
            headers: ["Cookie": "session=expired-token"],
            destinationURL: authDest,
            proxy: .direct,
            knownTotalBytes: Int64(payload.count),
            supportsRangesHint: true,
            cookieResolver: { _ in
                refreshCalls.withLock { $0 += 1 }
                return "session=fresh-token"
            },
            configuration: CuriumRangeEngineConfiguration(maxLanes: 2, retryBaseDelaySeconds: 0.01)
        ) { _ in }

        #expect(authResult.receivedBytes == Int64(payload.count))
        #expect(refreshCalls.withLock { $0 } == 1)
        #expect(try sha256Hex(ofFileAt: authDest) == sha256Hex(of: payload))

        // 3. Throttled store persistence (3.0s active throttle, immediate on phase transitions).
        let dbURL = tempDir.appendingPathComponent("throttle.sqlite3")
        let store = try CuriumTransferStore(databaseURL: dbURL, installLifecycleObservers: false)
        let now = ContinuousClock.now
        var rec = CuriumTransferRecord(
            id: "throttle-1",
            source: .manualURL,
            transportKind: .multiLaneRange,
            phase: .downloading,
            filename: "sample.bin",
            receivedBytes: 100
        )
        #expect(await store.upsertThrottled(rec, now: now) == true)
        rec.receivedBytes = 200
        #expect(await store.upsertThrottled(rec, now: now + .seconds(1)) == false)
        rec.receivedBytes = 300
        #expect(await store.upsertThrottled(rec, now: now + .seconds(3)) == true)
        rec.phase = .paused
        #expect(await store.upsertThrottled(rec, now: now + .milliseconds(3100)) == true)

        // 4. Preallocated writer truncate(to:) clean resume boundary.
        let truncURL = tempDir.appendingPathComponent("trunc.part")
        let writer = try CuriumPreallocatedFileWriter(fileURL: truncURL, preallocateBytes: 4096, truncateExisting: true)
        try writer.write(Data(repeating: 0xAB, count: 1024), at: 0)
        try writer.truncate(to: 512)
        #expect(try writer.currentFileSize() == 512)
        try writer.finalize()
    }

    @Test("Closed-writer safety, pwrite error slice rollback, DNS fast-fail, and redirect proxy lease re-evaluation")
    func closedWriterRollbackDNSFastFailAndRedirectProxyReevaluation() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Closed writer fails closed without touching POSIX FD, and commitAndWrite rolls back slice cursor.
        let partURL = tempDir.appendingPathComponent("rollback.part")
        let totalBytes: Int64 = 256 * 1024
        let writer = try CuriumPreallocatedFileWriter(fileURL: partURL, preallocateBytes: totalBytes, truncateExisting: true)
        let coordinator = CuriumSliceCoordinator(
            totalBytes: totalBytes,
            initialLanes: 1,
            existingSlices: nil,
            minimumStealBytes: 64 * 1024
        )
        let slice = try #require(coordinator.claimOrStealSlice())
        let firstDone = try CuriumRangeTransferEngine.commitAndWrite(
            Data(repeating: 0x5A, count: 4096),
            sliceID: slice.id,
            writer: writer,
            coordinator: coordinator
        )
        #expect(firstDone == false)
        #expect(coordinator.snapshot(totalBytes: totalBytes).receivedBytes == 4096)

        try writer.close()

        do {
            try writer.write(Data(repeating: 0xFF, count: 16), at: 4096)
            Issue.record("Expected closed writer.write to throw fileClosed")
        } catch let error as CuriumPreallocatedFileWriterError {
            #expect(error == .fileClosed)
        }

        do {
            _ = try CuriumRangeTransferEngine.commitAndWrite(
                Data(repeating: 0xEE, count: 16_384),
                sliceID: slice.id,
                writer: writer,
                coordinator: coordinator
            )
            Issue.record("Expected commitAndWrite on closed writer to throw fileClosed")
        } catch let error as CuriumPreallocatedFileWriterError {
            #expect(error == .fileClosed)
        }

        let afterRollback = coordinator.snapshot(totalBytes: totalBytes)
        #expect(afterRollback.receivedBytes == 4096)
        #expect(afterRollback.slices.first?.currentOffset == 4096)

        // 2. DNS errors fast-fail instead of burning transient retry attempts.
        #expect(CuriumRangeTransferEngine.isTransientNetworkError(URLError(.cannotFindHost)) == false)
        #expect(CuriumRangeTransferEngine.isTransientNetworkError(URLError(.dnsLookupFailed)) == false)
        #expect(CuriumRangeTransferEngine.isTransientNetworkError(URLError(.timedOut)) == true)
        #expect(CuriumRangeTransferEngine.isTransientNetworkError(URLError(.networkConnectionLost)) == true)
        #expect(CuriumRangeTransferEngine.isTransientNetworkError(POSIXError(.ECONNRESET)) == true)

        // 3. Probe redirect from bypassed host to external host re-acquires fixed-proxy SessionLease.
        let fixedProxy = CuriumProxyConfig.fixed(rules: "http://10.20.30.40:8080", bypassRules: "bypass.local")
        let initialURL = URL(string: "http://bypass.local/redirect")!
        let redirectedURL = URL(string: "https://cdn.example.com/archive.bin")!
        let initialLease = CuriumProxySessionPool.acquireSessionLease(
            for: .rangeTransfer,
            proxy: fixedProxy,
            targetURL: initialURL
        )
        #expect(initialLease.isDirectBypass == true)
        #expect(initialLease.descriptor == nil)

        let engine = CuriumRangeTransferEngine()
        let updatedLease = engine.reacquireLeaseIfRedirected(
            currentLease: initialLease,
            initialURL: initialURL,
            targetURL: redirectedURL,
            proxy: fixedProxy
        )
        defer { updatedLease.release() }
        #expect(updatedLease.isDirectBypass == false)
        #expect(updatedLease.descriptor?.host == "10.20.30.40")
        #expect(updatedLease.descriptor?.port == 8080)
    }
}
