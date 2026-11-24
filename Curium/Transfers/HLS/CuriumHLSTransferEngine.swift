import CommonCrypto
import Darwin
import Foundation

// MARK: - Public Request, Resume, Progress & Result Models

/// Self-contained request configuration for `CuriumHLSTransferEngine`.
/// Allows the transfer coordinator to plug in browser headers, dynamic tab cookie lookup,
/// and proxy-configured `URLSession` instances without coupling HLS transport to UI or storage.
public struct CuriumHLSRequestConfig: Sendable {
    public let userAgent: String?
    public let referer: String?
    public let origin: String?
    public let extraHeaders: [String: String]
    public let originatingURL: URL?
    public let cookieResolver: (@Sendable (URL) async -> String?)?
    public let sessionFactory: (@Sendable () -> URLSession)?

    public init(
        userAgent: String? = nil,
        referer: String? = nil,
        origin: String? = nil,
        extraHeaders: [String: String] = [:],
        originatingURL: URL? = nil,
        cookieResolver: (@Sendable (URL) async -> String?)? = nil,
        sessionFactory: (@Sendable () -> URLSession)? = nil
    ) {
        self.userAgent = userAgent
        self.referer = referer
        self.origin = origin
        self.extraHeaders = extraHeaders
        self.originatingURL = originatingURL
        self.cookieResolver = cookieResolver
        self.sessionFactory = sessionFactory
    }
}

/// Durable segment-checkpointed resume cursor persisted across Pause -> Resume and relaunches.
///
/// `completedSegments` and `contiguousByteOffset` strictly record the contiguous prefix `0..<k`
/// flushed to `video.part` (and similarly `audioCompletedSegments` / `audioContiguousByteOffset`
/// for optional separate `audio.part`), guaranteeing zero gaps or duplicate writes on resume.
public struct CuriumHLSResumeState: Codable, Hashable, Sendable {
    public var completedSegments: Int
    public var totalSegments: Int?
    public var contiguousByteOffset: Int64
    public var audioCompletedSegments: Int
    public var audioContiguousByteOffset: Int64
    public var isFMP4: Bool

    public init(
        completedSegments: Int = 0,
        totalSegments: Int? = nil,
        contiguousByteOffset: Int64 = 0,
        audioCompletedSegments: Int = 0,
        audioContiguousByteOffset: Int64 = 0,
        isFMP4: Bool = false
    ) {
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
        self.contiguousByteOffset = contiguousByteOffset
        self.audioCompletedSegments = audioCompletedSegments
        self.audioContiguousByteOffset = audioContiguousByteOffset
        self.isFMP4 = isFMP4
    }
}

/// Live monotonic HLS transfer telemetry emitted during playlist resolution, concurrent
/// segment streaming, and native `.mp4` remuxing.
public struct CuriumHLSProgressUpdate: Sendable, Equatable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case fetchingPlaylist
        case downloadingSegments
        case remuxing
    }

    public let phase: Phase
    public let receivedBytes: Int64
    public let estimatedTotalBytes: Int64?
    public let completedSegments: Int
    public let totalSegments: Int
    public let activeWorkers: Int
    public let resumeState: CuriumHLSResumeState

    public init(
        phase: Phase,
        receivedBytes: Int64,
        estimatedTotalBytes: Int64?,
        completedSegments: Int,
        totalSegments: Int,
        activeWorkers: Int,
        resumeState: CuriumHLSResumeState
    ) {
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.estimatedTotalBytes = estimatedTotalBytes
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
        self.activeWorkers = activeWorkers
        self.resumeState = resumeState
    }
}

/// Terminal output descriptor returned after staging, remuxing, and writing the final `.mp4`.
public struct CuriumHLSDownloadResult: Sendable, Equatable {
    public let outputFileURL: URL
    public let totalBytes: Int64
    public let completedSegments: Int
    public let wasRemuxedToMP4: Bool

    public init(
        outputFileURL: URL,
        totalBytes: Int64,
        completedSegments: Int,
        wasRemuxedToMP4: Bool
    ) {
        self.outputFileURL = outputFileURL
        self.totalBytes = totalBytes
        self.completedSegments = completedSegments
        self.wasRemuxedToMP4 = wasRemuxedToMP4
    }
}

/// Structured errors thrown by `CuriumHLSTransferEngine`.
public enum CuriumHLSError: LocalizedError, Equatable, Sendable {
    case disallowedURLScheme(String)
    case blockedPrivateNetworkHost(String)
    case invalidPlaylist(String)
    case emptyPlaylist
    case drmUnsupported(method: String)
    case httpStatusError(statusCode: Int, resource: String)
    case invalidAESKeyLength(Int)
    case invalidIVLength(Int)
    case decryptionFailed(Int32)
    case byteRangeMismatch(expected: Int64, actual: Int64)
    case fileIOFailed(code: Int32, operation: String)

    public var errorDescription: String? {
        switch self {
        case .disallowedURLScheme(let scheme):
            return "Blocked disallowed URL scheme in HLS transfer (\(scheme))."
        case .blockedPrivateNetworkHost(let host):
            return "Blocked private or local network host in HLS transfer (\(host))."
        case .invalidPlaylist(let reason):
            return "Invalid HLS playlist: \(reason)"
        case .emptyPlaylist:
            return "HLS playlist contained zero playable media segments."
        case .drmUnsupported(let method):
            return "DRM-protected HLS stream (\(method)) cannot be downloaded."
        case .httpStatusError(let statusCode, let resource):
            return "HTTP \(statusCode) while fetching \(resource)."
        case .invalidAESKeyLength(let count):
            return "AES-128 key response had invalid length (\(count) bytes; expected 16)."
        case .invalidIVLength(let count):
            return "AES-128 IV had invalid length (\(count) bytes; expected 16)."
        case .decryptionFailed(let status):
            return "AES-128-CBC segment decryption failed (CCCrypt status \(status))."
        case .byteRangeMismatch(let expected, let actual):
            return "Server returned \(actual) bytes for a \(expected)-byte HLS byte-range request."
        case .fileIOFailed(let code, let operation):
            return "HLS staging file \(operation) failed (POSIX errno \(code))."
        }
    }
}

// MARK: - AIMD Adaptive Concurrency Controller

/// TCP/BBR-inspired Additive-Increase / Multiplicative-Decrease concurrency window controller.
/// Starts at `min(6, ceiling)`, grows by `+1` after every 6 consecutive clean segment fetches
/// up to `maxLimit` (`<= 20`), and halves (`min 2` when `maxLimit >= 2`) on `408`/`429`/`5xx`/network errors.
public actor AIMDConcurrencyGate {
    public private(set) var currentLimit: Int
    public let maxLimit: Int
    private var consecutiveCleanCount: Int = 0

    public init(initialLimit: Int, maxLimit: Int) {
        let clampedMax = max(1, min(maxLimit, 20))
        self.maxLimit = clampedMax
        self.currentLimit = max(1, min(initialLimit, clampedMax))
    }

    public func recordSuccess() {
        consecutiveCleanCount += 1
        if consecutiveCleanCount >= 6, currentLimit < maxLimit {
            currentLimit += 1
            consecutiveCleanCount = 0
        }
    }

    public func recordCongestion() {
        consecutiveCleanCount = 0
        let floorLimit = min(maxLimit, 2)
        currentLimit = max(floorLimit, currentLimit / 2)
    }
}

// MARK: - CuriumHLSTransferEngine

/// Pure-Swift concurrent HLS (`.m3u8`) transfer engine with:
/// - Preloaded `#EXTM3U` text support & master variant + `#EXT-X-MEDIA:TYPE=AUDIO` selection
/// - `#EXT-X-MAP` (fMP4 + `BYTERANGE` + encrypted init maps) & `#EXT-X-BYTERANGE` RFC 8216 support
/// - Hardware-accelerated `#EXT-X-KEY:METHOD=AES-128` decryption via `CommonCrypto` + deduplicated `AESKeyCache`
/// - Fast-fail on `SAMPLE-AES` / DRM methods and permanent HTTP `4xx` / DNS / TLS errors
/// - `#EXT-X-DISCONTINUITY` injected ad-pod stripping & disguised PNG/JPEG header MPEG-TS sanitization
/// - `AIMDConcurrencyGate` (`6..20` lanes) + bounded `32 MiB` out-of-order segment reorder buffer
/// - Segment-checkpointed Pause -> Resume (`O_RDWR` without `O_TRUNC` + `ftruncate` to clean segment boundary)
/// - Strict monotonic `completedSegments`, `receivedBytes`, and `estimatedTotalBytes` telemetry
/// - Automatic `.mp4` post-processing via `CuriumMediaMuxActor` / `CuriumNativeMP4Remuxer`
public struct CuriumHLSTransferEngine: Sendable {
    public struct ByteRangeSpec: Sendable, Equatable {
        public let offset: Int64
        public let length: Int64

        public init(offset: Int64, length: Int64) {
            self.offset = offset
            self.length = length
        }

        public var headerValue: String {
            "bytes=\(offset)-\(offset + length - 1)"
        }
    }

    public struct SelectedVariant: Sendable, Equatable {
        public let playlistURL: URL
        public let audioPlaylistURL: URL?
        public let bandwidth: Int64
        public let resolutionPixels: Int64
    }

    public struct SegmentItem: Sendable, Equatable {
        public let sequenceIndex: Int
        public let url: URL
        public let keyURL: URL?
        public let explicitIV: Data?
        public let mediaSequence: UInt64
        public let durationSeconds: Double
        public let byteRange: ByteRangeSpec?
        public let discontinuityGroup: Int
    }

