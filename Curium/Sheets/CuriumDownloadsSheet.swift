import AVFoundation
import CuriumEngineContract
import PDFKit
import QuickLook
import SwiftUI
import UIKit

/// Bounded async thumbnail cache for saved video downloads (`AVAssetImageGenerator` off `@MainActor`).
@MainActor
private final class CuriumVideoThumbnailCache {
    static let shared = CuriumVideoThumbnailCache()

    private static let supportedExtensions: Set<String> = ["mp4", "m4v", "mov"]

    private let cache: NSCache<NSString, UIImage>
    private var failedPaths: Set<String> = []
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        let bounded = NSCache<NSString, UIImage>()
        bounded.countLimit = 64
        bounded.totalCostLimit = 24 * 1024 * 1024
        self.cache = bounded

        self.memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.purgeAll()
            }
        }
    }

    isolated deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func supportsThumbnail(for url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    func purgeAll() {
        cache.removeAllObjects()
        failedPaths.removeAll()
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url.standardizedFileURL.path as NSString)
    }

    func loadOrGenerate(for url: URL) async -> UIImage? {
        guard Self.supportsThumbnail(for: url) else { return nil }
        let key = url.standardizedFileURL.path
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }
        guard !failedPaths.contains(key) else { return nil }

        let generated: UIImage? = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 160)

            for seconds in [1.0, 0.1, 0.0] {
                if Task.isCancelled { return nil }
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let (cgImage, _) = try? await generator.image(at: time) {
                    return UIImage(cgImage: cgImage)
                }
            }
            return nil
        }.value

        guard !Task.isCancelled else { return nil }
        if let generated {
            let cost: Int
            if let cg = generated.cgImage {
                cost = max(1, cg.bytesPerRow * cg.height)
            } else {
                cost = max(1, Int(generated.size.width * generated.size.height * generated.scale * generated.scale * 4))
            }
            cache.setObject(generated, forKey: key as NSString, cost: cost)
            failedPaths.remove(key)
        } else {
            failedPaths.insert(key)
        }
        return generated
    }
}

enum CuriumDownloadsScope: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all = "All"
    case active = "Active"
    case saved = "Saved"

    var id: Self { self }
}

struct CuriumDownloadsViewState: Equatable, Sendable {
    var scope: CuriumDownloadsScope = .all
    var searchQuery: String = ""
    var selectedTransferID: String? = nil
    var inspectedTransferID: String? = nil
}

struct CuriumDownloadsSheet: View {
    private struct QuickLookItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    let store: CuriumBrowserStore
    @Binding var viewState: CuriumDownloadsViewState
    let onViewportWidthChange: ((CGFloat) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.curiumPalette) private var palette

    @State private var quickLookURL: URL?
    @State private var isShowingNewDownloadSheet = false
    @State private var saveFolderFlow = CuriumSaveFolderFlowState()
    @State private var viewportWidth: CGFloat = 0
    @State private var verticalDivisionRect: CGRect?

    init(
        store: CuriumBrowserStore,
        viewState: Binding<CuriumDownloadsViewState>,
        onViewportWidthChange: ((CGFloat) -> Void)? = nil
    ) {
        self.store = store
        self._viewState = viewState
        self.onViewportWidthChange = onViewportWidthChange
    }

    private var folderManager: CuriumDownloadsFolderManager { CuriumDownloadsFolderManager.shared }

    private var hasActiveDownloads: Bool {
        store.downloads.contains { $0.isActive }
    }

    private var hasFinishedTasks: Bool {
        store.downloads.contains { $0.phase.isTerminal }
    }

    private var hasQueueActions: Bool {
        store.hasPausableActiveDownloads || store.hasResumablePausedDownloads || hasFinishedTasks
    }

    private var hasAnyItems: Bool {
        !store.downloads.isEmpty || !store.savedDownloads.isEmpty
    }

