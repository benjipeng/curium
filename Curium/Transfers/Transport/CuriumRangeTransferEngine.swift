import Foundation
import os

/// Tuning parameters for `CuriumRangeTransferEngine`.
struct CuriumRangeEngineConfiguration: Sendable, Equatable {
    var maxLanes: Int
    /// Maximum byte span per individual HTTP `Range` request (`9 MiB` defeats CDN single-range throttling).
    var maxWindowBytes: Int64
    /// Minimum remaining bytes on a straggler slice before an idle worker steals its back half (`1 MiB`).
    var minimumStealBytes: Int64
    /// Minimum known total payload size required to activate multi-lane range downloading (`512 KiB`).
    var multiLaneThresholdBytes: Int64
    /// Header wait timeout for the `GET Range: bytes=0-0` probe (`3.5s`).
    var probeTimeoutSeconds: TimeInterval
    /// Maximum total attempts per range window on transient errors (`408`/`429`/`5xx`/socket reset).
    var maxWindowRetryAttempts: Int
    /// Base delay in seconds for exponential backoff + jitter between transient window retries.
    var retryBaseDelaySeconds: TimeInterval
    /// When `true`, `If-Range` rejection (`200` instead of `206`) restarts automatically from byte 0;
    /// when `false` (default), throws `CuriumRangeTransferError.remoteResourceModified`.
    var restartOnRemoteModification: Bool

    init(
        maxLanes: Int = CuriumTransferRecord.defaultLanes,
        maxWindowBytes: Int64 = 9 * 1024 * 1024,
        minimumStealBytes: Int64 = 1024 * 1024,
        multiLaneThresholdBytes: Int64 = 512 * 1024,
        probeTimeoutSeconds: TimeInterval = 3.5,
        maxWindowRetryAttempts: Int = 4,
        retryBaseDelaySeconds: TimeInterval = 0.4,
        restartOnRemoteModification: Bool = false
    ) {
        self.maxLanes = CuriumTransferRecord.clampLanes(maxLanes)
        self.maxWindowBytes = max(64 * 1024, maxWindowBytes)
        self.minimumStealBytes = max(64 * 1024, minimumStealBytes)
        self.multiLaneThresholdBytes = max(1, multiLaneThresholdBytes)
        self.probeTimeoutSeconds = max(0.25, probeTimeoutSeconds)
        self.maxWindowRetryAttempts = max(1, maxWindowRetryAttempts)
        self.retryBaseDelaySeconds = max(0.01, retryBaseDelaySeconds)
        self.restartOnRemoteModification = restartOnRemoteModification
    }
}

/// Errors emitted by `CuriumRangeTransferEngine`.
enum CuriumRangeTransferError: LocalizedError, Sendable, Equatable {
    case disallowedURLScheme(String)
    case blockedPrivateNetworkHost(String)
    case invalidHTTPResponse
    case httpStatus(Int)
    case remoteResourceModified
    case probeTimedOut
    case unexpectedContentRange(String?)

    var errorDescription: String? {
        switch self {
        case .disallowedURLScheme(let scheme):
            return "Blocked unsupported transfer URL scheme (\(scheme))."
        case .blockedPrivateNetworkHost(let host):
            return "Blocked private or local network transfer target (\(host))."
        case .invalidHTTPResponse:
            return "Server returned an invalid HTTP response."
        case .httpStatus(let code):
            return "Server responded with HTTP \(code)."
        case .remoteResourceModified:
            return "Remote file changed since the transfer was paused."
        case .probeTimedOut:
            return "Timed out waiting for server headers."
        case .unexpectedContentRange(let header):
            return "Server returned an unexpected Content-Range header (\(header ?? "missing"))."
        }
    }
}