    public struct ParsedMediaPlaylist: Sendable, Equatable {
        public let resolvedPlaylistURL: URL
        public let initializationMapURL: URL?
        public let initializationByteRange: ByteRangeSpec?
        public let initializationKeyURL: URL?
        public let initializationExplicitIV: Data?
        public let segments: [SegmentItem]
        public let strippedAdSegmentsCount: Int
        public let isFragmentedMP4: Bool
    }

    public static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"

    private static let maxPendingBufferBytes = 32 * 1024 * 1024
    private static let fmp4Extensions: Set<String> = ["m4s", "mp4", "m4v", "m4a", "cmfv", "cmfa"]

    private let muxActor: CuriumMediaMuxActor

    public init(muxActor: CuriumMediaMuxActor = .shared) {
        self.muxActor = muxActor
    }

    // MARK: - Primary Download & Checkpointed Resume Entry Point

    /// Downloads (or resumes from `resumeState`) an HLS playlist into `stagingDirectoryURL`
    /// (`video.part` + optional `audio.part`) and produces a verified playable `.mp4` at `destinationURL`.
    ///
    /// On pause/cancellation, cleanly `fsync`s all committed contiguous segments, emits a final
    /// `CuriumHLSProgressUpdate` carrying the exact `CuriumHLSResumeState`, leaves staging files intact,
    /// and throws `CancellationError`.
    public func download(
        manifestURL: URL,
        audioPlaylistURL explicitAudioPlaylistURL: URL? = nil,
        stagingDirectoryURL: URL,
        destinationURL: URL,
        requestConfig: CuriumHLSRequestConfig = .init(),
        concurrency: Int = 8,
        preloadedManifestText: String? = nil,
        resumeState initialResumeState: CuriumHLSResumeState? = nil,
        onProgress: @escaping @Sendable (CuriumHLSProgressUpdate) -> Void
    ) async throws -> CuriumHLSDownloadResult {
        let originatingURL = requestConfig.originatingURL ?? manifestURL
        try Self.validateTargetURL(manifestURL, originatingURL: requestConfig.originatingURL)
        if let explicitAudioPlaylistURL {
            try Self.validateTargetURL(explicitAudioPlaylistURL, originatingURL: originatingURL)
        }

        let initialSeed = initialResumeState ?? CuriumHLSResumeState()
        onProgress(CuriumHLSProgressUpdate(
            phase: .fetchingPlaylist,
            receivedBytes: max(0, initialSeed.contiguousByteOffset) + max(0, initialSeed.audioContiguousByteOffset),
            estimatedTotalBytes: nil,
            completedSegments: max(0, initialSeed.completedSegments) + max(0, initialSeed.audioCompletedSegments),
            totalSegments: max(0, initialSeed.totalSegments ?? 0),
            activeWorkers: 0,
            resumeState: initialSeed
        ))

        let sessionOwnership = Self.acquireSession(from: requestConfig)
        defer {
            if sessionOwnership.ownsSession {
                sessionOwnership.session.finishTasksAndInvalidate()
            }
        }
        let session = sessionOwnership.session
        let cookieCache = HLSCookieCache(resolver: requestConfig.cookieResolver)
        let baseHeaders = Self.normalizedBrowserHeaders(from: requestConfig, manifestURL: manifestURL)

        // 1. Resolve video media playlist (and auto-detected audio rendition if master playlist).
        let resolvedVideo = try await resolveVideoAndAudioPlaylists(
            from: manifestURL,
            explicitAudioPlaylistURL: explicitAudioPlaylistURL,
            headers: baseHeaders,
            originatingURL: originatingURL,
            preloadedManifestText: preloadedManifestText,
            session: session,
            cookieCache: cookieCache
        )
        let videoPlaylist = resolvedVideo.videoPlaylist
        guard !videoPlaylist.segments.isEmpty else {
            throw CuriumHLSError.emptyPlaylist
        }

        // 2. If separate audio rendition is present, resolve it upfront so total segment count is exact.
        let audioPlaylist: ParsedMediaPlaylist?
        if let audioURL = resolvedVideo.audioPlaylistURL {
            let audioHeaders = HLSRedirectSanitizer.stripCrossOriginAuthHeaders(
                from: baseHeaders,
                sourceURL: manifestURL,
                destinationURL: audioURL
            )
            let fetchedAudio = try await fetchMediaPlaylist(
                from: audioURL,
                headers: audioHeaders,
                originatingURL: originatingURL,
                session: session,
                cookieCache: cookieCache
            )
            guard !fetchedAudio.segments.isEmpty else {
                throw CuriumHLSError.emptyPlaylist
            }
            audioPlaylist = fetchedAudio
        } else {
            audioPlaylist = nil
        }

        let totalVideoSegments = videoPlaylist.segments.count
        let totalAudioSegments = audioPlaylist?.segments.count ?? 0
        let combinedTotalSegments = totalVideoSegments + totalAudioSegments

        try FileManager.default.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        let videoPartURL = stagingDirectoryURL.appending(path: "video.part", directoryHint: .notDirectory)
        let audioPartURL = stagingDirectoryURL.appending(path: "audio.part", directoryHint: .notDirectory)

        // Determine validated resume checkpoints against actual staged files on disk.
        let validatedVideoResume = Self.validateResumeOffset(
            fileURL: videoPartURL,
            completedSegments: initialResumeState?.completedSegments ?? 0,
            contiguousByteOffset: initialResumeState?.contiguousByteOffset ?? 0,
            totalTrackSegments: totalVideoSegments
        )
        let validatedAudioResume: (completedSegments: Int, byteOffset: Int64) = {
            guard audioPlaylist != nil else { return (0, 0) }
            return Self.validateResumeOffset(
                fileURL: audioPartURL,
                completedSegments: initialResumeState?.audioCompletedSegments ?? 0,
                contiguousByteOffset: initialResumeState?.audioContiguousByteOffset ?? 0,
                totalTrackSegments: totalAudioSegments
            )
        }()

        let telemetry = TransferTelemetryTracker(
            initialResumeState: CuriumHLSResumeState(
                completedSegments: validatedVideoResume.completedSegments,
                totalSegments: combinedTotalSegments,
                contiguousByteOffset: validatedVideoResume.byteOffset,
                audioCompletedSegments: validatedAudioResume.completedSegments,
                audioContiguousByteOffset: validatedAudioResume.byteOffset,
                isFMP4: videoPlaylist.isFragmentedMP4
            ),
            totalCombinedSegments: combinedTotalSegments
        )

        // 3. Download (or resume) primary video track into `video.part`.
        let videoOriginURL = videoPlaylist.resolvedPlaylistURL
        let videoHeaders = HLSRedirectSanitizer.stripCrossOriginAuthHeaders(
            from: baseHeaders,
            sourceURL: manifestURL,
            destinationURL: videoOriginURL
        )

        let videoResult = try await downloadSingleTrack(
            playlist: videoPlaylist,
            partFileURL: videoPartURL,
            headers: videoHeaders,
            originatingURL: originatingURL,
            session: session,
            cookieCache: cookieCache,
            concurrency: concurrency,
            resumeCompletedSegments: validatedVideoResume.completedSegments,
            resumeContiguousOffset: validatedVideoResume.byteOffset,
            emitTrackProgress: { trackDone, trackBytes, activeWorkers in
                let update = telemetry.updateVideo(
                    completedSegments: trackDone,
                    contiguousByteOffset: trackBytes,
                    activeWorkers: activeWorkers
                )
                onProgress(update)
            }
        )
        _ = telemetry.updateVideo(
            completedSegments: videoResult.completedSegments,
            contiguousByteOffset: videoResult.writtenBytes,
            activeWorkers: 0
        )

        // 4. Download (or resume) separate audio track into `audio.part`, if present.
        if let audioPlaylist {
            let audioOriginURL = audioPlaylist.resolvedPlaylistURL
            let audioHeaders = HLSRedirectSanitizer.stripCrossOriginAuthHeaders(
                from: baseHeaders,
                sourceURL: manifestURL,
                destinationURL: audioOriginURL
            )

            let audioResult = try await downloadSingleTrack(
                playlist: audioPlaylist,
                partFileURL: audioPartURL,
                headers: audioHeaders,
                originatingURL: originatingURL,
                session: session,
                cookieCache: cookieCache,
                concurrency: concurrency,
                resumeCompletedSegments: validatedAudioResume.completedSegments,
                resumeContiguousOffset: validatedAudioResume.byteOffset,
                emitTrackProgress: { trackDone, trackBytes, activeWorkers in
                    let update = telemetry.updateAudio(
                        completedSegments: trackDone,
                        contiguousByteOffset: trackBytes,
                        activeWorkers: activeWorkers
                    )
                    onProgress(update)
                }
            )
            _ = telemetry.updateAudio(
                completedSegments: audioResult.completedSegments,
                contiguousByteOffset: audioResult.writtenBytes,
                activeWorkers: 0
            )
        }

        try Task.checkCancellation()

        // 5. Emit `.remuxing` phase and produce final playable `.mp4` at `destinationURL`.
        let remuxUpdate = telemetry.makeRemuxingUpdate()
        let stagedBytes = remuxUpdate.receivedBytes
        onProgress(remuxUpdate)

        let wasRemuxedToMP4: Bool
        if audioPlaylist != nil {
            try await muxActor.remux(
                videoURL: videoPartURL,
                audioURL: audioPartURL,
                destinationURL: destinationURL
            )
            try? FileManager.default.removeItem(at: videoPartURL)
            try? FileManager.default.removeItem(at: audioPartURL)
            wasRemuxedToMP4 = true
        } else {
            wasRemuxedToMP4 = try await muxActor.remuxSingleStreamToMP4(
                sourceURL: videoPartURL,
                destinationURL: destinationURL
            )
            // If `remuxSingleStreamToMP4` remuxed TS -> MP4, clean up `video.part`.
            if FileManager.default.fileExists(atPath: videoPartURL.path),
               videoPartURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: videoPartURL)
            }
        }

        let finalAttrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let finalBytes = (finalAttrs?[.size] as? NSNumber)?.int64Value ?? stagedBytes

        return CuriumHLSDownloadResult(
            outputFileURL: destinationURL,
            totalBytes: finalBytes,
            completedSegments: combinedTotalSegments,
            wasRemuxedToMP4: wasRemuxedToMP4
        )
    }

    // MARK: - Track Download with Segment-Checkpointed Pause/Resume

    private struct TrackDownloadResult {
        let completedSegments: Int
        let writtenBytes: Int64
    }

    private func downloadSingleTrack(
        playlist: ParsedMediaPlaylist,
        partFileURL: URL,
        headers: [String: String],
        originatingURL: URL,
        session: URLSession,
        cookieCache: HLSCookieCache,
        concurrency: Int,
        resumeCompletedSegments: Int,
        resumeContiguousOffset: Int64,
        emitTrackProgress: (Int, Int64, Int) -> Void
    ) async throws -> TrackDownloadResult {
        let totalCount = playlist.segments.count
        let isResuming = resumeCompletedSegments > 0 && resumeContiguousOffset > 0

        let writer = try StagingPartFile(
            fileURL: partFileURL,
            truncateExisting: !isResuming
        )
        defer { try? writer.close() }

        var writeCursor: Int64 = 0
        if isResuming {
            try writer.truncate(to: resumeContiguousOffset)
            writeCursor = resumeContiguousOffset
        } else if let initMapURL = playlist.initializationMapURL {
            try Self.validateTargetURL(initMapURL, originatingURL: originatingURL)
            let initHeaders = HLSRedirectSanitizer.stripCrossOriginAuthHeaders(
                from: headers,
                sourceURL: playlist.resolvedPlaylistURL,
                destinationURL: initMapURL
            )
            let rawInitBytes = try await fetchWithRetry(
                url: initMapURL,
                headers: initHeaders,
                originatingURL: originatingURL,
                session: session,
                cookieCache: cookieCache,
                byteRange: playlist.initializationByteRange,
                aimd: nil,
                maxAttempts: 3,
                requestTimeout: 15
            )
            let initBytes: Data
            if let initKeyURL = playlist.initializationKeyURL {
                let initKeyCache = AESKeyCache(
                    session: session,
                    manifestOriginURL: playlist.resolvedPlaylistURL,
                    originatingURL: originatingURL,
                    headers: headers,
                    cookieCache: cookieCache
                )
                let keyData = try await initKeyCache.key(for: initKeyURL)
                let iv = Self.resolveIV(
                    explicitIV: playlist.initializationExplicitIV,
                    mediaSequence: playlist.segments.first?.mediaSequence ?? 0
                )
                initBytes = try Self.decryptAES128CBC(ciphertext: rawInitBytes, key: keyData, iv: iv)
            } else {
                initBytes = rawInitBytes
            }
            try writer.write(initBytes, at: 0)
            writeCursor = Int64(initBytes.count)
        }

        // Fast-path when every segment of this track was already checkpointed on disk.
        if resumeCompletedSegments >= totalCount {
            try writer.synchronize()
            emitTrackProgress(totalCount, writeCursor, 0)
            return TrackDownloadResult(completedSegments: totalCount, writtenBytes: writeCursor)
        }

        let keyCache = AESKeyCache(
            session: session,
            manifestOriginURL: playlist.resolvedPlaylistURL,
            originatingURL: originatingURL,
            headers: headers,
            cookieCache: cookieCache
        )

        let ceiling = max(1, min(concurrency, 20))
        let initialWindow = min(6, ceiling)
        let aimd = AIMDConcurrencyGate(initialLimit: initialWindow, maxLimit: ceiling)
        let isFMP4 = playlist.isFragmentedMP4
        let playlistOriginURL = playlist.resolvedPlaylistURL

        var nextToSchedule = resumeCompletedSegments
        var nextToWrite = resumeCompletedSegments
        var lastEmittedCompleted = resumeCompletedSegments
        var inFlight = 0
        var pendingBuffer: [Int: Data] = [:]
        var pendingBufferBytes = 0
        var lastProgressEmit = ContinuousClock.now - .seconds(1)

        func flushContiguousPending() throws {
            while let readyData = pendingBuffer.removeValue(forKey: nextToWrite) {
                pendingBufferBytes = max(0, pendingBufferBytes - readyData.count)
                try writer.write(readyData, at: writeCursor)
                writeCursor += Int64(readyData.count)
                nextToWrite += 1
            }
        }

        do {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                let startBudget = await aimd.currentLimit
                while nextToSchedule < totalCount, inFlight < startBudget {
                    try Task.checkCancellation()
                    let seg = playlist.segments[nextToSchedule]
                    nextToSchedule += 1
                    inFlight += 1
                    group.addTask {
                        let payload = try await fetchDecryptAndSanitizeSegment(
                            seg,
                            manifestOriginURL: playlistOriginURL,
                            originatingURL: originatingURL,
                            headers: headers,
                            session: session,
                            cookieCache: cookieCache,
                            isFragmentedMP4: isFMP4,
                            keyCache: keyCache,
                            aimd: aimd
                        )
                        return (seg.sequenceIndex, payload)
                    }
                }

                // Emit immediate live worker count + checkpointed state before first segment returns.
                emitTrackProgress(nextToWrite, writeCursor, inFlight)

                while let (seqIdx, segmentBytes) = try await group.next() {
                    inFlight -= 1
                    pendingBuffer[seqIdx] = segmentBytes
                    pendingBufferBytes += segmentBytes.count

                    try flushContiguousPending()

                    if Task.isCancelled {
                        group.cancelAll()
                        throw CancellationError()
                    }

                    let targetWindow = await aimd.currentLimit
                    while nextToSchedule < totalCount,
                          inFlight < targetWindow,
                          pendingBuffer.count < max(8, targetWindow * 2),
                          (pendingBufferBytes < Self.maxPendingBufferBytes || inFlight == 0) {
                        if Task.isCancelled {
                            group.cancelAll()
                            throw CancellationError()
                        }
                        let seg = playlist.segments[nextToSchedule]
                        nextToSchedule += 1
                        inFlight += 1
                        group.addTask {
                            let payload = try await fetchDecryptAndSanitizeSegment(
                                seg,
                                manifestOriginURL: playlistOriginURL,
                                originatingURL: originatingURL,
                                headers: headers,
                                session: session,
                                cookieCache: cookieCache,
                                isFragmentedMP4: isFMP4,
                                keyCache: keyCache,
                                aimd: aimd
                            )
                            return (seg.sequenceIndex, payload)
                        }
                    }

                    let now = ContinuousClock.now
                    if nextToWrite > lastEmittedCompleted || now - lastProgressEmit >= .milliseconds(150) || nextToWrite == totalCount {
                        lastProgressEmit = now
                        lastEmittedCompleted = nextToWrite
                        emitTrackProgress(nextToWrite, writeCursor, inFlight)
                        if Task.isCancelled {
                            group.cancelAll()
                            throw CancellationError()
                        }
                    }
                }
            }
        } catch {
            // Drain any already-received contiguous segments, fsync the staging file, and emit
            // the durable checkpoint WITHOUT deleting `partFileURL`.
            try? flushContiguousPending()
            try? writer.synchronize()
            emitTrackProgress(nextToWrite, writeCursor, 0)

            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if let urlErr = error as? URLError, urlErr.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }

        try flushContiguousPending()
        try writer.synchronize()
        emitTrackProgress(nextToWrite, writeCursor, 0)
        return TrackDownloadResult(completedSegments: nextToWrite, writtenBytes: writeCursor)
    }

    // MARK: - Playlist Resolution, Discontinuity Ad Filtering & Parsing

    public func resolveMediaPlaylist(
        from url: URL,
        requestConfig: CuriumHLSRequestConfig = .init(),
        preloadedManifestText: String? = nil
    ) async throws -> ParsedMediaPlaylist {
        let originatingURL = requestConfig.originatingURL ?? url
        try Self.validateTargetURL(url, originatingURL: requestConfig.originatingURL)

        let sessionOwnership = Self.acquireSession(from: requestConfig)
        defer {
            if sessionOwnership.ownsSession {
                sessionOwnership.session.finishTasksAndInvalidate()
            }
        }
        let cookieCache = HLSCookieCache(resolver: requestConfig.cookieResolver)
        let headers = Self.normalizedBrowserHeaders(from: requestConfig, manifestURL: url)

        let resolved = try await resolveVideoAndAudioPlaylists(
            from: url,
            explicitAudioPlaylistURL: nil,
            headers: headers,
            originatingURL: originatingURL,
            preloadedManifestText: preloadedManifestText,
            session: sessionOwnership.session,
            cookieCache: cookieCache
        )
        return resolved.videoPlaylist
    }

    private struct ResolvedPlaylists {
        let videoPlaylist: ParsedMediaPlaylist
        let audioPlaylistURL: URL?
    }

    private func resolveVideoAndAudioPlaylists(
        from url: URL,
        explicitAudioPlaylistURL: URL?,
        headers: [String: String],
        originatingURL: URL,
        preloadedManifestText: String?,
        session: URLSession,
        cookieCache: HLSCookieCache
    ) async throws -> ResolvedPlaylists {
        let text: String
        let resolvedURL: URL

        if let rawPreloaded = preloadedManifestText {
            let trimmed = Self.stripUTF8BOM(rawPreloaded).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXTM3U") {
                text = trimmed
                resolvedURL = url
            } else {
                let fetched = try await fetchPlaylistText(
                    url: url,
                    headers: headers,
                    originatingURL: originatingURL,
                    session: session,
                    cookieCache: cookieCache
                )
                text = fetched.text
                resolvedURL = fetched.finalURL
            }
        } else {
            let fetched = try await fetchPlaylistText(
                url: url,
                headers: headers,
                originatingURL: originatingURL,
                session: session,
                cookieCache: cookieCache
            )
            text = fetched.text
            resolvedURL = fetched.finalURL
        }

        let effectiveHeaders = HLSRedirectSanitizer.stripCrossOriginAuthHeaders(
            from: headers,
            sourceURL: url,
            destinationURL: resolvedURL
        )

        if let selectedVariant = try Self.selectBestVariant(
            manifestText: text,
            baseURL: resolvedURL,
            originatingURL: originatingURL
        ) {
            let subHeaders = HLSRedirectSanitizer.stripCrossOriginAuthHeaders(
                from: effectiveHeaders,
                sourceURL: resolvedURL,
                destinationURL: selectedVariant.playlistURL
            )
            let mediaPlaylist = try await fetchMediaPlaylist(
                from: selectedVariant.playlistURL,
                headers: subHeaders,
                originatingURL: originatingURL,
                session: session,
                cookieCache: cookieCache
            )
            let resolvedAudioURL = explicitAudioPlaylistURL ?? selectedVariant.audioPlaylistURL
            if let resolvedAudioURL {
                try Self.validateTargetURL(resolvedAudioURL, originatingURL: originatingURL)
            }
            return ResolvedPlaylists(videoPlaylist: mediaPlaylist, audioPlaylistURL: resolvedAudioURL)
        }

        let mediaPlaylist = try Self.parseMediaPlaylist(
            manifestText: text,
            baseURL: resolvedURL,
            originatingURL: originatingURL
        )
        return ResolvedPlaylists(videoPlaylist: mediaPlaylist, audioPlaylistURL: explicitAudioPlaylistURL)
    }

    private func fetchMediaPlaylist(
        from url: URL,
        headers: [String: String],
        originatingURL: URL,
        session: URLSession,
        cookieCache: HLSCookieCache
    ) async throws -> ParsedMediaPlaylist {
        let fetched = try await fetchPlaylistText(
            url: url,
            headers: headers,
            originatingURL: originatingURL,
            session: session,
            cookieCache: cookieCache
        )
        return try Self.parseMediaPlaylist(
            manifestText: fetched.text,
            baseURL: fetched.finalURL,
            originatingURL: originatingURL
        )
    }

    private func fetchPlaylistText(
        url: URL,
        headers: [String: String],
        originatingURL: URL,
        session: URLSession,
        cookieCache: HLSCookieCache
    ) async throws -> (text: String, finalURL: URL) {
        try Self.validateTargetURL(url, originatingURL: originatingURL)
        // Manifests are tiny text files: fail fast (2 attempts x 12 s) instead of hanging on a dead CDN.
        let fetched = try await fetchWithRetryWithFinalURL(
            url: url,
            headers: headers,
            originatingURL: originatingURL,
            session: session,
            cookieCache: cookieCache,
            byteRange: nil,
            aimd: nil,
            maxAttempts: 2,
            requestTimeout: 12
        )
        guard let decoded = String(data: fetched.data, encoding: .utf8)
            ?? String(data: fetched.data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }
        return (Self.stripUTF8BOM(decoded), fetched.finalURL)
    }

    /// Selects the highest-bandwidth/highest-resolution variant from a Master Playlist, also resolving
    /// its associated default `#EXT-X-MEDIA:TYPE=AUDIO` rendition URI when present.
    public static func selectBestVariant(
        manifestText: String,
        baseURL: URL,
        originatingURL: URL? = nil
    ) throws -> SelectedVariant? {
        let cleanedText = stripUTF8BOM(manifestText)
        guard cleanedText.contains("#EXT-X-STREAM-INF:") else { return nil }

        let effectiveOrigin = originatingURL ?? baseURL
        let lines = cleanedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Pass 1: Collect #EXT-X-MEDIA audio renditions and reject DRM #EXT-X-SESSION-KEY upfront.
        struct AudioRendition {
            let uri: URL?
            let isDefault: Bool
            let isAutoSelect: Bool
        }
        var audioGroups: [String: AudioRendition] = [:]

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-SESSION-KEY:".count)))
                let method = (attrs["METHOD"] ?? "NONE").uppercased()
                if method != "NONE" && method != "AES-128" {
                    throw CuriumHLSError.drmUnsupported(method: method)
                }
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard attrs["TYPE"]?.uppercased() == "AUDIO",
                      let groupID = attrs["GROUP-ID"], !groupID.isEmpty else {
                    continue
                }
                let resolvedURI: URL?
                if let rawURI = attrs["URI"], !rawURI.isEmpty {
                    let candidate = try resolveAndValidateURL(rawURI, relativeTo: baseURL, originatingURL: effectiveOrigin)
                    resolvedURI = candidate
                } else {
                    resolvedURI = nil
                }
                let isDefault = attrs["DEFAULT"]?.uppercased() == "YES"
                let isAutoSelect = attrs["AUTOSELECT"]?.uppercased() == "YES"
                let rendition = AudioRendition(uri: resolvedURI, isDefault: isDefault, isAutoSelect: isAutoSelect)
                if let existing = audioGroups[groupID] {
                    let replaces = (!existing.isDefault && rendition.isDefault)
                        || (!existing.isDefault && !existing.isAutoSelect && rendition.isAutoSelect)
                    if replaces {
                        audioGroups[groupID] = rendition
                    }
                } else {
                    audioGroups[groupID] = rendition
                }
            }
        }

        // Pass 2: Pick best variant by bandwidth / resolution, preferring universally playable AAC (`mp4a`).
        var best: (variant: SelectedVariant, score: Int64, codecRank: Int)?
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                let bw = Int64(attrs["BANDWIDTH"] ?? attrs["AVERAGE-BANDWIDTH"] ?? "0") ?? 0
                let resPixels: Int64 = {
                    guard let res = attrs["RESOLUTION"] else { return 0 }
                    let parts = res.lowercased().split(separator: "x")
                    if parts.count == 2, let w = Int64(parts[0]), let h = Int64(parts[1]), w > 0, h > 0 {
                        return w * h
                    }
                    return 0
                }()
                let score = bw > 0 ? bw : resPixels
                let codecRank = audioCodecCompatibilityRank(attrs["CODECS"])
                let audioGroupID = attrs["AUDIO"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let audioURI = audioGroupID.flatMap { $0.isEmpty ? nil : audioGroups[$0]?.uri }

                var nextIdx = idx + 1
                while nextIdx < lines.count, (lines[nextIdx].isEmpty || lines[nextIdx].hasPrefix("#")) {
                    nextIdx += 1
                }
                if nextIdx < lines.count {
                    let candidateURL = try resolveAndValidateURL(
                        lines[nextIdx],
                        relativeTo: baseURL,
                        originatingURL: effectiveOrigin
                    )
                    let candidate = SelectedVariant(
                        playlistURL: candidateURL,
                        audioPlaylistURL: audioURI,
                        bandwidth: bw,
                        resolutionPixels: resPixels
                    )
                    if let currentBest = best {
                        let isBetter: Bool
                        if candidateURL == currentBest.variant.playlistURL {
                            isBetter = codecRank > currentBest.codecRank
                                || (codecRank == currentBest.codecRank && score >= currentBest.score)
                        } else {
                            isBetter = score > currentBest.score
                                || (score == currentBest.score && resPixels > currentBest.variant.resolutionPixels)
                                || (score == currentBest.score && resPixels == currentBest.variant.resolutionPixels && codecRank >= currentBest.codecRank)
                        }
                        if isBetter {
                            best = (candidate, score, codecRank)
                        }
                    } else {
                        best = (candidate, score, codecRank)
                    }
                }
                idx = nextIdx + 1
            } else {
                idx += 1
            }
        }
        return best?.variant
    }

    /// Parses an HLS media playlist, validates URL safety, fast-fails on unsupported DRM (`SAMPLE-AES`, etc.),
    /// resolves `#EXT-X-MAP` + `#EXT-X-BYTERANGE`, and strips injected `#EXT-X-DISCONTINUITY` ad pods.
    public static func parseMediaPlaylist(
        manifestText: String,
        baseURL: URL,
        originatingURL: URL? = nil
    ) throws -> ParsedMediaPlaylist {
        let effectiveOrigin = originatingURL ?? baseURL
        let cleaned = stripUTF8BOM(manifestText)
        let lines = cleaned
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let firstNonEmpty = lines.first(where: { !$0.isEmpty }),
              firstNonEmpty == "#EXTM3U" else {
            throw CuriumHLSError.invalidPlaylist("Missing #EXTM3U header.")
        }

        var initMapURL: URL?
        var initByteRange: ByteRangeSpec?
        var initKeyURL: URL?
        var initExplicitIV: Data?
        var currentKeyURL: URL?
        var currentExplicitIV: Data?
        var mediaSequenceBase: UInt64 = 0
        var discontinuityGroup = 0
        var pendingDuration: Double = 4.0
        var pendingByteRange: ByteRangeSpec?
        var lastByteRangeEndByURL: [URL: Int64] = [:]
        var hasFMP4Extension = false
        var rawSegments: [SegmentItem] = []

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let val = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)
                mediaSequenceBase = UInt64(val) ?? 0
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                discontinuityGroup += 1
            } else if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst("#EXTINF:".count)
                let durToken = body.split(separator: ",").first.map(String.init) ?? ""
                pendingDuration = Double(durToken.trimmingCharacters(in: .whitespaces)) ?? 4.0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let specStr = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                pendingByteRange = parseByteRange(specStr, defaultOffset: nil)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attrs["URI"], !uri.isEmpty {
                    let resolved = try resolveAndValidateURL(uri, relativeTo: baseURL, originatingURL: effectiveOrigin)
                    initMapURL = resolved
                    if let br = attrs["BYTERANGE"] {
                        // RFC 8216 §4.3.2.5: if @o is omitted in #EXT-X-MAP, offset defaults to 0.
                        initByteRange = parseByteRange(br, defaultOffset: 0)
                    } else {
                        initByteRange = nil
                    }
                    initKeyURL = currentKeyURL
                    initExplicitIV = currentExplicitIV
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = (attrs["METHOD"] ?? "NONE").uppercased()
                switch method {
                case "NONE":
                    currentKeyURL = nil
                    currentExplicitIV = nil
                case "AES-128":
                    guard let uri = attrs["URI"], !uri.isEmpty else {
                        throw CuriumHLSError.invalidPlaylist("AES-128 #EXT-X-KEY missing URI attribute.")
                    }
                    let resolved = try resolveAndValidateURL(uri, relativeTo: baseURL, originatingURL: effectiveOrigin)
                    currentKeyURL = resolved
                    if let rawIV = attrs["IV"], !rawIV.isEmpty {
                        guard let parsedIV = parseHexIV(rawIV) else {
                            throw CuriumHLSError.invalidPlaylist("Malformed AES-128 IV: \(rawIV)")
                        }
                        currentExplicitIV = parsedIV
                    } else {
                        currentExplicitIV = nil
                    }
                default:
                    // Fast-fail with clear error on SAMPLE-AES / SAMPLE-AES-CTR / FairPlay DRM.
                    throw CuriumHLSError.drmUnsupported(method: method)
                }
            } else if !line.hasPrefix("#") {
                let segURL = try resolveAndValidateURL(line, relativeTo: baseURL, originatingURL: effectiveOrigin)
                if fmp4Extensions.contains(segURL.pathExtension.lowercased()) {
                    hasFMP4Extension = true
                }

                var finalRange = pendingByteRange
                if let pr = pendingByteRange {
                    if pr.offset < 0 {
                        let inferredOffset = lastByteRangeEndByURL[segURL] ?? 0
                        finalRange = ByteRangeSpec(offset: inferredOffset, length: pr.length)
                        lastByteRangeEndByURL[segURL] = inferredOffset + pr.length
                    } else {
                        lastByteRangeEndByURL[segURL] = pr.offset + pr.length
                    }
                }

                let rawIdx = rawSegments.count
                rawSegments.append(SegmentItem(
                    sequenceIndex: rawIdx,
                    url: segURL,
                    keyURL: currentKeyURL,
                    explicitIV: currentExplicitIV,
                    mediaSequence: mediaSequenceBase + UInt64(rawIdx),
                    durationSeconds: pendingDuration,
                    byteRange: finalRange,
                    discontinuityGroup: discontinuityGroup
                ))
                pendingByteRange = nil
                pendingDuration = 4.0
            }
        }

        let (cleanSegments, strippedCount) = filterInjectedAdDiscontinuities(rawSegments)
        return ParsedMediaPlaylist(
            resolvedPlaylistURL: baseURL,
            initializationMapURL: initMapURL,
            initializationByteRange: initByteRange,
            initializationKeyURL: initKeyURL,
            initializationExplicitIV: initExplicitIV,
            segments: cleanSegments,
            strippedAdSegmentsCount: strippedCount,
            isFragmentedMP4: initMapURL != nil || hasFMP4Extension
        )
    }

    /// Detects and removes anomalous injected `#EXT-X-DISCONTINUITY` ad pods whose CDN origin/directory
    /// diverges from the dominant program stream while preserving legitimate multi-part program segments.
    public static func filterInjectedAdDiscontinuities(_ segments: [SegmentItem]) -> ([SegmentItem], Int) {
        guard segments.count >= 6 else { return (segments, 0) }
        let groups = Dictionary(grouping: segments, by: \.discontinuityGroup)
        guard groups.count > 1 else { return (segments, 0) }

        func originSignature(for url: URL) -> String {
            let host = (url.host() ?? "").lowercased()
            let dir = url.deletingLastPathComponent().path.lowercased()
            return "\(host)\(dir)"
        }

        var durationBySignature: [String: Double] = [:]
        for seg in segments {
            durationBySignature[originSignature(for: seg.url), default: 0] += max(0.5, seg.durationSeconds)
        }
        guard let dominantSignature = durationBySignature.max(by: { $0.value < $1.value })?.key else {
            return (segments, 0)
        }

        var kept: [SegmentItem] = []
        kept.reserveCapacity(segments.count)
        var stripped = 0

        for groupID in groups.keys.sorted() {
            guard let cluster = groups[groupID], let first = cluster.first else { continue }
            let sig = originSignature(for: first.url)
            let clusterDuration = cluster.reduce(0.0) { $0 + $1.durationSeconds }
            let isMinority = cluster.count <= 18
                && clusterDuration < 65.0
                && Double(cluster.count) < Double(segments.count) * 0.30

            if sig != dominantSignature && isMinority {
                stripped += cluster.count
                continue
            }
            for item in cluster {
                kept.append(SegmentItem(
                    sequenceIndex: kept.count,
                    url: item.url,
                    keyURL: item.keyURL,
                    explicitIV: item.explicitIV,
                    mediaSequence: item.mediaSequence,
                    durationSeconds: item.durationSeconds,
                    byteRange: item.byteRange,
                    discontinuityGroup: item.discontinuityGroup
                ))
            }
        }

        return kept.isEmpty ? (segments, 0) : (kept, stripped)
    }

    // MARK: - Anti-Poisoning Payload Sanitizer (Fake PNG/JPEG/BMP Header Stripping)

    /// Strips disguised fake PNG/JPEG/BMP headers prepended to MPEG-TS segments by scanning
    /// up to 32 KiB for three consecutive 188-byte `0x47` sync markers (`p < 6e-8` false-positive rate).
    public static func sanitizeMPEGTSPayload(_ data: Data) -> Data {
        let count = data.count
        guard count >= 188 else { return data }

        return data.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return data }

            // Fast O(1) path for clean MPEG-TS segments.
            if base[0] == 0x47, (count <= 376 || (base[188] == 0x47 && base[376] == 0x47)) {
                return data
            }

            let maxScan = min(count - 377, 32_768)
            if maxScan >= 1 {
                var offset = 1
                while offset <= maxScan {
                    if base[offset] == 0x47,
                       base[offset + 188] == 0x47,
                       base[offset + 376] == 0x47 {
                        return data.subdata(in: offset..<count)
                    }
                    offset += 1
                }
            }
            return data
        }
    }

    // MARK: - AES-128-CBC Decryption

    /// Resolves the 16-byte AES-128-CBC IV per RFC 8216 §5.2: uses `explicitIV` when 16 bytes,
    /// otherwise encodes `mediaSequence` as a big-endian 128-bit unsigned integer.
    public static func resolveIV(explicitIV: Data?, mediaSequence: UInt64) -> Data {
        if let explicitIV, explicitIV.count == kCCBlockSizeAES128 {
            return explicitIV
        }
        var bigEndianSeq = mediaSequence.bigEndian
        var synthesized = Data(repeating: 0, count: 8)
        withUnsafeBytes(of: &bigEndianSeq) { synthesized.append(contentsOf: $0) }
        return synthesized
    }

    /// Decrypts AES-128-CBC PKCS#7-padded segment bytes using native hardware-accelerated `CommonCrypto`.
    public static func decryptAES128CBC(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw CuriumHLSError.invalidAESKeyLength(key.count)
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw CuriumHLSError.invalidIVLength(iv.count)
        }
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw CuriumHLSError.decryptionFailed(Int32(kCCAlignmentError))
        }

        let capacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var movedBytes: size_t = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuf in
            ciphertext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress,
                            key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress,
                            ciphertext.count,
                            outBuf.baseAddress,
                            capacity,
                            &movedBytes
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw CuriumHLSError.decryptionFailed(status)
        }
        output.count = movedBytes
        return output
    }

    // MARK: - Segment Fetch & Retry

    private func fetchDecryptAndSanitizeSegment(
        _ segment: SegmentItem,
        manifestOriginURL: URL,
        originatingURL: URL,
        headers: [String: String],
        session: URLSession,
        cookieCache: HLSCookieCache,
        isFragmentedMP4: Bool,
        keyCache: AESKeyCache,
        aimd: AIMDConcurrencyGate
    ) async throws -> Data {
        try Self.validateTargetURL(segment.url, originatingURL: originatingURL)
        let segHeaders = HLSRedirectSanitizer.stripCrossOriginAuthHeaders(
            from: headers,
            sourceURL: manifestOriginURL,
            destinationURL: segment.url
        )
        let rawBytes = try await fetchWithRetry(
            url: segment.url,
            headers: segHeaders,
            originatingURL: originatingURL,
            session: session,
            cookieCache: cookieCache,
            byteRange: segment.byteRange,
            aimd: aimd
        )

        let decrypted: Data
        if let keyURL = segment.keyURL {
            let keyData = try await keyCache.key(for: keyURL)
            let ivData = Self.resolveIV(explicitIV: segment.explicitIV, mediaSequence: segment.mediaSequence)
            decrypted = try Self.decryptAES128CBC(ciphertext: rawBytes, key: keyData, iv: ivData)
        } else {
            decrypted = rawBytes
        }

        return isFragmentedMP4 ? decrypted : Self.sanitizeMPEGTSPayload(decrypted)
    }

    private struct NonRetryableError: Error {
        let underlying: Error
    }

    private struct FetchedPayload {
        let data: Data
        let finalURL: URL
    }

    private static func isFatalTransportError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed, .unsupportedURL, .badURL,
             .noPermissionsToReadFile,
             .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected:
            return true
        default:
            return false
        }
    }

    private func fetchWithRetry(
        url: URL,
        headers: [String: String],
        originatingURL: URL,
        session: URLSession,
        cookieCache: HLSCookieCache,
        byteRange: ByteRangeSpec?,
        aimd: AIMDConcurrencyGate?,
        maxAttempts: Int = 5,
        requestTimeout: TimeInterval = 30
    ) async throws -> Data {
        try await fetchWithRetryWithFinalURL(
            url: url,
            headers: headers,
            originatingURL: originatingURL,
            session: session,
            cookieCache: cookieCache,
            byteRange: byteRange,
            aimd: aimd,
            maxAttempts: maxAttempts,
            requestTimeout: requestTimeout
        ).data
    }

    private func fetchWithRetryWithFinalURL(
        url: URL,
        headers: [String: String],
        originatingURL: URL,
        session: URLSession,
        cookieCache: HLSCookieCache,
        byteRange: ByteRangeSpec?,
        aimd: AIMDConcurrencyGate?,
        maxAttempts: Int = 5,
        requestTimeout: TimeInterval = 30
    ) async throws -> FetchedPayload {
        try Self.validateTargetURL(url, originatingURL: originatingURL)
        let attempts = max(1, maxAttempts)
        var lastError: Error = URLError(.badServerResponse)

        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let redirectDelegate = HLSRedirectSecurityDelegate(originatingURL: originatingURL)
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = requestTimeout
                var hasCookieHeader = false
                for (k, v) in headers {
                    req.setValue(v, forHTTPHeaderField: k)
                    if k.lowercased() == "cookie", !v.isEmpty {
                        hasCookieHeader = true
                    }
                }
                if !hasCookieHeader, let resolvedCookie = await cookieCache.cookie(for: url), !resolvedCookie.isEmpty {
                    req.setValue(resolvedCookie, forHTTPHeaderField: "Cookie")
                }
                if let byteRange {
                    req.setValue(byteRange.headerValue, forHTTPHeaderField: "Range")
                }

                let (rawData, response) = try await session.data(for: req, delegate: redirectDelegate)

                if let blockedError = redirectDelegate.blockedRedirectError {
                    throw NonRetryableError(underlying: blockedError)
                }

                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                let finalURL = http.url ?? url
                try Self.validateTargetURL(finalURL, originatingURL: originatingURL)

                if (200...299).contains(http.statusCode) {
                    let finalData = try Self.extractValidatedByteRange(
                        rawData: rawData,
                        statusCode: http.statusCode,
                        byteRange: byteRange
                    )
                    if let aimd { await aimd.recordSuccess() }
                    return FetchedPayload(data: finalData, finalURL: finalURL)
                }

                if http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    if let aimd { await aimd.recordCongestion() }
                    let retryAfterSec = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    let baseSec = retryAfterSec ?? (0.35 * pow(2.0, Double(attempt)))
                    let backoffMs = Int(baseSec * 1000.0) + Int.random(in: 40...260)
                    lastError = CuriumHLSError.httpStatusError(
                        statusCode: http.statusCode,
                        resource: url.lastPathComponent.isEmpty ? (url.host() ?? "resource") : url.lastPathComponent
                    )
                    if attempt + 1 < attempts {
                        try await Task.sleep(for: .milliseconds(min(backoffMs, 8_000)))
                    }
                    continue
                }

                // Permanent HTTP 4xx (401/403/404/410 etc.) fails fast without burning retries.
                throw NonRetryableError(underlying: CuriumHLSError.httpStatusError(
                    statusCode: http.statusCode,
                    resource: url.lastPathComponent.isEmpty ? (url.host() ?? "resource") : url.lastPathComponent
                ))
            } catch is CancellationError {
                if let blockedError = redirectDelegate.blockedRedirectError {
                    throw blockedError
                }
                throw CancellationError()
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                if let blockedError = redirectDelegate.blockedRedirectError {
                    throw blockedError
                }
                throw CancellationError()
            } catch let urlErr as URLError where Self.isFatalTransportError(urlErr) {
                throw urlErr
            } catch let fatal as NonRetryableError {
                throw fatal.underlying
            } catch let hlsErr as CuriumHLSError {
                switch hlsErr {
                case .disallowedURLScheme, .blockedPrivateNetworkHost, .drmUnsupported, .byteRangeMismatch:
                    throw hlsErr
                default:
                    lastError = hlsErr
                    if attempt + 1 < attempts {
                        if let aimd { await aimd.recordCongestion() }
                        let backoffMs = Int(300.0 * pow(2.0, Double(attempt))) + Int.random(in: 50...250)
                        try await Task.sleep(for: .milliseconds(min(backoffMs, 6_000)))
                    }
                }
            } catch {
                lastError = error
                if attempt + 1 < attempts {
                    if let aimd { await aimd.recordCongestion() }
                    let backoffMs = Int(300.0 * pow(2.0, Double(attempt))) + Int.random(in: 50...250)
                    try await Task.sleep(for: .milliseconds(min(backoffMs, 6_000)))
                }
            }
        }
        throw lastError
    }

    private static func extractValidatedByteRange(
        rawData: Data,
        statusCode: Int,
        byteRange: ByteRangeSpec?
    ) throws -> Data {
        guard let byteRange else { return rawData }
        let expectedLen = byteRange.length
        if statusCode == 206 {
            guard Int64(rawData.count) == expectedLen else {
                throw CuriumHLSError.byteRangeMismatch(expected: expectedLen, actual: Int64(rawData.count))
            }
            return rawData
        }
        // Static servers that ignore `Range` and respond 200 OK with the full resource.
        let start = Int(byteRange.offset)
        let length = Int(byteRange.length)
        guard start >= 0, length > 0, start + length <= rawData.count else {
            throw CuriumHLSError.byteRangeMismatch(expected: expectedLen, actual: Int64(rawData.count))
        }
        return rawData.subdata(in: start..<(start + length))
    }

    // MARK: - Helpers

    private static func acquireSession(from config: CuriumHLSRequestConfig) -> (session: URLSession, ownsSession: Bool) {
        if let factory = config.sessionFactory {
            return (factory(), false)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 20
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return (URLSession(configuration: cfg), true)
    }

    private static func validateResumeOffset(
        fileURL: URL,
        completedSegments: Int,
        contiguousByteOffset: Int64,
        totalTrackSegments: Int
    ) -> (completedSegments: Int, byteOffset: Int64) {
        guard completedSegments > 0,
              completedSegments <= totalTrackSegments,
              contiguousByteOffset > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
              fileSize >= contiguousByteOffset else {
            return (0, 0)
        }
        return (completedSegments, contiguousByteOffset)
    }

    private static func validateTargetURL(_ url: URL, originatingURL: URL?) throws {
        guard CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumHLSError.disallowedURLScheme(url.scheme ?? "unknown")
        }
        guard CuriumHLSParser.isAllowedTargetURL(url, originatingURL: originatingURL) else {
            throw CuriumHLSError.blockedPrivateNetworkHost(url.host ?? "private")
        }
    }

    private static func resolveAndValidateURL(
        _ rawURI: String,
        relativeTo baseURL: URL,
        originatingURL: URL
    ) throws -> URL {
        let trimmed = rawURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CuriumHLSError.invalidPlaylist("Empty URI reference in playlist.")
        }
        let resolved: URL
        if let direct = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
            resolved = direct
        } else if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let fallback = URL(string: encoded, relativeTo: baseURL)?.absoluteURL {
            resolved = fallback
        } else {
            throw CuriumHLSError.invalidPlaylist("Malformed URI reference: \(trimmed)")
        }
        try validateTargetURL(resolved, originatingURL: originatingURL)
        return resolved
    }

    private static func normalizedBrowserHeaders(
        from config: CuriumHLSRequestConfig,
        manifestURL: URL
    ) -> [String: String] {
        var merged = config.extraHeaders
        var keysLower = Set(merged.keys.map { $0.lowercased() })

        if !keysLower.contains("user-agent") {
            merged["User-Agent"] = (config.userAgent?.isEmpty == false) ? config.userAgent! : defaultUserAgent
            keysLower.insert("user-agent")
        }
        if !keysLower.contains("accept") {
            merged["Accept"] = "*/*"
        }
        if !keysLower.contains("accept-language") {
            merged["Accept-Language"] = "en-US,en;q=0.9"
        }
        if !keysLower.contains("referer") {
            if let explicitReferer = config.referer, !explicitReferer.isEmpty {
                merged["Referer"] = explicitReferer
            } else if let scheme = manifestURL.scheme, let host = manifestURL.host() {
                merged["Referer"] = "\(scheme)://\(host)/"
            }
        }
        if !keysLower.contains("origin"), let explicitOrigin = config.origin, !explicitOrigin.isEmpty {
            merged["Origin"] = explicitOrigin
        }

        // Real browsers omit `Origin` on same-origin GET requests; strip it if it matches the target origin.
        if let targetScheme = manifestURL.scheme?.lowercased(),
           let targetHost = manifestURL.host()?.lowercased() {
            let targetOrigin = manifestURL.port.map { "\(targetScheme)://\(targetHost):\($0)" }
                ?? "\(targetScheme)://\(targetHost)"
            for key in Array(merged.keys) where key.lowercased() == "origin" {
                if merged[key]?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased() == targetOrigin {
                    merged.removeValue(forKey: key)
                }
            }
        }
        return merged
    }

    private static func stripUTF8BOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private static func audioCodecCompatibilityRank(_ codecs: String?) -> Int {
        guard let lowered = codecs?.lowercased(), !lowered.isEmpty else { return 0 }
        let tokens = lowered.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if tokens.contains(where: { $0.hasPrefix("mp4a") }) { return 2 }
        if tokens.contains(where: { $0.hasPrefix("ac-3") || $0.hasPrefix("ec-3") }) { return 1 }
        return 0
    }

    private static func parseByteRange(_ raw: String, defaultOffset: Int64?) -> ByteRangeSpec? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let parts = cleaned.split(separator: "@", maxSplits: 1)
        guard let len = parts.first.flatMap({ Int64($0) }), len > 0 else { return nil }
        if parts.count == 2, let explicitOff = Int64(parts[1]), explicitOff >= 0 {
            return ByteRangeSpec(offset: explicitOff, length: len)
        }
        return ByteRangeSpec(offset: defaultOffset ?? -1, length: len)
    }

    private static func parseAttributeList(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var readingValue = false

        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "=", !inQuotes, !readingValue {
                readingValue = true
            } else if ch == ",", !inQuotes {
                let k = key.trimmingCharacters(in: .whitespaces).uppercased()
                if !k.isEmpty { result[k] = value.trimmingCharacters(in: .whitespaces) }
                key = ""
                value = ""
                readingValue = false
            } else if readingValue {
                value.append(ch)
            } else {
                key.append(ch)
            }
        }
        let k = key.trimmingCharacters(in: .whitespaces).uppercased()
        if !k.isEmpty { result[k] = value.trimmingCharacters(in: .whitespaces) }
        return result
    }

    private static func parseHexIV(_ raw: String) -> Data? {
        var hex = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count <= 32 else { return nil }
        if hex.count < 32 {
            hex = String(repeating: "0", count: 32 - hex.count) + hex
        }
        var bytes = Data()
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        for _ in 0..<16 {
            guard index < hex.endIndex,
                  let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

// MARK: - Private Self-Contained Support Primitives

/// Thread-safe monotonic progress & resume-state aggregator across video and optional audio tracks.
private final class TransferTelemetryTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var resumeState: CuriumHLSResumeState
    private let totalCombinedSegments: Int
    private var previousEstimate: Int64?

    init(initialResumeState: CuriumHLSResumeState, totalCombinedSegments: Int) {
        self.resumeState = initialResumeState
        self.totalCombinedSegments = totalCombinedSegments
    }

    func updateVideo(
        completedSegments: Int,
        contiguousByteOffset: Int64,
        activeWorkers: Int
    ) -> CuriumHLSProgressUpdate {
        lock.withLock {
            resumeState.completedSegments = max(resumeState.completedSegments, completedSegments)
            resumeState.contiguousByteOffset = max(resumeState.contiguousByteOffset, contiguousByteOffset)
            return makeDownloadingUpdateLocked(activeWorkers: activeWorkers)
        }
    }

    func updateAudio(
        completedSegments: Int,
        contiguousByteOffset: Int64,
        activeWorkers: Int
    ) -> CuriumHLSProgressUpdate {
        lock.withLock {
            resumeState.audioCompletedSegments = max(resumeState.audioCompletedSegments, completedSegments)
            resumeState.audioContiguousByteOffset = max(resumeState.audioContiguousByteOffset, contiguousByteOffset)
            return makeDownloadingUpdateLocked(activeWorkers: activeWorkers)
        }
    }

    func makeRemuxingUpdate() -> CuriumHLSProgressUpdate {
        lock.withLock {
            let receivedBytes = resumeState.contiguousByteOffset + resumeState.audioContiguousByteOffset
            let estimate = updateEstimateLocked(
                completedSegments: totalCombinedSegments,
                receivedBytes: receivedBytes
            )
            return CuriumHLSProgressUpdate(
                phase: .remuxing,
                receivedBytes: receivedBytes,
                estimatedTotalBytes: estimate ?? receivedBytes,
                completedSegments: totalCombinedSegments,
                totalSegments: totalCombinedSegments,
                activeWorkers: 0,
                resumeState: resumeState
            )
        }
    }

    private func makeDownloadingUpdateLocked(activeWorkers: Int) -> CuriumHLSProgressUpdate {
        let combinedCompleted = resumeState.completedSegments + resumeState.audioCompletedSegments
        let combinedBytes = resumeState.contiguousByteOffset + resumeState.audioContiguousByteOffset
        let estimate = updateEstimateLocked(
            completedSegments: combinedCompleted,
            receivedBytes: combinedBytes
        )
        return CuriumHLSProgressUpdate(
            phase: .downloadingSegments,
            receivedBytes: combinedBytes,
            estimatedTotalBytes: estimate,
            completedSegments: combinedCompleted,
            totalSegments: totalCombinedSegments,
            activeWorkers: activeWorkers,
            resumeState: resumeState
        )
    }

    private func updateEstimateLocked(completedSegments: Int, receivedBytes: Int64) -> Int64? {
        guard totalCombinedSegments > 0 else { return previousEstimate }
        if completedSegments >= 2 {
            let avgPerSegment = Double(receivedBytes) / Double(completedSegments)
            let projected = Int64((avgPerSegment * Double(totalCombinedSegments)).rounded())
            let candidate = max(receivedBytes, projected)
            let monotonic = max(previousEstimate ?? 0, candidate)
            previousEstimate = monotonic
            return monotonic
        }
        if totalCombinedSegments == 1 && completedSegments == 1 {
            let monotonic = max(previousEstimate ?? 0, receivedBytes)
            previousEstimate = monotonic
            return monotonic
        }
        return previousEstimate
    }
}

/// Self-contained POSIX staging file writer supporting non-truncating resume, `ftruncate` boundary
/// alignment, `com.apple.runningboard.can-suspend-locked` xattr protection, `pwrite`, and `fsync`.
private final class StagingPartFile: @unchecked Sendable {
    private let fd: Int32
    private let closeLock = NSLock()
    private var isClosed = false

    init(fileURL: URL, truncateExisting: Bool) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var openFlags = O_CREAT | O_RDWR | O_CLOEXEC
        if truncateExisting {
            openFlags |= O_TRUNC
        }
        let descriptor = fileURL.path.withCString { cPath in
            Darwin.open(cPath, openFlags, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard descriptor >= 0 else {
            throw CuriumHLSError.fileIOFailed(code: errno, operation: "open")
        }
        self.fd = descriptor

        // Guard against 0xdead10cc termination if iOS suspends while staging file is open.
        var flag: UInt8 = 1
        _ = fileURL.path.withCString { cPath in
            setxattr(cPath, "com.apple.runningboard.can-suspend-locked", &flag, 1, 0, 0)
        }
    }

    deinit {
        try? close()
    }

    func truncate(to length: Int64) throws {
        guard length >= 0 else { return }
        try closeLock.withLock {
            guard !isClosed else {
                throw CuriumHLSError.fileIOFailed(code: EBADF, operation: "ftruncate")
            }
            if Darwin.ftruncate(fd, off_t(length)) == -1 {
                throw CuriumHLSError.fileIOFailed(code: errno, operation: "ftruncate")
            }
        }
    }

    func write(_ data: Data, at offset: Int64) throws {
        guard !data.isEmpty else { return }
        try closeLock.withLock {
            guard !isClosed else {
                throw CuriumHLSError.fileIOFailed(code: EBADF, operation: "pwrite")
            }
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                var writtenSoFar = 0
                while remaining > 0 {
                    let ptr = base.advanced(by: writtenSoFar)
                    let rc = Darwin.pwrite(fd, ptr, remaining, off_t(offset) + off_t(writtenSoFar))
                    if rc < 0 {
                        if errno == EINTR { continue }
                        throw CuriumHLSError.fileIOFailed(code: errno, operation: "pwrite")
                    }
                    writtenSoFar += rc
                    remaining -= rc
                }
            }
        }
    }

    func synchronize() throws {
        try closeLock.withLock {
            guard !isClosed else { return }
            if Darwin.fsync(fd) == -1 {
                throw CuriumHLSError.fileIOFailed(code: errno, operation: "fsync")
            }
        }
    }

    func close() throws {
        try closeLock.withLock {
            guard !isClosed else { return }
            isClosed = true
            if Darwin.close(fd) == -1 {
                throw CuriumHLSError.fileIOFailed(code: errno, operation: "close")
            }
        }
    }
}

/// Deduplicated AES-128 key cache with SSRF enforcement and cross-origin credential stripping.
private actor AESKeyCache {
    private let session: URLSession
    private let manifestOriginURL: URL
    private let originatingURL: URL
    private let headers: [String: String]
    private let cookieCache: HLSCookieCache
    private var cache: [URL: Data] = [:]
    private var inFlight: [URL: Task<Data, Error>] = [:]

    init(
        session: URLSession,
        manifestOriginURL: URL,
        originatingURL: URL,
        headers: [String: String],
        cookieCache: HLSCookieCache
    ) {
        self.session = session
        self.manifestOriginURL = manifestOriginURL
        self.originatingURL = originatingURL
        self.headers = headers
        self.cookieCache = cookieCache
    }

    func key(for url: URL) async throws -> Data {
        guard CuriumHLSParser.isAllowedHTTPURL(url) else {
            throw CuriumHLSError.disallowedURLScheme(url.scheme ?? "unknown")
        }
        guard CuriumHLSParser.isAllowedTargetURL(url, originatingURL: originatingURL) else {
            throw CuriumHLSError.blockedPrivateNetworkHost(url.host ?? "private")
        }
        if let existing = cache[url] { return existing }
        if let task = inFlight[url] { return try await task.value }

        let sessionRef = session
        let originURL = originatingURL
        let cookieCacheRef = cookieCache
        let scopedHeaders = HLSRedirectSanitizer.stripCrossOriginAuthHeaders(
            from: headers,
            sourceURL: manifestOriginURL,
            destinationURL: url
        )

        let task = Task<Data, Error> {
            let maxAttempts = 3
            var lastError: Error = URLError(.badServerResponse)

            for attempt in 0..<maxAttempts {
                try Task.checkCancellation()
                let delegate = HLSRedirectSecurityDelegate(originatingURL: originURL)
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    var hasCookie = false
                    for (k, v) in scopedHeaders {
                        req.setValue(v, forHTTPHeaderField: k)
                        if k.lowercased() == "cookie", !v.isEmpty { hasCookie = true }
                    }
                    if !hasCookie, let cookie = await cookieCacheRef.cookie(for: url), !cookie.isEmpty {
                        req.setValue(cookie, forHTTPHeaderField: "Cookie")
                    }

                    let (data, resp) = try await sessionRef.data(for: req, delegate: delegate)
                    if let blocked = delegate.blockedRedirectError {
                        throw blocked
                    }
                    guard let http = resp as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    if (200...299).contains(http.statusCode) {
                        guard data.count == kCCKeySizeAES128 else {
                            throw CuriumHLSError.invalidAESKeyLength(data.count)
                        }
                        return data
                    }
                    if http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                        lastError = CuriumHLSError.httpStatusError(
                            statusCode: http.statusCode,
                            resource: url.lastPathComponent.isEmpty ? "key" : url.lastPathComponent
                        )
                        if attempt + 1 < maxAttempts {
                            let backoffMs = Int(300.0 * pow(2.0, Double(attempt))) + Int.random(in: 40...200)
                            try await Task.sleep(for: .milliseconds(backoffMs))
                        }
                        continue
                    }
                    throw CuriumHLSError.httpStatusError(
                        statusCode: http.statusCode,
                        resource: url.lastPathComponent.isEmpty ? "key" : url.lastPathComponent
                    )
                } catch is CancellationError {
                    if let blocked = delegate.blockedRedirectError {
                        throw blocked
                    }
                    throw CancellationError()
                } catch let urlErr as URLError where urlErr.code == .cancelled {
                    if let blocked = delegate.blockedRedirectError {
                        throw blocked
                    }
                    throw CancellationError()
                } catch let hlsErr as CuriumHLSError {
                    switch hlsErr {
                    case .httpStatusError(let code, _) where code == 408 || code == 429 || (500...599).contains(code):
                        lastError = hlsErr
                    default:
                        throw hlsErr
                    }
                } catch {
                    lastError = error
                    if attempt + 1 < maxAttempts {
                        let backoffMs = Int(300.0 * pow(2.0, Double(attempt))) + Int.random(in: 40...200)
                        try await Task.sleep(for: .milliseconds(backoffMs))
                    }
                }
            }
            throw lastError
        }

        inFlight[url] = task
        do {
            let data = try await task.value
            inFlight.removeValue(forKey: url)
            cache[url] = data
            return data
        } catch {
            inFlight.removeValue(forKey: url)
            throw error
        }
    }
}

