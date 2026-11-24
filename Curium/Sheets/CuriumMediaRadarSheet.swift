import CuriumEngineContract
import SwiftUI
import UIKit

struct CuriumMediaRadarSheet: View {
    let store: CuriumBrowserStore
    var onOpenDownloads: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.curiumPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var snapshot: CuriumMediaScanSnapshot
    @State private var isScanning = false
    @State private var hlsStates: [String: HLSInspectionState] = [:]
    @State private var expandedHLSIDs: Set<String> = []
    @State private var startingDownloadKeys: Set<String> = []
    @State private var downloadsByTargetKey: [String: CuriumDownload] = [:]
    @State private var copiedCandidateID: String?
    @State private var manualScanTask: Task<Void, Never>?
    @State private var inspectionTasks: [String: Task<Void, Never>] = [:]
    @State private var copiedResetTask: Task<Void, Never>?

    private var folderManager: CuriumDownloadsFolderManager { CuriumDownloadsFolderManager.shared }

    private enum HLSInspectionState {
        case loading
        case loaded(CuriumHLSMasterInspection)
        case failed(String)
    }

    init(store: CuriumBrowserStore, onOpenDownloads: @escaping () -> Void = {}) {
        self.store = store
        self.onOpenDownloads = onOpenDownloads
        _snapshot = State(initialValue: store.currentMediaSnapshot())
    }

    private var subsumedChildHLSIDs: Set<String> {
        let loadedMasters = hlsStates.compactMapValues { state -> CuriumHLSMasterInspection? in
            guard case .loaded(let inspection) = state, inspection.isMasterPlaylist else { return nil }
            return inspection
        }
        return Self.computeSubsumedChildHLSIDs(
            loadedMasters: loadedMasters,
            localDownloadsByTargetKey: downloadsByTargetKey,
            storeDownloads: store.downloads
        )
    }

    /// Collapses redundant child `.m3u8` rows referenced by an inspected master playlist while
    /// preserving standalone direct child downloads across sheet reopen (without un-subsuming
    /// a child row whose download is already displayed inside a master's variant row).
    static func computeSubsumedChildHLSIDs(
        loadedMasters: [String: CuriumHLSMasterInspection],
        localDownloadsByTargetKey: [String: CuriumDownload],
        storeDownloads: [CuriumDownload]
    ) -> Set<String> {
        let liveStoreIDs = Set(storeDownloads.map(\.id))
        let visibleDownloads = storeDownloads.filter { item in
            item.isActive || item.state == .pending || item.state == .completed
        }

        var subsumed: Set<String> = []
        for (masterID, inspection) in loadedMasters {
            guard inspection.isMasterPlaylist else { continue }
            let displayedVariantURLs: Set<String> = inspection.isDownloadable
                ? Set(inspection.variants.map { $0.url.absoluteString })
                : []

            for childURL in inspection.referencedPlaylistURLs {
                let childID = childURL.absoluteString
                guard childID != masterID else { continue }

                if let local = localDownloadsByTargetKey[childID], liveStoreIDs.contains(local.id) {
                    continue
                }

                let matchingDownloads = visibleDownloads.filter { $0.originalURL == childURL }
                let hasStandaloneDirectDownload = matchingDownloads.contains { $0.hlsMasterPlaylistURL == nil }
                if hasStandaloneDirectDownload {
                    continue
                }

                // If a child download exists (e.g. audio rendition or non-downloadable master) and
                // is NOT already displayed inside this master's variant rows, do not hide the child row.
                let displayedInMasterVariantRow = displayedVariantURLs.contains(childID)
                    && matchingDownloads.contains { $0.hlsMasterPlaylistURL == inspection.sourceURL }
                if !matchingDownloads.isEmpty && !displayedInMasterVariantRow {
                    continue
                }

                subsumed.insert(childID)
            }
        }
        return subsumed
    }

    private var streamCandidates: [CuriumMediaCandidate] {
        let hidden = subsumedChildHLSIDs
        return snapshot.candidates.filter {
            ($0.kind == .hls || $0.kind == .dash) && !hidden.contains($0.id)
        }
    }