/// Thread-safe byte-slice state machine supporting concurrent clamping and midpoint work-stealing.
final class CuriumSliceCoordinator: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State(
        slices: [],
        nextSliceID: 0,
        lastProgressReport: .now - .seconds(1)
    ))
    private let minimumStealBytes: Int64

    private struct State: Sendable {
        var slices: [CuriumByteRangeSlice]
        var nextSliceID: Int
        var lastProgressReport: ContinuousClock.Instant
    }

    init(
        totalBytes: Int64,
        initialLanes: Int,
        existingSlices: [CuriumByteRangeSlice]?,
        minimumStealBytes: Int64
    ) {
        self.minimumStealBytes = max(64 * 1024, minimumStealBytes)
        let builtSlices: [CuriumByteRangeSlice]
        let nextID: Int

        if let existingSlices,
           !existingSlices.isEmpty,
           Self.isValidResumePartition(existingSlices, totalBytes: totalBytes) {
            builtSlices = existingSlices.map { slice in
                var copy = slice
                copy.isActiveLane = false
                return copy
            }
            nextID = (existingSlices.map(\.id).max() ?? 0) + 1
        } else {
            let maxUsefulLanes = Int(max(1, totalBytes / max(1, self.minimumStealBytes / 2)))
            let laneCount = max(1, min(initialLanes, maxUsefulLanes))
            let baseChunk = totalBytes / Int64(laneCount)
            var slices: [CuriumByteRangeSlice] = []
            slices.reserveCapacity(laneCount)
            var cursor: Int64 = 0
            for idx in 0..<laneCount {
                let end = (idx == laneCount - 1) ? (totalBytes - 1) : (cursor + baseChunk - 1)
                slices.append(CuriumByteRangeSlice(
                    id: idx,
                    startOffset: cursor,
                    currentOffset: cursor,
                    endOffset: end,
                    isActiveLane: false
                ))
                cursor = end + 1
            }
            builtSlices = slices
            nextID = laneCount
        }

        lock.withLock { state in
            state.slices = builtSlices
            state.nextSliceID = nextID
        }
    }

    static func isValidResumePartition(_ slices: [CuriumByteRangeSlice], totalBytes: Int64) -> Bool {
        guard totalBytes > 0, !slices.isEmpty else { return false }
        let sorted = slices.sorted { $0.startOffset < $1.startOffset }
        var expectedStart: Int64 = 0
        for slice in sorted {
            guard slice.startOffset == expectedStart,
                  slice.endOffset >= slice.startOffset,
                  slice.currentOffset >= slice.startOffset,
                  slice.currentOffset <= slice.endOffset + 1 else {
                return false
            }
            expectedStart = slice.endOffset + 1
        }
        return expectedStart == totalBytes
    }

    /// Assigns an unclaimed incomplete slice, or steals the back half of the largest active straggler.
    func claimOrStealSlice() -> CuriumByteRangeSlice? {
        lock.withLock { state in
            if let idleIdx = state.slices.firstIndex(where: { !$0.isActiveLane && !$0.isComplete }) {
                state.slices[idleIdx].isActiveLane = true
                return state.slices[idleIdx]
            }

            // Dynamic Midpoint Work-Stealing: split the back half of the largest active straggler.
            var bestIdx: Int?
            var largestRemaining: Int64 = 0
            for idx in state.slices.indices where state.slices[idx].isActiveLane {
                let rem = state.slices[idx].remainingBytes
                if rem >= minimumStealBytes * 2, rem > largestRemaining {
                    largestRemaining = rem
                    bestIdx = idx
                }
            }

            guard let targetIdx = bestIdx else { return nil }
            let victim = state.slices[targetIdx]
            let midpoint = victim.currentOffset + (victim.remainingBytes / 2)
            guard midpoint > victim.currentOffset, midpoint <= victim.endOffset else { return nil }

            let oldEnd = victim.endOffset
            state.slices[targetIdx].endOffset = midpoint - 1

            let stolen = CuriumByteRangeSlice(
                id: state.nextSliceID,
                startOffset: midpoint,
                currentOffset: midpoint,
                endOffset: oldEnd,
                isActiveLane: true
            )
            state.nextSliceID += 1
            if targetIdx + 1 < state.slices.count {
                state.slices.insert(stolen, at: targetIdx + 1)
            } else {
                state.slices.append(stolen)
            }
            return stolen
        }
    }

    /// Atomically reserves up to `incomingCount` bytes for `sliceID`, strictly clamping to `endOffset`
    /// so in-flight TCP bytes can never overwrite a stolen tail.
    func commitChunk(sliceID: Int, incomingCount: Int) -> (writeOffset: Int64, allowedBytes: Int, reachedSliceEnd: Bool)? {
        lock.withLock { state in
            guard let idx = state.slices.firstIndex(where: { $0.id == sliceID }) else { return nil }
            let remaining = state.slices[idx].remainingBytes
            guard remaining > 0 else {
                state.slices[idx].isActiveLane = false
                return (state.slices[idx].currentOffset, 0, true)
            }

            let allowed = Int(min(Int64(incomingCount), remaining))
            let writeOffset = state.slices[idx].currentOffset
            state.slices[idx].currentOffset += Int64(allowed)
            let done = state.slices[idx].isComplete
            if done {
                state.slices[idx].isActiveLane = false
            }
            return (writeOffset, allowed, done)
        }
    }

    /// Rolls back a slice's write cursor after a failed `pwrite` so resume retries from `toOffset`
    /// without leaving a zero-filled hole on disk.
    func rollbackChunk(sliceID: Int, toOffset: Int64) {
        lock.withLock { state in
            guard let idx = state.slices.firstIndex(where: { $0.id == sliceID }) else { return }
            let clamped = max(state.slices[idx].startOffset, min(toOffset, state.slices[idx].currentOffset))
            state.slices[idx].currentOffset = clamped
            if !state.slices[idx].isComplete {
                state.slices[idx].isActiveLane = true
            }
        }
    }

    func currentWindow(for sliceID: Int, maxWindowBytes: Int64) -> (start: Int64, end: Int64)? {
        lock.withLock { state in
            guard let idx = state.slices.firstIndex(where: { $0.id == sliceID }),
                  !state.slices[idx].isComplete else {
                return nil
            }
            let start = state.slices[idx].currentOffset
            let end = min(state.slices[idx].endOffset, start + maxWindowBytes - 1)
            return (start, end)
        }
    }

    func releaseSlice(sliceID: Int) {
        lock.withLock { state in
            if let idx = state.slices.firstIndex(where: { $0.id == sliceID }) {
                state.slices[idx].isActiveLane = false
            }
        }
    }

    func snapshotIfDue(
        totalBytes: Int64,
        minInterval: Duration = .milliseconds(200)
    ) -> CuriumRangeProgressUpdate? {
        lock.withLock { state in
            let now = ContinuousClock.now
            guard state.lastProgressReport.duration(to: now) >= minInterval else { return nil }
            state.lastProgressReport = now
            return Self.makeSnapshot(slices: state.slices, totalBytes: totalBytes, forceInactive: false)
        }
    }

    func snapshot(totalBytes: Int64, forceInactive: Bool = false) -> CuriumRangeProgressUpdate {
        lock.withLock { state in
            if forceInactive {
                for idx in state.slices.indices {
                    state.slices[idx].isActiveLane = false
                }
            }
            return Self.makeSnapshot(slices: state.slices, totalBytes: totalBytes, forceInactive: forceInactive)
        }
    }

    private static func makeSnapshot(
        slices: [CuriumByteRangeSlice],
        totalBytes: Int64,
        forceInactive: Bool
    ) -> CuriumRangeProgressUpdate {
        var received: Int64 = 0
        var active = 0
        for slice in slices {
            received += slice.downloadedBytes
            if !forceInactive && slice.isActiveLane && !slice.isComplete {
                active += 1
            }
        }
        return CuriumRangeProgressUpdate(
            receivedBytes: min(totalBytes, received),
            totalBytes: totalBytes,
            activeLanes: active,
            slices: slices
        )
    }
}

/// High-concurrency HTTP `Range` transfer engine with midpoint work-stealing, `If-Range` validation,
/// bounded TCP backpressure, lock-free `Darwin.pwrite`, per-window transient auto-retry,
/// 1-shot auth cookie refresh on `401`/`403`, and single-stream fallback.
struct CuriumRangeTransferEngine: Sendable {
    private let customSession: URLSession?

    init(session: URLSession? = nil) {
        self.customSession = session
    }

    // MARK: - Probe