    private var normalizedQuery: String {
        viewState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredTransfers: [CuriumDownload] {
        let scoped: [CuriumDownload]
        switch viewState.scope {
        case .all:
            scoped = store.downloads
        case .active:
            scoped = store.downloads.filter { $0.phase != .completed }
        case .saved:
            return []
        }

        let query = normalizedQuery
        guard !query.isEmpty else { return scoped }
        return scoped.filter { item in
            if item.filename.lowercased().contains(query) { return true }
            if let domain = item.sourceDomain?.lowercased(), domain.contains(query) { return true }
            if let urlStr = (item.resolvedURL ?? item.originalURL)?.absoluteString.lowercased(),
               urlStr.contains(query) {
                return true
            }
            return item.transportKind.displayTitle.lowercased().contains(query)
        }
    }

    private var filteredSavedDownloads: [CuriumSavedDownload] {
        guard viewState.scope != .active else { return [] }
        let query = normalizedQuery
        guard !query.isEmpty else { return store.savedDownloads }
        return store.savedDownloads.filter { file in
            file.filename.lowercased().contains(query)
        }
    }

    private var resolvedSelectedTransfer: CuriumDownload? {
        if let selectedTransferID = viewState.selectedTransferID,
           let match = store.downloads.first(where: { $0.id == selectedTransferID }) {
            return match
        }
        return filteredTransfers.first ?? store.downloads.first
    }

    private var isSplitExpanded: Bool {
        viewportWidth >= 760
    }

    private var activeSectionHeaderTitle: String {
        if store.aggregateActiveSpeedBytesPerSec >= 1 {
            return "Active Transfers · ↓ \(CuriumTransferFormatters.speed(store.aggregateActiveSpeedBytesPerSec))"
        }
        return hasActiveDownloads ? "Active Transfers" : "Transfers"
    }

    var body: some View {
        let folderStatus = folderManager.status
        let _ = folderManager.revision
        let displayPath = CuriumDownloadsFolderManager.displayDownloadsPath

        NavigationStack {
            Group {
                if isSplitExpanded {
                    splitContent(folderStatus: folderStatus, displayPath: displayPath)
                } else {
                    masterList(
                        folderStatus: folderStatus,
                        displayPath: displayPath,
                        isSplit: false
                    )
                }
            }
            .background {
                GeometryReader { proxy in
                    let division = Self.extractVerticalDivision(from: proxy)
                    Color(uiColor: .systemGroupedBackground)
                        .ignoresSafeArea()
                        .onAppear {
                            viewportWidth = proxy.size.width
                            verticalDivisionRect = division
                            onViewportWidthChange?(proxy.size.width)
                        }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            viewportWidth = newWidth
                            onViewportWidthChange?(newWidth)
                        }
                        .onChange(of: division) { _, newDivision in
                            verticalDivisionRect = newDivision
                        }
                }
            }
            .modifier(CuriumConditionalSearchableModifier(isEnabled: hasAnyItems, text: $viewState.searchQuery))
            .curiumSaveFolderPickerFlow($saveFolderFlow) {
                store.refreshSavedDownloads()
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $viewState.inspectedTransferID) { transferID in
                if let transfer = store.downloads.first(where: { $0.id == transferID }) {
                    CuriumTransferInspectorView(
                        store: store,
                        download: transfer,
                        isEmbeddedInSplit: false,
                        onOpenSavedFile: openFile,
                        onDeleted: {
                            viewState.inspectedTransferID = nil
                            if viewState.selectedTransferID == transferID {
                                viewState.selectedTransferID = nil
                            }
                        }
                    )
                    .navigationTitle("Inspector")
                    .navigationBarTitleDisplayMode(.inline)
                } else {
                    ContentUnavailableView(
                        "Transfer Removed",
                        systemImage: "arrow.down.circle",
                        description: Text("This transfer is no longer in the queue.")
                    )
                }
            }
            .onChange(of: isSplitExpanded) { _, expanded in
                if expanded, let id = viewState.inspectedTransferID {
                    viewState.selectedTransferID = id
                    viewState.inspectedTransferID = nil
                }
            }
            .toolbar {
                if hasQueueActions {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if store.hasPausableActiveDownloads {
                                Button {
                                    store.pauseAllActiveDownloads()
                                } label: {
                                    Label("Pause All Active", systemImage: "pause.circle")
                                }
                            }

                            if store.hasResumablePausedDownloads {
                                Button {
                                    store.resumeAllPausedDownloads()
                                } label: {
                                    Label("Resume All Paused", systemImage: "play.circle")
                                }
                            }

                            if hasFinishedTasks {
                                if store.hasPausableActiveDownloads || store.hasResumablePausedDownloads {
                                    Divider()
                                }
                                Button(role: .destructive) {
                                    store.clearFinishedDownloadTasks()
                                    if let selectedID = viewState.selectedTransferID,
                                       !store.downloads.contains(where: { $0.id == selectedID }) {
                                        viewState.selectedTransferID = nil
                                    }
                                } label: {
                                    Label("Clear Finished", systemImage: "trash")
                                }
                            }
                        } label: {
                            Label("Queue Actions", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("curium.downloads.queueActions")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingNewDownloadSheet = true
                    } label: {
                        Label("New Download", systemImage: "plus")
                    }
                    .accessibilityIdentifier("curium.downloads.new")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
        .onAppear {
            folderManager.resolveInBackgroundIfNeeded()
            store.refreshSavedDownloads()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                folderManager.resolveInBackgroundIfNeeded()
                store.refreshSavedDownloads()
            }
        }
        .onChange(of: folderManager.revision) { _, _ in
            store.refreshSavedDownloads()
        }
        .curiumSheetErrorAlert(store: store)
        .sheet(isPresented: $isShowingNewDownloadSheet) {
            CuriumNewDownloadSheet(store: store) { started in
                viewState.selectedTransferID = started.id
                if viewState.scope == .saved {
                    viewState.scope = .all
                }
            }
        }
        .sheet(item: Binding(
            get: { quickLookURL.map(QuickLookItem.init(url:)) },
            set: { quickLookURL = $0?.url }
        )) { item in
            NavigationStack {
                CuriumQuickLookPreview(url: item.url)
                    .navigationTitle(item.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { quickLookURL = nil } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Fold-Aware Equal-Peer Dual-Pane Layout (iPhone Duo Inner Landscape >= 760 pt)

    @ViewBuilder
    private func splitContent(
        folderStatus: CuriumDownloadsFolderManager.Status,
        displayPath: String
    ) -> some View {
        let geometry = splitColumnGeometry()

        HStack(spacing: 0) {
            masterList(
                folderStatus: folderStatus,
                displayPath: displayPath,
                isSplit: true
            )
            .frame(width: geometry.leftWidth)

            Color(uiColor: .systemGroupedBackground)
                .frame(width: geometry.gutterWidth)
                .accessibilityHidden(true)

            Group {
                if let selected = resolvedSelectedTransfer {
                    CuriumTransferInspectorView(
                        store: store,
                        download: selected,
                        isEmbeddedInSplit: true,
                        onOpenSavedFile: openFile,
                        onDeleted: {
                            viewState.selectedTransferID = nil
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "Transfer Inspector",
                        systemImage: "gauge.with.dots.needle.67percent",
                        description: Text("Start or select a transfer to inspect live multi-lane byte ranges, throughput, and diagnostics.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func splitColumnGeometry() -> (leftWidth: CGFloat, gutterWidth: CGFloat) {
        if let hinge = verticalDivisionRect,
           hinge.minX >= 260,
           (viewportWidth - hinge.maxX) >= 260 {
            let left = max(260, floor(hinge.minX))
            let gutter = max(40, ceil(hinge.maxX) - left)
            return (left, gutter)
        }
        let gutter: CGFloat = 40
        let left = max(300, floor((viewportWidth - gutter) * 0.48))
        return (left, gutter)
    }

    private static func extractVerticalDivision(from proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        let divisions = proxy.reservedRegions(kind: .division, options: [.includeInactive])
        if let active = divisions.first(where: { $0.isActive && $0.frame.height > $0.frame.width && $0.frame.width > 0 }) {
            return active.frame
        }
        return divisions.first(where: { $0.frame.height > $0.frame.width && $0.frame.width > 0 })?.frame
    }

    // MARK: - Master List

    private func masterList(
        folderStatus: CuriumDownloadsFolderManager.Status,
        displayPath: String,
        isSplit: Bool
    ) -> some View {
        let transfers = filteredTransfers
        let savedFiles = filteredSavedDownloads
        let activeSelectionID = resolvedSelectedTransfer?.id

        return List {
            Section {
                CuriumSaveLocationRow(
                    flow: $saveFolderFlow,
                    accessibilityID: "curium.downloads.saveLocation"
                ) {
                    store.refreshSavedDownloads()
                }

                if case .needsHostGrant(let folderName, _, _) = folderStatus {
                    Button {
                        saveFolderFlow.isShowingPicker = true
                    } label: {
                        Label(
                            "Link “\(folderName)” on \(CuriumDownloadsFolderManager.currentHostDisplayName())",
                            systemImage: "folder.badge.person.crop"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                    .tint(.orange)
                    .accessibilityIdentifier("curium.downloads.linkFolder")
                }
            } footer: {
                saveLocationFooter(for: folderStatus, displayPath: displayPath)
            }

            if !hasAnyItems {
                Section {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.to.line")
                    } description: {
                        Text(
                            store.isEngineReady
                                ? "Saved files and multi-lane transfers appear here. Tap + to download a direct file or HLS stream by URL."
                                : "Tap + to start a direct download, or browse once Blink is ready."
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    Picker("Scope", selection: $viewState.scope) {
                        ForEach(CuriumDownloadsScope.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .accessibilityIdentifier("curium.downloads.scope")
                }

                if transfers.isEmpty && savedFiles.isEmpty {
                    Section {
                        if !normalizedQuery.isEmpty {
                            ContentUnavailableView.search(text: viewState.searchQuery)
                                .listRowBackground(Color.clear)
                        } else if viewState.scope == .active {
                            ContentUnavailableView(
                                "No Active Transfers",
                                systemImage: "arrow.down.circle",
                                description: Text("In-progress, paused, and queued downloads appear here.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .listRowBackground(Color.clear)
                        } else {
                            ContentUnavailableView(
                                "No Saved Files",
                                systemImage: "folder",
                                description: Text("Completed files saved to \(displayPath) appear here.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .listRowBackground(Color.clear)
                        }
                    }
                } else {
                    if !transfers.isEmpty {
                        Section {
                            ForEach(transfers) { item in
                                let isSelected = isSplit && activeSelectionID == item.id
                                transferRow(item, isSplit: isSplit, isSelected: isSelected)
                                    .id("\(item.id)-\(item.phase.isTerminal ? "done" : "live")")
                                    .listRowBackground(
                                        isSelected
                                            ? palette.tile
                                            : Color(uiColor: .secondarySystemGroupedBackground)
                                    )
                            }
                        } header: {
                            Text(activeSectionHeaderTitle)
                                .monospacedDigit()
                        }
                    }

                    if !savedFiles.isEmpty {
                        Section {
                            ForEach(savedFiles) { file in
                                CuriumSavedDownloadRow(
                                    file: file,
                                    onOpen: {
                                        openFile(url: file.url, filename: file.filename, isPDF: file.isPDF)
                                    }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        store.deleteSavedDownload(file)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text("Saved Files")
                        } footer: {
                            Text("Saved to \(displayPath).")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func transferRow(
        _ item: CuriumDownload,
        isSplit: Bool,
        isSelected: Bool
    ) -> some View {
        let card = CuriumTransferCardView(
            download: item,
            isSelected: isSelected
        ) {
            performPrimaryAction(for: item)
        }

        HStack(spacing: 8) {
            card
            if !isSplit {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSplit {
                viewState.selectedTransferID = item.id
            } else {
                viewState.inspectedTransferID = item.id
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.isActive || item.phase == .queued || item.phase == .paused || item.phase == .pendingConfirmation {
                Button(role: .destructive) {
                    store.cancelDownload(item)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else {
                Button(role: .destructive) {
                    store.removeTransfer(item)
                    if viewState.selectedTransferID == item.id {
                        viewState.selectedTransferID = nil
                    }
                    if viewState.inspectedTransferID == item.id {
                        viewState.inspectedTransferID = nil
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if item.phase == .pendingConfirmation {
                Button {
                    Task { await store.startDownload(item) }
                } label: {
                    Label("Save Download", systemImage: "arrow.down.circle")
                }
            } else if item.canPause {
                Button {
                    store.pauseDownload(item)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            } else if item.canResume {
                Button {
                    store.resumeDownload(item)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
            } else if item.canRetry {
                Button {
                    store.retryDownload(item)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }

            if item.phase == .completed, let savedURL = store.savedURL(for: item) {
                Button {
                    openFile(url: savedURL, filename: item.filename, isPDF: item.isPDF)
                } label: {
                    Label(item.isPDF ? "Open in Tab" : "Preview", systemImage: item.isPDF ? "doc.richtext" : "eye")
                }

                ShareLink(item: savedURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            if let url = item.resolvedURL ?? item.originalURL {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
            }

            Divider()

            if item.isActive || item.phase == .queued || item.phase == .paused || item.phase == .pendingConfirmation {
                Button(role: .destructive) {
                    store.cancelDownload(item)
                } label: {
                    Label("Cancel Transfer", systemImage: "xmark.circle")
                }
            }

            Button(role: .destructive) {
                store.removeTransfer(item)
                if viewState.selectedTransferID == item.id {
                    viewState.selectedTransferID = nil
                }
                if viewState.inspectedTransferID == item.id {
                    viewState.inspectedTransferID = nil
                }
            } label: {
                Label("Remove from List", systemImage: "trash")
            }
        }
    }

    private func performPrimaryAction(for item: CuriumDownload) {
        if item.phase == .pendingConfirmation {
            Task { await store.startDownload(item) }
        } else if item.canPause {
            store.pauseDownload(item)
        } else if item.canResume {
            store.resumeDownload(item)
        } else if item.canRetry {
            store.retryDownload(item)
        }
    }

    @ViewBuilder
    private func saveLocationFooter(
        for status: CuriumDownloadsFolderManager.Status,
        displayPath: String
    ) -> some View {
        switch status {
        case .needsHostGrant(let folderName, _, _):
            Text("Another LiveContainer instance saves downloads to “\(folderName)”. Grant folder access once to share the same Files library here.")
        case .customActive:
            Text("Saved to \(displayPath). Shared across all profiles and accessible in Files.")
        case .defaultInternal:
            if CuriumDownloadsFolderManager.isDownloadsDirectoryVisibleInFiles {
                Text("Saved to \(displayPath). Accessible in Files and shared across all profiles.")
            } else {
                Text("Saved to \(displayPath). Choose a folder in Files or iCloud Drive to browse downloads directly in Files. Shared across all profiles.")
            }
        }
    }

    private func openFile(url: URL, filename: String, isPDF: Bool) {
        if isPDF {
            let saved = CuriumSavedDownload(
                url: url,
                filename: filename,
                byteCount: 0,
                modifiedAt: .now,
                isPDF: true
            )
            store.openSavedPDFInActiveTab(saved)
            dismiss()
        } else {
            quickLookURL = url
        }
    }
}

private struct CuriumConditionalSearchableModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, prompt: "Search downloads")
        } else {
            content
        }
    }
}

/// Saved file row with async bounded-cache `AVAssetImageGenerator` thumbnails for video files.
private struct CuriumSavedDownloadRow: View {
    @Environment(\.curiumPalette) private var palette

    let file: CuriumSavedDownload
    let onOpen: () -> Void

    @State private var thumbnail: UIImage?

    private var supportsVideoThumbnail: Bool {
        file.isVideo && CuriumVideoThumbnailCache.supportsThumbnail(for: file.url)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    leadingVisual

                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.filename)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(metadataText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ShareLink(item: file.url) {
                Label("Share \(file.filename)", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .frame(width: CuriumSpace.tapTarget, height: CuriumSpace.tapTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .task(id: file.url) {
            guard supportsVideoThumbnail else { return }
            if let cached = CuriumVideoThumbnailCache.shared.cachedImage(for: file.url) {
                thumbnail = cached
                return
            }
            thumbnail = await CuriumVideoThumbnailCache.shared.loadOrGenerate(for: file.url)
        }
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if supportsVideoThumbnail {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                    }
                    .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.tile)
                    .frame(width: 52, height: 36)
                    .overlay {
                        Image(systemName: file.symbolName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.tint)
                    }
                    .accessibilityHidden(true)
            }
        } else {
            Image(systemName: file.symbolName)
                .font(.title3)
                .foregroundStyle(
                    (file.isPDF || file.isVideo || file.isAudio)
                        ? AnyShapeStyle(palette.tint)
                        : AnyShapeStyle(.secondary)
                )
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
        }
    }

    private var metadataText: String {
        let size = CuriumTransferFormatters.bytes(file.byteCount)
        let date = file.modifiedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(size) · \(date)"
    }
}

private struct CuriumQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
