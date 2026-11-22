import PDFKit
import SwiftUI
import UIKit

/// Full-bleed inline PDF reader mounted directly inside a browser tab.
/// Keeps Liquid Glass strictly on floating chrome controls over scrolling PDF pages
/// and keeps overlays clear of iPhone Duo's `.division` crease when partially folded.
struct CuriumInlinePDFView: View {
    @Bindable var session: CuriumTabPDFSession
    let topInset: CGFloat
    let bottomPadding: CGFloat
    let palette: CuriumPalette
    let onClose: () -> Void
    let onRetry: (() -> Void)?
    let onOpenLink: (URL) -> Void
    let onSavedToDownloads: (URL) -> Void
    let onSaveError: (String) -> Void

    @State private var showingOutline = false
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let pane = activePaneLayout(in: proxy)
            let effectiveBottomPadding: CGFloat = searchFieldFocused ? 10 : bottomPadding

            ZStack(alignment: .bottom) {
                Color(uiColor: .secondarySystemBackground)
                    .ignoresSafeArea(.all)

                switch session.phase {
                case .loading(let progress):
                    loadingView(progress: progress, pane: pane)
                case .ready:
                    if let document = session.document {
                        CuriumPDFKitCanvas(
                            document: document,
                            topInset: topInset,
                            bottomInset: bottomPadding + 74,
                            navigationRequestID: session.navigationRequestID,
                            requestedPageIndex: session.requestedPageIndex,
                            requestedSelection: session.requestedSelection,
                            requestedZoomScale: session.requestedZoomScale,
                            highlightedSelections: session.searchMatches,
                            highlightRevision: session.highlightRevision,
                            onPageChanged: { session.updateCurrentPage($0) },
                            onZoomChanged: { session.updateObservedZoomScale($0) },
                            onOpenLink: onOpenLink
                        )
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                    }
                case .failed(let message):
                    failureView(message: message, pane: pane)
                }

                if case .ready = session.phase {
                    GlassEffectContainer(spacing: 10) {
                        VStack(spacing: 10) {
                            if session.isSearching {
                                searchBar(maxWidth: min(460, max(240, pane.maxWidth)))
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            floatingControlPill
                        }
                    }
                    .frame(maxWidth: pane.maxWidth)
                    .padding(.leading, pane.leadingInset)
                    .padding(.trailing, pane.trailingInset)
                    .padding(.bottom, effectiveBottomPadding)
                    .frame(maxWidth: .infinity, alignment: pane.alignment)
                    .animation(.smooth(duration: 0.24), value: session.isSearching)
                }
            }
        }
        .sheet(isPresented: $showingOutline) {
            CuriumPDFOutlineSheet(
                title: session.displayTitle,
                items: session.outlineItems,
                currentPageIndex: session.currentPageIndex
            ) { pageIndex in
                showingOutline = false
                session.jumpToPage(pageIndex)
            }
        }
        .onChange(of: session.isSearching) { _, active in
            searchFieldFocused = active
        }
        .onChange(of: session.saveError) { _, message in
            if let message {
                session.clearSaveError()
                onSaveError("Couldn’t save “\(session.displayTitle)”: \(message)")
            }
        }
    }

    private struct PaneLayout {
        let leadingInset: CGFloat
        let trailingInset: CGFloat
        let maxWidth: CGFloat
        let alignment: Alignment
        let verticalOffset: CGFloat
    }

    private func activePaneLayout(in proxy: GeometryProxy) -> PaneLayout {
        let width = proxy.size.width
        let defaultLayout = PaneLayout(
            leadingInset: 16,
            trailingInset: 16,
            maxWidth: max(240, width - 32),
            alignment: .center,
            verticalOffset: 0
        )
        guard #available(iOS 27.1, *) else { return defaultLayout }

        for region in proxy.reservedRegions(kind: .division, options: [.includeInactive]) where region.isActive {
            let frame = region.frame
            guard frame.minX < width - 2, frame.maxX > 2 else { continue }
            if frame.height > frame.width {
                let leftRoom = max(0, frame.minX - 28)
                let rightRoom = max(0, width - frame.maxX - 28)
                if leftRoom >= rightRoom, leftRoom >= 220 {
                    return PaneLayout(
                        leadingInset: 16,
                        trailingInset: width - frame.minX + 12,
                        maxWidth: leftRoom,
                        alignment: .leading,
                        verticalOffset: 0
                    )
                } else if rightRoom >= 220 {
                    return PaneLayout(
                        leadingInset: frame.maxX + 12,
                        trailingInset: 16,
                        maxWidth: rightRoom,
                        alignment: .trailing,
                        verticalOffset: 0
                    )
                }
            } else if frame.width > frame.height {
                // Partially folded horizontal crease: lift centered empty/loading state into upper pane.
                let upperCenter = (topInset + frame.minY) / 2
                let delta = upperCenter - (proxy.size.height / 2)
                return PaneLayout(
                    leadingInset: 16,
                    trailingInset: 16,
                    maxWidth: max(240, width - 32),
                    alignment: .center,
                    verticalOffset: delta
                )
            }
        }
        return defaultLayout
    }

    private func loadingView(progress: Double?, pane: PaneLayout) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(palette.tint)
                .accessibilityHidden(true)

            Text(session.displayTitle)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: min(340, pane.maxWidth))

            if let progress {
                ProgressView(value: progress)
                    .frame(maxWidth: min(240, pane.maxWidth))
                    .tint(palette.tint)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .tint(palette.tint)
                Text("Opening PDF…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel", role: .cancel, action: onClose)
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(.top, topInset)
        .padding(.leading, pane.leadingInset)
        .padding(.trailing, pane.trailingInset)
        .offset(y: pane.verticalOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(message: String, pane: PaneLayout) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Open PDF", systemImage: "doc.badge.ellipsis")
        } description: {
            Text(message)
        } actions: {
            HStack(spacing: 12) {
                if session.canRetry, let onRetry {
                    Button("Try Again", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
                if session.localFileURL != nil, !session.isSavedToDownloads {
                    Button("Save File Anyway") {
                        Task {
                            if let saved = await session.saveToDownloads() {
                                onSavedToDownloads(saved)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Button("Close", role: .cancel, action: onClose)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.top, topInset)
        .padding(.leading, pane.leadingInset)
        .padding(.trailing, pane.trailingInset)
        .offset(y: pane.verticalOffset)
    }

    private var floatingControlPill: some View {
        HStack(spacing: 4) {
            if session.pageCount > 0 {
                Text("\(session.currentPageIndex + 1) / \(session.pageCount)")
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .accessibilityLabel("Page \(session.currentPageIndex + 1) of \(session.pageCount)")
                    .accessibilityIdentifier("curium.pdf.pageCounter")
            }

            if !session.outlineItems.isEmpty {
                Button {
                    showingOutline = true
                } label: {
                    Label("Table of Contents", systemImage: "list.bullet.indent")
                        .labelStyle(.iconOnly)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("curium.pdf.outline")
            }

            Button {
                if session.isSearching {
                    session.closeSearch()
                } else {
                    session.openSearch()
                }
            } label: {
                Label("Find in PDF", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(session.isSearching ? palette.tint : .primary)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("curium.pdf.find")

            Button {
                Task {
                    if let saved = await session.saveToDownloads() {
                        onSavedToDownloads(saved)
                    }
                }
            } label: {
                Group {
                    if session.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            session.isSavedToDownloads ? "Saved to Downloads" : "Save to Downloads",
                            systemImage: session.isSavedToDownloads ? "checkmark.circle.fill" : "arrow.down.to.line"
                        )
                        .labelStyle(.iconOnly)
                        .foregroundStyle(session.isSavedToDownloads ? palette.tint : .primary)
                    }
                }
                .frame(width: 38, height: 38)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(session.isSaving || session.isSavedToDownloads)
            .accessibilityIdentifier("curium.pdf.save")

            if let shareURL = session.savedDownloadURL ?? session.localFileURL {
                ShareLink(item: shareURL) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("curium.pdf.share")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: CuriumSpace.tapTarget)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func searchBar(maxWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Find in PDF", text: Binding(
                get: { session.searchQuery },
                set: { session.performSearch(query: $0) }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($searchFieldFocused)
            .onSubmit { session.nextSearchMatch() }
            .accessibilityIdentifier("curium.pdf.searchField")

            if session.isSearchInProgress {
                ProgressView().controlSize(.small)
            } else if !session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(
                    session.searchMatches.isEmpty
                        ? "0"
                        : "\(session.activeMatchIndex + 1)/\(session.searchMatches.count)"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button { session.previousSearchMatch() } label: {
                Label("Previous Match", systemImage: "chevron.up")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(session.searchMatches.isEmpty)

            Button { session.nextSearchMatch() } label: {
                Label("Next Match", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(session.searchMatches.isEmpty)

            Button { session.closeSearch() } label: {
                Label("Close Find", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: maxWidth, minHeight: CuriumSpace.tapTarget)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private struct CuriumPDFKitCanvas: UIViewRepresentable {
    let document: PDFDocument
    let topInset: CGFloat
    let bottomInset: CGFloat
    let navigationRequestID: Int
    let requestedPageIndex: Int?
    let requestedSelection: PDFSelection?
    let requestedZoomScale: CGFloat?
    let highlightedSelections: [PDFSelection]
    let highlightRevision: Int
    let onPageChanged: (Int) -> Void
    let onZoomChanged: (CGFloat) -> Void
    let onOpenLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPageChanged: onPageChanged,
            onZoomChanged: onZoomChanged,
            onOpenLink: onOpenLink
        )
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        view.delegate = context.coordinator
        applyInsets(to: view)
        context.coordinator.attach(to: view)
        return view
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        view.delegate = nil
        view.document = nil
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.onOpenLink = onOpenLink

        if view.document !== document {
            view.document = document
            view.autoScales = true
        }

        applyInsets(to: view)

        if context.coordinator.lastHighlightRevision != highlightRevision {
            context.coordinator.lastHighlightRevision = highlightRevision
            view.highlightedSelections = highlightedSelections.isEmpty ? nil : highlightedSelections
        }

        guard context.coordinator.lastNavigationRequestID != navigationRequestID else { return }
        context.coordinator.lastNavigationRequestID = navigationRequestID

        if let selection = requestedSelection {
            view.setCurrentSelection(selection, animate: true)
            view.go(to: selection)
            keepSelectionClearOfTopChrome(selection, in: view)
        } else if let pageIndex = requestedPageIndex, let page = document.page(at: pageIndex) {
            view.go(to: page)
        }

        if let requestedZoomScale {
            let fit = max(0.1, view.scaleFactorForSizeToFit)
            let clamped = min(view.maxScaleFactor, max(view.minScaleFactor, fit * requestedZoomScale))
            view.autoScales = abs(requestedZoomScale - 1.0) < 0.01
            if !view.autoScales {
                view.scaleFactor = clamped
            }
        }
    }

    private func applyInsets(to view: PDFView) {
        guard let scrollView = view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
        if scrollView.contentInsetAdjustmentBehavior != .never {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        let target = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        if abs(scrollView.contentInset.top - target.top) > 0.5
            || abs(scrollView.contentInset.bottom - target.bottom) > 0.5 {
            let wasAtTop = scrollView.contentOffset.y <= -scrollView.contentInset.top + 4
            scrollView.contentInset = target
            scrollView.verticalScrollIndicatorInsets = target
            if wasAtTop {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -target.top), animated: false)
            }
        }
    }

    private func keepSelectionClearOfTopChrome(_ selection: PDFSelection, in view: PDFView) {
        guard let page = selection.pages.first,
              let scrollView = view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
        let selectionRect = view.convert(selection.bounds(for: page), from: page)
        let desiredTop = topInset + 12
        guard selectionRect.minY < desiredTop else { return }
        let shift = desiredTop - selectionRect.minY
        let minOffsetY = -scrollView.contentInset.top
        let targetY = max(minOffsetY, scrollView.contentOffset.y - shift)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        var onPageChanged: (Int) -> Void
        var onZoomChanged: (CGFloat) -> Void
        var onOpenLink: (URL) -> Void
        var lastNavigationRequestID = 0
        var lastHighlightRevision = -1
        private weak var pdfView: PDFView?

        init(
            onPageChanged: @escaping (Int) -> Void,
            onZoomChanged: @escaping (CGFloat) -> Void,
            onOpenLink: @escaping (URL) -> Void
        ) {
            self.onPageChanged = onPageChanged
            self.onZoomChanged = onZoomChanged
            self.onOpenLink = onOpenLink
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to view: PDFView) {
            pdfView = view
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(handlePageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
            center.addObserver(
                self,
                selector: #selector(handleScaleChanged(_:)),
                name: .PDFViewScaleChanged,
                object: view
            )
        }

        nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { return }
            Task { @MainActor [weak self] in
                self?.onOpenLink(url)
            }
        }

        @objc private func handlePageChanged(_ notification: Notification) {
            guard let view = pdfView,
                  let document = view.document,
                  let page = view.currentPage else { return }
            let idx = document.index(for: page)
            if idx != NSNotFound {
                onPageChanged(idx)
            }
        }

        @objc private func handleScaleChanged(_ notification: Notification) {
            guard let view = pdfView else { return }
            let fit = max(0.1, view.scaleFactorForSizeToFit)
            onZoomChanged(view.scaleFactor / fit)
        }
    }
}

private struct CuriumPDFOutlineSheet: View {
    let title: String
    let items: [CuriumPDFOutlineItem]
    let currentPageIndex: Int
    let selectPage: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        Button {
                            selectPage(item.pageIndex)
                        } label: {
                            HStack {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                    .padding(.leading, CGFloat(item.depth) * 14)
                                Spacer()
                                Text("\(item.pageIndex + 1)")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(item.pageIndex == currentPageIndex ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                } header: {
                    Text(title)
                        .textCase(nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
    }
}