    /// Probes byte-range support via `GET` with `Range: bytes=0-0` (`3.5s` header timeout),
    /// cancelling the body immediately after reading headers.
    func probe(
        url: URL,
        headers: [String: String] = [:],
        proxy: CuriumProxyConfig = .system,
        originatingURL: URL? = nil,
        cookieResolver: (@Sendable (URL) async -> String?)? = nil,
        timeoutSeconds: TimeInterval = 3.5
    ) async throws -> CuriumRangeProbeResult {
        try Self.validateTargetURL(url, originatingURL: originatingURL)
        let lease = acquireSessionLease(for: .streamProber, proxy: proxy, targetURL: url)
        defer { lease.release() }
        return try await probe(
            url: url,
            headers: headers,
            session: lease.session,
            originatingURL: originatingURL,
            cookieResolver: cookieResolver,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func probe(
        url: URL,
        headers: [String: String],
        session: URLSession,
        originatingURL: URL?,
        cookieResolver: (@Sendable (URL) async -> String?)?,
        timeoutSeconds: TimeInterval
    ) async throws -> CuriumRangeProbeResult {
        var effectiveHeaders = headers
        if !Self.hasHeader("cookie", in: effectiveHeaders),
           let cookieResolver,
           let cookie = await cookieResolver(url)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cookie.isEmpty {
            effectiveHeaders["Cookie"] = cookie
        }

        var didRefreshAuth = false
        while true {
            try Task.checkCancellation()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
            req.httpMethod = "GET"
            req.httpShouldHandleCookies = false
            for (k, v) in effectiveHeaders {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")

            let redirectGuard = CrossOriginRedirectAuthStripper(
                originatingURL: originatingURL,
                cookieResolver: cookieResolver
            )
            let receiver = BulkChunkReceiver(redirectStripper: redirectGuard)

            let response = try await startWithHeaderTimeout(
                receiver: receiver,
                request: req,
                via: session,
                timeoutSeconds: timeoutSeconds
            )
            defer { receiver.cancelFromConsumer() }

            guard let http = response as? HTTPURLResponse else {
                throw CuriumRangeTransferError.invalidHTTPResponse
            }

            if (http.statusCode == 401 || http.statusCode == 403),
               !didRefreshAuth,
               let cookieResolver {
                didRefreshAuth = true
                if let refreshed = await cookieResolver(http.url ?? url)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !refreshed.isEmpty {
                    Self.setHeader("Cookie", value: refreshed, in: &effectiveHeaders)
                    continue
                }
            }

            if http.statusCode == 416,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               Self.parseContentRangeTotal(contentRange) == 0 {
                let finalURL = http.url ?? url
                let mime = Self.normalizedMIMEType(from: http)
                return CuriumRangeProbeResult(
                    finalURL: finalURL,
                    statusCode: http.statusCode,
                    supportsByteRanges: false,
                    totalBytes: 0,
                    eTag: http.value(forHTTPHeaderField: "ETag"),
                    lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                    suggestedFilename: Self.resolveSuggestedFilename(from: http),
                    mimeType: mime,
                    isHTMLResponse: Self.isHTMLMIMEType(mime)
                )
            }

            guard (200...299).contains(http.statusCode) else {
                throw CuriumRangeTransferError.httpStatus(http.statusCode)
            }

            let finalURL = http.url ?? url
            let contentRange = http.value(forHTTPHeaderField: "Content-Range")
            var resolvedTotal = contentRange.flatMap(Self.parseContentRangeTotal)

            if resolvedTotal == nil, http.statusCode == 200 {
                if let headerLength = http.value(forHTTPHeaderField: "Content-Length")
                    .flatMap({ Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                   headerLength > 0 {
                    resolvedTotal = headerLength
                } else if response.expectedContentLength > 0 {
                    resolvedTotal = response.expectedContentLength
                }
            }

            let supportsRanges = (http.statusCode == 206) && ((resolvedTotal ?? 0) > 0)
            let mime = Self.normalizedMIMEType(from: http)

            return CuriumRangeProbeResult(
                finalURL: finalURL,
                statusCode: http.statusCode,
                supportsByteRanges: supportsRanges,
                totalBytes: resolvedTotal,
                eTag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                suggestedFilename: Self.resolveSuggestedFilename(from: http),
                mimeType: mime,
                isHTMLResponse: Self.isHTMLMIMEType(mime)
            )
        }
    }

    // MARK: - Download

    /// Downloads `url` to `destinationURL` using multi-lane `Range` work-stealing when supported
    /// and `totalBytes >= configuration.multiLaneThresholdBytes`, or single-stream fallback otherwise.
    func download(
        url: URL,
        headers: [String: String] = [:],
        destinationURL: URL,
        proxy: CuriumProxyConfig = .system,
        originatingURL: URL? = nil,
        knownTotalBytes: Int64? = nil,
        supportsRangesHint: Bool? = nil,
        existingSlices: [CuriumByteRangeSlice]? = nil,
        ifRangeValidator: String? = nil,
        cookieResolver: (@Sendable (URL) async -> String?)? = nil,
        configuration: CuriumRangeEngineConfiguration = CuriumRangeEngineConfiguration(),
        onProgress: @escaping @Sendable (CuriumRangeProgressUpdate) -> Void
    ) async throws -> CuriumRangeProgressUpdate {
        try Self.validateTargetURL(url, originatingURL: originatingURL)

        do {
            return try await executeDownload(
                url: url,
                headers: headers,
                destinationURL: destinationURL,
                proxy: proxy,
                originatingURL: originatingURL,
                knownTotalBytes: knownTotalBytes,
                supportsRangesHint: supportsRangesHint,
                existingSlices: existingSlices,
                ifRangeValidator: ifRangeValidator,
                cookieResolver: cookieResolver,
                configuration: configuration,
                onProgress: onProgress
            )
        } catch CuriumRangeTransferError.remoteResourceModified
            where configuration.restartOnRemoteModification && existingSlices != nil {
            return try await executeDownload(
                url: url,
                headers: headers,
                destinationURL: destinationURL,
                proxy: proxy,
                originatingURL: originatingURL,
                knownTotalBytes: nil,
                supportsRangesHint: nil,
                existingSlices: nil,
                ifRangeValidator: nil,
                cookieResolver: cookieResolver,
                configuration: configuration,
                onProgress: onProgress
            )
        }
    }

    private func executeDownload(
        url: URL,
        headers: [String: String],
        destinationURL: URL,
        proxy: CuriumProxyConfig,
        originatingURL: URL?,
        knownTotalBytes: Int64?,
        supportsRangesHint: Bool?,
        existingSlices: [CuriumByteRangeSlice]?,
        ifRangeValidator: String?,
        cookieResolver: (@Sendable (URL) async -> String?)?,
        configuration: CuriumRangeEngineConfiguration,
        onProgress: @escaping @Sendable (CuriumRangeProgressUpdate) -> Void
    ) async throws -> CuriumRangeProgressUpdate {
        var lease = acquireSessionLease(for: .rangeTransfer, proxy: proxy, targetURL: url)
        defer { lease.release() }

        let totalBytes: Int64?
        let supportsRanges: Bool
        let targetURL: URL
        let effectiveIfRange: String?

        if let knownTotalBytes, knownTotalBytes > 0, let supportsRangesHint {
            totalBytes = knownTotalBytes
            supportsRanges = supportsRangesHint
            targetURL = url
            effectiveIfRange = Self.sanitizedIfRangeValidator(ifRangeValidator)
        } else {
            let probed = try await probe(
                url: url,
                headers: headers,
                session: lease.session,
                originatingURL: originatingURL,
                cookieResolver: cookieResolver,
                timeoutSeconds: configuration.probeTimeoutSeconds
            )
            totalBytes = probed.totalBytes ?? knownTotalBytes
            supportsRanges = probed.supportsByteRanges
            targetURL = probed.finalURL
            effectiveIfRange = Self.sanitizedIfRangeValidator(ifRangeValidator) ?? probed.ifRangeValidator
        }

        try Self.validateTargetURL(targetURL, originatingURL: originatingURL ?? url)

        lease = reacquireLeaseIfRedirected(
            currentLease: lease,
            initialURL: url,
            targetURL: targetURL,
            proxy: proxy
        )
        let activeSession = lease.session

        var effectiveHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
            from: headers,
            sourceURL: url,
            destinationURL: targetURL
        )
        if !Self.hasHeader("cookie", in: effectiveHeaders),
           let cookieResolver,
           let refreshed = await cookieResolver(targetURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshed.isEmpty {
            effectiveHeaders["Cookie"] = refreshed
        }

        guard supportsRanges,
              let totalBytes,
              totalBytes >= configuration.multiLaneThresholdBytes else {
            return try await downloadSingleStreamFallback(
                url: targetURL,
                headers: effectiveHeaders,
                session: activeSession,
                destinationURL: destinationURL,
                originatingURL: originatingURL,
                expectedBytes: totalBytes,
                cookieResolver: cookieResolver,
                configuration: configuration,
                onProgress: onProgress
            )
        }

        let canResumeExisting: Bool = {
            guard let existingSlices,
                  CuriumSliceCoordinator.isValidResumePartition(existingSlices, totalBytes: totalBytes),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
                  let diskSize = (attrs[.size] as? NSNumber)?.int64Value,
                  diskSize >= totalBytes else {
                return false
            }
            return true
        }()

        let isFreshStart = !canResumeExisting
        let writer = try CuriumPreallocatedFileWriter(
            fileURL: destinationURL,
            preallocateBytes: totalBytes,
            truncateExisting: isFreshStart
        )

        let coordinator = CuriumSliceCoordinator(
            totalBytes: totalBytes,
            initialLanes: configuration.maxLanes,
            existingSlices: isFreshStart ? nil : existingSlices,
            minimumStealBytes: configuration.minimumStealBytes
        )

        let headerStore = SharedHeaderStore(headers: effectiveHeaders)
        onProgress(coordinator.snapshot(totalBytes: totalBytes))

        let maxUsefulWorkers = Int(max(1, totalBytes / max(1, configuration.minimumStealBytes / 2)))
        let workerCount = max(1, min(configuration.maxLanes, maxUsefulWorkers))

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        try await runWorkerLoop(
                            url: targetURL,
                            headerStore: headerStore,
                            session: activeSession,
                            originatingURL: originatingURL,
                            ifRangeValidator: effectiveIfRange,
                            cookieResolver: cookieResolver,
                            writer: writer,
                            coordinator: coordinator,
                            totalBytes: totalBytes,
                            configuration: configuration,
                            onProgress: onProgress
                        )
                    }
                }
                try await group.waitForAll()
            }

            try writer.finalize()
            let finalSnapshot = coordinator.snapshot(totalBytes: totalBytes, forceInactive: true)
            onProgress(finalSnapshot)
            return finalSnapshot
        } catch {
            // Flush all already-committed slices on pause/cancel/error without deleting the staging file.
            try? writer.synchronize()
            try? writer.close()
            onProgress(coordinator.snapshot(totalBytes: totalBytes, forceInactive: true))
            throw error
        }
    }

    // MARK: - Worker Loop & Per-Window Auto-Retry

    private func runWorkerLoop(
        url: URL,
        headerStore: SharedHeaderStore,
        session: URLSession,
        originatingURL: URL?,
        ifRangeValidator: String?,
        cookieResolver: (@Sendable (URL) async -> String?)?,
        writer: CuriumPreallocatedFileWriter,
        coordinator: CuriumSliceCoordinator,
        totalBytes: Int64,
        configuration: CuriumRangeEngineConfiguration,
        onProgress: @escaping @Sendable (CuriumRangeProgressUpdate) -> Void
    ) async throws {
        while !Task.isCancelled {
            guard let claimed = coordinator.claimOrStealSlice() else {
                return
            }
            let sliceID = claimed.id
            do {
                while !Task.isCancelled,
                      coordinator.currentWindow(for: sliceID, maxWindowBytes: configuration.maxWindowBytes) != nil {
                    try await fetchWindowWithRetry(
                        url: url,
                        headerStore: headerStore,
                        session: session,
                        originatingURL: originatingURL,
                        ifRangeValidator: ifRangeValidator,
                        cookieResolver: cookieResolver,
                        sliceID: sliceID,
                        writer: writer,
                        coordinator: coordinator,
                        totalBytes: totalBytes,
                        configuration: configuration,
                        onProgress: onProgress
                    )
                }
                coordinator.releaseSlice(sliceID: sliceID)
            } catch {
                coordinator.releaseSlice(sliceID: sliceID)
                throw error
            }
        }
        try Task.checkCancellation()
    }

    private func fetchWindowWithRetry(
        url: URL,
        headerStore: SharedHeaderStore,
        session: URLSession,
        originatingURL: URL?,
        ifRangeValidator: String?,
        cookieResolver: (@Sendable (URL) async -> String?)?,
        sliceID: Int,
        writer: CuriumPreallocatedFileWriter,
        coordinator: CuriumSliceCoordinator,
        totalBytes: Int64,
        configuration: CuriumRangeEngineConfiguration,
        onProgress: @escaping @Sendable (CuriumRangeProgressUpdate) -> Void
    ) async throws {
        var attempt = 0
        var didRefreshAuthForWindow = false

        while true {
            try Task.checkCancellation()
            guard let window = coordinator.currentWindow(for: sliceID, maxWindowBytes: configuration.maxWindowBytes) else {
                return
            }

            attempt += 1
            do {
                try await fetchWindowOnce(
                    url: url,
                    headers: headerStore.currentHeaders(),
                    session: session,
                    originatingURL: originatingURL,
                    ifRangeValidator: ifRangeValidator,
                    cookieResolver: cookieResolver,
                    sliceID: sliceID,
                    windowStart: window.start,
                    windowEnd: window.end,
                    writer: writer,
                    coordinator: coordinator,
                    totalBytes: totalBytes,
                    onProgress: onProgress
                )
                return
            } catch let retryable as WindowRetryableError {
                // 1-shot cookie refresh on 401/403 before failing.
                if (retryable.statusCode == 401 || retryable.statusCode == 403),
                   !didRefreshAuthForWindow,
                   let cookieResolver {
                    didRefreshAuthForWindow = true
                    let refreshed = await headerStore.refreshCookieOnce(for: url, using: cookieResolver)
                    if refreshed {
                        attempt = max(0, attempt - 1)
                        continue
                    }
                    throw CuriumRangeTransferError.httpStatus(retryable.statusCode ?? 403)
                }

                guard attempt < configuration.maxWindowRetryAttempts,
                      retryable.isTransient else {
                    throw retryable.underlyingError
                }

                let delay = Self.retryDelaySeconds(
                    attempt: attempt,
                    baseDelay: configuration.retryBaseDelaySeconds,
                    retryAfterHeader: retryable.retryAfterHeader
                )
                try await Task.sleep(for: .seconds(delay))
            } catch {
                if error is CancellationError {
                    throw error
                }
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw CancellationError()
                }
                if attempt < configuration.maxWindowRetryAttempts,
                   Self.isTransientNetworkError(error) {
                    let delay = Self.retryDelaySeconds(
                        attempt: attempt,
                        baseDelay: configuration.retryBaseDelaySeconds,
                        retryAfterHeader: nil
                    )
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            }
        }
    }

    private struct WindowRetryableError: Error {
        let statusCode: Int?
        let retryAfterHeader: String?
        let isTransient: Bool
        let underlyingError: any Error
    }

    private func fetchWindowOnce(
        url: URL,
        headers: [String: String],
        session: URLSession,
        originatingURL: URL?,
        ifRangeValidator: String?,
        cookieResolver: (@Sendable (URL) async -> String?)?,
        sliceID: Int,
        windowStart: Int64,
        windowEnd: Int64,
        writer: CuriumPreallocatedFileWriter,
        coordinator: CuriumSliceCoordinator,
        totalBytes: Int64,
        onProgress: @escaping @Sendable (CuriumRangeProgressUpdate) -> Void
    ) async throws {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("bytes=\(windowStart)-\(windowEnd)", forHTTPHeaderField: "Range")
        if let ifRangeValidator, !ifRangeValidator.isEmpty {
            req.setValue(ifRangeValidator, forHTTPHeaderField: "If-Range")
        }

        let redirectGuard = CrossOriginRedirectAuthStripper(
            originatingURL: originatingURL,
            cookieResolver: cookieResolver
        )
        let receiver = BulkChunkReceiver(redirectStripper: redirectGuard)
        let response = try await receiver.start(request: req, via: session)
        defer { receiver.cancelFromConsumer() }

        guard let http = response as? HTTPURLResponse else {
            throw CuriumRangeTransferError.invalidHTTPResponse
        }

        if http.statusCode == 200, ifRangeValidator != nil {
            throw CuriumRangeTransferError.remoteResourceModified
        }

        if http.statusCode != 206 {
            let status = http.statusCode
            let isTransient = status == 408 || status == 429 || (500...599).contains(status)
            throw WindowRetryableError(
                statusCode: status,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                isTransient: isTransient,
                underlyingError: CuriumRangeTransferError.httpStatus(status)
            )
        }

        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let parsedStart = Self.parseContentRangeStart(contentRange),
           parsedStart != windowStart {
            throw CuriumRangeTransferError.unexpectedContentRange(contentRange)
        }

        let coalesceSize = 128 * 1024
        var buffer = Data()
        buffer.reserveCapacity(coalesceSize)

        while let chunk = try await receiver.nextChunk() {
            try Task.checkCancellation()
            if buffer.isEmpty && chunk.count >= coalesceSize {
                let done = try Self.commitAndWrite(chunk, sliceID: sliceID, writer: writer, coordinator: coordinator)
                if let update = coordinator.snapshotIfDue(totalBytes: totalBytes) {
                    onProgress(update)
                }
                if done { return }
            } else {
                buffer.append(chunk)
                if buffer.count >= coalesceSize {
                    let done = try flushCoalescedBuffer(&buffer, sliceID: sliceID, writer: writer, coordinator: coordinator)
                    if let update = coordinator.snapshotIfDue(totalBytes: totalBytes) {
                        onProgress(update)
                    }
                    if done { return }
                }
            }
        }

        try Task.checkCancellation()
        if !buffer.isEmpty {
            _ = try flushCoalescedBuffer(&buffer, sliceID: sliceID, writer: writer, coordinator: coordinator)
        }
        if let update = coordinator.snapshotIfDue(totalBytes: totalBytes) {
            onProgress(update)
        }
    }

    static func commitAndWrite(
        _ chunk: Data,
        sliceID: Int,
        writer: CuriumPreallocatedFileWriter,
        coordinator: CuriumSliceCoordinator
    ) throws -> Bool {
        guard let commit = coordinator.commitChunk(sliceID: sliceID, incomingCount: chunk.count) else {
            return true
        }
        if commit.allowedBytes > 0 {
            do {
                if commit.allowedBytes == chunk.count {
                    try writer.write(chunk, at: commit.writeOffset)
                } else {
                    try writer.write(Data(chunk.prefix(commit.allowedBytes)), at: commit.writeOffset)
                }
            } catch {
                coordinator.rollbackChunk(sliceID: sliceID, toOffset: commit.writeOffset)
                throw error
            }
        }
        return commit.reachedSliceEnd
    }

    private func flushCoalescedBuffer(
        _ buffer: inout Data,
        sliceID: Int,
        writer: CuriumPreallocatedFileWriter,
        coordinator: CuriumSliceCoordinator
    ) throws -> Bool {
        defer { buffer.removeAll(keepingCapacity: true) }
        return try Self.commitAndWrite(buffer, sliceID: sliceID, writer: writer, coordinator: coordinator)
    }

    // MARK: - Single-Stream Fallback

    private func downloadSingleStreamFallback(
        url: URL,
        headers: [String: String],
        session: URLSession,
        destinationURL: URL,
        originatingURL: URL?,
        expectedBytes: Int64?,
        cookieResolver: (@Sendable (URL) async -> String?)?,
        configuration: CuriumRangeEngineConfiguration,
        onProgress: @escaping @Sendable (CuriumRangeProgressUpdate) -> Void
    ) async throws -> CuriumRangeProgressUpdate {
        var effectiveHeaders = headers
        var didRefreshAuth = false
        var attempt = 0

        let responseAndReceiver: (HTTPURLResponse, BulkChunkReceiver)
        while true {
            try Task.checkCancellation()
            attempt += 1
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            req.httpMethod = "GET"
            req.httpShouldHandleCookies = false
            for (k, v) in effectiveHeaders {
                req.setValue(v, forHTTPHeaderField: k)
            }

            let redirectGuard = CrossOriginRedirectAuthStripper(
                originatingURL: originatingURL,
                cookieResolver: cookieResolver
            )
            let receiver = BulkChunkReceiver(redirectStripper: redirectGuard)

            do {
                let response = try await receiver.start(request: req, via: session)
                guard let http = response as? HTTPURLResponse else {
                    receiver.cancelFromConsumer()
                    throw CuriumRangeTransferError.invalidHTTPResponse
                }
                if (http.statusCode == 401 || http.statusCode == 403),
                   !didRefreshAuth,
                   let cookieResolver {
                    receiver.cancelFromConsumer()
                    didRefreshAuth = true
                    if let refreshed = await cookieResolver(http.url ?? url)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !refreshed.isEmpty {
                        Self.setHeader("Cookie", value: refreshed, in: &effectiveHeaders)
                        attempt = max(0, attempt - 1)
                        continue
                    }
                    throw CuriumRangeTransferError.httpStatus(http.statusCode)
                }
                let status = http.statusCode
                if !(200...299).contains(status) {
                    receiver.cancelFromConsumer()
                    let isTransient = status == 408 || status == 429 || (500...599).contains(status)
                    if isTransient && attempt < configuration.maxWindowRetryAttempts {
                        let delay = Self.retryDelaySeconds(
                            attempt: attempt,
                            baseDelay: configuration.retryBaseDelaySeconds,
                            retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                        )
                        try await Task.sleep(for: .seconds(delay))
                        continue
                    }
                    throw CuriumRangeTransferError.httpStatus(status)
                }
                responseAndReceiver = (http, receiver)
                break
            } catch {
                receiver.cancelFromConsumer()
                if error is CancellationError {
                    throw error
                }
                if let urlErr = error as? URLError, urlErr.code == .cancelled {
                    throw CancellationError()
                }
                if attempt < configuration.maxWindowRetryAttempts && Self.isTransientNetworkError(error) {
                    let delay = Self.retryDelaySeconds(
                        attempt: attempt,
                        baseDelay: configuration.retryBaseDelaySeconds,
                        retryAfterHeader: nil
                    )
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            }
        }

        let (http, receiver) = responseAndReceiver
        defer { receiver.cancelFromConsumer() }

        let resolvedExpected: Int64? = expectedBytes ?? (http.expectedContentLength > 0 ? http.expectedContentLength : nil)
        let writer = try CuriumPreallocatedFileWriter(
            fileURL: destinationURL,
            preallocateBytes: resolvedExpected,
            truncateExisting: true
        )

        var offset: Int64 = 0
        var buffer = Data()
        let coalesceSize = 128 * 1024
        buffer.reserveCapacity(coalesceSize)
        var lastReport = ContinuousClock.now - .milliseconds(250)

        do {
            while let chunk = try await receiver.nextChunk() {
                try Task.checkCancellation()
                buffer.append(chunk)
                let now = ContinuousClock.now
                let reportDue = lastReport.duration(to: now) >= .milliseconds(200)

                if buffer.count >= coalesceSize || reportDue {
                    if !buffer.isEmpty {
                        try writer.write(buffer, at: offset)
                        offset += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                    }
                    if reportDue {
                        lastReport = now
                        let slice = CuriumByteRangeSlice(
                            id: 0,
                            startOffset: 0,
                            currentOffset: offset,
                            endOffset: max(offset, (resolvedExpected ?? offset) - 1),
                            isActiveLane: true
                        )
                        onProgress(CuriumRangeProgressUpdate(
                            receivedBytes: offset,
                            totalBytes: resolvedExpected,
                            activeLanes: 1,
                            slices: [slice]
                        ))
                    }
                }
            }

            try Task.checkCancellation()
            if !buffer.isEmpty {
                try writer.write(buffer, at: offset)
                offset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: false)
            }
            try writer.finalize()

            let finalSlice = CuriumByteRangeSlice(
                id: 0,
                startOffset: 0,
                currentOffset: offset,
                endOffset: max(0, offset - 1),
                isActiveLane: false
            )
            let summary = CuriumRangeProgressUpdate(
                receivedBytes: offset,
                totalBytes: resolvedExpected ?? offset,
                activeLanes: 0,
                slices: [finalSlice]
            )
            onProgress(summary)
            return summary
        } catch {
            try? writer.synchronize()
            try? writer.close()
            let pausedSlice = CuriumByteRangeSlice(
                id: 0,
                startOffset: 0,
                currentOffset: offset,
                endOffset: max(0, (resolvedExpected ?? offset) - 1),
                isActiveLane: false
            )
            onProgress(CuriumRangeProgressUpdate(
                receivedBytes: offset,
                totalBytes: resolvedExpected,
                activeLanes: 0,
                slices: offset > 0 ? [pausedSlice] : []
            ))
            throw error
        }
    }

    // MARK: - Bounded Backpressure Receiver

    /// Bounded bulk chunk-level HTTP body reader applying true TCP backpressure
    /// (`dataTask.suspend()` at `2 MiB` / `resume()` at `512 KiB`) and delegating 3xx redirects
    /// through `CrossOriginRedirectAuthStripper`.
    private final class BulkChunkReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private static let highWaterBytes = 2 * 1024 * 1024
        private static let lowWaterBytes = 512 * 1024

        private let redirectStripper: CrossOriginRedirectAuthStripper
        private let lock = NSLock()
        private weak var activeTask: URLSessionDataTask?
        private var headerContinuation: CheckedContinuation<URLResponse, any Error>?
        private var chunkContinuation: CheckedContinuation<Data?, any Error>?
        private var pendingResponse: URLResponse?
        private var bufferedChunks: [Data] = []
        private var headIndex: Int = 0
        private var bufferedBytes: Int = 0
        private var isSuspendedForBackpressure: Bool = false
        private var streamCompleted: Bool = false
        private var streamError: (any Error)?

        init(redirectStripper: CrossOriginRedirectAuthStripper) {
            self.redirectStripper = redirectStripper
            super.init()
        }

        func start(request: URLRequest, via session: URLSession) async throws -> URLResponse {
            let task = session.dataTask(with: request)
            task.delegate = self
            lock.withLock {
                self.activeTask = task
            }

            let response: URLResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    enum HeaderAction {
                        case returnResponse(URLResponse)
                        case throwError(any Error)
                        case resumeTask
                    }
                    let action: HeaderAction = lock.withLock {
                        if let resp = pendingResponse {
                            return .returnResponse(resp)
                        }
                        if let err = streamError {
                            return .throwError(err)
                        }
                        if streamCompleted {
                            return .throwError(CuriumRangeTransferError.invalidHTTPResponse)
                        }
                        headerContinuation = cont
                        return .resumeTask
                    }
                    switch action {
                    case .returnResponse(let resp):
                        cont.resume(returning: resp)
                    case .throwError(let err):
                        cont.resume(throwing: err)
                    case .resumeTask:
                        task.resume()
                    }
                }
            } onCancel: {
                self.cancelFromConsumer()
            }
            return response
        }

        func nextChunk() async throws -> Data? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, any Error>) in
                    enum NextAction {
                        case deliver(Data, URLSessionDataTask?)
                        case finish
                        case fail(any Error)
                        case wait
                    }

                    let action: NextAction = lock.withLock {
                        if let err = streamError {
                            return .fail(err)
                        }
                        if headIndex < bufferedChunks.count {
                            let chunk = bufferedChunks[headIndex]
                            bufferedChunks[headIndex] = Data()
                            headIndex += 1
                            bufferedBytes = max(0, bufferedBytes - chunk.count)
                            if headIndex >= 32, headIndex * 2 >= bufferedChunks.count {
                                bufferedChunks.removeFirst(headIndex)
                                headIndex = 0
                            }
                            var taskToResume: URLSessionDataTask?
                            if isSuspendedForBackpressure && bufferedBytes <= Self.lowWaterBytes {
                                isSuspendedForBackpressure = false
                                taskToResume = activeTask
                            }
                            return .deliver(chunk, taskToResume)
                        }
                        if streamCompleted {
                            return .finish
                        }
                        chunkContinuation = cont
                        return .wait
                    }

                    switch action {
                    case .deliver(let data, let taskToResume):
                        taskToResume?.resume()
                        cont.resume(returning: data)
                    case .finish:
                        cont.resume(returning: nil)
                    case .fail(let err):
                        cont.resume(throwing: err)
                    case .wait:
                        break
                    }
                }
            } onCancel: {
                self.cancelFromConsumer()
            }
        }

        func cancelFromConsumer() {
            let (hCont, cCont, task, wasSuspended): (
                CheckedContinuation<URLResponse, any Error>?,
                CheckedContinuation<Data?, any Error>?,
                URLSessionDataTask?,
                Bool
            ) = lock.withLock {
                if streamError == nil {
                    streamError = CancellationError()
                }
                streamCompleted = true
                bufferedChunks.removeAll(keepingCapacity: false)
                headIndex = 0
                bufferedBytes = 0
                let suspended = isSuspendedForBackpressure
                isSuspendedForBackpressure = false
                let h = headerContinuation
                headerContinuation = nil
                let c = chunkContinuation
                chunkContinuation = nil
                return (h, c, activeTask, suspended)
            }
            if wasSuspended {
                task?.resume()
            }
            task?.cancel()
            hCont?.resume(throwing: CancellationError())
            cCont?.resume(throwing: CancellationError())
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            redirectStripper.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: completionHandler
            )
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let cont: CheckedContinuation<URLResponse, any Error>? = lock.withLock {
                pendingResponse = response
                let c = headerContinuation
                headerContinuation = nil
                return c
            }
            cont?.resume(returning: response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !data.isEmpty else { return }
            let (directCont, shouldSuspend): (CheckedContinuation<Data?, any Error>?, Bool) = lock.withLock {
                guard !streamCompleted else { return (nil, false) }
                if let waiting = chunkContinuation {
                    chunkContinuation = nil
                    return (waiting, false)
                }
                bufferedChunks.append(data)
                bufferedBytes += data.count
                if bufferedBytes >= Self.highWaterBytes && !isSuspendedForBackpressure {
                    isSuspendedForBackpressure = true
                    return (nil, true)
                }
                return (nil, false)
            }
            if let directCont {
                directCont.resume(returning: data)
            } else if shouldSuspend {
                dataTask.suspend()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let blockedError = redirectStripper.takeBlockedError(for: task.taskIdentifier)
            let mappedError: (any Error)? = {
                if let blockedError {
                    switch blockedError {
                    case .disallowedURLScheme(let scheme):
                        return CuriumRangeTransferError.disallowedURLScheme(scheme)
                    case .blockedPrivateNetworkHost(let host):
                        return CuriumRangeTransferError.blockedPrivateNetworkHost(host)
                    }
                }
                return error
            }()

            let (hCont, cCont, finalError): (CheckedContinuation<URLResponse, any Error>?, CheckedContinuation<Data?, any Error>?, (any Error)?) = lock.withLock {
                streamCompleted = true
                if let mappedError, streamError == nil {
                    streamError = mappedError
                }
                let h = headerContinuation
                headerContinuation = nil
                let c = chunkContinuation
                chunkContinuation = nil
                return (h, c, streamError)
            }

            if let finalError {
                hCont?.resume(throwing: finalError)
                cCont?.resume(throwing: finalError)
            } else {
                hCont?.resume(throwing: CuriumRangeTransferError.invalidHTTPResponse)
                cCont?.resume(returning: nil)
            }
        }
    }

    // MARK: - Shared Auth Header State

    private final class SharedHeaderStore: @unchecked Sendable {
        private struct State: Sendable {
            var headers: [String: String]
            var didRefresh: Bool
            var inFlightTask: Task<Bool, Never>?
        }

        private let state: OSAllocatedUnfairLock<State>

        init(headers: [String: String]) {
            self.state = OSAllocatedUnfairLock(initialState: State(
                headers: headers,
                didRefresh: false,
                inFlightTask: nil
            ))
        }

        func currentHeaders() -> [String: String] {
            state.withLock { $0.headers }
        }

        func refreshCookieOnce(
            for url: URL,
            using resolver: @escaping @Sendable (URL) async -> String?
        ) async -> Bool {
            let task: Task<Bool, Never>? = state.withLock { s in
                if let existing = s.inFlightTask {
                    return existing
                }
                if s.didRefresh {
                    return nil
                }
                let created = Task<Bool, Never> { [weak self] in
                    let refreshed = await resolver(url)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self else { return false }
                    return self.state.withLock { inner in
                        inner.inFlightTask = nil
                        inner.didRefresh = true
                        guard let refreshed, !refreshed.isEmpty else { return false }
                        CuriumRangeTransferEngine.setHeader("Cookie", value: refreshed, in: &inner.headers)
                        return true
                    }
                }
                s.inFlightTask = created
                return created
            }
            guard let task else { return false }
            return await task.value
        }
    }

    // MARK: - Helpers & Header Parsing

    func reacquireLeaseIfRedirected(
        currentLease: CuriumProxySessionPool.SessionLease,
        initialURL: URL,
        targetURL: URL,
        proxy: CuriumProxyConfig
    ) -> CuriumProxySessionPool.SessionLease {
        guard customSession == nil, targetURL != initialURL else {
            return currentLease
        }
        let nextLease = acquireSessionLease(for: .rangeTransfer, proxy: proxy, targetURL: targetURL)
        currentLease.release()
        return nextLease
    }

    private func acquireSessionLease(
        for profile: CuriumProxySessionPool.SessionProfile,
        proxy: CuriumProxyConfig,
        targetURL: URL
    ) -> CuriumProxySessionPool.SessionLease {
        if let customSession {
            return CuriumProxySessionPool.SessionLease(session: customSession)
        }
        return CuriumProxySessionPool.acquireSessionLease(for: profile, proxy: proxy, targetURL: targetURL)
    }

    private func startWithHeaderTimeout(
        receiver: BulkChunkReceiver,
        request: URLRequest,
        via session: URLSession,
        timeoutSeconds: TimeInterval
    ) async throws -> URLResponse {
        try await withThrowingTaskGroup(of: URLResponse?.self) { group in
            group.addTask {
                try await receiver.start(request: request, via: session)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            guard let first = try await group.next() else {
                throw CuriumRangeTransferError.probeTimedOut
            }
            group.cancelAll()
            if let result = first {
                return result
            }
            receiver.cancelFromConsumer()
            throw CuriumRangeTransferError.probeTimedOut
        }
    }

    static func sanitizedIfRangeValidator(_ raw: String?) -> String? {
        CuriumTransferRecord.strongETag(from: raw)
    }

    static func resolveIfRangeValidator(etag: String?, lastModified: String?) -> String? {
        if let strong = CuriumTransferRecord.strongETag(from: etag) {
            return strong
        }
        if let lm = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines), !lm.isEmpty {
            return lm
        }
        return nil
    }

    /// Parses RFC 6266 / RFC 5987 `Content-Disposition` filename (`filename*=` takes precedence over `filename=`).
    static func parseContentDispositionFilename(_ header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        let segments = header.split(separator: ";").dropFirst()

        var extendedFilename: String?
        var basicFilename: String?

        for rawSegment in segments {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eqIdx = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<eqIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = segment[segment.index(after: eqIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "filename*" {
                let unquoted = stripOuterQuotes(rawValue)
                if let firstQuote = unquoted.firstIndex(of: "'"),
                   let secondQuote = unquoted[unquoted.index(after: firstQuote)...].firstIndex(of: "'") {
                    let encoded = String(unquoted[unquoted.index(after: secondQuote)...])
                    let decoded = encoded.removingPercentEncoding ?? encoded
                    if !decoded.isEmpty {
                        extendedFilename = decoded
                    }
                } else if let decoded = unquoted.removingPercentEncoding, !decoded.isEmpty {
                    extendedFilename = decoded
                }
            } else if key == "filename" {
                let unquoted = unescapeQuotedString(stripOuterQuotes(rawValue))
                if !unquoted.isEmpty {
                    basicFilename = unquoted
                }
            }
        }

        let winner = extendedFilename ?? basicFilename
        guard let winner, !winner.isEmpty else { return nil }
        return CuriumDownloadStorage.sanitizedFilename(winner)
    }

    static func parseContentRangeTotal(_ header: String) -> Int64? {
        guard let slashIdx = header.lastIndex(of: "/") else { return nil }
        let totalPart = header[header.index(after: slashIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard totalPart != "*", let parsed = Int64(totalPart), parsed >= 0 else { return nil }
        return parsed
    }

    static func parseContentRangeStart(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard let rangePart = body.split(separator: "/", maxSplits: 1).first,
              let dashIdx = rangePart.firstIndex(of: "-") else {
            return nil
        }
        return Int64(rangePart[..<dashIdx].trimmingCharacters(in: .whitespaces))
    }

    static func retryDelaySeconds(
        attempt: Int,
        baseDelay: TimeInterval,
        retryAfterHeader: String?
    ) -> TimeInterval {
        if let retryAfterHeader {
            let trimmed = retryAfterHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
                return min(15.0, max(0.05, seconds))
            }
            if let date = parseHTTPDate(trimmed) {
                let delta = date.timeIntervalSinceNow
                if delta.isFinite, delta > 0 {
                    return min(15.0, max(0.05, delta))
                }
            }
        }
        let exponent = Double(max(0, attempt - 1))
        let raw = baseDelay * pow(2.0, exponent)
        let jitter = Double.random(in: 0.75...1.25)
        return min(15.0, max(0.01, raw * jitter))
    }

    private static func resolveSuggestedFilename(from response: HTTPURLResponse) -> String? {
        if let parsed = parseContentDispositionFilename(response.value(forHTTPHeaderField: "Content-Disposition")) {
            return parsed
        }
        if let suggested = response.suggestedFilename, !suggested.isEmpty {
            return CuriumDownloadStorage.sanitizedFilename(suggested)
        }
        return nil
    }

    private static func normalizedMIMEType(from response: HTTPURLResponse) -> String? {
        let raw = response.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
        guard let raw else { return nil }
        let primary = raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return (primary?.isEmpty == false) ? primary : nil
    }

    private static func isHTMLMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return mimeType == "text/html" || mimeType == "application/xhtml+xml"
    }

    private static func validateTargetURL(_ url: URL, originatingURL: URL?) throws {
        guard CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumRangeTransferError.disallowedURLScheme(url.scheme ?? "unknown")
        }
        guard CuriumHLSParser.isAllowedTargetURL(url, originatingURL: originatingURL) else {
            throw CuriumRangeTransferError.blockedPrivateNetworkHost(url.host ?? "private")
        }
    }

    static func isTransientNetworkError(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotConnectToHost,
                 .internationalRoamingOff,
                 .dataNotAllowed,
                 .callIsActive:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case ECONNRESET, EPIPE, ETIMEDOUT, ENETRESET, ECONNABORTED:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func hasHeader(_ lowercaseName: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.lowercased() == lowercaseName }
    }

    private static func setHeader(_ name: String, value: String, in headers: inout [String: String]) {
        let lower = name.lowercased()
        for existingKey in headers.keys where existingKey.lowercased() == lower {
            headers.removeValue(forKey: existingKey)
        }
        headers[name] = value
    }

    private static func stripOuterQuotes(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func unescapeQuotedString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var escaped = false
        for ch in value {
            if escaped {
                result.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: value) {
                return parsed
            }
        }
        return nil
    }
}