/// Coalesced per-directory cookie lookup cache wrapping `CuriumHLSRequestConfig.cookieResolver`.
private actor HLSCookieCache {
    private struct ScopeKey: Hashable, Sendable {
        let scheme: String
        let host: String
        let port: Int
        let directoryPath: String
    }

    private let resolver: (@Sendable (URL) async -> String?)?
    private var resolvedByScope: [ScopeKey: String?] = [:]
    private var inFlightByScope: [ScopeKey: Task<String?, Never>] = [:]

    init(resolver: (@Sendable (URL) async -> String?)?) {
        self.resolver = resolver
    }

    func cookie(for url: URL) async -> String? {
        guard let resolver else { return nil }
        guard let scope = Self.scopeKey(for: url) else { return nil }
        if let cached = resolvedByScope[scope] { return cached }
        if let task = inFlightByScope[scope] { return await task.value }

        let task = Task<String?, Never> {
            await resolver(url)
        }
        inFlightByScope[scope] = task
        let value = await task.value
        inFlightByScope.removeValue(forKey: scope)
        resolvedByScope[scope] = value
        return value
    }

    private static func scopeKey(for url: URL) -> ScopeKey? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased() else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let dir = url.deletingLastPathComponent().path
        return ScopeKey(scheme: scheme, host: host, port: port, directoryPath: dir)
    }
}

