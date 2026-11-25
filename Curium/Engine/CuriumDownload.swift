import CuriumEngineContract
import Foundation
import Observation

@MainActor
@Observable
final class CuriumDownload: Identifiable {
    let id: String
    let sourceTabID: String?
    private(set) var originalURL: URL?
    private(set) var filename: String
    private(set) var mimeType: String?
    let isExplicitDownload: Bool
    let isMainFrame: Bool
    let httpMethod: String

    // MARK: - Rich Dysprosium-Grade Transfer State & Telemetry

    private(set) var phase: CuriumTransferPhase
    private(set) var transportKind: CuriumTransferTransportKind
    private(set) var source: CuriumTransferSource
    private(set) var resolvedURL: URL?
    private(set) var pageURL: URL?
    private(set) var eTag: String?
    /// Exact payload length in bytes (`nil` when unknown—never `-1` or a segment count).
    private(set) var knownTotalBytes: Int64?
    /// Approximate byte total hint (e.g., monotonic HLS estimate).
    private(set) var estimatedTotalBytes: Int64?
    private(set) var completedSegments: Int = 0
    private(set) var totalSegments: Int?
    private(set) var slices: [CuriumByteRangeSlice] = []
    private(set) var configuredLanes: Int = CuriumTransferRecord.defaultLanes
    private(set) var activeLanes: Int = 0
    private(set) var speedBytesPerSec: Double = 0
    private(set) var peakSpeedBytesPerSec: Double = 0
    private(set) var throughputSamples: [Double] = []
    private(set) var etaSeconds: TimeInterval?
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var createdAt: Date
    private(set) var completedAt: Date?
    private(set) var saveDestinationLabel: String?

    // MARK: - Legacy & Compatibility State

    private(set) var state: CrIOSDownloadState
    private(set) var savedURL: URL?
    private(set) var failure: String?
    private(set) var fraction: Double?
    /// Expected size in bytes, or `-1` when unknown (preserved for legacy compatibility).
    private(set) var totalBytes: Int64 = -1
    private(set) var receivedBytes: Int64 = 0

    @ObservationIgnored var onActivityChange: (@MainActor () -> Void)?
    @ObservationIgnored var stagedCommitHandlerOverride: (@Sendable (URL, String) async throws -> URL)?

    @ObservationIgnored internal var blinkTask: (any CrIOSDownloadTaskV1)?
    @ObservationIgnored internal var isManagedByCoordinator = false
    @ObservationIgnored internal var onCancelRequested: (@MainActor () -> Void)?
    @ObservationIgnored private var storedHLSMasterPlaylistURL: URL?

    var isActive: Bool {
        phase.isActive || state == .inProgress
    }

    var requiresBackgroundKeepAlive: Bool {
        phase.isBackgroundKeepAliveRequired
    }

    var sourceDomain: String? {
        (resolvedURL ?? originalURL)?.host()
    }

