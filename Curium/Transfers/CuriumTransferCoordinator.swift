import CuriumEngineContract
import Foundation
import OSLog
import UIKit
import os

/// Smart 4-source transfer router and durable lifecycle coordinator bridging
/// Blink downloads, Media Radar Direct, Media Radar HLS, and Manual `+ New Download`
/// onto `CuriumRangeTransferEngine`, `CuriumHLSTransferEngine`, `CuriumTransferStore`,
/// and `CuriumDownloadStorage`.
@MainActor
final class CuriumTransferCoordinator {
    static let maxConcurrentTransfers = 3

    struct Environment {
        var downloadsRootOverride: URL?
        var stagingRootOverride: URL?
        var databaseURLOverride: URL?
        var rangeEngine: CuriumRangeTransferEngine
        var hlsEngine: CuriumHLSTransferEngine
        var rangeConfiguration: CuriumRangeEngineConfiguration
        var installStoreLifecycleObservers: Bool
        var enablePersistence: Bool

        init(
            downloadsRootOverride: URL? = nil,
            stagingRootOverride: URL? = nil,
            databaseURLOverride: URL? = nil,
            rangeEngine: CuriumRangeTransferEngine = CuriumRangeTransferEngine(),
            hlsEngine: CuriumHLSTransferEngine = CuriumHLSTransferEngine(),
            rangeConfiguration: CuriumRangeEngineConfiguration = CuriumRangeEngineConfiguration(),
            installStoreLifecycleObservers: Bool = true,
            enablePersistence: Bool = true
        ) {
            self.downloadsRootOverride = downloadsRootOverride
            self.stagingRootOverride = stagingRootOverride
            self.databaseURLOverride = databaseURLOverride
            self.rangeEngine = rangeEngine
            self.hlsEngine = hlsEngine
            self.rangeConfiguration = rangeConfiguration
            self.installStoreLifecycleObservers = installStoreLifecycleObservers
            self.enablePersistence = enablePersistence
        }
    }

    struct HostBridge {
        var activeProfileID: @MainActor () -> String
        var effectiveProxy: @MainActor () -> CuriumProxyConfig
        var resolveCookieHeader: @MainActor (URL, String?) async -> String?
        var tabContext: @MainActor (String?) -> (userAgent: String?, pageURL: URL?)
        var allDownloads: @MainActor () -> [CuriumDownload]
        var insertDownload: @MainActor (CuriumDownload, Bool) -> Void
        var appendHydratedDownload: @MainActor (CuriumDownload) -> Void
        var removeDownload: @MainActor (String) -> Void
        var syncBackgroundKeepAlive: @MainActor () -> Void
        var refreshSavedDownloads: @MainActor () -> Void
    }

    private enum StopIntent {
        case pause
        case cancel
    }

    private final class LatestRangeSnapshotBox: Sendable {
        private let lock = OSAllocatedUnfairLock<CuriumRangeProgressUpdate?>(initialState: nil)
        func store(_ update: CuriumRangeProgressUpdate) {
            lock.withLock { $0 = update }
        }
        var latest: CuriumRangeProgressUpdate? {
            lock.withLock { $0 }
        }
    }

