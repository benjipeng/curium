import Foundation

/// Lifecycle phase of a Curium transfer across intake, probing, transport, remuxing, and durable commit.
enum CuriumTransferPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case pendingConfirmation
    case queued
    case probing
    case downloading
    case remuxing
    case saving
    case paused
    case completed
    case failed
    case cancelled

    /// True while the transfer owns active network, remux, or storage commit work.
    var isActive: Bool {
        switch self {
        case .probing, .downloading, .remuxing, .saving:
            return true
        case .pendingConfirmation, .queued, .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    /// True once the transfer has reached an immutable end state.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .pendingConfirmation, .queued, .probing, .downloading, .remuxing, .saving, .paused:
            return false
        }
    }

    /// True when LiveContainer background silent-audio keep-alive must remain armed.
    var isBackgroundKeepAliveRequired: Bool {
        switch self {
        case .probing, .downloading, .remuxing, .saving:
            return true
        case .pendingConfirmation, .queued, .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    /// True when the transfer should transition to `.paused` if left behind after an abrupt process exit.
    var pausesOnColdLaunch: Bool {
        isActive || self == .queued
    }

    var canPause: Bool {
        isActive || self == .queued
    }

    var canResume: Bool {
        self == .paused || self == .failed
    }

    var displayTitle: String {
        switch self {
        case .pendingConfirmation: return "Confirm"
        case .queued: return "Queued"
        case .probing: return "Probing"
        case .downloading: return "Downloading"
        case .remuxing: return "Remuxing"
        case .saving: return "Saving"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Transport strategy driving a transfer's data plane.
enum CuriumTransferTransportKind: String, Codable, Sendable, Equatable, CaseIterable {
    case multiLaneRange
    case singleStream
    case hlsRemuxMP4
    case blinkNativeStream

    var displayTitle: String {
        switch self {
        case .multiLaneRange: return "Multi-Lane Range"
        case .singleStream: return "Single Stream"
        case .hlsRemuxMP4: return "HLS → MP4"
        case .blinkNativeStream: return "Browser Stream"
        }
    }
}

/// Intake origin that created a transfer.
enum CuriumTransferSource: String, Codable, Sendable, Equatable, CaseIterable {
    case blinkDownload
    case mediaRadarDirect
    case mediaRadarHLS
    case manualURL
}

/// Contiguous inclusive byte interval `[startOffset ... endOffset]` tracked for concurrent Range lanes
/// and crash-safe resume from exact write cursors.
struct CuriumByteRangeSlice: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    /// Inclusive starting byte offset within the preallocated staging file.
    var startOffset: Int64
    /// Next unwritten byte offset (`startOffset ... endOffset + 1`).
    var currentOffset: Int64
    /// Inclusive ending byte offset owned by this slice.
    var endOffset: Int64
    /// Whether an active socket worker currently owns this slice.
    var isActiveLane: Bool

    init(
        id: Int,
        startOffset: Int64,
        currentOffset: Int64,
        endOffset: Int64,
        isActiveLane: Bool = false
    ) {
        self.id = id
        self.startOffset = startOffset
        self.currentOffset = currentOffset
        self.endOffset = endOffset
        self.isActiveLane = isActiveLane
    }

    var totalBytes: Int64 {
        guard endOffset >= startOffset else { return 0 }
        let (span, overflow) = (endOffset - startOffset).addingReportingOverflow(1)
        return overflow ? Int64.max : span
    }

    var downloadedBytes: Int64 {
        let total = totalBytes
        guard total > 0 else { return 0 }
        return min(total, max(0, currentOffset - startOffset))
    }

    var remainingBytes: Int64 {
        guard currentOffset <= endOffset else { return 0 }
        let (remaining, overflow) = (endOffset - currentOffset).addingReportingOverflow(1)
        return overflow ? Int64.max : remaining
    }

    var fraction: Double {
        let total = totalBytes
        guard total > 0 else { return isComplete ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(total)))
    }

    var isComplete: Bool {
        currentOffset > endOffset
    }
}

/// Segment-checkpointed resume metadata persisted for HLS transfers.
struct CuriumHLSCheckpoint: Codable, Hashable, Sendable {
    var playlistURL: URL
    var audioPlaylistURL: URL?
    var masterPlaylistURL: URL?
    var completedSegments: Int
    var totalSegments: Int?
    var contiguousByteOffset: Int64
    var isFMP4: Bool
    var preloadedPlaylistText: String?
    var audioCompletedSegments: Int
    var audioContiguousByteOffset: Int64

    init(
        playlistURL: URL,
        audioPlaylistURL: URL? = nil,
        masterPlaylistURL: URL? = nil,
        completedSegments: Int = 0,
        totalSegments: Int? = nil,
        contiguousByteOffset: Int64 = 0,
        isFMP4: Bool = false,
        preloadedPlaylistText: String? = nil,
        audioCompletedSegments: Int = 0,
        audioContiguousByteOffset: Int64 = 0
    ) {
        self.playlistURL = playlistURL
        self.audioPlaylistURL = audioPlaylistURL
        self.masterPlaylistURL = masterPlaylistURL
        self.completedSegments = max(0, completedSegments)
        self.totalSegments = totalSegments.flatMap { $0 > 0 ? $0 : nil }
        self.contiguousByteOffset = max(0, contiguousByteOffset)
        self.isFMP4 = isFMP4
        self.preloadedPlaylistText = preloadedPlaylistText
        self.audioCompletedSegments = max(0, audioCompletedSegments)
        self.audioContiguousByteOffset = max(0, audioContiguousByteOffset)
    }

    private enum CodingKeys: String, CodingKey {
        case playlistURL
        case audioPlaylistURL
        case masterPlaylistURL
        case completedSegments
        case totalSegments
        case contiguousByteOffset
        case isFMP4
        case preloadedPlaylistText
        case audioCompletedSegments
        case audioContiguousByteOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlistURL = try container.decode(URL.self, forKey: .playlistURL)
        audioPlaylistURL = try container.decodeIfPresent(URL.self, forKey: .audioPlaylistURL)
        masterPlaylistURL = try container.decodeIfPresent(URL.self, forKey: .masterPlaylistURL)
        completedSegments = max(0, try container.decodeIfPresent(Int.self, forKey: .completedSegments) ?? 0)
        totalSegments = try container.decodeIfPresent(Int.self, forKey: .totalSegments).flatMap { $0 > 0 ? $0 : nil }
        contiguousByteOffset = max(0, try container.decodeIfPresent(Int64.self, forKey: .contiguousByteOffset) ?? 0)
        isFMP4 = try container.decodeIfPresent(Bool.self, forKey: .isFMP4) ?? false
        preloadedPlaylistText = try container.decodeIfPresent(String.self, forKey: .preloadedPlaylistText)
        audioCompletedSegments = max(0, try container.decodeIfPresent(Int.self, forKey: .audioCompletedSegments) ?? 0)
        audioContiguousByteOffset = max(0, try container.decodeIfPresent(Int64.self, forKey: .audioContiguousByteOffset) ?? 0)
    }
}

/// Durable transfer state persisted in SQLite WAL.
/// Sensitive auth headers (`Cookie`, `Authorization`, `Proxy-Authorization`) are intentionally absent
/// so credentials are never written to disk.
struct CuriumTransferRecord: Identifiable, Codable, Equatable, Sendable {
    static let defaultLanes = 8
    static let minLanes = 1
    static let maxLanes = 16

    private static let sensitiveAuthHeaderNames: Set<String> = [
        "cookie",
        "authorization",
        "proxy-authorization",
        "set-cookie",
    ]

    var id: String
    var sourceProfileID: String
    var sourceTabID: String?
    var source: CuriumTransferSource
    var transportKind: CuriumTransferTransportKind
    var phase: CuriumTransferPhase

    var sourceURL: URL?
    var resolvedURL: URL?
    var pageURL: URL?
    var filename: String
    var mimeType: String?
    var eTag: String?
    var lastModified: String?

    var receivedBytes: Int64
    /// Known exact payload length in bytes (`nil` when unknown—never `-1` or a segment count).
    var totalBytes: Int64?
    /// Approximate byte total hint (e.g., monotonic HLS estimate).
    var estimatedTotalBytes: Int64?

    var completedSegments: Int
    var totalSegments: Int?

    var configuredLanes: Int
    var activeLanes: Int
    var slices: [CuriumByteRangeSlice]
    var hlsCheckpoint: CuriumHLSCheckpoint?

    var stagingDirectoryName: String
    var stagingFileName: String
    var savedBookmarkPath: String?

    var userAgent: String?
    var referer: String?
    var origin: String?
    var includeTabCookies: Bool

    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var failureMessage: String?

    /// Optional persisted performance insights for Transfer Inspector / history display.
    var activeDurationSeconds: Double?
    var peakSpeedBytesPerSec: Double?
    var averageSpeedBytesPerSec: Double?

    init(
        id: String = UUID().uuidString,
        sourceProfileID: String = "default",
        sourceTabID: String? = nil,
        source: CuriumTransferSource,
        transportKind: CuriumTransferTransportKind,
        phase: CuriumTransferPhase = .queued,
        sourceURL: URL? = nil,
        resolvedURL: URL? = nil,
        pageURL: URL? = nil,
        filename: String,
        mimeType: String? = nil,
        eTag: String? = nil,
        lastModified: String? = nil,
        receivedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        estimatedTotalBytes: Int64? = nil,
        completedSegments: Int = 0,
        totalSegments: Int? = nil,
        configuredLanes: Int = CuriumTransferRecord.defaultLanes,
        activeLanes: Int = 0,
        slices: [CuriumByteRangeSlice] = [],
        hlsCheckpoint: CuriumHLSCheckpoint? = nil,
        stagingDirectoryName: String? = nil,
        stagingFileName: String? = nil,
        savedBookmarkPath: String? = nil,
        userAgent: String? = nil,
        referer: String? = nil,
        origin: String? = nil,
        includeTabCookies: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        failureMessage: String? = nil,
        activeDurationSeconds: Double? = nil,
        peakSpeedBytesPerSec: Double? = nil,
        averageSpeedBytesPerSec: Double? = nil
    ) {
        self.id = id
        self.sourceProfileID = sourceProfileID.isEmpty ? "default" : sourceProfileID
        self.sourceTabID = sourceTabID
        self.source = source
        self.transportKind = transportKind
        self.phase = phase
        self.sourceURL = sourceURL
        self.resolvedURL = resolvedURL
        self.pageURL = pageURL
        self.filename = filename
        self.mimeType = mimeType
        self.eTag = Self.strongETag(from: eTag)
        self.lastModified = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.receivedBytes = max(0, receivedBytes)
        self.totalBytes = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.estimatedTotalBytes = estimatedTotalBytes.flatMap { $0 > 0 ? $0 : nil }
        self.completedSegments = max(0, completedSegments)
        self.totalSegments = totalSegments.flatMap { $0 > 0 ? $0 : nil }
        self.configuredLanes = Self.clampLanes(configuredLanes)
        self.activeLanes = max(0, activeLanes)
        self.slices = slices
        self.hlsCheckpoint = hlsCheckpoint
        self.stagingDirectoryName = stagingDirectoryName ?? id
        self.stagingFileName = stagingFileName ?? (filename.isEmpty ? "payload.part" : "\(filename).part")
        self.savedBookmarkPath = savedBookmarkPath
        self.userAgent = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.referer = referer?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.includeTabCookies = includeTabCookies
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.failureMessage = failureMessage
        self.activeDurationSeconds = activeDurationSeconds
        self.peakSpeedBytesPerSec = peakSpeedBytesPerSec
        self.averageSpeedBytesPerSec = averageSpeedBytesPerSec
    }

    static func clampLanes(_ lanes: Int) -> Int {
        max(minLanes, min(lanes, maxLanes))
    }

    /// Returns a strong HTTP `ETag` validator per RFC 9110 §13.1.5, discarding weak tags (`W/"..."`).
    static func strongETag(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("W/") || trimmed.hasPrefix("w/") {
            return nil
        }
        return trimmed
    }

    /// Strips sensitive credentials (`Cookie`, `Authorization`, `Proxy-Authorization`, `Set-Cookie`)
    /// from an in-memory HTTP header map.
    static func scrubbingAuthHeaders(from headers: [String: String]) -> [String: String] {
        guard !headers.isEmpty else { return headers }
        return headers.filter { !sensitiveAuthHeaderNames.contains($0.key.lowercased()) }
    }

    /// Strong `If-Range` validator derived from strong `eTag` first, falling back to `lastModified`.
    var ifRangeValidator: String? {
        if let strong = Self.strongETag(from: eTag) {
            return strong
        }
        return lastModified?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
    }

    /// Progress fraction (`0.0 ... 1.0`), or `nil` when indeterminate.
    var progressFraction: Double? {
        if let totalSegments, totalSegments > 0 {
            return min(1.0, max(0.0, Double(completedSegments) / Double(totalSegments)))
        }
        if let totalBytes, totalBytes > 0 {
            return min(1.0, max(0.0, Double(receivedBytes) / Double(totalBytes)))
        }
        if phase == .completed {
            return 1.0
        }
        return nil
    }

    /// Returns a sanitized copy suitable for terminal persistence (inactive lanes cleared).
    func normalizedForPersistence() -> CuriumTransferRecord {
        var copy = self
        copy.configuredLanes = Self.clampLanes(copy.configuredLanes)
        copy.receivedBytes = max(0, copy.receivedBytes)
        if let total = copy.totalBytes, total < 0 {
            copy.totalBytes = nil
        }
        copy.eTag = Self.strongETag(from: copy.eTag)
        if !copy.phase.isActive {
            copy.activeLanes = 0
            for idx in copy.slices.indices {
                copy.slices[idx].isActiveLane = false
            }
        }
        return copy
    }
}

/// Result of a lightweight `GET` `Range: bytes=0-0` header probe.
struct CuriumRangeProbeResult: Sendable, Equatable {
    let finalURL: URL
    let statusCode: Int
    let supportsByteRanges: Bool
    let totalBytes: Int64?
    /// Strong entity tag only (`W/` weak tags filtered per RFC 9110 §13.1.5).
    let eTag: String?
    let lastModified: String?
    let suggestedFilename: String?
    let mimeType: String?
    let isHTMLResponse: Bool

    init(
        finalURL: URL,
        statusCode: Int,
        supportsByteRanges: Bool,
        totalBytes: Int64?,
        eTag: String?,
        lastModified: String?,
        suggestedFilename: String?,
        mimeType: String?,
        isHTMLResponse: Bool
    ) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.supportsByteRanges = supportsByteRanges
        self.totalBytes = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.eTag = CuriumTransferRecord.strongETag(from: eTag)
        self.lastModified = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.suggestedFilename = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.mimeType = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nonEmptyOrNil
        self.isHTMLResponse = isHTMLResponse
    }

    /// Preferred `If-Range` header value (strong `ETag` first, else `Last-Modified`).
    var ifRangeValidator: String? {
        if let strong = CuriumTransferRecord.strongETag(from: eTag) {
            return strong
        }
        return lastModified
    }
}

/// Live progress snapshot emitted by `CuriumRangeTransferEngine`.
struct CuriumRangeProgressUpdate: Sendable, Equatable {
    let receivedBytes: Int64
    let totalBytes: Int64?
    let activeLanes: Int
    let slices: [CuriumByteRangeSlice]
}

private extension String {
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