    var canPause: Bool {
        switch phase {
        case .queued, .probing, .downloading, .remuxing:
            return transportKind == .multiLaneRange || transportKind == .hlsRemuxMP4
        case .pendingConfirmation, .saving, .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    var canResume: Bool {
        phase == .paused && supportsHTTPReplay
    }

    var canRetry: Bool {
        (phase == .failed || phase == .cancelled) && supportsHTTPReplay
    }

    /// True when this coordinator-managed HTTP transfer is paused or failed and can safely
    /// verify and swap in a fresh download URL (excluding un-upgraded Blink/POST streams).
    var canRefreshURL: Bool {
        guard isManagedByCoordinator,
              blinkTask == nil,
              httpMethod == "GET",
              phase == .paused || phase == .failed else {
            return false
        }
        switch transportKind {
        case .multiLaneRange, .singleStream, .hlsRemuxMP4:
            return true
        case .blinkNativeStream:
            return false
        }
    }

    /// Non-nil when this download originated from a specific HLS master playlist's variant row.
    var hlsMasterPlaylistURL: URL? {
        storedHLSMasterPlaylistURL
    }

    private var supportsHTTPReplay: Bool {
        guard httpMethod == "GET",
              let target = resolvedURL ?? originalURL else {
            return false
        }
        return CuriumHLSParser.isAllowedHTTPURL(target)
    }

    // MARK: - Initializers

    init(task: any CrIOSDownloadTaskV1) {
        self.blinkTask = task
        self.id = task.downloadID
        self.sourceTabID = task.sourceTabID
        self.originalURL = task.originalURL
        self.resolvedURL = (task.finalURL ?? nil) ?? task.originalURL
        self.eTag = (task.eTag ?? nil).flatMap(CuriumTransferRecord.strongETag(from:))
        self.filename = CuriumDownloadStorage.sanitizedFilename(task.suggestedFilename)
        self.mimeType = task.mimeType
        self.isExplicitDownload = task.isExplicitDownload ?? false
        self.isMainFrame = task.isMainFrame ?? true
        let method = (task.httpMethod ?? "GET").trimmingCharacters(in: .whitespacesAndNewlines)
        self.httpMethod = method.isEmpty ? "GET" : method.uppercased()

        self.source = .blinkDownload
        self.transportKind = .blinkNativeStream

        self.createdAt = Date()
        let initialState = task.state
        self.state = initialState
        let initialPhase = Self.phase(forLegacyState: initialState)
        self.phase = initialPhase
        let initialKnownTotal: Int64? = task.totalBytes > 0 ? task.totalBytes : nil
        self.knownTotalBytes = initialKnownTotal
        self.totalBytes = initialKnownTotal ?? -1
        let initialReceived = max(0, task.receivedBytes)
        self.receivedBytes = initialReceived
        self.fraction = Self.computeFraction(
            phase: initialPhase,
            receivedBytes: initialReceived,
            knownTotalBytes: initialKnownTotal,
            completedSegments: 0,
            totalSegments: nil
        )
    }

    internal init(
        record: CuriumTransferRecord,
        savedURL: URL? = nil,
        hlsMasterPlaylistURL: URL? = nil,
        saveDestinationLabel: String? = nil,
        isExplicitDownload: Bool = true,
        isMainFrame: Bool = true,
        httpMethod: String = "GET"
    ) {
        self.blinkTask = nil
        self.isManagedByCoordinator = true
        self.id = record.id
        self.sourceTabID = record.sourceTabID
        self.originalURL = record.sourceURL ?? record.resolvedURL
        self.filename = CuriumDownloadStorage.sanitizedFilename(record.filename)
        self.mimeType = record.mimeType
        self.isExplicitDownload = isExplicitDownload
        self.isMainFrame = isMainFrame
        self.httpMethod = httpMethod
        self.phase = record.phase
        self.transportKind = record.transportKind
        self.source = record.source
        self.resolvedURL = record.resolvedURL
        self.pageURL = record.pageURL
        self.eTag = record.eTag
        self.knownTotalBytes = record.totalBytes
        self.estimatedTotalBytes = record.estimatedTotalBytes
        self.completedSegments = record.completedSegments
        self.totalSegments = record.totalSegments
        self.slices = record.slices
        self.configuredLanes = record.configuredLanes
        self.activeLanes = record.phase.isActive ? record.activeLanes : 0
        self.speedBytesPerSec = 0
        self.peakSpeedBytesPerSec = record.peakSpeedBytesPerSec ?? 0
        self.throughputSamples = []
        self.etaSeconds = nil
        self.elapsedSeconds = record.activeDurationSeconds ?? 0
        self.createdAt = record.createdAt
        self.completedAt = record.completedAt
        if let saveDestinationLabel, !saveDestinationLabel.isEmpty {
            self.saveDestinationLabel = saveDestinationLabel
        } else if record.phase == .saving {
            self.saveDestinationLabel = CuriumDownloadsFolderManager.displayDownloadsPath
        } else if record.phase == .completed, let savedURL {
            self.saveDestinationLabel = Self.displayDestinationLabel(forSavedURL: savedURL)
        } else {
            self.saveDestinationLabel = nil
        }
        self.savedURL = savedURL
        self.failure = record.failureMessage
        self.receivedBytes = record.receivedBytes
        self.totalBytes = record.totalBytes ?? -1
        self.state = Self.legacyState(for: record.phase)
        self.storedHLSMasterPlaylistURL = hlsMasterPlaylistURL ?? record.hlsCheckpoint?.masterPlaylistURL
        self.fraction = Self.computeFraction(
            phase: record.phase,
            receivedBytes: record.receivedBytes,
            knownTotalBytes: record.totalBytes,
            completedSegments: record.completedSegments,
            totalSegments: record.totalSegments
        )
    }

    // MARK: - Classification

    var isPDF: Bool {
        CuriumDownloadStorage.isPDF(mimeType: mimeType, filename: filename, url: resolvedURL ?? originalURL)
    }

    var isVideo: Bool {
        CuriumDownloadStorage.isVideo(mimeType: mimeType, filename: filename, url: resolvedURL ?? originalURL)
    }

    var isAudio: Bool {
        CuriumDownloadStorage.isAudio(mimeType: mimeType, filename: filename, url: resolvedURL ?? originalURL)
    }

    var symbolName: String {
        CuriumDownloadStorage.symbolName(mimeType: mimeType, filename: filename, url: resolvedURL ?? originalURL)
    }

    var formattedByteSize: String? {
        guard let total = knownTotalBytes, total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    func cancel() {
        onCancelRequested?()
    }

    // MARK: - Internal Coordinator Mutation Surface

    internal func configureForCoordinator(
        source: CuriumTransferSource,
        transportKind: CuriumTransferTransportKind,
        phase: CuriumTransferPhase,
        pageURL: URL?,
        configuredLanes: Int,
        hlsMasterPlaylistURL: URL? = nil
    ) {
        self.isManagedByCoordinator = true
        if self.source != source { self.source = source }
        if self.transportKind != transportKind { self.transportKind = transportKind }
        if self.pageURL != pageURL { self.pageURL = pageURL }
        let clampedLanes = CuriumTransferRecord.clampLanes(configuredLanes)
        if self.configuredLanes != clampedLanes { self.configuredLanes = clampedLanes }
        if let hlsMasterPlaylistURL {
            self.storedHLSMasterPlaylistURL = hlsMasterPlaylistURL
        }
        applyPhase(phase)
    }

    internal func detachBlinkTask() {
        blinkTask = nil
    }

    internal func setPhase(
        _ newPhase: CuriumTransferPhase,
        saveDestinationLabel: String? = nil,
        failureMessage: String? = nil
    ) {
        let wasKeepAlive = requiresBackgroundKeepAlive
        if saveDestinationLabel != self.saveDestinationLabel {
            self.saveDestinationLabel = saveDestinationLabel
        }
        if let failureMessage {
            if self.failure != failureMessage { self.failure = failureMessage }
        } else if newPhase != .failed, self.failure != nil {
            self.failure = nil
        }
        if !newPhase.isActive {
            if activeLanes != 0 { activeLanes = 0 }
            if speedBytesPerSec != 0 { speedBytesPerSec = 0 }
            if etaSeconds != nil { etaSeconds = nil }
        }
        applyPhase(newPhase)
        if wasKeepAlive != requiresBackgroundKeepAlive || newPhase.isTerminal || newPhase == .paused {
            onActivityChange?()
        }
    }

    internal func updateMetadata(
        filename: String? = nil,
        mimeType: String? = nil,
        resolvedURL: URL? = nil,
        pageURL: URL? = nil,
        eTag: String? = nil,
        transportKind: CuriumTransferTransportKind? = nil,
        configuredLanes: Int? = nil
    ) {
        if let filename, !filename.isEmpty, self.filename != filename {
            self.filename = filename
        }
        if let mimeType, !mimeType.isEmpty, self.mimeType != mimeType {
            self.mimeType = mimeType
        }
        if let resolvedURL, self.resolvedURL != resolvedURL {
            self.resolvedURL = resolvedURL
        }
        if let pageURL, self.pageURL != pageURL {
            self.pageURL = pageURL
        }
        if let eTag {
            let strong = CuriumTransferRecord.strongETag(from: eTag)
            if self.eTag != strong { self.eTag = strong }
        }
        if let transportKind, self.transportKind != transportKind {
            self.transportKind = transportKind
        }
        if let configuredLanes {
            let clamped = CuriumTransferRecord.clampLanes(configuredLanes)
            if self.configuredLanes != clamped { self.configuredLanes = clamped }
        }
    }

    internal func applyRefreshedURL(
        sourceURL: URL,
        resolvedURL: URL,
        eTag: String? = nil,
        clearETagIfNil: Bool = false,
        hlsMasterPlaylistURL: URL? = nil
    ) {
        if self.originalURL != sourceURL {
            self.originalURL = sourceURL
        }
        if self.resolvedURL != resolvedURL {
            self.resolvedURL = resolvedURL
        }
        if let eTag {
            let strong = CuriumTransferRecord.strongETag(from: eTag)
            if self.eTag != strong {
                self.eTag = strong
            }
        } else if clearETagIfNil, self.eTag != nil {
            self.eTag = nil
        }
        if let hlsMasterPlaylistURL {
            self.storedHLSMasterPlaylistURL = hlsMasterPlaylistURL
        }
        if self.failure != nil {
            self.failure = nil
        }
    }

    internal func updateRangeTelemetry(
        receivedBytes: Int64,
        knownTotalBytes: Int64?,
        slices: [CuriumByteRangeSlice],
        activeLanes: Int,
        speedBytesPerSec: Double,
        peakSpeedBytesPerSec: Double,
        throughputSamples: [Double],
        etaSeconds: TimeInterval?,
        elapsedSeconds: TimeInterval
    ) {
        let clampedReceived = max(0, receivedBytes)
        if self.receivedBytes != clampedReceived { self.receivedBytes = clampedReceived }
        let sanitizedTotal = knownTotalBytes.flatMap { $0 > 0 ? $0 : nil }
        if self.knownTotalBytes != sanitizedTotal { self.knownTotalBytes = sanitizedTotal }
        let legacyTotal = sanitizedTotal ?? -1
        if self.totalBytes != legacyTotal { self.totalBytes = legacyTotal }
        if self.slices != slices { self.slices = slices }
        let clampedLanes = max(0, activeLanes)
        if self.activeLanes != clampedLanes { self.activeLanes = clampedLanes }
        applySpeedMetrics(
            speed: speedBytesPerSec,
            peak: peakSpeedBytesPerSec,
            samples: throughputSamples,
            eta: etaSeconds,
            elapsed: elapsedSeconds
        )
        syncFraction()
    }

    internal func updateHLSTelemetry(
        receivedBytes: Int64,
        estimatedTotalBytes: Int64?,
        completedSegments: Int,
        totalSegments: Int?,
        activeLanes: Int,
        speedBytesPerSec: Double,
        peakSpeedBytesPerSec: Double,
        throughputSamples: [Double],
        etaSeconds: TimeInterval?,
        elapsedSeconds: TimeInterval
    ) {
        let clampedReceived = max(0, receivedBytes)
        if self.receivedBytes != clampedReceived { self.receivedBytes = clampedReceived }
        // Never leak segment counts into knownTotalBytes or totalBytes during HLS streaming.
        if self.knownTotalBytes != nil { self.knownTotalBytes = nil }
        if self.totalBytes != -1 { self.totalBytes = -1 }
        let sanitizedEst = estimatedTotalBytes.flatMap { $0 > 0 ? $0 : nil }
        if self.estimatedTotalBytes != sanitizedEst { self.estimatedTotalBytes = sanitizedEst }
        let clampedCompleted = max(0, completedSegments)
        if self.completedSegments != clampedCompleted { self.completedSegments = clampedCompleted }
        let sanitizedTotalSegs = totalSegments.flatMap { $0 > 0 ? $0 : nil }
        if self.totalSegments != sanitizedTotalSegs { self.totalSegments = sanitizedTotalSegs }
        let clampedLanes = max(0, activeLanes)
        if self.activeLanes != clampedLanes { self.activeLanes = clampedLanes }
        applySpeedMetrics(
            speed: speedBytesPerSec,
            peak: peakSpeedBytesPerSec,
            samples: throughputSamples,
            eta: etaSeconds,
            elapsed: elapsedSeconds
        )
        syncFraction()
    }

    internal func updateBlinkTelemetry(
        receivedBytes: Int64,
        knownTotalBytes: Int64?,
        speedBytesPerSec: Double,
        peakSpeedBytesPerSec: Double,
        throughputSamples: [Double],
        etaSeconds: TimeInterval?,
        elapsedSeconds: TimeInterval
    ) {
        let clampedReceived = max(0, receivedBytes)
        if self.receivedBytes != clampedReceived { self.receivedBytes = clampedReceived }
        let sanitizedTotal = knownTotalBytes.flatMap { $0 > 0 ? $0 : nil }
        if self.knownTotalBytes != sanitizedTotal { self.knownTotalBytes = sanitizedTotal }
        let legacyTotal = sanitizedTotal ?? -1
        if self.totalBytes != legacyTotal { self.totalBytes = legacyTotal }
        applySpeedMetrics(
            speed: speedBytesPerSec,
            peak: peakSpeedBytesPerSec,
            samples: throughputSamples,
            eta: etaSeconds,
            elapsed: elapsedSeconds
        )
        syncFraction()
    }

    internal func resetProgressForFreshRestart() {
        if receivedBytes != 0 { receivedBytes = 0 }
        if knownTotalBytes != nil { knownTotalBytes = nil }
        if totalBytes != -1 { totalBytes = -1 }
        if estimatedTotalBytes != nil { estimatedTotalBytes = nil }
        if completedSegments != 0 { completedSegments = 0 }
        if totalSegments != nil { totalSegments = nil }
        if !slices.isEmpty { slices = [] }
        if activeLanes != 0 { activeLanes = 0 }
        if speedBytesPerSec != 0 { speedBytesPerSec = 0 }
        if etaSeconds != nil { etaSeconds = nil }
        if fraction != nil { fraction = nil }
        if failure != nil { failure = nil }
        if savedURL != nil { savedURL = nil }
        if completedAt != nil { completedAt = nil }
    }

    internal func resetBytesForFreshRestart() {
        if receivedBytes != 0 { receivedBytes = 0 }
        if completedSegments != 0 { completedSegments = 0 }
        if !slices.isEmpty { slices = [] }
        if activeLanes != 0 { activeLanes = 0 }
        if speedBytesPerSec != 0 { speedBytesPerSec = 0 }
        if etaSeconds != nil { etaSeconds = nil }
        syncFraction()
    }

    internal func markCompleted(
        savedURL: URL,
        finalFilename: String?,
        finalByteCount: Int64?,
        completedAt: Date,
        elapsedSeconds: TimeInterval,
        peakSpeedBytesPerSec: Double,
        saveDestinationLabel: String? = nil
    ) {
        self.savedURL = savedURL
        if let finalFilename, !finalFilename.isEmpty, self.filename != finalFilename {
            self.filename = finalFilename
        }
        if let finalByteCount, finalByteCount >= 0 {
            if self.receivedBytes < finalByteCount { self.receivedBytes = finalByteCount }
            if finalByteCount > 0 {
                if self.knownTotalBytes != finalByteCount { self.knownTotalBytes = finalByteCount }
                if self.totalBytes != finalByteCount { self.totalBytes = finalByteCount }
            }
        }
        self.completedAt = completedAt
        self.elapsedSeconds = max(self.elapsedSeconds, elapsedSeconds)
        if peakSpeedBytesPerSec > self.peakSpeedBytesPerSec {
            self.peakSpeedBytesPerSec = peakSpeedBytesPerSec
        }
        self.activeLanes = 0
        self.speedBytesPerSec = 0
        self.etaSeconds = nil
        if let saveDestinationLabel, !saveDestinationLabel.isEmpty {
            self.saveDestinationLabel = saveDestinationLabel
        } else if self.saveDestinationLabel == nil {
            self.saveDestinationLabel = Self.displayDestinationLabel(forSavedURL: savedURL)
        }
        self.failure = nil
        deactivateSlices()
        applyPhase(.completed)
        if self.fraction != 1.0 { self.fraction = 1.0 }
        onActivityChange?()
    }

    internal nonisolated static func displayDestinationLabel(forSavedURL savedURL: URL) -> String {
        let parent = savedURL.deletingLastPathComponent().standardizedFileURL
        if let customRoot = CuriumDownloadsFolderManager.activeCustomDownloadsURL?.standardizedFileURL,
           parent.path == customRoot.path || parent.path.hasPrefix(customRoot.path + "/") {
            return CuriumDownloadsFolderManager.displayDownloadsPath
        }
        if let record = CuriumDownloadsFolderManager.loadRecord(),
           !record.breadcrumb.isEmpty,
           parent.path == record.canonicalPathHint || parent.path.hasPrefix(record.canonicalPathHint + "/") {
            return record.breadcrumb
        }
        let folderName = parent.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return folderName.isEmpty ? "Downloads" : folderName
    }

    internal func markPaused(
        slices: [CuriumByteRangeSlice]? = nil,
        receivedBytes: Int64? = nil,
        completedSegments: Int? = nil,
        totalSegments: Int? = nil,
        estimatedTotalBytes: Int64? = nil,
        elapsedSeconds: TimeInterval
    ) {
        if let slices {
            self.slices = slices.map { slice in
                var copy = slice
                copy.isActiveLane = false
                return copy
            }
        } else {
            deactivateSlices()
        }
        if let receivedBytes {
            let clamped = max(0, receivedBytes)
            if self.receivedBytes != clamped { self.receivedBytes = clamped }
        }
        if let completedSegments {
            let clamped = max(0, completedSegments)
            if self.completedSegments != clamped { self.completedSegments = clamped }
        }
        if let totalSegments {
            let sanitized = totalSegments > 0 ? totalSegments : nil
            if self.totalSegments != sanitized { self.totalSegments = sanitized }
        }
        if let estimatedTotalBytes {
            let sanitized = estimatedTotalBytes > 0 ? estimatedTotalBytes : nil
            if self.estimatedTotalBytes != sanitized { self.estimatedTotalBytes = sanitized }
        }
        self.activeLanes = 0
        self.speedBytesPerSec = 0
        self.etaSeconds = nil
        self.elapsedSeconds = max(self.elapsedSeconds, elapsedSeconds)
        self.saveDestinationLabel = nil
        applyPhase(.paused)
        syncFraction()
        onActivityChange?()
    }

    internal func markFailed(message: String, elapsedSeconds: TimeInterval) {
        self.failure = message
        self.activeLanes = 0
        self.speedBytesPerSec = 0
        self.etaSeconds = nil
        self.elapsedSeconds = max(self.elapsedSeconds, elapsedSeconds)
        self.saveDestinationLabel = nil
        deactivateSlices()
        applyPhase(.failed)
        syncFraction()
        onActivityChange?()
    }

    internal func markCancelled(elapsedSeconds: TimeInterval) {
        self.failure = nil
        self.activeLanes = 0
        self.speedBytesPerSec = 0
        self.etaSeconds = nil
        self.elapsedSeconds = max(self.elapsedSeconds, elapsedSeconds)
        self.saveDestinationLabel = nil
        deactivateSlices()
        applyPhase(.cancelled)
        onActivityChange?()
    }

    // MARK: - Private Sync Helpers

    private func applyPhase(_ newPhase: CuriumTransferPhase) {
        if phase != newPhase {
            phase = newPhase
        }
        let syncedState = Self.legacyState(for: newPhase)
        if state != syncedState {
            state = syncedState
        }
        syncFraction()
    }

    private func applySpeedMetrics(
        speed: Double,
        peak: Double,
        samples: [Double],
        eta: TimeInterval?,
        elapsed: TimeInterval
    ) {
        let cleanSpeed = speed.isFinite ? max(0, speed) : 0
        if abs(speedBytesPerSec - cleanSpeed) >= 1.0 || (cleanSpeed == 0 && speedBytesPerSec != 0) {
            speedBytesPerSec = cleanSpeed
        }
        let cleanPeak = peak.isFinite ? max(peakSpeedBytesPerSec, peak) : peakSpeedBytesPerSec
        if cleanPeak > peakSpeedBytesPerSec {
            peakSpeedBytesPerSec = cleanPeak
        }
        if throughputSamples != samples {
            throughputSamples = samples
        }
        if etaSeconds != eta {
            etaSeconds = eta
        }
        let cleanElapsed = elapsed.isFinite ? max(0, elapsed) : elapsedSeconds
        if abs(elapsedSeconds - cleanElapsed) >= 0.05 {
            elapsedSeconds = cleanElapsed
        }
    }

    private func deactivateSlices() {
        guard slices.contains(where: \.isActiveLane) else { return }
        slices = slices.map { slice in
            var copy = slice
            copy.isActiveLane = false
            return copy
        }
    }

    private func syncFraction() {
        let next = Self.computeFraction(
            phase: phase,
            receivedBytes: receivedBytes,
            knownTotalBytes: knownTotalBytes,
            completedSegments: completedSegments,
            totalSegments: totalSegments
        )
        if fraction != next {
            fraction = next
        }
    }

    private static func computeFraction(
        phase: CuriumTransferPhase,
        receivedBytes: Int64,
        knownTotalBytes: Int64?,
        completedSegments: Int,
        totalSegments: Int?
    ) -> Double? {
        if phase == .completed {
            return 1.0
        }
        if let totalSegments, totalSegments > 0 {
            if phase == .remuxing || phase == .saving {
                return 1.0
            }
            return min(1.0, max(0.0, Double(completedSegments) / Double(totalSegments)))
        }
        if let knownTotalBytes, knownTotalBytes > 0 {
            return min(1.0, max(0.0, Double(receivedBytes) / Double(knownTotalBytes)))
        }
        return nil
    }

    private static func legacyState(for phase: CuriumTransferPhase) -> CrIOSDownloadState {
        switch phase {
        case .pendingConfirmation, .queued, .paused:
            return .pending
        case .probing, .downloading, .remuxing, .saving:
            return .inProgress
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    private static func phase(forLegacyState state: CrIOSDownloadState) -> CuriumTransferPhase {
        switch state {
        case .pending:
            return .pendingConfirmation
        case .inProgress:
            return .downloading
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        @unknown default:
            return .pendingConfirmation
        }
    }
}