    private final class LatestHLSSnapshotBox: Sendable {
        private let lock = OSAllocatedUnfairLock<CuriumHLSProgressUpdate?>(initialState: nil)
        func store(_ update: CuriumHLSProgressUpdate) {
            lock.withLock { $0 = update }
        }
        var latest: CuriumHLSProgressUpdate? {
            lock.withLock { $0 }
        }
    }

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "transfers.coordinator")

    /// Common multi-label public suffixes for accurate same-site (eTLD+1) cookie inheritance checks.
    private nonisolated static let multiLabelPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "net.tw", "org.tw", "com.hk", "org.hk", "edu.hk",
        "com.br", "net.br", "org.br", "com.mx", "org.mx",
        "co.kr", "or.kr", "ne.kr", "co.nz", "net.nz", "org.nz",
        "co.in", "net.in", "org.in", "com.sg", "com.my",
        "co.za", "co.il", "com.tr", "com.ar", "com.pl", "com.ua",
    ]

    private let environment: Environment
    private let host: HostBridge
    private let transferStore: CuriumTransferStore?

    private var itemsByID: [String: CuriumDownload] = [:]
    private var recordsByID: [String: CuriumTransferRecord] = [:]
    private var metersByID: [String: CuriumThroughputMeter] = [:]
    private var runningTasksByID: [String: Task<Void, Never>] = [:]
    private var activeCommitTasksByID: [String: Task<URL, any Error>] = [:]
    private var blinkPollTasksByID: [String: Task<Void, Never>] = [:]
    private var stopIntentsByID: [String: StopIntent] = [:]
    /// In-memory only auth cookies—never written to SQLite.
    private var transientCookiesByID: [String: String] = [:]
    private var customFilenameTransferIDs: Set<String> = []
    private var hydrationTask: Task<Void, Never>?

    init(environment: Environment, host: HostBridge) {
        self.environment = environment
        self.host = host
        if environment.enablePersistence {
            do {
                self.transferStore = try CuriumTransferStore(
                    databaseURL: environment.databaseURLOverride,
                    installLifecycleObservers: environment.installStoreLifecycleObservers
                )
            } catch {
                Self.log.error("Failed to open CuriumTransferStore: \(error.localizedDescription, privacy: .public)")
                self.transferStore = nil
            }
        } else {
            self.transferStore = nil
        }

        if transferStore != nil {
            hydrationTask = Task { @MainActor [weak self] in
                await self?.performColdLaunchHydration()
            }
        }
    }

    func waitForHydration() async {
        await hydrationTask?.value
    }

    // MARK: - Cold-Launch Hydration

    private func performColdLaunchHydration() async {
        guard let store = transferStore else { return }
        _ = await store.markInterruptedTransfersPausedOnLaunch()
        let persisted = await store.loadAll()

        var preservedStagingDirs: Set<String> = []
        let hasPendingExternalFolder = CuriumDownloadsFolderManager.shared.isResolving
            || CuriumDownloadsFolderManager.shared.status.needsHostGrant
            || (CuriumDownloadsFolderManager.loadRecord() != nil
                && CuriumDownloadsFolderManager.activeCustomDownloadsURL == nil)
        let fm = FileManager.default

        for record in persisted {
            if itemsByID[record.id] != nil {
                if !record.phase.isTerminal {
                    preservedStagingDirs.insert(record.stagingDirectoryName)
                }
                continue
            }

            switch record.phase {
            case .pendingConfirmation, .cancelled:
                // Blink task handles do not survive process exit; prune cancelled/unconfirmed rows.
                await store.delete(id: record.id)
                cleanupStagingDirectory(named: record.stagingDirectoryName)
                continue

            case .completed:
                guard let savedPath = record.savedBookmarkPath, !savedPath.isEmpty else {
                    await store.delete(id: record.id)
                    continue
                }
                let savedURL = URL(fileURLWithPath: savedPath)
                if !fm.fileExists(atPath: savedURL.path) {
                    let parentDir = savedURL.deletingLastPathComponent()
                    var isParentDir: ObjCBool = false
                    let isLocalMountedAndReadable = !hasPendingExternalFolder
                        && fm.fileExists(atPath: parentDir.path, isDirectory: &isParentDir)
                        && isParentDir.boolValue
                        && fm.isReadableFile(atPath: parentDir.path)
                    if isLocalMountedAndReadable {
                        await store.delete(id: record.id)
                        continue
                    }
                }
                let item = makeHydratedItem(from: record, savedURL: savedURL)
                itemsByID[record.id] = item
                recordsByID[record.id] = record
                host.appendHydratedDownload(item)

            case .paused, .failed:
                var normalizedRecord = record
                normalizedRecord.activeLanes = 0
                if normalizedRecord.phase == .paused {
                    preservedStagingDirs.insert(normalizedRecord.stagingDirectoryName)
                } else if normalizedRecord.receivedBytes > 0 {
                    preservedStagingDirs.insert(normalizedRecord.stagingDirectoryName)
                }
                let item = makeHydratedItem(from: normalizedRecord, savedURL: nil)
                itemsByID[normalizedRecord.id] = item
                recordsByID[normalizedRecord.id] = normalizedRecord
                host.appendHydratedDownload(item)

            case .queued, .probing, .downloading, .remuxing, .saving:
                // markInterruptedTransfersPausedOnLaunch already transitioned these; handle defensively.
                var pausedRecord = record
                pausedRecord.phase = .paused
                pausedRecord.activeLanes = 0
                for idx in pausedRecord.slices.indices {
                    pausedRecord.slices[idx].isActiveLane = false
                }
                preservedStagingDirs.insert(pausedRecord.stagingDirectoryName)
                let item = makeHydratedItem(from: pausedRecord, savedURL: nil)
                itemsByID[pausedRecord.id] = item
                recordsByID[pausedRecord.id] = pausedRecord
                await store.upsert(pausedRecord)
                host.appendHydratedDownload(item)
            }
        }

        let stagingRootOverride = environment.stagingRootOverride
        let preserved = preservedStagingDirs
        Task.detached(priority: .utility) {
            CuriumDownloadStorage.cleanupOrphanedDurableTransferStaging(
                preservingDirectoryNames: preserved,
                stagingRoot: stagingRootOverride,
                minimumAgeSeconds: 60
            )
        }
    }

    private func makeHydratedItem(from record: CuriumTransferRecord, savedURL: URL?) -> CuriumDownload {
        let destinationLabel: String? = (record.phase == .completed)
            ? savedURL.map { CuriumDownload.displayDestinationLabel(forSavedURL: $0) }
            : nil
        let item = CuriumDownload(
            record: record,
            savedURL: savedURL,
            hlsMasterPlaylistURL: record.hlsCheckpoint?.masterPlaylistURL,
            saveDestinationLabel: destinationLabel
        )
        wireItemCallbacks(item)
        return item
    }

    private func wireItemCallbacks(_ item: CuriumDownload) {
        item.onActivityChange = { [weak self] in
            self?.host.syncBackgroundKeepAlive()
        }
        item.onCancelRequested = { [weak self, weak item] in
            guard let self, let item else { return }
            self.cancelDownload(item)
        }
    }

    // MARK: - Source 1: Blink `didCreateDownload`

    func registerBlinkDownload(task: any CrIOSDownloadTaskV1) -> CuriumDownload? {
        if itemsByID[task.downloadID] != nil || host.allDownloads().contains(where: { $0.id == task.downloadID }) {
            return nil
        }
        let item = CuriumDownload(task: task)
        let tabCtx = host.tabContext(task.sourceTabID)
        item.configureForCoordinator(
            source: .blinkDownload,
            transportKind: .blinkNativeStream,
            phase: .pendingConfirmation,
            pageURL: tabCtx.pageURL,
            configuredLanes: CuriumTransferRecord.defaultLanes
        )
        wireItemCallbacks(item)

        let record = CuriumTransferRecord(
            id: item.id,
            sourceProfileID: host.activeProfileID(),
            sourceTabID: item.sourceTabID,
            source: .blinkDownload,
            transportKind: .blinkNativeStream,
            phase: .pendingConfirmation,
            sourceURL: item.originalURL,
            resolvedURL: nil,
            pageURL: tabCtx.pageURL,
            filename: item.filename,
            mimeType: item.mimeType,
            receivedBytes: item.receivedBytes,
            totalBytes: item.knownTotalBytes,
            configuredLanes: CuriumTransferRecord.defaultLanes,
            activeLanes: 0,
            stagingDirectoryName: item.id,
            stagingFileName: "\(item.filename).part",
            userAgent: tabCtx.userAgent,
            referer: Self.safeRefererString(from: tabCtx.pageURL, targetURL: item.originalURL),
            origin: Self.originString(for: tabCtx.pageURL),
            includeTabCookies: true,
            createdAt: item.createdAt,
            updatedAt: Date()
        )
        itemsByID[item.id] = item
        recordsByID[item.id] = record
        host.insertDownload(item, true)
        return item
    }

    /// Starts a pending Blink download (or resumes a queued/pending coordinator item), awaiting completion.
    func startDownload(_ item: CuriumDownload) async {
        // Legacy standalone items created directly without coordinator registration.
        if !item.isManagedByCoordinator {
            item.onActivityChange = { [weak self] in
                self?.host.syncBackgroundKeepAlive()
            }
            host.syncBackgroundKeepAlive()
            defer { host.syncBackgroundKeepAlive() }
            if await item.start(downloadsRoot: environment.downloadsRootOverride) != nil {
                host.refreshSavedDownloads()
            }
            return
        }

        if let existingTask = runningTasksByID[item.id] {
            await existingTask.value
            return
        }

        guard item.phase == .pendingConfirmation || item.phase == .queued else {
            return
        }

        stopIntentsByID.removeValue(forKey: item.id)

        if item.blinkTask != nil {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.executeBlinkDownload(item)
            }
            runningTasksByID[item.id] = task
            await task.value
            return
        }

        let task = launchManagedTransferTask(for: item)
        await task.value
    }

    // MARK: - Source 2 & 3: Media Radar Direct & HLS

    @discardableResult
    func startMediaRadarDownload(
        candidate: CuriumMediaCandidate,
        hlsVariant: CuriumHLSVariant?,
        inTabID tabID: String,
        context: CuriumMediaRequestContext,
        cachedHLSInspection: CuriumHLSMasterInspection?
    ) -> CuriumDownload? {
        let targetURL = (candidate.kind == .hls ? hlsVariant?.url : nil) ?? candidate.url
        let tabCtx = host.tabContext(tabID)
        let pageURL = context.referrer ?? tabCtx.pageURL
        let transferID = UUID().uuidString

        let record: CuriumTransferRecord
        let masterURL: URL?

        switch candidate.kind {
        case .hls:
            let baseStem = (candidate.suggestedFilename as NSString).deletingPathExtension
            let labeledStem: String
            if let res = hlsVariant?.resolutionLabel, !res.isEmpty {
                labeledStem = "\(baseStem) (\(res))"
            } else {
                labeledStem = baseStem
            }
            let mp4Filename = Self.ensureMP4Extension(
                CuriumDownloadStorage.sanitizedFilename("\(labeledStem).mp4", fallback: "Video.mp4")
            )
            masterURL = hlsVariant != nil ? candidate.url : nil
            let checkpoint = CuriumHLSCheckpoint(
                playlistURL: targetURL,
                audioPlaylistURL: hlsVariant?.audioURI,
                masterPlaylistURL: masterURL,
                isFMP4: cachedHLSInspection?.isFMP4 ?? false
            )
            record = CuriumTransferRecord(
                id: transferID,
                sourceProfileID: host.activeProfileID(),
                sourceTabID: tabID,
                source: .mediaRadarHLS,
                transportKind: .hlsRemuxMP4,
                phase: .queued,
                sourceURL: targetURL,
                resolvedURL: targetURL,
                pageURL: pageURL,
                filename: mp4Filename,
                mimeType: "video/mp4",
                receivedBytes: 0,
                totalBytes: nil,
                estimatedTotalBytes: nil,
                completedSegments: 0,
                totalSegments: nil,
                configuredLanes: CuriumTransferRecord.defaultLanes,
                activeLanes: 0,
                hlsCheckpoint: checkpoint,
                stagingDirectoryName: transferID,
                stagingFileName: mp4Filename,
                userAgent: context.userAgent,
                referer: Self.safeRefererString(from: context.referrer, targetURL: targetURL),
                origin: context.origin,
                includeTabCookies: true
            )

        case .video, .audio:
            // Intentionally ignore Blink's subresource chunk `candidate.contentLength` (often a small
            // 206 range response slice); CuriumRangeTransferEngine.probe discovers the true file size.
            masterURL = nil
            let safeName = CuriumDownloadStorage.sanitizedFilename(
                candidate.suggestedFilename,
                fallback: candidate.kind == .audio ? "Audio.m4a" : "Video.mp4"
            )
            record = CuriumTransferRecord(
                id: transferID,
                sourceProfileID: host.activeProfileID(),
                sourceTabID: tabID,
                source: .mediaRadarDirect,
                transportKind: .multiLaneRange,
                phase: .queued,
                sourceURL: targetURL,
                resolvedURL: nil,
                pageURL: pageURL,
                filename: safeName,
                mimeType: candidate.mimeType,
                receivedBytes: 0,
                totalBytes: nil,
                configuredLanes: CuriumTransferRecord.defaultLanes,
                activeLanes: 0,
                stagingDirectoryName: transferID,
                stagingFileName: "\(safeName).part",
                userAgent: context.userAgent,
                referer: Self.safeRefererString(from: context.referrer, targetURL: targetURL),
                origin: context.origin,
                includeTabCookies: true
            )

        case .dash:
            return nil
        }

        if let cookie = context.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty {
            transientCookiesByID[transferID] = cookie
        }

        let item = CuriumDownload(record: record, hlsMasterPlaylistURL: masterURL)
        wireItemCallbacks(item)
        itemsByID[transferID] = item
        recordsByID[transferID] = record
        host.insertDownload(item, true)
        persistImmediate(record)
        pumpQueue()
        return item
    }

    // MARK: - Source 4: Manual `+ New Download`

    @discardableResult
    func startManualDownload(
        url: URL,
        suggestedFilename: String?,
        lanes: Int,
        includeActiveTabCookies: Bool,
        activeTabID: String?,
        activeTabURL: URL?,
        activeTabUserAgent: String?
    ) async -> CuriumDownload? {
        guard CuriumHLSParser.isAllowedHTTPURL(url) else {
            return nil
        }

        let isHLS = Self.isLikelyHLSURL(url)
        let trimmedCustomName = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCustomName = (trimmedCustomName?.isEmpty == false)
        let derivedRawName: String = {
            if let custom = trimmedCustomName, !custom.isEmpty {
                return custom
            }
            let lastComp = url.lastPathComponent
            if !lastComp.isEmpty, lastComp != "/" {
                return lastComp
            }
            return isHLS ? "Video.mp4" : "Download"
        }()

        let filename: String = isHLS
            ? Self.ensureMP4Extension(CuriumDownloadStorage.sanitizedFilename(derivedRawName, fallback: "Video.mp4"))
            : CuriumDownloadStorage.sanitizedFilename(derivedRawName, fallback: "Download")

        let clampedLanes = CuriumTransferRecord.clampLanes(lanes)
        let transferID = UUID().uuidString

        var cookieHeader: String?
        var referer: String?
        var origin: String?
        var userAgent: String?
        var sourceTabID: String?

        if includeActiveTabCookies {
            sourceTabID = activeTabID
            userAgent = activeTabUserAgent
            if let tabURL = activeTabURL, CuriumHLSParser.isAllowedHTTPURL(tabURL) {
                referer = Self.safeRefererString(from: tabURL, targetURL: url)
                if !CrossOriginRedirectAuthStripper.isHTTPSDowngrade(from: tabURL, to: url) {
                    origin = Self.originString(for: tabURL)
                }
            }
            if let activeTabID {
                cookieHeader = await host.resolveCookieHeader(url, activeTabID)
            }
        }

        let record: CuriumTransferRecord
        if isHLS {
            let checkpoint = CuriumHLSCheckpoint(playlistURL: url)
            record = CuriumTransferRecord(
                id: transferID,
                sourceProfileID: host.activeProfileID(),
                sourceTabID: sourceTabID,
                source: .manualURL,
                transportKind: .hlsRemuxMP4,
                phase: .queued,
                sourceURL: url,
                resolvedURL: url,
                pageURL: nil, // Manual URLs explicitly typed by the user must never be SSRF-blocked by an unrelated tab.
                filename: filename,
                mimeType: "video/mp4",
                configuredLanes: clampedLanes,
                hlsCheckpoint: checkpoint,
                stagingDirectoryName: transferID,
                stagingFileName: filename,
                userAgent: userAgent,
                referer: referer,
                origin: origin,
                includeTabCookies: includeActiveTabCookies
            )
        } else {
            record = CuriumTransferRecord(
                id: transferID,
                sourceProfileID: host.activeProfileID(),
                sourceTabID: sourceTabID,
                source: .manualURL,
                transportKind: clampedLanes > 1 ? .multiLaneRange : .singleStream,
                phase: .queued,
                sourceURL: url,
                resolvedURL: nil,
                pageURL: nil,
                filename: filename,
                mimeType: nil,
                configuredLanes: clampedLanes,
                stagingDirectoryName: transferID,
                stagingFileName: "\(filename).part",
                userAgent: userAgent,
                referer: referer,
                origin: origin,
                includeTabCookies: includeActiveTabCookies
            )
        }

        if hasCustomName {
            customFilenameTransferIDs.insert(transferID)
        }
        if let cookie = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty {
            transientCookiesByID[transferID] = cookie
        }

        let item = CuriumDownload(record: record)
        wireItemCallbacks(item)
        itemsByID[transferID] = item
        recordsByID[transferID] = record
        host.insertDownload(item, true)
        persistImmediate(record)
        pumpQueue()
        return item
    }

    // MARK: - User Actions: Pause / Resume / Retry / Cancel / Remove

    func pauseDownload(_ item: CuriumDownload) {
        guard item.isManagedByCoordinator else { return }
        guard item.canPause else { return }

        if item.phase == .queued, runningTasksByID[item.id] == nil {
            let elapsed = metersByID[item.id]?.elapsedSeconds ?? item.elapsedSeconds
            metersByID[item.id]?.markPaused()
            item.markPaused(elapsedSeconds: elapsed)
            if var record = recordsByID[item.id] {
                record.phase = .paused
                record.activeLanes = 0
                record.activeDurationSeconds = elapsed
                record.updatedAt = Date()
                recordsByID[item.id] = record
                persistImmediate(record)
            }
            host.syncBackgroundKeepAlive()
            return
        }

        stopIntentsByID[item.id] = .pause
        metersByID[item.id]?.markPaused()
        runningTasksByID[item.id]?.cancel()
        blinkPollTasksByID.removeValue(forKey: item.id)?.cancel()
    }

    func resumeDownload(_ item: CuriumDownload) {
        guard item.isManagedByCoordinator else { return }
        if item.phase == .failed {
            retryDownload(item)
            return
        }
        guard item.canResume else { return }

        stopIntentsByID.removeValue(forKey: item.id)
        if let meter = metersByID[item.id] {
            meter.resetForResume(currentBytes: item.receivedBytes)
        } else {
            metersByID[item.id] = CuriumThroughputMeter(
                initialBytes: item.receivedBytes,
                priorElapsedSeconds: item.elapsedSeconds,
                priorPeakSpeedBytesPerSec: item.peakSpeedBytesPerSec,
                priorSamples: item.throughputSamples
            )
        }

        item.setPhase(.queued)
        if var record = recordsByID[item.id] {
            // Re-promote replayable Blink downloads paused across relaunch onto Range or HLS transport.
            if record.transportKind == .blinkNativeStream {
                let target = record.resolvedURL ?? record.sourceURL
                record.transportKind = target.map(Self.isLikelyHLSURL) == true ? .hlsRemuxMP4 : .multiLaneRange
                item.updateMetadata(transportKind: record.transportKind)
            }
            record.phase = .queued
            record.failureMessage = nil
            record.updatedAt = Date()
            recordsByID[item.id] = record
            persistImmediate(record)
        }
        pumpQueue()
    }

    func retryDownload(_ item: CuriumDownload) {
        guard item.isManagedByCoordinator else { return }
        guard item.canRetry || item.canResume else { return }

        let wasCancelled = (item.phase == .cancelled)
        stopIntentsByID.removeValue(forKey: item.id)

        if var record = recordsByID[item.id] {
            let stagingDir = try? resolvedStagingDirectory(named: record.stagingDirectoryName)
            let hasReusableStaging: Bool = {
                guard !wasCancelled, let stagingDir else { return false }
                if record.transportKind == .hlsRemuxMP4 {
                    if preStagedCompleteHLSFileURL(for: record, in: stagingDir) != nil {
                        return true
                    }
                    let videoPart = stagingDir.appending(path: "video.part", directoryHint: .notDirectory)
                    return FileManager.default.fileExists(atPath: videoPart.path)
                }
                let stagedFile = stagingDir.appending(path: record.stagingFileName, directoryHint: .notDirectory)
                return FileManager.default.fileExists(atPath: stagedFile.path) && !record.slices.isEmpty
            }()

            if !hasReusableStaging {
                record.receivedBytes = 0
                record.slices = []
                record.completedSegments = 0
                record.totalSegments = nil
                record.estimatedTotalBytes = nil
                if var cp = record.hlsCheckpoint {
                    cp.completedSegments = 0
                    cp.contiguousByteOffset = 0
                    cp.audioCompletedSegments = 0
                    cp.audioContiguousByteOffset = 0
                    record.hlsCheckpoint = cp
                }
                item.resetProgressForFreshRestart()
                metersByID[item.id] = CuriumThroughputMeter()
            } else {
                metersByID[item.id] = CuriumThroughputMeter(
                    initialBytes: record.receivedBytes,
                    priorElapsedSeconds: record.activeDurationSeconds ?? item.elapsedSeconds,
                    priorPeakSpeedBytesPerSec: record.peakSpeedBytesPerSec ?? item.peakSpeedBytesPerSec,
                    priorSamples: item.throughputSamples
                )
            }

            // Re-promote non-Blink replayable retries onto Range or HLS transport.
            if record.transportKind == .blinkNativeStream {
                let target = record.resolvedURL ?? record.sourceURL
                record.transportKind = target.map(Self.isLikelyHLSURL) == true ? .hlsRemuxMP4 : .multiLaneRange
                item.updateMetadata(transportKind: record.transportKind)
            }

            record.phase = .queued
            record.failureMessage = nil
            record.completedAt = nil
            record.savedBookmarkPath = nil
            record.updatedAt = Date()
            recordsByID[item.id] = record
            item.setPhase(.queued)
            persistImmediate(record)
            pumpQueue()
        }
    }

    func cancelDownload(_ item: CuriumDownload) {
        if !item.isManagedByCoordinator {
            item.cancel()
            return
        }

        guard !item.phase.isTerminal else { return }

        stopIntentsByID[item.id] = .cancel
        transientCookiesByID.removeValue(forKey: item.id)
        blinkPollTasksByID.removeValue(forKey: item.id)?.cancel()
        activeCommitTasksByID[item.id]?.cancel()

        if let blinkTask = item.blinkTask {
            blinkTask.cancel()
            item.detachBlinkTask()
        }

        if let running = runningTasksByID[item.id] {
            running.cancel()
            // Reflect cancellation immediately so callers observe `.cancelled` without waiting a hop.
            let elapsed = metersByID[item.id]?.elapsedSeconds ?? item.elapsedSeconds
            item.markCancelled(elapsedSeconds: elapsed)
            if var record = recordsByID[item.id] {
                record.phase = .cancelled
                record.activeLanes = 0
                record.failureMessage = nil
                record.updatedAt = Date()
                recordsByID[item.id] = record
                persistImmediate(record)
            }
            host.syncBackgroundKeepAlive()
            return
        }

        // Not currently running (`.pendingConfirmation`, `.queued`, or `.paused`).
        let elapsed = metersByID[item.id]?.elapsedSeconds ?? item.elapsedSeconds
        metersByID.removeValue(forKey: item.id)
        item.markCancelled(elapsedSeconds: elapsed)
        if var record = recordsByID[item.id] {
            cleanupStagingDirectory(named: record.stagingDirectoryName)
            record.phase = .cancelled
            record.activeLanes = 0
            record.slices = []
            record.failureMessage = nil
            record.updatedAt = Date()
            recordsByID[item.id] = record
            persistImmediate(record)
        }
        host.syncBackgroundKeepAlive()
        pumpQueue()
    }

    func removeTransfer(_ item: CuriumDownload) {
        if item.isActive || item.phase == .queued || item.phase == .pendingConfirmation {
            cancelDownload(item)
        } else if let record = recordsByID[item.id], record.phase != .completed {
            cleanupStagingDirectory(named: record.stagingDirectoryName)
        }

        let id = item.id
        transientCookiesByID.removeValue(forKey: id)
        customFilenameTransferIDs.remove(id)
        metersByID.removeValue(forKey: id)
        stopIntentsByID.removeValue(forKey: id)
        itemsByID.removeValue(forKey: id)
        recordsByID.removeValue(forKey: id)
        host.removeDownload(id)
        if let store = transferStore {
            Task { await store.delete(id: id) }
        }
        host.syncBackgroundKeepAlive()
    }

    func pruneFinishedTransfers(ids: [String]) {
        for id in ids {
            if let record = recordsByID[id], record.phase != .completed {
                cleanupStagingDirectory(named: record.stagingDirectoryName)
            }
            transientCookiesByID.removeValue(forKey: id)
            customFilenameTransferIDs.remove(id)
            metersByID.removeValue(forKey: id)
            stopIntentsByID.removeValue(forKey: id)
            itemsByID.removeValue(forKey: id)
            recordsByID.removeValue(forKey: id)
            if let store = transferStore {
                Task { await store.delete(id: id) }
            }
        }
    }

    func handleSavedFileDeleted(matchingDownloadIDs ids: [String]) {
        for id in ids {
            if var record = recordsByID[id] {
                record.savedBookmarkPath = nil
                recordsByID[id] = record
            }
            if let store = transferStore {
                Task { await store.delete(id: id) }
            }
        }
    }

    // MARK: - Profile Switch Relaunch & Background Checkpointing

    /// Pauses all queued/active transfers cleanly (flushing staging files and persisting
    /// exact slice/segment checkpoints) and truncates the SQLite WAL before relaunch.
    func pauseAllActiveTransfersForRelaunch() async {
        let allItems = host.allDownloads()
        var tasksToAwait: [Task<Void, Never>] = []

        for item in allItems {
            guard item.isManagedByCoordinator else {
                if item.isActive {
                    item.cancel()
                }
                continue
            }

            switch item.phase {
            case .queued:
                if let running = runningTasksByID[item.id] {
                    stopIntentsByID[item.id] = .pause
                    running.cancel()
                    tasksToAwait.append(running)
                } else {
                    let elapsed = metersByID[item.id]?.elapsedSeconds ?? item.elapsedSeconds
                    metersByID[item.id]?.markPaused()
                    item.markPaused(elapsedSeconds: elapsed)
                    if var record = recordsByID[item.id] {
                        record.phase = .paused
                        record.activeLanes = 0
                        record.activeDurationSeconds = elapsed
                        record.updatedAt = Date()
                        recordsByID[item.id] = record
                        if let store = transferStore {
                            await store.upsert(record)
                        }
                    }
                }

            case .probing, .downloading, .remuxing:
                // Pause instead of cancel so multi-lane Range, HLS, and GET downloads resume after relaunch.
                let canPreserveAsPaused = item.canPause
                    || (item.httpMethod == "GET" && (item.resolvedURL ?? item.originalURL).map(CuriumHLSParser.isAllowedHTTPURL) == true)
                stopIntentsByID[item.id] = canPreserveAsPaused ? .pause : .cancel
                metersByID[item.id]?.markPaused()
                blinkPollTasksByID.removeValue(forKey: item.id)?.cancel()
                if let blinkTask = item.blinkTask {
                    blinkTask.cancel()
                    item.detachBlinkTask()
                }
                if let running = runningTasksByID[item.id] {
                    running.cancel()
                    tasksToAwait.append(running)
                } else if canPreserveAsPaused {
                    let elapsed = metersByID[item.id]?.elapsedSeconds ?? item.elapsedSeconds
                    item.markPaused(elapsedSeconds: elapsed)
                    if var record = recordsByID[item.id] {
                        record.phase = .paused
                        record.activeLanes = 0
                        record.activeDurationSeconds = elapsed
                        record.updatedAt = Date()
                        recordsByID[item.id] = record
                        if let store = transferStore {
                            await store.upsert(record)
                        }
                    }
                }

            case .saving:
                // Allow an in-flight atomic commit to finish cleanly before relaunching.
                if let running = runningTasksByID[item.id] {
                    tasksToAwait.append(running)
                }

            case .pendingConfirmation, .paused, .completed, .failed, .cancelled:
                break
            }
        }

        for task in tasksToAwait {
            await task.value
        }

        // Persist all paused records synchronously before WAL truncation.
        if let store = transferStore {
            for record in recordsByID.values where record.phase == .paused {
                await store.upsert(record)
            }
            _ = await store.checkpointTruncate()
        }
        host.syncBackgroundKeepAlive()
    }

    func checkpointStoreForBackground() {
        guard let store = transferStore else { return }
        let bgID = UIApplication.shared.beginBackgroundTask(withName: "Curium.TransferCoordinator.WALCheckpoint")
        Task.detached(priority: .userInitiated) {
            _ = await store.checkpointTruncate()
            if bgID != .invalid {
                await MainActor.run {
                    UIApplication.shared.endBackgroundTask(bgID)
                }
            }
        }
    }

    // MARK: - Queue Scheduler

    private func pumpQueue() {
        var activeSlots = runningTasksByID.count
        guard activeSlots < Self.maxConcurrentTransfers else { return }

        // FIFO: `downloads` inserts newest at index 0, so iterate in reverse for oldest queued first.
        let candidates = host.allDownloads().reversed().filter {
            $0.isManagedByCoordinator && $0.phase == .queued && runningTasksByID[$0.id] == nil
        }

        for item in candidates {
            guard activeSlots < Self.maxConcurrentTransfers else { break }
            _ = launchManagedTransferTask(for: item)
            activeSlots += 1
        }
    }

    @discardableResult
    private func launchManagedTransferTask(for item: CuriumDownload) -> Task<Void, Never> {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeManagedTransfer(item)
        }
        runningTasksByID[item.id] = task
        return task
    }

    // MARK: - Execution: Source 1 (Non-Destructive Blink Probe-Before-Cancel vs BlinkNativeRunner)

    private func executeBlinkDownload(_ item: CuriumDownload) async {
        let id = item.id
        defer {
            blinkPollTasksByID.removeValue(forKey: id)?.cancel()
            activeCommitTasksByID.removeValue(forKey: id)
            runningTasksByID.removeValue(forKey: id)
            stopIntentsByID.removeValue(forKey: id)
            host.syncBackgroundKeepAlive()
            pumpQueue()
        }

        guard let blinkTask = item.blinkTask else {
            await executeManagedTransfer(item)
            return
        }

        let initialTotal = blinkTask.totalBytes
        let threshold = environment.rangeConfiguration.multiLaneThresholdBytes
        let isTinyKnownFile = initialTotal > 0 && initialTotal < threshold
        let canConsiderRangeUpgrade = item.httpMethod == "GET"
            && !isTinyKnownFile
            && item.originalURL.map(CuriumHLSParser.isAllowedHTTPURL) == true

        if canConsiderRangeUpgrade, let url = item.originalURL {
            item.setPhase(.probing)
            if var record = recordsByID[id] {
                record.phase = .probing
                record.updatedAt = Date()
                recordsByID[id] = record
                persistImmediate(record)
            }

            let proxy = host.effectiveProxy()
            let tabCtx = host.tabContext(item.sourceTabID)
            let pageURL = tabCtx.pageURL ?? item.pageURL
            let initialCookie = await host.resolveCookieHeader(url, item.sourceTabID)
            let headers = buildHTTPHeaders(
                userAgent: tabCtx.userAgent,
                referer: Self.safeRefererString(from: pageURL, targetURL: url),
                origin: Self.originString(for: pageURL),
                cookie: initialCookie
            )
            let cookieResolver = makeCookieResolver(
                transferID: id,
                sourceTabID: item.sourceTabID,
                includeTabCookies: true,
                primaryURL: url
            )

            let probeResult = try? await environment.rangeEngine.probe(
                url: url,
                headers: headers,
                proxy: proxy,
                originatingURL: pageURL,
                cookieResolver: cookieResolver,
                timeoutSeconds: environment.rangeConfiguration.probeTimeoutSeconds
            )

            // Honor user cancel/pause that arrived while probing.
            if let intent = stopIntentsByID[id] ?? (Task.isCancelled ? .cancel : nil) {
                if intent == .pause {
                    blinkTask.cancel()
                    item.detachBlinkTask()
                    handlePausedOutcome(for: item, meter: metersByID[id])
                } else {
                    blinkTask.cancel()
                    item.detachBlinkTask()
                    handleCancelledOutcome(for: item, meter: metersByID[id])
                }
                return
            }

            // ONLY cancel the parked Blink task when probe proves 206 byte ranges >= 512 KiB & non-HTML!
            if let probe = probeResult,
               probe.statusCode == 206,
               probe.supportsByteRanges,
               let probedTotal = probe.totalBytes,
               probedTotal >= threshold,
               !probe.isHTMLResponse {
                blinkTask.cancel()
                item.detachBlinkTask()

                if let cookie = initialCookie, !cookie.isEmpty {
                    transientCookiesByID[id] = cookie
                }

                let upgradedFilename: String = {
                    if item.filename == "Download", let probedName = probe.suggestedFilename, !probedName.isEmpty {
                        return probedName
                    }
                    return item.filename
                }()
                let upgradedMime = (item.mimeType == nil || item.mimeType == "application/octet-stream")
                    ? (probe.mimeType ?? item.mimeType)
                    : item.mimeType

                item.updateMetadata(
                    filename: upgradedFilename,
                    mimeType: upgradedMime,
                    resolvedURL: probe.finalURL,
                    eTag: probe.eTag,
                    transportKind: .multiLaneRange,
                    configuredLanes: CuriumTransferRecord.defaultLanes
                )

                if var record = recordsByID[id] {
                    record.transportKind = .multiLaneRange
                    record.resolvedURL = probe.finalURL
                    record.eTag = probe.eTag
                    record.lastModified = probe.lastModified
                    record.totalBytes = probedTotal
                    record.filename = upgradedFilename
                    record.mimeType = upgradedMime
                    record.stagingFileName = "\(upgradedFilename).part"
                    record.userAgent = tabCtx.userAgent
                    record.referer = Self.safeRefererString(from: pageURL, targetURL: probe.finalURL)
                    record.origin = Self.originString(for: pageURL)
                    record.updatedAt = Date()
                    recordsByID[id] = record
                }

                await executeRangeTransfer(
                    item,
                    preProbed: probe
                )
                return
            }
            // Otherwise: non-destructive fallback! The parked `blinkTask` was never cancelled.
        }

        await executeBlinkNativeRunner(item, blinkTask: blinkTask)
    }

    private func executeBlinkNativeRunner(_ item: CuriumDownload, blinkTask: any CrIOSDownloadTaskV1) async {
        let id = item.id
        let stagingDirName = recordsByID[id]?.stagingDirectoryName ?? id
        let meter = ensureMeter(for: item)

        item.updateMetadata(transportKind: .blinkNativeStream, configuredLanes: 1)
        item.setPhase(.downloading)
        if var record = recordsByID[id] {
            record.transportKind = .blinkNativeStream
            record.configuredLanes = 1
            record.activeLanes = 1
            record.phase = .downloading
            record.updatedAt = Date()
            recordsByID[id] = record
            persistImmediate(record)
        }

        do {
            let stagingDir = try resolvedStagingDirectory(named: stagingDirName)
            let stagedFileURL = stagingDir.appending(
                path: CuriumDownloadStorage.sanitizedFilename(item.filename),
                directoryHint: .notDirectory
            )

            // 200ms coordinator-owned polling loop so telemetry updates even when banner/sheet are closed.
            let pollTask = Task { @MainActor [weak self, weak item] in
                while !Task.isCancelled {
                    guard let self, let item, item.phase == .downloading else { break }
                    self.sampleBlinkTaskTelemetry(item: item, blinkTask: blinkTask, meter: meter, force: false)
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        break
                    }
                }
            }
            blinkPollTasksByID[id] = pollTask

            let downloadedURL = try await blinkTask.start(withDestinationURL: stagedFileURL)
            pollTask.cancel()
            blinkPollTasksByID.removeValue(forKey: id)
            item.detachBlinkTask()

            if let intent = stopIntentsByID[id] ?? (Task.isCancelled ? .cancel : nil) {
                if intent == .pause {
                    handlePausedOutcome(for: item, meter: meter)
                } else {
                    handleCancelledOutcome(for: item, meter: meter)
                }
                return
            }

            // Emit final byte/speed reading from Blink task (or staged file size if task didn't report).
            sampleBlinkTaskTelemetry(
                item: item,
                blinkTask: blinkTask,
                meter: meter,
                fallbackStagedURL: downloadedURL,
                force: true
            )

            let preferredName = downloadedURL.lastPathComponent.isEmpty
                ? item.filename
                : downloadedURL.lastPathComponent

            await commitAndComplete(
                item: item,
                stagedFileURL: downloadedURL,
                preferredFilename: preferredName,
                finalByteCountHint: item.knownTotalBytes ?? max(item.receivedBytes, Self.fileSize(at: downloadedURL) ?? 0),
                meter: meter
            )
        } catch is CancellationError {
            blinkPollTasksByID.removeValue(forKey: id)?.cancel()
            item.detachBlinkTask()
            if stopIntentsByID[id] == .pause {
                handlePausedOutcome(for: item, meter: meter)
            } else {
                handleCancelledOutcome(for: item, meter: meter)
            }
        } catch {
            blinkPollTasksByID.removeValue(forKey: id)?.cancel()
            item.detachBlinkTask()
            if stopIntentsByID[id] == .pause {
                handlePausedOutcome(for: item, meter: meter)
            } else if stopIntentsByID[id] == .cancel || blinkTask.state == .cancelled {
                handleCancelledOutcome(for: item, meter: meter)
            } else {
                handleFailedOutcome(for: item, message: error.localizedDescription, meter: meter)
            }
        }
    }

    private func sampleBlinkTaskTelemetry(
        item: CuriumDownload,
        blinkTask: any CrIOSDownloadTaskV1,
        meter: CuriumThroughputMeter,
        fallbackStagedURL: URL? = nil,
        force: Bool
    ) {
        var received = max(0, blinkTask.receivedBytes)
        let rawTotal = blinkTask.totalBytes
        var knownTotal: Int64? = rawTotal > 0 ? rawTotal : nil

        if received == 0, let fallbackStagedURL, let diskSize = Self.fileSize(at: fallbackStagedURL), diskSize > 0 {
            received = diskSize
            if knownTotal == nil { knownTotal = diskSize }
        }

        let snapshot = meter.record(totalBytesNow: received, minTickInterval: 0.18, force: force)
        let speed = snapshot?.speedBytesPerSec ?? meter.speedBytesPerSec
        let peak = snapshot?.peakSpeedBytesPerSec ?? meter.peakSpeedBytesPerSec
        let samples = snapshot?.samples ?? meter.samples
        let elapsed = snapshot?.elapsedSeconds ?? meter.elapsedSeconds
        let remaining = knownTotal.map { max(0, $0 - received) }
        let eta = meter.etaSeconds(remainingBytes: remaining)

        item.updateBlinkTelemetry(
            receivedBytes: received,
            knownTotalBytes: knownTotal,
            speedBytesPerSec: speed,
            peakSpeedBytesPerSec: peak,
            throughputSamples: samples,
            etaSeconds: eta,
            elapsedSeconds: elapsed
        )

        if var record = recordsByID[item.id] {
            record.receivedBytes = received
            record.totalBytes = knownTotal
            record.activeLanes = 1
            record.activeDurationSeconds = elapsed
            record.peakSpeedBytesPerSec = peak
            record.updatedAt = Date()
            recordsByID[item.id] = record
            if snapshot?.shouldPersist == true || force {
                persistThrottled(record, force: force)
            }
        }
    }

    // MARK: - Execution: Range & HLS Managed Transfers

    private func executeManagedTransfer(_ item: CuriumDownload) async {
        let id = item.id
        defer {
            activeCommitTasksByID.removeValue(forKey: id)
            runningTasksByID.removeValue(forKey: id)
            stopIntentsByID.removeValue(forKey: id)
            host.syncBackgroundKeepAlive()
            pumpQueue()
        }

        guard let record = recordsByID[id] else { return }

        if record.transportKind == .hlsRemuxMP4 || record.source == .mediaRadarHLS {
            await executeHLSTransfer(item)
        } else {
            await executeRangeTransfer(item, preProbed: nil)
        }
    }

    private func executeRangeTransfer(
        _ item: CuriumDownload,
        preProbed: CuriumRangeProbeResult?
    ) async {
        let id = item.id
        guard var record = recordsByID[id],
              let targetURL = record.resolvedURL ?? record.sourceURL else {
            handleFailedOutcome(for: item, message: "Missing transfer URL.", meter: metersByID[id])
            return
        }

        let meter = ensureMeter(for: item)
        let latestBox = LatestRangeSnapshotBox()

        do {
            let stagingDir = try resolvedStagingDirectory(named: record.stagingDirectoryName)
            let stagedPathCandidate = stagingDir.appending(path: record.stagingFileName, directoryHint: .notDirectory)

            // Fast-path: transfer was interrupted during `.saving` after all slices already completed on disk.
            if preProbed == nil,
               let total = record.totalBytes,
               total > 0,
               !record.slices.isEmpty,
               record.slices.allSatisfy(\.isComplete),
               CuriumSliceCoordinator.isValidResumePartition(record.slices, totalBytes: total),
               let diskSize = Self.fileSize(at: stagedPathCandidate),
               diskSize == total {
                await commitAndComplete(
                    item: item,
                    stagedFileURL: stagedPathCandidate,
                    preferredFilename: record.filename,
                    finalByteCountHint: total,
                    meter: meter
                )
                return
            }

            let proxy = host.effectiveProxy()
            let cookieResolver = makeCookieResolver(
                transferID: id,
                sourceTabID: record.sourceTabID,
                includeTabCookies: record.includeTabCookies,
                primaryURL: targetURL
            )

            var initialCookie = transientCookiesByID[id]
            if initialCookie == nil && record.includeTabCookies {
                if let resolved = await host.resolveCookieHeader(targetURL, record.sourceTabID), !resolved.isEmpty {
                    transientCookiesByID[id] = resolved
                    initialCookie = resolved
                }
            }

            let baseHeaders = buildHTTPHeaders(
                userAgent: record.userAgent,
                referer: record.referer,
                origin: record.origin,
                cookie: initialCookie
            )

            var downloadURL = targetURL
            var knownTotal = record.totalBytes
            var supportsRangesHint: Bool?
            var existingSlices: [CuriumByteRangeSlice]?
            var ifRangeValidator = record.ifRangeValidator

            let hasValidResumeState: Bool = {
                guard let total = record.totalBytes,
                      total >= environment.rangeConfiguration.multiLaneThresholdBytes,
                      !record.slices.isEmpty,
                      CuriumSliceCoordinator.isValidResumePartition(record.slices, totalBytes: total),
                      let diskSize = Self.fileSize(at: stagedPathCandidate),
                      diskSize >= total else {
                    return false
                }
                return true
            }()

            if let preProbed {
                downloadURL = preProbed.finalURL
                knownTotal = preProbed.totalBytes
                supportsRangesHint = preProbed.supportsByteRanges
                ifRangeValidator = preProbed.ifRangeValidator ?? ifRangeValidator
            } else if hasValidResumeState {
                supportsRangesHint = true
                existingSlices = record.slices
            } else {
                // Restarting from byte 0: reset throughput meter and prior byte counters so speed never freezes at 0 B/s.
                if record.receivedBytes > 0 || item.receivedBytes > 0 || !record.slices.isEmpty {
                    meter.resetForResume(currentBytes: 0)
                    record.receivedBytes = 0
                    record.slices = []
                    item.resetBytesForFreshRestart()
                }
                item.setPhase(.probing)
                record.phase = .probing
                record.updatedAt = Date()
                recordsByID[id] = record
                persistImmediate(record)

                let probed = try await environment.rangeEngine.probe(
                    url: targetURL,
                    headers: baseHeaders,
                    proxy: proxy,
                    originatingURL: record.pageURL,
                    cookieResolver: cookieResolver,
                    timeoutSeconds: environment.rangeConfiguration.probeTimeoutSeconds
                )

                try Task.checkCancellation()

                downloadURL = probed.finalURL
                knownTotal = probed.totalBytes
                supportsRangesHint = probed.supportsByteRanges
                ifRangeValidator = probed.ifRangeValidator

                var updatedFilename = record.filename
                if !customFilenameTransferIDs.contains(id),
                   (record.source == .manualURL || record.filename == "Download"),
                   let suggested = probed.suggestedFilename,
                   !suggested.isEmpty {
                    updatedFilename = CuriumDownloadStorage.sanitizedFilename(suggested)
                }

                let useMultiLane = probed.supportsByteRanges
                    && (probed.totalBytes ?? 0) >= environment.rangeConfiguration.multiLaneThresholdBytes
                    && record.configuredLanes > 1

                record.resolvedURL = probed.finalURL
                record.eTag = probed.eTag
                record.lastModified = probed.lastModified
                record.totalBytes = probed.totalBytes
                record.filename = updatedFilename
                record.stagingFileName = "\(updatedFilename).part"
                if let probedMime = probed.mimeType,
                   record.mimeType == nil || record.mimeType == "application/octet-stream" {
                    record.mimeType = probedMime
                }
                record.transportKind = useMultiLane ? .multiLaneRange : .singleStream
                record.updatedAt = Date()
                recordsByID[id] = record

                item.updateMetadata(
                    filename: record.filename,
                    mimeType: record.mimeType,
                    resolvedURL: record.resolvedURL,
                    eTag: record.eTag,
                    transportKind: record.transportKind,
                    configuredLanes: useMultiLane ? record.configuredLanes : 1
                )
            }

            let stagedFileURL = stagingDir.appending(path: record.stagingFileName, directoryHint: .notDirectory)
            var config = environment.rangeConfiguration
            config.maxLanes = record.configuredLanes
            config.restartOnRemoteModification = true

            let isMultiLaneRun = (supportsRangesHint == true)
                && (knownTotal ?? 0) >= config.multiLaneThresholdBytes
                && config.maxLanes > 1
            record.transportKind = isMultiLaneRun ? .multiLaneRange : .singleStream
            record.phase = .downloading
            record.updatedAt = Date()
            recordsByID[id] = record
            item.updateMetadata(
                transportKind: record.transportKind,
                configuredLanes: isMultiLaneRun ? record.configuredLanes : 1
            )
            item.setPhase(.downloading)
            persistImmediate(record)

            let finalUpdate = try await environment.rangeEngine.download(
                url: downloadURL,
                headers: baseHeaders,
                destinationURL: stagedFileURL,
                proxy: proxy,
                originatingURL: record.pageURL,
                knownTotalBytes: knownTotal,
                supportsRangesHint: supportsRangesHint,
                existingSlices: existingSlices,
                ifRangeValidator: ifRangeValidator,
                cookieResolver: cookieResolver,
                configuration: config,
                onProgress: { [weak self, weak item] update in
                    latestBox.store(update)
                    Task { @MainActor [weak self, weak item] in
                        guard let self, let item, item.phase == .downloading else { return }
                        self.applyRangeProgressUpdate(update, to: item, meter: meter, force: false)
                    }
                }
            )

            latestBox.store(finalUpdate)
            applyRangeProgressUpdate(finalUpdate, to: item, meter: meter, force: true)

            if let intent = stopIntentsByID[id] ?? (Task.isCancelled ? .cancel : nil) {
                if intent == .pause {
                    handlePausedRangeOutcome(for: item, latest: latestBox.latest, meter: meter)
                } else {
                    handleCancelledOutcome(for: item, meter: meter)
                }
                return
            }

            let finalBytes = finalUpdate.totalBytes ?? finalUpdate.receivedBytes
            let preferredName = recordsByID[id]?.filename ?? item.filename
            await commitAndComplete(
                item: item,
                stagedFileURL: stagedFileURL,
                preferredFilename: preferredName,
                finalByteCountHint: finalBytes,
                meter: meter
            )
        } catch is CancellationError {
            if stopIntentsByID[id] == .pause {
                handlePausedRangeOutcome(for: item, latest: latestBox.latest, meter: meter)
            } else {
                handleCancelledOutcome(for: item, meter: meter)
            }
        } catch {
            if stopIntentsByID[id] == .pause {
                handlePausedRangeOutcome(for: item, latest: latestBox.latest, meter: meter)
            } else if stopIntentsByID[id] == .cancel {
                handleCancelledOutcome(for: item, meter: meter)
            } else {
                if let latest = latestBox.latest {
                    syncPausedRangeSlices(latest, transferID: id, item: item)
                }
                handleFailedOutcome(for: item, message: error.localizedDescription, meter: meter)
            }
        }
    }

    private func applyRangeProgressUpdate(
        _ update: CuriumRangeProgressUpdate,
        to item: CuriumDownload,
        meter: CuriumThroughputMeter,
        force: Bool
    ) {
        if update.receivedBytes < item.receivedBytes {
            meter.resetForResume(currentBytes: 0)
        }
        let snap = meter.record(totalBytesNow: update.receivedBytes, force: force)
        let speed = snap?.speedBytesPerSec ?? meter.speedBytesPerSec
        let peak = snap?.peakSpeedBytesPerSec ?? meter.peakSpeedBytesPerSec
        let samples = snap?.samples ?? meter.samples
        let elapsed = snap?.elapsedSeconds ?? meter.elapsedSeconds
        let remaining = update.totalBytes.map { max(0, $0 - update.receivedBytes) }
        let eta = meter.etaSeconds(remainingBytes: remaining)

        item.updateRangeTelemetry(
            receivedBytes: update.receivedBytes,
            knownTotalBytes: update.totalBytes,
            slices: update.slices,
            activeLanes: update.activeLanes,
            speedBytesPerSec: speed,
            peakSpeedBytesPerSec: peak,
            throughputSamples: samples,
            etaSeconds: eta,
            elapsedSeconds: elapsed
        )

        if var record = recordsByID[item.id] {
            record.receivedBytes = update.receivedBytes
            record.totalBytes = update.totalBytes
            record.activeLanes = update.activeLanes
            record.slices = update.slices
            record.activeDurationSeconds = elapsed
            record.peakSpeedBytesPerSec = peak
            record.updatedAt = Date()
            recordsByID[item.id] = record
            if snap?.shouldPersist == true || force {
                persistThrottled(record, force: force)
            }
        }
    }

    private func syncPausedRangeSlices(
        _ latest: CuriumRangeProgressUpdate,
        transferID: String,
        item: CuriumDownload
    ) {
        let inactiveSlices = latest.slices.map { slice -> CuriumByteRangeSlice in
            var copy = slice
            copy.isActiveLane = false
            return copy
        }
        if var record = recordsByID[transferID] {
            record.receivedBytes = latest.receivedBytes
            if let total = latest.totalBytes {
                record.totalBytes = total
            }
            record.slices = inactiveSlices
            record.activeLanes = 0
            recordsByID[transferID] = record
        }
    }

    private func handlePausedRangeOutcome(
        for item: CuriumDownload,
        latest: CuriumRangeProgressUpdate?,
        meter: CuriumThroughputMeter
    ) {
        meter.markPaused()
        let elapsed = meter.elapsedSeconds
        let inactiveSlices = latest?.slices.map { slice -> CuriumByteRangeSlice in
            var copy = slice
            copy.isActiveLane = false
            return copy
        }
        let received = latest?.receivedBytes ?? item.receivedBytes

        item.markPaused(
            slices: inactiveSlices,
            receivedBytes: received,
            elapsedSeconds: elapsed
        )
        if var record = recordsByID[item.id] {
            record.phase = .paused
            record.receivedBytes = received
            if let total = latest?.totalBytes {
                record.totalBytes = total
            }
            if let inactiveSlices {
                record.slices = inactiveSlices
            } else {
                for idx in record.slices.indices {
                    record.slices[idx].isActiveLane = false
                }
            }
            record.activeLanes = 0
            record.activeDurationSeconds = elapsed
            record.peakSpeedBytesPerSec = max(record.peakSpeedBytesPerSec ?? 0, meter.peakSpeedBytesPerSec)
            record.updatedAt = Date()
            recordsByID[item.id] = record
            persistImmediate(record)
        }
        host.syncBackgroundKeepAlive()
    }

    private func preStagedCompleteHLSFileURL(for record: CuriumTransferRecord, in stagingDir: URL) -> URL? {
        let mp4Name = Self.ensureMP4Extension(record.filename)
        let stagedOutputURL = stagingDir.appending(path: mp4Name, directoryHint: .notDirectory)
        guard let size = Self.fileSize(at: stagedOutputURL),
              size > 0,
              CuriumNativeMP4Remuxer.isISOBaseMediaFile(at: stagedOutputURL) else {
            return nil
        }
        return stagedOutputURL
    }

    private func executeHLSTransfer(_ item: CuriumDownload) async {
        let id = item.id
        guard var record = recordsByID[id],
              let manifestURL = record.hlsCheckpoint?.playlistURL ?? record.resolvedURL ?? record.sourceURL else {
            handleFailedOutcome(for: item, message: "Missing HLS playlist URL.", meter: metersByID[id])
            return
        }

        let meter = ensureMeter(for: item)
        let latestBox = LatestHLSSnapshotBox()

        do {
            let stagingDir = try resolvedStagingDirectory(named: record.stagingDirectoryName)
            let mp4Name = Self.ensureMP4Extension(record.filename)
            if record.filename != mp4Name {
                record.filename = mp4Name
                record.stagingFileName = mp4Name
                recordsByID[id] = record
                item.updateMetadata(filename: mp4Name, mimeType: "video/mp4")
            }

            // Fast-path: transfer was interrupted during `.saving` after remux already produced a valid `.mp4`.
            if let preStagedMP4 = preStagedCompleteHLSFileURL(for: record, in: stagingDir) {
                await commitAndComplete(
                    item: item,
                    stagedFileURL: preStagedMP4,
                    preferredFilename: mp4Name,
                    finalByteCountHint: Self.fileSize(at: preStagedMP4),
                    meter: meter
                )
                return
            }

            let proxy = host.effectiveProxy()

            // Plug `CuriumProxySessionPool` into `CuriumHLSTransferEngine.sessionFactory`, holding the
            // reference-counted lease alive for the entire transfer.
            let sessionLease = CuriumProxySessionPool.acquireSessionLease(
                for: .hlsStream,
                proxy: proxy,
                targetURL: manifestURL
            )
            defer { sessionLease.release() }

            let stagedOutputURL = stagingDir.appending(path: mp4Name, directoryHint: .notDirectory)

            let cookieResolver = makeCookieResolver(
                transferID: id,
                sourceTabID: record.sourceTabID,
                includeTabCookies: record.includeTabCookies,
                primaryURL: manifestURL
            )

            let requestConfig = CuriumHLSRequestConfig(
                userAgent: record.userAgent,
                referer: record.referer,
                origin: record.origin,
                extraHeaders: [:],
                originatingURL: record.pageURL,
                cookieResolver: cookieResolver,
                sessionFactory: { sessionLease.session }
            )

            let videoPartURL = stagingDir.appending(path: "video.part", directoryHint: .notDirectory)
            let resumeState: CuriumHLSResumeState? = record.hlsCheckpoint.flatMap { cp in
                guard cp.completedSegments > 0 || cp.audioCompletedSegments > 0 else { return nil }
                if cp.completedSegments > 0 {
                    guard cp.contiguousByteOffset > 0,
                          let partSize = Self.fileSize(at: videoPartURL),
                          partSize >= cp.contiguousByteOffset else {
                        return nil
                    }
                }
                return CuriumHLSResumeState(
                    completedSegments: cp.completedSegments,
                    totalSegments: cp.totalSegments,
                    contiguousByteOffset: cp.contiguousByteOffset,
                    audioCompletedSegments: cp.audioCompletedSegments,
                    audioContiguousByteOffset: cp.audioContiguousByteOffset,
                    isFMP4: cp.isFMP4
                )
            }

            if resumeState == nil && (record.receivedBytes > 0 || item.receivedBytes > 0 || record.completedSegments > 0) {
                meter.resetForResume(currentBytes: 0)
                record.receivedBytes = 0
                record.completedSegments = 0
                if var cp = record.hlsCheckpoint {
                    cp.completedSegments = 0
                    cp.contiguousByteOffset = 0
                    cp.audioCompletedSegments = 0
                    cp.audioContiguousByteOffset = 0
                    record.hlsCheckpoint = cp
                }
                item.resetBytesForFreshRestart()
            }

            item.setPhase(.probing)
            record.phase = .probing
            record.updatedAt = Date()
            recordsByID[id] = record
            persistImmediate(record)

            let result = try await environment.hlsEngine.download(
                manifestURL: manifestURL,
                audioPlaylistURL: record.hlsCheckpoint?.audioPlaylistURL,
                stagingDirectoryURL: stagingDir,
                destinationURL: stagedOutputURL,
                requestConfig: requestConfig,
                concurrency: record.configuredLanes,
                preloadedManifestText: record.hlsCheckpoint?.preloadedPlaylistText,
                resumeState: resumeState,
                onProgress: { [weak self, weak item] update in
                    latestBox.store(update)
                    Task { @MainActor [weak self, weak item] in
                        guard let self, let item,
                              item.phase == .probing || item.phase == .downloading || item.phase == .remuxing else {
                            return
                        }
                        self.applyHLSProgressUpdate(update, to: item, meter: meter, force: update.phase == .remuxing)
                    }
                }
            )

            if let intent = stopIntentsByID[id] ?? (Task.isCancelled ? .cancel : nil) {
                if intent == .pause {
                    handlePausedHLSOutcome(for: item, latest: latestBox.latest, meter: meter)
                } else {
                    handleCancelledOutcome(for: item, meter: meter)
                }
                return
            }

            if let latest = latestBox.latest {
                applyHLSProgressUpdate(latest, to: item, meter: meter, force: true)
            }

            await commitAndComplete(
                item: item,
                stagedFileURL: result.outputFileURL,
                preferredFilename: mp4Name,
                finalByteCountHint: result.totalBytes,
                meter: meter
            )
        } catch is CancellationError {
            if stopIntentsByID[id] == .pause {
                handlePausedHLSOutcome(for: item, latest: latestBox.latest, meter: meter)
            } else {
                handleCancelledOutcome(for: item, meter: meter)
            }
        } catch {
            if stopIntentsByID[id] == .pause {
                handlePausedHLSOutcome(for: item, latest: latestBox.latest, meter: meter)
            } else if stopIntentsByID[id] == .cancel {
                handleCancelledOutcome(for: item, meter: meter)
            } else {
                if let latest = latestBox.latest {
                    syncHLSCheckpoint(from: latest, transferID: id)
                }
                handleFailedOutcome(for: item, message: error.localizedDescription, meter: meter)
            }
        }
    }

    private func applyHLSProgressUpdate(
        _ update: CuriumHLSProgressUpdate,
        to item: CuriumDownload,
        meter: CuriumThroughputMeter,
        force: Bool
    ) {
        let mappedPhase: CuriumTransferPhase = {
            switch update.phase {
            case .fetchingPlaylist: return .probing
            case .downloadingSegments: return .downloading
            case .remuxing: return .remuxing
            }
        }()
        let phaseChanged = item.phase != mappedPhase
        if phaseChanged {
            item.setPhase(mappedPhase)
        }

        if update.receivedBytes < item.receivedBytes {
            meter.resetForResume(currentBytes: 0)
        }

        let snap = meter.record(totalBytesNow: update.receivedBytes, force: force || phaseChanged)
        let speed = mappedPhase == .downloading ? (snap?.speedBytesPerSec ?? meter.speedBytesPerSec) : 0
        let peak = snap?.peakSpeedBytesPerSec ?? meter.peakSpeedBytesPerSec
        let samples = snap?.samples ?? meter.samples
        let elapsed = snap?.elapsedSeconds ?? meter.elapsedSeconds
        let remaining = update.estimatedTotalBytes.map { max(0, $0 - update.receivedBytes) }
        let eta = mappedPhase == .downloading ? meter.etaSeconds(remainingBytes: remaining) : nil

        item.updateHLSTelemetry(
            receivedBytes: update.receivedBytes,
            estimatedTotalBytes: update.estimatedTotalBytes,
            completedSegments: update.completedSegments,
            totalSegments: update.totalSegments > 0 ? update.totalSegments : nil,
            activeLanes: mappedPhase == .downloading ? update.activeWorkers : 0,
            speedBytesPerSec: speed,
            peakSpeedBytesPerSec: peak,
            throughputSamples: samples,
            etaSeconds: eta,
            elapsedSeconds: elapsed
        )

        syncHLSCheckpoint(from: update, transferID: item.id)
        if var record = recordsByID[item.id] {
            record.phase = mappedPhase
            record.receivedBytes = update.receivedBytes
            record.totalBytes = nil
            record.estimatedTotalBytes = update.estimatedTotalBytes
            record.completedSegments = update.completedSegments
            record.totalSegments = update.totalSegments > 0 ? update.totalSegments : nil
            record.activeLanes = mappedPhase == .downloading ? update.activeWorkers : 0
            record.activeDurationSeconds = elapsed
            record.peakSpeedBytesPerSec = peak
            record.updatedAt = Date()
            recordsByID[item.id] = record
            if phaseChanged || snap?.shouldPersist == true || force {
                persistThrottled(record, force: phaseChanged || force)
            }
        }
    }

    private func syncHLSCheckpoint(from update: CuriumHLSProgressUpdate, transferID: String) {
        guard var record = recordsByID[transferID] else { return }
        let rs = update.resumeState
        if var cp = record.hlsCheckpoint {
            cp.completedSegments = rs.completedSegments
            cp.totalSegments = rs.totalSegments ?? (update.totalSegments > 0 ? update.totalSegments : cp.totalSegments)
            cp.contiguousByteOffset = rs.contiguousByteOffset
            cp.audioCompletedSegments = rs.audioCompletedSegments
            cp.audioContiguousByteOffset = rs.audioContiguousByteOffset
            cp.isFMP4 = rs.isFMP4
            record.hlsCheckpoint = cp
        }
        recordsByID[transferID] = record
    }

    private func handlePausedHLSOutcome(
        for item: CuriumDownload,
        latest: CuriumHLSProgressUpdate?,
        meter: CuriumThroughputMeter
    ) {
        meter.markPaused()
        let elapsed = meter.elapsedSeconds
        if let latest {
            syncHLSCheckpoint(from: latest, transferID: item.id)
        }
        item.markPaused(
            receivedBytes: latest?.receivedBytes ?? item.receivedBytes,
            completedSegments: latest?.completedSegments ?? item.completedSegments,
            totalSegments: (latest?.totalSegments ?? 0) > 0 ? latest?.totalSegments : item.totalSegments,
            estimatedTotalBytes: latest?.estimatedTotalBytes ?? item.estimatedTotalBytes,
            elapsedSeconds: elapsed
        )
        if var record = recordsByID[item.id] {
            record.phase = .paused
            record.activeLanes = 0
            if let latest {
                record.receivedBytes = latest.receivedBytes
                record.completedSegments = latest.completedSegments
                record.totalSegments = latest.totalSegments > 0 ? latest.totalSegments : record.totalSegments
                record.estimatedTotalBytes = latest.estimatedTotalBytes
            }
            record.activeDurationSeconds = elapsed
            record.peakSpeedBytesPerSec = max(record.peakSpeedBytesPerSec ?? 0, meter.peakSpeedBytesPerSec)
            record.updatedAt = Date()
            recordsByID[item.id] = record
            persistImmediate(record)
        }
        host.syncBackgroundKeepAlive()
    }

    // MARK: - Staged Commit & Terminal Transitions

    private func commitAndComplete(
        item: CuriumDownload,
        stagedFileURL: URL,
        preferredFilename: String,
        finalByteCountHint: Int64?,
        meter: CuriumThroughputMeter
    ) async {
        let id = item.id
        let destinationLabel = resolvedSaveDestinationLabel()
        item.setPhase(.saving, saveDestinationLabel: destinationLabel)
        if var record = recordsByID[id] {
            record.phase = .saving
            record.activeLanes = 0
            record.updatedAt = Date()
            recordsByID[id] = record
            persistImmediate(record)
        }
        host.syncBackgroundKeepAlive()

        let customCommitHandler = item.stagedCommitHandlerOverride
        let downloadsRootOverride = environment.downloadsRootOverride
        let stagingDirName = recordsByID[id]?.stagingDirectoryName ?? id
        let stagingRootOverride = environment.stagingRootOverride

        let commitTask = Task.detached(priority: .utility) { () async throws -> URL in
            try Task.checkCancellation()
            if let customCommitHandler {
                let committed = try await customCommitHandler(stagedFileURL, preferredFilename)
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: committed)
                    throw CancellationError()
                }
                CuriumDownloadStorage.removeDurableTransferStagingDirectory(
                    named: stagingDirName,
                    stagingRoot: stagingRootOverride
                )
                return committed
            }

            let destinationDirectory = try downloadsRootOverride ?? CuriumDownloadStorage.downloadsRootDirectory()
            try Task.checkCancellation()
            let committed = try CuriumDownloadStorage.commitStagedFile(
                from: stagedFileURL,
                toDirectory: destinationDirectory,
                preferredFilename: preferredFilename,
                removeSource: true
            )
            if Task.isCancelled {
                try? CuriumDownloadStorage.deleteSavedDownload(at: committed, downloadsRoot: destinationDirectory)
                throw CancellationError()
            }
            CuriumDownloadStorage.removeDurableTransferStagingDirectory(
                named: stagingDirName,
                stagingRoot: stagingRootOverride
            )
            return committed
        }
        activeCommitTasksByID[id] = commitTask

        do {
            let committedURL = try await commitTask.value
            activeCommitTasksByID.removeValue(forKey: id)

            if stopIntentsByID[id] == .cancel || Task.isCancelled {
                let rootOverride = environment.downloadsRootOverride
                Task.detached(priority: .utility) {
                    if customCommitHandler != nil {
                        try? FileManager.default.removeItem(at: committedURL)
                    } else if let dir = try? rootOverride ?? CuriumDownloadStorage.downloadsRootDirectory() {
                        try? CuriumDownloadStorage.deleteSavedDownload(at: committedURL, downloadsRoot: dir)
                    }
                }
                handleCancelledOutcome(for: item, meter: meter)
                return
            }

            let diskSize = Self.fileSize(at: committedURL)
            let finalByteCount = diskSize ?? finalByteCountHint
            let now = Date()
            let elapsed = meter.elapsedSeconds
            let peak = meter.peakSpeedBytesPerSec
            let avg = (elapsed > 0.05 && (finalByteCount ?? 0) > 0)
                ? Double(finalByteCount!) / elapsed
                : nil

            transientCookiesByID.removeValue(forKey: id)
            metersByID.removeValue(forKey: id)
            customFilenameTransferIDs.remove(id)

            let finalName = committedURL.lastPathComponent
            item.markCompleted(
                savedURL: committedURL,
                finalFilename: finalName.isEmpty ? nil : finalName,
                finalByteCount: finalByteCount,
                completedAt: now,
                elapsedSeconds: elapsed,
                peakSpeedBytesPerSec: peak,
                saveDestinationLabel: destinationLabel
            )

            if var record = recordsByID[id] {
                record.phase = .completed
                record.filename = item.filename
                record.receivedBytes = finalByteCount ?? item.receivedBytes
                record.totalBytes = finalByteCount ?? record.totalBytes
                record.activeLanes = 0
                for idx in record.slices.indices {
                    record.slices[idx].isActiveLane = false
                }
                record.savedBookmarkPath = committedURL.path
                record.completedAt = now
                record.updatedAt = now
                record.failureMessage = nil
                record.activeDurationSeconds = elapsed
                record.peakSpeedBytesPerSec = peak
                record.averageSpeedBytesPerSec = avg
                recordsByID[id] = record
                persistImmediate(record)
            }

            host.syncBackgroundKeepAlive()
            host.refreshSavedDownloads()
        } catch is CancellationError {
            activeCommitTasksByID.removeValue(forKey: id)
            handleCancelledOutcome(for: item, meter: meter)
        } catch {
            activeCommitTasksByID.removeValue(forKey: id)
            if stopIntentsByID[id] == .cancel {
                handleCancelledOutcome(for: item, meter: meter)
            } else {
                handleFailedOutcome(for: item, message: error.localizedDescription, meter: meter)
            }
        }
    }

    private func handlePausedOutcome(for item: CuriumDownload, meter: CuriumThroughputMeter?) {
        meter?.markPaused()
        let elapsed = meter?.elapsedSeconds ?? item.elapsedSeconds
        item.markPaused(elapsedSeconds: elapsed)
        if var record = recordsByID[item.id] {
            record.phase = .paused
            record.activeLanes = 0
            record.activeDurationSeconds = elapsed
            if let peak = meter?.peakSpeedBytesPerSec {
                record.peakSpeedBytesPerSec = max(record.peakSpeedBytesPerSec ?? 0, peak)
            }
            record.updatedAt = Date()
            recordsByID[item.id] = record
            persistImmediate(record)
        }
        host.syncBackgroundKeepAlive()
    }

    private func handleCancelledOutcome(for item: CuriumDownload, meter: CuriumThroughputMeter?) {
        let elapsed = meter?.elapsedSeconds ?? item.elapsedSeconds
        transientCookiesByID.removeValue(forKey: item.id)
        metersByID.removeValue(forKey: item.id)
        item.markCancelled(elapsedSeconds: elapsed)
        if var record = recordsByID[item.id] {
            cleanupStagingDirectory(named: record.stagingDirectoryName)
            record.phase = .cancelled
            record.activeLanes = 0
            record.slices = []
            record.failureMessage = nil
            record.updatedAt = Date()
            recordsByID[item.id] = record
            persistImmediate(record)
        }
        host.syncBackgroundKeepAlive()
    }

    private func handleFailedOutcome(
        for item: CuriumDownload,
        message: String,
        meter: CuriumThroughputMeter?
    ) {
        meter?.markPaused()
        let elapsed = meter?.elapsedSeconds ?? item.elapsedSeconds
        item.markFailed(message: message, elapsedSeconds: elapsed)
        if var record = recordsByID[item.id] {
            record.phase = .failed
            record.activeLanes = 0
            record.failureMessage = message
            record.activeDurationSeconds = elapsed
            record.updatedAt = Date()
            recordsByID[item.id] = record
            persistImmediate(record)
        }
        host.syncBackgroundKeepAlive()
    }

    // MARK: - Persistence & Staging Helpers

    private func persistImmediate(_ record: CuriumTransferRecord) {
        guard let store = transferStore else { return }
        let snapshot = record.normalizedForPersistence()
        Task { await store.upsert(snapshot) }
    }

    private func persistThrottled(_ record: CuriumTransferRecord, force: Bool) {
        guard let store = transferStore else { return }
        let snapshot = record.normalizedForPersistence()
        Task { _ = await store.upsertThrottled(snapshot, force: force) }
    }

    private func ensureMeter(for item: CuriumDownload) -> CuriumThroughputMeter {
        if let existing = metersByID[item.id] {
            return existing
        }
        let meter = CuriumThroughputMeter(
            initialBytes: item.receivedBytes,
            priorElapsedSeconds: item.elapsedSeconds,
            priorPeakSpeedBytesPerSec: item.peakSpeedBytesPerSec,
            priorSamples: item.throughputSamples
        )
        metersByID[item.id] = meter
        return meter
    }

    private func resolvedStagingDirectory(named directoryName: String) throws -> URL {
        try CuriumDownloadStorage.durableTransferStagingDirectory(
            for: directoryName,
            stagingRoot: environment.stagingRootOverride
        )
    }

    private func cleanupStagingDirectory(named directoryName: String) {
        let overrideRoot = environment.stagingRootOverride
        Task.detached(priority: .utility) {
            CuriumDownloadStorage.removeDurableTransferStagingDirectory(
                named: directoryName,
                stagingRoot: overrideRoot
            )
        }
    }

    private func resolvedSaveDestinationLabel() -> String {
        if let customRoot = environment.downloadsRootOverride {
            return customRoot.lastPathComponent.isEmpty ? "Downloads" : customRoot.lastPathComponent
        }
        return CuriumDownloadsFolderManager.displayDownloadsPath
    }

    private func makeCookieResolver(
        transferID: String,
        sourceTabID: String?,
        includeTabCookies: Bool,
        primaryURL: URL
    ) -> (@Sendable (URL) async -> String?)? {
        guard includeTabCookies else { return nil }
        return { [weak self] targetURL in
            guard let self else { return nil }
            return await self.resolveLiveCookie(
                for: targetURL,
                transferID: transferID,
                sourceTabID: sourceTabID,
                primaryURL: primaryURL
            )
        }
    }

    private func resolveLiveCookie(
        for targetURL: URL,
        transferID: String,
        sourceTabID: String?,
        primaryURL: URL
    ) async -> String? {
        if let fresh = await host.resolveCookieHeader(targetURL, sourceTabID), !fresh.isEmpty {
            if CrossOriginRedirectAuthStripper.isSameOrigin(targetURL, primaryURL) {
                transientCookiesByID[transferID] = fresh
            }
            return fresh
        }
        if CrossOriginRedirectAuthStripper.isSameOrigin(targetURL, primaryURL) {
            return transientCookiesByID[transferID]
        }
        return nil
    }

    private func buildHTTPHeaders(
        userAgent: String?,
        referer: String?,
        origin: String?,
        cookie: String?
    ) -> [String: String] {
        var headers: [String: String] = [:]
        if let ua = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !ua.isEmpty {
            headers["User-Agent"] = ua
        }
        if let ref = referer?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            headers["Referer"] = ref
        }
        if let orig = origin?.trimmingCharacters(in: .whitespacesAndNewlines), !orig.isEmpty {
            headers["Origin"] = orig
        }
        if let cookie = cookie?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    // MARK: - Static URL, Site & Filename Helpers

    /// Returns `true` when `url` is same-site (eTLD+1) with `activeTabURL` and does not
    /// downgrade `https` to plaintext `http`.
    nonisolated static func canInheritCookies(for targetURL: URL, activeTabURL: URL?) -> Bool {
        guard let activeTabURL,
              CuriumHLSParser.isAllowedHTTPURL(targetURL),
              CuriumHLSParser.isAllowedHTTPURL(activeTabURL) else {
            return false
        }
        if CrossOriginRedirectAuthStripper.isHTTPSDowngrade(from: activeTabURL, to: targetURL) {
            return false
        }
        guard let targetHost = normalizedHost(targetURL),
              let tabHost = normalizedHost(activeTabURL) else {
            return false
        }
        if targetHost == tabHost {
            return true
        }
        // IP literals and single-label hosts (e.g., localhost) require exact host equality.
        if isIPLiteral(targetHost) || isIPLiteral(tabHost)
            || !targetHost.contains(".") || !tabHost.contains(".") {
            return false
        }
        guard let targetSite = registrableSite(for: targetHost),
              let tabSite = registrableSite(for: tabHost) else {
            return false
        }
        return targetSite == tabSite
    }

    nonisolated static func isLikelyHLSURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" { return true }
        return url.lastPathComponent.lowercased().hasSuffix(".m3u8")
    }

    nonisolated static func ensureMP4Extension(_ filename: String) -> String {
        let safe = CuriumDownloadStorage.sanitizedFilename(filename, fallback: "Video.mp4")
        let ns = safe as NSString
        let ext = ns.pathExtension.lowercased()
        if ext == "mp4" {
            return safe
        }
        let stem = ns.deletingPathExtension
        let base = stem.isEmpty ? safe : stem
        return CuriumDownloadStorage.sanitizedFilename("\(base).mp4", fallback: "Video.mp4")
    }

    private nonisolated static func safeRefererString(from pageURL: URL?, targetURL: URL?) -> String? {
        guard let pageURL, CuriumHLSParser.isAllowedHTTPURL(pageURL) else { return nil }
        if CrossOriginRedirectAuthStripper.isHTTPSDowngrade(from: pageURL, to: targetURL) {
            return nil
        }
        return pageURL.absoluteString
    }

    private nonisolated static func originString(for url: URL?) -> String? {
        guard let url,
              CuriumHLSParser.isAllowedHTTPURL(url),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }
        if let port = url.port {
            let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            return isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private nonisolated static func normalizedHost(_ url: URL) -> String? {
        guard let raw = url.host()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        let unbracketed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return unbracketed.hasSuffix(".") ? String(unbracketed.dropLast()) : unbracketed
    }

    private nonisolated static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return true
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return true
        }
        return false
    }

    private nonisolated static func registrableSite(for host: String) -> String? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let lastTwo = "\(labels[labels.count - 2]).\(labels[labels.count - 1])"
        if multiLabelPublicSuffixes.contains(lastTwo) {
            guard labels.count >= 3 else { return nil }
            return "\(labels[labels.count - 3]).\(lastTwo)"
        }
        return lastTwo
    }

    private nonisolated static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return size
    }
}