/// Self-contained cross-origin auth stripper & HTTPS->HTTP downgrade sanitizer (zero dependency on `w1`).
private enum HLSRedirectSanitizer {
    private static let authHeaderNames: Set<String> = [
        "cookie",
        "authorization",
        "proxy-authorization"
    ]

    static func isSameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let s1 = lhs.scheme?.lowercased(), let s2 = rhs.scheme?.lowercased(), s1 == s2,
              let h1 = lhs.host()?.lowercased(), let h2 = rhs.host()?.lowercased(), h1 == h2 else {
            return false
        }
        let p1 = lhs.port ?? (s1 == "https" ? 443 : (s1 == "http" ? 80 : -1))
        let p2 = rhs.port ?? (s2 == "https" ? 443 : (s2 == "http" ? 80 : -1))
        return p1 == p2
    }

    static func stripCrossOriginAuthHeaders(
        from headers: [String: String],
        sourceURL: URL?,
        destinationURL: URL?
    ) -> [String: String] {
        guard !isSameOrigin(sourceURL, destinationURL) else {
            return headers
        }
        let isHTTPSDowngrade = (sourceURL?.scheme?.lowercased() == "https")
            && (destinationURL?.scheme?.lowercased() == "http")
        return headers.filter { key, _ in
            let lower = key.lowercased()
            if authHeaderNames.contains(lower) { return false }
            if isHTTPSDowngrade && (lower == "referer" || lower == "origin") { return false }
            return true
        }
    }

    static func sanitizedRedirectRequest(from sourceURL: URL?, to request: URLRequest) -> URLRequest {
        guard !isSameOrigin(sourceURL, request.url) else {
            return request
        }
        var sanitized = request
        if let headers = sanitized.allHTTPHeaderFields {
            for key in headers.keys where authHeaderNames.contains(key.lowercased()) {
                sanitized.setValue(nil, forHTTPHeaderField: key)
            }
        }
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        if sourceURL?.scheme?.lowercased() == "https",
           request.url?.scheme?.lowercased() == "http" {
            sanitized.setValue(nil, forHTTPHeaderField: "Referer")
            sanitized.setValue(nil, forHTTPHeaderField: "Origin")
        }
        return sanitized
    }
}