    private var hasMultipleVisibleStreams: Bool {
        streamCandidates.count > 1
    }

    private var videoCandidates: [CuriumMediaCandidate] {
        snapshot.candidates.filter { $0.kind == .video }
    }

    private var audioCandidates: [CuriumMediaCandidate] {
        snapshot.candidates.filter { $0.kind == .audio }
    }

    private var hasActiveDownloads: Bool {
        store.downloads.contains { $0.isActive }
    }

    private var hasDownloadsToOpen: Bool {
        store.pendingOrActiveDownloadCount > 0 || !store.downloads.isEmpty
    }

    var body: some View {
        let _ = folderManager.status
        let _ = folderManager.revision
        let displayPath = CuriumDownloadsFolderManager.displayDownloadsPath

        NavigationStack {
            List {
                if snapshot.candidates.isEmpty {
                    emptyStateSection
                } else {
                    if !streamCandidates.isEmpty {
                        Section("Streams (HLS / DASH)") {
                            ForEach(streamCandidates) { candidate in
                                candidateRow(candidate)
                            }
                        }
                    }

                    if !videoCandidates.isEmpty {
                        Section("Videos") {
                            ForEach(videoCandidates) { candidate in
                                candidateRow(candidate)
                            }
                        }
                    }

                    if !audioCandidates.isEmpty {
                        Section("Audio") {
                            ForEach(audioCandidates) { candidate in
                                candidateRow(candidate)
                            }
                        }
                    }
                }

                saveDestinationSection(displayPath: displayPath)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Detected Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        triggerManualScan()
                    } label: {
                        Label("Scan Page", systemImage: "arrow.clockwise")
                    }
                    .disabled(isScanning || store.activeTab?.url == nil || store.activeTab?.isShowingPDF == true)
                    .accessibilityIdentifier("curium.mediaRadar.scan")

                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Scanning page for media")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .accessibilityIdentifier("curium.mediaRadar.done")
                }
            }
        }
        .onAppear {
            folderManager.resolveInBackgroundIfNeeded()
        }
        .task {
            await performScan()
        }
        .task(id: scenePhase == .active && hasActiveDownloads) {
            guard scenePhase == .active, hasActiveDownloads else { return }
            while !Task.isCancelled {
                for item in store.downloads where item.isActive {
                    item.refresh()
                }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { break }
            }
        }
        .onDisappear {
            manualScanTask?.cancel()
            manualScanTask = nil
            for task in inspectionTasks.values {
                task.cancel()
            }
            inspectionTasks.removeAll()
            copiedResetTask?.cancel()
            copiedResetTask = nil
        }
        .curiumSheetErrorAlert(store: store)
    }

    // MARK: - Sections

    private var emptyStateSection: some View {
        Section {
            ContentUnavailableView {
                Label(
                    snapshot.detectedBlobVideoCount > 0 ? "Streaming Player Detected" : "No Media Detected",
                    systemImage: snapshot.detectedBlobVideoCount > 0 ? "play.rectangle.on.rectangle" : "film.stack"
                )
            } description: {
                if snapshot.detectedBlobVideoCount > 0 {
                    Text(
                        "Detected \(snapshot.detectedBlobVideoCount) streaming player(s) using MediaSource (blob:). Start playback and tap Scan Page to capture the manifest, or the site may use DRM."
                    )
                } else {
                    Text("No media streams detected on this page yet. Start playing a video or audio track, then tap Scan Page.")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
        }
    }

    private func saveDestinationSection(displayPath: String) -> some View {
        Section {
            if hasDownloadsToOpen {
                Button {
                    onOpenDownloads()
                } label: {
                    HStack(spacing: 10) {
                        Label("Open Downloads", systemImage: "arrow.down.circle")
                        Spacer(minLength: 8)
                        if store.activeTransferCount > 0 && store.aggregateActiveSpeedBytesPerSec >= 1 {
                            Text("\(store.activeTransferCount) active · \(CuriumTransferFormatters.speed(store.aggregateActiveSpeedBytesPerSec))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if store.pendingOrActiveDownloadCount > 0 {
                            Text("\(store.pendingOrActiveDownloadCount) active")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("curium.mediaRadar.openDownloads")
            }
        } footer: {
            Text("Downloads save to \(displayPath).")
        }
    }

    // MARK: - Candidate Rows

    private func candidateRow(_ candidate: CuriumMediaCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: leadingSymbolName(for: candidate.kind))
                    .font(.body.weight(.medium))
                    .foregroundStyle(candidate.kind == .dash ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .frame(width: 24, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        formatBadgePill(
                            candidate.formatBadge,
                            isSecondary: candidate.kind == .dash
                        )

                        if let metadata = metadataLine(for: candidate) {
                            Text(metadata)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingControl(for: candidate)
            }

            if candidate.kind == .video || candidate.kind == .audio {
                let tracked = resolvedDownload(for: candidate.id, url: candidate.url)
                if let tracked, showsInlineProgress(for: tracked) {
                    inlineProgressView(for: tracked)
                        .padding(.leading, 34)
                } else if let tracked, tracked.phase == .failed || tracked.state == .failed, let failure = tracked.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .padding(.leading, 34)
                }
            }

            if candidate.kind == .hls, expandedHLSIDs.contains(candidate.id) {
                hlsInspectorContent(for: candidate)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button {
                copyCandidateURL(candidate)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }

            Button {
                if store.newTab(url: candidate.url) {
                    dismiss()
                }
            } label: {
                Label("Open in New Tab", systemImage: "plus.square")
            }
        }
    }

    @ViewBuilder
    private func trailingControl(for candidate: CuriumMediaCandidate) -> some View {
        switch candidate.kind {
        case .hls:
            hlsTrailingControl(for: candidate)
        case .video, .audio:
            let tracked = resolvedDownload(for: candidate.id, url: candidate.url)
            downloadActionControl(
                isStarting: startingDownloadKeys.contains(candidate.id),
                download: tracked,
                showsButtonTitle: false,
                accessibilityID: "curium.mediaRadar.download.\(candidate.id)"
            ) {
                triggerDownload(candidate: candidate, hlsVariant: nil, targetKey: candidate.id)
            }
        case .dash:
            let isCopied = copiedCandidateID == candidate.id
            Button {
                copyCandidateURL(candidate)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    Text(isCopied ? "Copied" : "Copy")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel(isCopied ? "Copied URL" : "Copy URL")
            .accessibilityIdentifier("curium.mediaRadar.copy.\(candidate.id)")
        }
    }

    @ViewBuilder
    private func hlsTrailingControl(for candidate: CuriumMediaCandidate) -> some View {
        switch hlsStates[candidate.id] {
        case nil:
            Button {
                inspectHLS(candidate)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                    Text("Inspect")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(palette.tile, in: Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("Inspect HLS Stream")
            .accessibilityIdentifier("curium.mediaRadar.inspect.\(candidate.id)")

        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 36, minHeight: 32)
                .layoutPriority(1)

        case .loaded, .failed:
            let isExpanded = expandedHLSIDs.contains(candidate.id)
            Button {
                toggleHLSExpansion(candidate.id)
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .layoutPriority(1)
            .accessibilityLabel(isExpanded ? "Hide Stream Details" : "Show Stream Details")
            .accessibilityIdentifier("curium.mediaRadar.toggleHLS.\(candidate.id)")
        }
    }

    // MARK: - Inline HLS Quality Inspector

    @ViewBuilder
    private func hlsInspectorContent(for candidate: CuriumMediaCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            switch hlsStates[candidate.id] {
            case nil, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting HLS playlist…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

            case .failed(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        inspectHLS(candidate, forceReload: true)
                    } label: {
                        Text("Retry")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(palette.tile, in: Capsule())
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)

            case .loaded(let inspection):
                if !inspection.isDownloadable {
                    hlsUnavailableNotice(for: inspection)
                } else if inspection.isMasterPlaylist {
                    if inspection.variants.isEmpty {
                        Text(inspection.unavailableReason ?? "No downloadable stream variants found in this playlist.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(inspection.variants.enumerated()), id: \.element.id) { index, variant in
                                if index > 0 {
                                    Divider()
                                }
                                variantRow(candidate: candidate, variant: variant)
                            }
                        }
                    }
                } else {
                    directMediaPlaylistRow(candidate: candidate, inspection: inspection)
                }
            }
        }
    }

    @ViewBuilder
    private func hlsUnavailableNotice(for inspection: CuriumHLSMasterInspection) -> some View {
        let isDRM: Bool = {
            if case .unsupportedDRM = inspection.encryption { return true }
            return false
        }()
        let symbolName = isDRM ? "lock.slash.fill" : (inspection.isLiveStream ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
        let tintColor: Color = isDRM ? .red : .orange
        let defaultMessage: String = {
            if isDRM { return "DRM-protected streams cannot be downloaded." }
            if inspection.isLiveStream { return "Live streams cannot be downloaded." }
            return "This HLS stream is unavailable for download."
        }()

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(tintColor)
                .font(.subheadline)
                .accessibilityHidden(true)
            Text(inspection.unavailableReason ?? defaultMessage)
                .font(.caption)
                .foregroundStyle(tintColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func variantRow(candidate: CuriumMediaCandidate, variant: CuriumHLSVariant) -> some View {
        let targetKey = Self.variantTargetKey(candidateID: candidate.id, variantID: variant.id)
        let tracked = resolvedDownload(for: targetKey, url: variant.url, masterPlaylistURL: candidate.url)
        let isStarting = startingDownloadKeys.contains(targetKey)
        let detail = variantDetailText(for: variant)

        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(variant.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let tracked, showsInlineProgress(for: tracked) {
                    inlineProgressView(for: tracked)
                } else if let tracked, tracked.phase == .failed || tracked.state == .failed, let failure = tracked.failure {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            downloadActionControl(
                isStarting: isStarting,
                download: tracked,
                showsButtonTitle: true,
                accessibilityID: "curium.mediaRadar.variantDownload.\(variant.id)"
            ) {
                triggerDownload(candidate: candidate, hlsVariant: variant, targetKey: targetKey)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func directMediaPlaylistRow(
        candidate: CuriumMediaCandidate,
        inspection: CuriumHLSMasterInspection
    ) -> some View {
        let tracked = resolvedDownload(for: candidate.id, url: candidate.url)
        let isStarting = startingDownloadKeys.contains(candidate.id)
        let summary = directPlaylistSummary(for: inspection)

        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Media Playlist")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let tracked, showsInlineProgress(for: tracked) {
                    inlineProgressView(for: tracked)
                } else if let tracked, tracked.phase == .failed || tracked.state == .failed, let failure = tracked.failure {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            downloadActionControl(
                isStarting: isStarting,
                download: tracked,
                showsButtonTitle: true,
                accessibilityID: "curium.mediaRadar.hlsDirectDownload.\(candidate.id)"
            ) {
                triggerDownload(candidate: candidate, hlsVariant: nil, targetKey: candidate.id)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Reusable Controls & Helpers

    @ViewBuilder
    private func downloadActionControl(
        isStarting: Bool,
        download: CuriumDownload?,
        showsButtonTitle: Bool,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        if let download, isQueuedOrSaved(download) {
            let statusPill = mediaDownloadStatusPill(for: download)
            Button {
                onOpenDownloads()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: statusPill.symbol)
                    Text(statusPill.title)
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(statusPill.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(statusPill.background, in: Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("View in Downloads")
            .accessibilityIdentifier(accessibilityID)
        } else if isStarting {
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 36, minHeight: 32)
                .layoutPriority(1)
        } else if showsButtonTitle {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Save")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(palette.tile, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(palette.tint.opacity(0.35), lineWidth: 1)
                )
                .fixedSize()
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("Download")
            .accessibilityIdentifier(accessibilityID)
        } else {
            Button(action: action) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(palette.tint)
                    .frame(minWidth: 36, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("Download")
            .accessibilityIdentifier(accessibilityID)
        }
    }

    private func showsInlineProgress(for download: CuriumDownload) -> Bool {
        download.isActive || download.phase == .paused || download.phase == .queued
    }

    private func mediaDownloadStatusPill(
        for download: CuriumDownload
    ) -> (title: String, symbol: String, foreground: Color, background: Color) {
        switch download.phase {
        case .completed:
            return ("View", "checkmark.circle.fill", .green, Color.green.opacity(0.14))
        case .paused:
            return ("Paused", "pause.circle.fill", .orange, Color.orange.opacity(0.16))
        case .remuxing:
            return ("Muxing", "film", .green, Color.green.opacity(0.14))
        case .saving:
            return ("Saving", "folder.badge.plus", palette.tint, palette.tile)
        case .probing:
            return ("Probing", "arrow.down.circle.fill", palette.tint, palette.tile)
        case .downloading:
            let pct = CuriumTransferFormatters.percentage(download.fraction) ?? "Active"
            return (pct, "arrow.down.circle.fill", palette.tint, palette.tile)
        case .queued, .pendingConfirmation:
            return ("Queued", "clock.fill", palette.tint, palette.tile)
        case .failed:
            return ("Failed", "exclamationmark.triangle.fill", .red, Color.red.opacity(0.14))
        case .cancelled:
            return ("Cancelled", "xmark.circle.fill", .secondary, Color(uiColor: .tertiarySystemFill))
        }
    }

    @ViewBuilder
    private func inlineProgressView(for download: CuriumDownload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CuriumByteRangeHeatmapBar(
                slices: download.slices,
                totalBytes: download.knownTotalBytes,
                fallbackFraction: download.fraction,
                phase: download.phase,
                height: 5
            )
            Text(CuriumTransferFormatters.mediaRadarProgressLine(for: download))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func formatBadgePill(_ badge: String, isSecondary: Bool) -> some View {
        Text(badge)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                isSecondary ? Color(uiColor: .tertiarySystemFill) : palette.tile,
                in: Capsule()
            )
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    private func leadingSymbolName(for kind: CuriumMediaResourceEvent.StreamKind) -> String {
        switch kind {
        case .hls, .dash:
            return "play.rectangle.on.rectangle"
        case .video:
            return "film"
        case .audio:
            return "waveform"
        }
    }

    private func metadataLine(for candidate: CuriumMediaCandidate) -> String? {
        var parts: [String] = []
        if hasMultipleVisibleStreams,
           let pathHint = candidate.manifestPathHint,
           !pathHint.isEmpty {
            parts.append(pathHint)
        }
        if let resolution = candidate.resolutionLabel, !resolution.isEmpty {
            parts.append(resolution)
        }
        if let duration = candidate.formattedDuration, !duration.isEmpty {
            parts.append(duration)
        }
        if let size = candidate.formattedByteSize, !size.isEmpty {
            parts.append(size)
        }
        if !candidate.host.isEmpty {
            parts.append(candidate.host)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func variantDetailText(for variant: CuriumHLSVariant) -> String? {
        var parts: [String] = []
        if let fps = variant.frameRate, fps.isFinite, fps > 0 {
            parts.append("\(Int(fps.rounded())) fps")
        }
        if let codecs = variant.codecs, !codecs.isEmpty {
            parts.append(codecs)
        }
        if variant.audioURI != nil {
            parts.append("Muxed Audio")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func directPlaylistSummary(for inspection: CuriumHLSMasterInspection) -> String {
        var parts: [String] = []
        parts.append("\(inspection.directSegmentCount) segment\(inspection.directSegmentCount == 1 ? "" : "s")")
        if let duration = inspection.estimatedDurationSeconds, duration.isFinite, duration > 0 {
            let pattern: Duration.TimeFormatStyle.Pattern = duration >= 3600 ? .hourMinuteSecond : .minuteSecond
            parts.append(Duration.seconds(duration).formatted(.time(pattern: pattern)))
        }
        parts.append(inspection.isFMP4 ? "fMP4" : "MPEG-TS")
        if case .aes128 = inspection.encryption {
            parts.append("AES-128")
        }
        return parts.joined(separator: " · ")
    }

    private static func variantTargetKey(candidateID: String, variantID: String) -> String {
        "\(candidateID)#\(variantID)"
    }

    private func resolvedDownload(
        for targetKey: String,
        url: URL,
        masterPlaylistURL: URL? = nil
    ) -> CuriumDownload? {
        if let tracked = downloadsByTargetKey[targetKey],
           store.downloads.contains(where: { $0.id == tracked.id }) {
            return tracked
        }
        return store.downloads.first { item in
            guard item.originalURL == url,
                  item.isActive || item.phase == .paused || item.phase == .queued || item.state == .pending || item.state == .completed else {
                return false
            }
            if let masterPlaylistURL {
                return item.hlsMasterPlaylistURL == masterPlaylistURL
            }
            return item.hlsMasterPlaylistURL == nil
        }
    }

    private func isQueuedOrSaved(_ download: CuriumDownload) -> Bool {
        if download.isActive || download.phase == .paused || download.phase == .queued || download.state == .pending {
            return true
        }
        if download.phase == .completed || download.state == .completed {
            if download.savedURL != nil {
                return store.savedURL(for: download) != nil
            }
            return true
        }
        return false
    }

    // MARK: - Actions

    private func triggerManualScan() {
        guard !isScanning else { return }
        manualScanTask?.cancel()
        manualScanTask = Task {
            await performScan()
            manualScanTask = nil
        }
    }

    private func performScan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let previousTabID = snapshot.tabID
        let updated = await store.scanActiveTabMedia()
        guard !Task.isCancelled else { return }

        if updated.tabID != previousTabID {
            for task in inspectionTasks.values {
                task.cancel()
            }
            inspectionTasks.removeAll()
            hlsStates.removeAll()
            expandedHLSIDs.removeAll()
        } else {
            let validCandidateIDs = Set(updated.candidates.map(\.id))
            for (candidateID, task) in inspectionTasks where !validCandidateIDs.contains(candidateID) {
                task.cancel()
                inspectionTasks.removeValue(forKey: candidateID)
            }
            hlsStates = hlsStates.filter { validCandidateIDs.contains($0.key) }
            expandedHLSIDs.formIntersection(validCandidateIDs)
        }
        snapshot = updated
    }

    private func toggleHLSExpansion(_ candidateID: String) {
        if expandedHLSIDs.contains(candidateID) {
            expandedHLSIDs.remove(candidateID)
        } else {
            expandedHLSIDs.insert(candidateID)
        }
    }

    private func inspectHLS(_ candidate: CuriumMediaCandidate, forceReload: Bool = false) {
        expandedHLSIDs.insert(candidate.id)
        if !forceReload {
            switch hlsStates[candidate.id] {
            case .loading, .loaded:
                return
            case .failed, nil:
                break
            }
        }

        inspectionTasks[candidate.id]?.cancel()
        hlsStates[candidate.id] = .loading
        let targetTabID = snapshot.tabID

        inspectionTasks[candidate.id] = Task {
            do {
                let inspection = try await store.inspectHLSStream(for: candidate, inTabID: targetTabID)
                guard !Task.isCancelled else { return }
                hlsStates[candidate.id] = .loaded(inspection)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                hlsStates[candidate.id] = .failed(error.localizedDescription)
            }
            inspectionTasks.removeValue(forKey: candidate.id)
        }
    }

    private func triggerDownload(
        candidate: CuriumMediaCandidate,
        hlsVariant: CuriumHLSVariant?,
        targetKey: String
    ) {
        guard !startingDownloadKeys.contains(targetKey) else { return }
        startingDownloadKeys.insert(targetKey)
        let targetTabID = snapshot.tabID

        Task {
            defer { startingDownloadKeys.remove(targetKey) }
            if let started = await store.startMediaDownload(
                candidate: candidate,
                hlsVariant: hlsVariant,
                inTabID: targetTabID
            ) {
                downloadsByTargetKey[targetKey] = started
            }
        }
    }

    private func copyCandidateURL(_ candidate: CuriumMediaCandidate) {
        UIPasteboard.general.string = candidate.url.absoluteString
        copiedCandidateID = candidate.id
        copiedResetTask?.cancel()
        let copiedID = candidate.id
        copiedResetTask = Task {
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard !Task.isCancelled, copiedCandidateID == copiedID else { return }
            copiedCandidateID = nil
            copiedResetTask = nil
        }
    }
}