/// Per-request redirect delegate enforcing scheme allowlist, SSRF guard, and cross-origin auth stripping.
private final class HLSRedirectSecurityDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originatingURL: URL
    private let lock = NSLock()
    private var _blockedRedirectError: CuriumHLSError?

    init(originatingURL: URL) {
        self.originatingURL = originatingURL
        super.init()
    }

    var blockedRedirectError: CuriumHLSError? {
        lock.withLock { _blockedRedirectError }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let targetURL = request.url else {
            lock.withLock { _blockedRedirectError = .disallowedURLScheme("missing") }
            task.cancel()
            completionHandler(nil)
            return
        }
        guard CuriumHLSParser.isAllowedHTTPURL(targetURL) else {
            lock.withLock { _blockedRedirectError = .disallowedURLScheme(targetURL.scheme ?? "unknown") }
            task.cancel()
            completionHandler(nil)
            return
        }
        guard CuriumHLSParser.isAllowedTargetURL(targetURL, originatingURL: originatingURL) else {
            lock.withLock { _blockedRedirectError = .blockedPrivateNetworkHost(targetURL.host ?? "private") }
            task.cancel()
            completionHandler(nil)
            return
        }
        let originURL = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
        completionHandler(HLSRedirectSanitizer.sanitizedRedirectRequest(from: originURL, to: request))
    }
}
