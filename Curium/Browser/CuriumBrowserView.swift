import SwiftUI
import UIKit

struct CuriumBrowserView: View {
    @Bindable var store: CuriumBrowserStore
    @Binding var palette: CuriumPalette
    @Binding var siteMode: CuriumSiteMode
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var placement = CuriumVerticalBarPlacement.none
    /// Active occlusion regions in window coordinates; nil until UIKit reports them.
    @State private var occlusions: [CGRect]?
    @State private var sheet: Destination?
    @State private var dismissKeyboardTrigger = 0
    @State private var addressFocused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate enum Destination: Hashable, Identifiable {
        case tabs, extensions, downloads, bookmarks, history, settings

        var id: Self { self }
    }

    private var tab: CuriumTabModel? { store.activeTab }
    private var isFullscreen: Bool { tab?.isFullscreen == true && tab?.isShowingPDF != true }
    private var showsStartPage: Bool { tab?.isBlankStartPage == true }

    var body: some View {
        GeometryReader { proxy in
            let clearance = topChromeClearance(in: proxy)
            let restingTopInset: CGFloat = isFullscreen ? 0 : clearance.bandFloor

            ZStack(alignment: .top) {
                CuriumPageCanvas(tab: tab)
                    .ignoresSafeArea(.all)

                CuriumBlinkViewportHost(
                    tab: tab,
                    restingTopInset: restingTopInset,
                    viewportSize: CGSize(
                        width: proxy.size.width,
                        height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                    ),
                    isChromePinned: tab?.isChromePinned == true,
                    standby: CuriumStandbyPage(
                        tab: tab, topInset: restingTopInset, engineReady: store.isEngineReady, palette: palette
                    ),
                    scheduleSnapshot: store.scheduleSnapshot(for:)
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .ignoresSafeArea(.keyboard)
                .allowsHitTesting(!showsStartPage && tab?.isShowingPDF != true && !addressFocused)
                .accessibilityHidden(showsStartPage || tab?.isShowingPDF == true)

                if let pdfSession = tab?.pdfSession {
                    CuriumInlinePDFView(
                        session: pdfSession,
                        topInset: restingTopInset,
                        bottomPadding: placement == .none ? CuriumSpace.bottomToolbarClearance : 14,
                        palette: palette,
                        onClose: { tab?.dismissPDFSession() },
                        onRetry: pdfSession.originalURL.map { url in { tab?.load(url) } },
                        onOpenLink: { tab?.load($0) },
                        onSavedToDownloads: { _ in store.refreshSavedDownloads() },
                        onSaveError: { store.errorMessage = $0 }
                    )
                    .id(pdfSession.id)
                }

                if !isFullscreen {
                    CuriumReadingEdge(
                        tab: tab, focused: addressFocused,
                        height: clearance.pillTop + CuriumSpace.compactPillHeight + 22
                    )
                }

                if showsStartPage {
                    CuriumStartPage(store: store, topInset: clearance.bandFloor)
                        .ignoresSafeArea(.container, edges: .top)
                        .ignoresSafeArea(.keyboard)
                }

                if !isFullscreen && addressFocused {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { addressFocused = false }
                        .accessibilityHidden(true)
                }

                if !isFullscreen {
                    CuriumAddressBar(
                        store: store,
                        tab: tab,
                        dismissKeyboardTrigger: dismissKeyboardTrigger,
                        restingTop: clearance.top,
                        pillTop: clearance.pillTop,
                        pillShift: clearance.pillShift,
                        pillMaxWidth: clearance.pillMaxWidth,
                        span: max(0, proxy.size.width - clearance.leading - clearance.trailing),
                        addressFocused: $addressFocused,
                        expand: { withAnimation(chromeAnimation) { tab?.pinChromeOpen() } }
                    )
                    .frame(maxWidth: .infinity)
                    // Center the pill in the same available span as the field.
                    .padding(.leading, clearance.leading)
                    .padding(.trailing, clearance.trailing)
                    .padding(.bottom, 8)
                    .frame(
                        height: max(0, min(proxy.size.height + proxy.safeAreaInsets.top, clearance.panelBottom)),
                        alignment: .top
                    )
                    .ignoresSafeArea(.container, edges: .top)
                }

                if !isFullscreen, tab?.isShowingPDF != true {
                    CuriumStoreInstallPillOverlay(
                        store: store,
                        palette: palette,
                        bottomPadding: placement == .none ? CuriumSpace.bottomToolbarClearance : 14,
                        openExtensions: { present(.extensions) }
                    )
                }

                if !isFullscreen, let bannerDownload = store.activeDownloadBanner {
                    let pdfStackOffset: CGFloat = {
                        guard let pdf = tab?.pdfSession, case .ready = pdf.phase else { return 0 }
                        return pdf.isSearching ? 114 : 58
                    }()
                    CuriumDownloadBannerOverlay(
                        store: store,
                        download: bannerDownload,
                        palette: palette,
                        bottomPadding: (placement == .none ? CuriumSpace.bottomToolbarClearance : 14) + pdfStackOffset,
                        openDownloads: {
                            store.dismissDownloadBanner()
                            present(.downloads)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: proxy.size.width, initial: true) { _, newWidth in
                store.updateViewportWidth(newWidth)
            }
            .alert(
                store.activeMediaPermissionPrompt?.title ?? "",
                isPresented: Binding(
                    get: { store.activeMediaPermissionPrompt != nil },
                    set: { if !$0 { store.dismissActiveMediaPermissionPromptWithoutAction() } }
                ),
                presenting: store.activeMediaPermissionPrompt
            ) { _ in
                Button("Don’t Allow", role: .cancel) {
                    store.respondToActiveMediaPermissionPrompt(allowed: false)
                }
                Button("Allow") {
                    store.respondToActiveMediaPermissionPrompt(allowed: true)
                }
            }
        }
        .background {
            CuriumVerticalBarReader { placement = $0 }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            // Spans the whole window: UIKit reports only regions that overlap the view.
            // The first report snaps into place; later ones (a Live Activity widening
            // or releasing the island) move the bar in step with the island's own spring.
            CuriumOcclusionReader { frames, shouldAnimate in
                if shouldAnimate {
                    withAnimation(.smooth(duration: 0.4)) { occlusions = frames }
                } else {
                    occlusions = frames
                }
            }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(isFullscreen ? .hidden : .visible, for: .bottomBar)
        .toolbar { browserToolbar }
        .onChange(of: store.requestShowTabs) { _, requested in
            if requested {
                store.requestShowTabs = false
                present(.tabs)
            }
        }
        .sheet(item: $sheet, onDismiss: { store.setSheetPresented(false) }) { item in
            switch item {
            case .tabs: CuriumTabsSheet(store: store)
            case .extensions: CuriumExtensionsSheet(browser: store)
            case .downloads: CuriumDownloadsSheet(store: store)
            case .bookmarks:
                CuriumLibrarySheet(
                    store: store, section: .bookmarks,
                    currentPage: store.activeTab?.bookmarkableURL.map {
                        CuriumBookmarkPage(url: $0, title: store.activeTab?.displayTitle ?? "")
                    }
                )
            case .history: CuriumLibrarySheet(store: store, section: .history)
            case .settings:
                CuriumSettingsSheet(
                    palette: $palette, siteMode: $siteMode,
                    library: store.library, engineReady: store.isEngineReady
                )
            }
        }
        .alert("Curium", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            CuriumBackToolbarButton(store: store)
            CuriumForwardToolbarButton(store: store)
            Spacer()
            Button {
                store.newTab()
            } label: { Label("New Tab", systemImage: "plus") }
            CuriumExtensionsToolbarButton(extensions: store.extensions) { present(.extensions) }
            CuriumTabsToolbarButton(store: store) { present(.tabs) }
            CuriumOverflowToolbarMenu(store: store, present: present)
        }
    }

    private var chromeAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.32) }

    private func present(_ destination: Destination) {
        if destination == .tabs {
            store.prepareSnapshotsForTabsSheet()
        }
        store.setSheetPresented(true)
        dismissKeyboardTrigger += 1
        sheet = destination
    }

    struct TopChromeClearance: Equatable {
        let leading: CGFloat
        let trailing: CGFloat
        let top: CGFloat
        /// Top edge of the collapsed pill.
        let pillTop: CGFloat
        /// Horizontal travel that centers the pill on the window, and the widest pill
        /// that stays clear of the status cluster once centered. Zero travel in a fold.
        let pillShift: CGFloat
        let pillMaxWidth: CGFloat
        let bandFloor: CGFloat
        let panelBottom: CGFloat
    }

    private func topChromeClearance(in proxy: GeometryProxy) -> TopChromeClearance {
        let width = proxy.size.width
        let safeTop = proxy.safeAreaInsets.top
        let corner = proxy.containerCornerInsets
        let remLeading = max(0, corner.topLeading.width - proxy.safeAreaInsets.leading)
        let remTrailing = max(0, corner.topTrailing.width - proxy.safeAreaInsets.trailing)

        guard #available(iOS 27.1, *) else {
            return Self.resolveTopChromeClearance(
                width: width,
                safeTop: safeTop,
                remLeading: remLeading,
                remTrailing: remTrailing,
                origin: proxy.frame(in: .global).origin,
                occlusions: nil,
                activeDivisions: [],
                supportsReservedRegions: false,
                layoutDirection: layoutDirection
            )
        }

        let activeDivisions = proxy
            .reservedRegions(kind: .division, options: [.includeInactive])
            .filter(\.isActive)
            .map(\.frame)

        return Self.resolveTopChromeClearance(
            width: width,
            safeTop: safeTop,
            remLeading: remLeading,
            remTrailing: remTrailing,
            origin: proxy.frame(in: .global).origin,
            occlusions: occlusions,
            activeDivisions: activeDivisions,
            supportsReservedRegions: true,
            layoutDirection: layoutDirection
        )
    }

    static func resolveTopChromeClearance(
        width: CGFloat,
        safeTop: CGFloat,
        remLeading: CGFloat,
        remTrailing: CGFloat,
        origin: CGPoint,
        occlusions: [CGRect]?,
        activeDivisions: [CGRect],
        supportsReservedRegions: Bool = true,
        layoutDirection: LayoutDirection = .leftToRight
    ) -> TopChromeClearance {
        let baseSide: CGFloat = width < 420 ? 16 : 24

        // A non-zero top inset is the system status band (inner portrait and other
        // horizontal-bar postures). The address bar lives inside that band, centered
        // on the status cluster's line, and stops short of the cluster with an
        // interactive safety gap; web content starts at the band's floor.
        // Without a status band (vertical-bar postures), the bar rises into the top
        // edge and clears the 59 pt physical corners concentrically
        // (R_screen = 59, R_cap = 22; radialClearance = 37 - hypot(37 - side, 37 - top)):
        // - Inner Landscape (remLeading == 59): top = 20, side = 36 -> 19.97 pt radial.
        // - Outer Portrait (hinge corner 8 pt): top = 14, side = 16.
        let hasStatusBand = safeTop > 0
        let exposedHardwareCorner = !hasStatusBand && max(remLeading, remTrailing) > 20
        let sideClearance: CGFloat = exposedHardwareCorner ? 36 : baseSide

        var left = sideClearance
        var right = sideClearance
        var top: CGFloat
        var bandFloor: CGFloat
        if hasStatusBand {
            top = max(6, CuriumSpace.statusCenterline - CuriumSpace.tapTarget / 2)
            bandFloor = max(safeTop, top + CuriumSpace.tapTarget + 6)
            // Until UIKit reports the cluster, assume it is as wide as it gets.
            if occlusions == nil { right = max(right, CuriumSpace.statusClusterReserve) }
        } else {
            top = exposedHardwareCorner ? 20 : 14
            bandFloor = top + CuriumSpace.tapTarget + 10
        }

        guard supportsReservedRegions else {
            return TopChromeClearance(
                leading: layoutDirection == .leftToRight ? left : right,
                trailing: layoutDirection == .leftToRight ? right : left,
                top: top,
                pillTop: CuriumSpace.compactPillTop,
                pillShift: 0,
                pillMaxWidth: max(0, width - left - right),
                bandFloor: bandFloor,
                panelBottom: .infinity
            )
        }

        var asymmetricHorizontalConstraint = hasStatusBand
        var foldClaimsSide = false
        var panelBottom: CGFloat = .infinity

        // 1. Top-edge hardware/status .occlusion inside our width.
        // Regions arrive in window coordinates; the band starts at the window's top edge.
        // Keep an explicit interactive gap (`occlusionGap`) outside the reported cluster
        // boundary so trailing controls stay well clear of system status/Control Center gates.
        let topBand = CGRect(x: 0, y: 0, width: width, height: 110)
        var obstacles: [CGRect] = []
        for windowFrame in occlusions ?? [] {
            let frame = windowFrame.offsetBy(dx: -origin.x, dy: safeTop - origin.y)
            guard frame.height < 160,
                  frame.minX < width - 2,
                  frame.maxX > 2,
                  frame.intersects(topBand) else { continue }
            obstacles.append(frame)
            let clampedMinX = max(0, frame.minX)
            let clampedMaxX = min(width, frame.maxX)
            let leftRoom = clampedMinX - left
            let rightRoom = width - right - clampedMaxX
            if max(leftRoom, rightRoom) >= 160 {
                if leftRoom >= rightRoom {
                    right = max(right, width - clampedMinX + CuriumSpace.occlusionGap)
                } else {
                    left = max(left, clampedMaxX + CuriumSpace.occlusionGap)
                }
                asymmetricHorizontalConstraint = true
                bandFloor = max(bandFloor, min(110, frame.maxY))
            } else {
                top = max(top, min(110, frame.maxY + 8))
                bandFloor = max(bandFloor, top + CuriumSpace.tapTarget + 10)
            }
        }

        // Guard against empty occlusion arrays or one-frame stale post-rotation coordinates
        // inside a horizontal status band so the bar never extends under the status cluster.
        if hasStatusBand, obstacles.isEmpty {
            let fallbackReserve = occlusions == nil
                ? CuriumSpace.statusClusterReserve
                : CuriumSpace.statusClusterIdleReserve
            right = max(right, fallbackReserve)
            let clampedReserve = min(width, fallbackReserve)
            obstacles.append(CGRect(x: width - clampedReserve, y: 0, width: clampedReserve, height: safeTop))
        }

        // 2. Keep the chrome within one pane when a fold is active.
        for frame in activeDivisions {
            guard frame.minX < width - 2,
                  frame.maxX > 2 else { continue }
            if frame.width > frame.height {
                panelBottom = min(panelBottom, frame.minY + safeTop)
                continue
            }
            let leftRoom = frame.minX - left
            let rightRoom = width - right - frame.maxX
            if leftRoom >= rightRoom && leftRoom >= 160 {
                right = max(right, width - frame.minX + 20)
                asymmetricHorizontalConstraint = true
                foldClaimsSide = true
            } else if rightRoom >= 160 {
                left = max(left, frame.maxX + 20)
                asymmetricHorizontalConstraint = true
                foldClaimsSide = true
            }
        }

        // Preserve exact left-right symmetry whenever neither an active status occlusion
        // nor an active fold division claims one side of the top band.
        if !asymmetricHorizontalConstraint {
            let sym = max(left, right)
            left = sym
            right = sym
        }

        // The pill settles on the window's center line unless a fold confines the bar
        // to one pane; offsets are physical, so mirror them for right-to-left layout.
        let physicalShift = foldClaimsSide ? 0 : (right - left) / 2
        let pillCenter = foldClaimsSide ? (left + width - right) / 2 : width / 2
        let pill = Self.compactPill(
            centerX: pillCenter,
            maxWidth: foldClaimsSide ? width - left - right : width - 2 * sideClearance,
            obstacles: obstacles
        )
        return TopChromeClearance(
            leading: layoutDirection == .leftToRight ? left : right,
            trailing: layoutDirection == .leftToRight ? right : left,
            top: top,
            pillTop: pill.top,
            pillShift: layoutDirection == .leftToRight ? physicalShift : -physicalShift,
            pillMaxWidth: pill.maxWidth,
            bandFloor: bandFloor,
            panelBottom: panelBottom
        )
    }

    /// Places the collapsed pill on `centerX`, in the highest row that clears every
    /// obstacle (occlusion regions, in top-edge coordinates). An obstacle beside the
    /// center narrows the pill; one across the center, or a squeeze below a
    /// readable width, moves the row below the obstacles in it.
    static func compactPill(
        centerX: CGFloat,
        maxWidth: CGFloat,
        obstacles: [CGRect]
    ) -> (top: CGFloat, maxWidth: CGFloat) {
        let height = CuriumSpace.compactPillHeight
        let minWidth = 2 * CuriumSpace.tapTarget
        var top = CuriumSpace.compactPillTop
        while true {
            let inRow = obstacles.filter { $0.minY < top + height && $0.maxY > top }
            var half = max(0, maxWidth / 2)
            var straddling: [CGRect] = []
            for frame in inRow {
                if frame.minX >= centerX {
                    half = min(half, frame.minX - centerX)
                } else if frame.maxX <= centerX {
                    half = min(half, centerX - frame.maxX)
                } else {
                    straddling.append(frame)
                }
            }
            let width = max(0, 2 * half)
            if straddling.isEmpty, width >= minWidth || inRow.isEmpty { return (top, width) }
            let blockers = straddling.isEmpty ? inRow : straddling
            top = (blockers.map(\.maxY).max() ?? top) + 6
        }
    }
}

private struct CuriumBackToolbarButton: View {
    let store: CuriumBrowserStore

    var body: some View {
        Button {
            store.activeTab?.goBack()
        } label: { Label("Back", systemImage: "chevron.left") }
        .disabled(store.activeTab?.effectiveCanGoBack != true)
    }
}

private struct CuriumForwardToolbarButton: View {
    let store: CuriumBrowserStore

    var body: some View {
        Button {
            store.activeTab?.goForward()
        } label: { Label("Forward", systemImage: "chevron.right") }
        .disabled(store.activeTab?.effectiveCanGoForward != true)
    }
}

private struct CuriumTabsToolbarButton: View {
    let store: CuriumBrowserStore
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label("Tabs", systemImage: "square.on.square")
        }
        .accessibilityValue(Text(store.tabs.count, format: .number))
    }
}

private struct CuriumOverflowToolbarMenu: View {
    let store: CuriumBrowserStore
    let present: (CuriumBrowserView.Destination) -> Void

    private var tab: CuriumTabModel? { store.activeTab }
    private var canScalePage: Bool {
        if let pdf = tab?.pdfSession {
            return pdf.phase == .ready
        }
        return tab?.url != nil && tab?.engine != nil
    }
    private var canFindInPage: Bool {
        if let pdf = tab?.pdfSession {
            return pdf.phase == .ready
        }
        return tab?.url != nil && tab?.engine != nil
    }

    var body: some View {
        Menu {
            pageScaleControls
            Button {
                if let pdf = tab?.pdfSession {
                    pdf.openSearch()
                } else {
                    tab?.engine?.presentFindInPage()
                }
            } label: {
                Label(tab?.isShowingPDF == true ? "Find in PDF" : "Find in Page", systemImage: "magnifyingglass")
            }
            .disabled(!canFindInPage)

            Button {
                tab?.toggleDesktopSite()
            } label: {
                Label(
                    tab?.usesDesktopSite == true ? "Request Mobile Site" : "Request Desktop Site",
                    systemImage: tab?.usesDesktopSite == true ? "iphone" : "desktopcomputer"
                )
            }
            .disabled(tab?.engine == nil || tab?.isShowingPDF == true)

            Button { present(.bookmarks) } label: { Label("Bookmarks", systemImage: "book") }
                .accessibilityIdentifier("curium.menu.bookmarks")
            Button { present(.history) } label: { Label("History", systemImage: "clock") }
                .accessibilityIdentifier("curium.menu.history")

            Button { present(.downloads) } label: {
                let pending = store.pendingOrActiveDownloadCount
                Label(
                    pending > 0 ? "Downloads (\(pending))" : "Downloads",
                    systemImage: "arrow.down.circle"
                )
            }
            .accessibilityIdentifier("curium.menu.downloads")
            Button { present(.settings) } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    /// One compact inline row, as Safari's: steps keep the menu open; the percentage resets to 100%.
    @ViewBuilder private var pageScaleControls: some View {
        let percentage = Int(((tab?.effectiveZoomScale ?? 1) * 100).rounded())
        let value = Text(Double(percentage) / 100, format: .percent.precision(.fractionLength(0)))
        ControlGroup {
            Button { setPageScale(percentage - 5) } label: {
                Label("Decrease Page Scale", systemImage: "minus")
            }
            .disabled(!canScalePage || percentage <= 50)

            Button { setPageScale(100) } label: { value }
                .disabled(!canScalePage || percentage == 100)
                .accessibilityLabel("Page Scale")
                .accessibilityValue(value)
                .accessibilityHint("Resets to 100 percent.")

            Button { setPageScale(percentage + 5) } label: {
                Label("Increase Page Scale", systemImage: "plus")
            }
            .disabled(!canScalePage || percentage >= 200)
        }
        .controlGroupStyle(.palette)
        .labelStyle(.iconOnly)
        .menuActionDismissBehavior(.disabled)
        .accessibilityIdentifier("curium.pagescale")
    }

    private func setPageScale(_ percentage: Int) {
        tab?.setZoomScale(CGFloat(min(200, max(50, percentage))) / 100)
    }
}

private struct CuriumStoreInstallPillOverlay: View {
    let store: CuriumBrowserStore
    let palette: CuriumPalette
    let bottomPadding: CGFloat
    let openExtensions: () -> Void

    var body: some View {
        if let storeID = CuriumExtensionStore.storeExtensionID(from: store.activeTab?.url) {
            let alreadyInstalled = store.extensions.isInstalled(storeID)
            VStack {
                Spacer()
                Button {
                    if alreadyInstalled {
                        openExtensions()
                    } else {
                        store.extensions.prepareStoreExtension(id: storeID)
                        openExtensions()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if store.extensions.isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: alreadyInstalled ? "checkmark.circle.fill" : "plus.circle.fill")
                                .font(.callout.weight(.semibold))
                        }
                        Text(alreadyInstalled ? "Installed in Curium" : "Add to Curium")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(alreadyInstalled ? AnyShapeStyle(.secondary) : AnyShapeStyle(palette.tint))
                    .padding(.horizontal, 18)
                    .frame(minHeight: CuriumSpace.tapTarget)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityIdentifier("curium.store.install")
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, bottomPadding)
        .ignoresSafeArea(.keyboard)
        }
    }
}

/// Floating Liquid Glass download prompt & progress bar for non-PDF downloads.
private struct CuriumDownloadBannerOverlay: View {
    let store: CuriumBrowserStore
    @Bindable var download: CuriumDownload
    let palette: CuriumPalette
    let bottomPadding: CGFloat
    let openDownloads: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let pane = bannerPane(in: proxy)
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: statusIcon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(palette.tint)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(download.filename)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if download.isActive {
                            if let fraction = download.fraction {
                                ProgressView(value: fraction)
                                    .tint(palette.tint)
                            } else {
                                Text("Downloading…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let failure = download.failure {
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if download.state == .completed {
                            Text("Saved to Downloads")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let size = download.formattedByteSize {
                            Text(size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Ready to download")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if download.isActive {
                        Button {
                            download.cancel()
                        } label: {
                            Text("Cancel")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if download.state == .pending {
                        Button {
                            Task { await store.startDownload(download) }
                        } label: {
                            Text("Download")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.tint)
                        .controlSize(.small)
                        .accessibilityIdentifier("curium.download.banner.start")
                    } else if download.state == .completed {
                        Button("View", action: openDownloads)
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(palette.tint)
                            .controlSize(.small)
                            .accessibilityIdentifier("curium.download.banner.view")
                    }

                    Button {
                        store.dismissDownloadBanner()
                    } label: {
                        Label("Dismiss Download Banner", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("curium.download.banner.dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: min(480, pane.maxWidth), minHeight: CuriumSpace.tapTarget + 6)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .padding(.leading, pane.leading)
            .padding(.trailing, pane.trailing)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pane.alignment)
        }
        .ignoresSafeArea(.keyboard)
        .task(id: download.isActive) {
            guard download.isActive else { return }
            while !Task.isCancelled && download.isActive {
                download.refresh()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
    }

    private func bannerPane(in proxy: GeometryProxy) -> (leading: CGFloat, trailing: CGFloat, maxWidth: CGFloat, alignment: Alignment) {
        let width = proxy.size.width
        guard #available(iOS 27.1, *) else {
            return (16, 16, max(240, width - 32), .center)
        }
        for region in proxy.reservedRegions(kind: .division, options: [.includeInactive]) where region.isActive {
            let frame = region.frame
            guard frame.height > frame.width, frame.minX < width - 2, frame.maxX > 2 else { continue }
            let leftRoom = max(0, frame.minX - 28)
            let rightRoom = max(0, width - frame.maxX - 28)
            if leftRoom >= rightRoom, leftRoom >= 220 {
                return (16, width - frame.minX + 12, leftRoom, .leading)
            } else if rightRoom >= 220 {
                return (frame.maxX + 12, 16, rightRoom, .trailing)
            }
        }
        return (16, 16, max(240, width - 32), .center)
    }

    private var statusIcon: String {
        switch download.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "arrow.down.circle.fill"
        }
    }
}

private struct CuriumExtensionsToolbarButton: View {
    let extensions: CuriumExtensionStore
    let open: () -> Void

    var body: some View {
        let badge = extensions.badge
        Button(action: open) {
            Label("Extensions", systemImage: "puzzlepiece.extension")
        }
        .badge(badge.map { Text(verbatim: $0) })
        .accessibilityValue(Text(verbatim: badge ?? ""))
    }
}

private struct CuriumPageCanvas: View {
    let tab: CuriumTabModel?

    var body: some View {
        Color(uiColor: tab?.pageCanvasColor ?? .systemBackground)
    }
}

/// Soft canvas-tinted gradient veil behind the collapsed pill. Permanently mounted and
/// driven purely by GPU opacity so scroll start never allocates a backdrop blur pass.
private struct CuriumReadingEdge: View {
    let tab: CuriumTabModel?
    let focused: Bool
    let height: CGFloat

    var body: some View {
        let collapse = tab?.chrome.collapse(focused: focused, hasPage: tab?.url != nil && tab?.isShowingPDF != true) ?? 0
        let base = Color(uiColor: tab?.pageCanvasColor ?? .systemBackground)
        LinearGradient(
            stops: [
                .init(color: base.opacity(0.92), location: 0),
                .init(color: base.opacity(0.72), location: 0.45),
                .init(color: base.opacity(0), location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .opacity(collapse)
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CuriumAddressBar: View {
    let store: CuriumBrowserStore
    let tab: CuriumTabModel?
    let dismissKeyboardTrigger: Int
    /// Top edges of the full bar and of the pill it collapses into.
    let restingTop: CGFloat
    let pillTop: CGFloat
    let pillShift: CGFloat
    let pillMaxWidth: CGFloat
    /// Width of the full bar.
    let span: CGFloat
    @Binding var addressFocused: Bool
    let expand: () -> Void

    @State private var address = ""
    @State private var cachedSite = ""
    @State private var siteWidth: CGFloat = 0

    private var text: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canReload: Bool {
        if let pdf = tab?.pdfSession {
            return pdf.originalURL != nil
        }
        return tab?.engine != nil && (tab?.url != nil || tab?.isLoading == true)
    }

    private static func addressDisplayText(for tab: CuriumTabModel?) -> String {
        guard let tab else { return "" }
        if let pdf = tab.pdfSession {
            return pdf.originalURL?.absoluteString ?? pdf.displayTitle
        }
        return tab.url?.absoluteString ?? ""
    }

    private static func hostLabel(for tab: CuriumTabModel?) -> String {
        if let pdf = tab?.pdfSession {
            if let host = pdf.originalURL?.host(percentEncoded: false), !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return pdf.displayTitle
        }
        let host = tab?.url?.host(percentEncoded: false) ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func refreshCachedSite(for tab: CuriumTabModel?) {
        let nextSite = Self.hostLabel(for: tab)
        guard nextSite != cachedSite else { return }
        cachedSite = nextSite
        siteWidth = (nextSite as NSString).size(withAttributes: [.font: CuriumSpace.pillUIFont]).width.rounded(.up)
    }

    var body: some View {
        // One capsule morphs between the bar and the pill; every dimension is a
        // function of the collapse, so the motion follows the page exactly.
        let collapse = tab?.chrome.collapse(
            focused: addressFocused,
            hasPage: tab?.url != nil && tab?.isShowingPDF != true
        ) ?? 0
        let pillWidth = min(pillMaxWidth, siteWidth + 24)
        let width = span + (pillWidth - span) * collapse
        let height = CuriumSpace.tapTarget + (CuriumSpace.compactPillHeight - CuriumSpace.tapTarget) * collapse
        let collapsed = collapse >= 0.5
        let fieldOpacity = max(0, 1 - collapse / 0.6)
        let fieldScale = 1 - 0.22 * collapse

        VStack(spacing: 6) {
            ZStack {
                CuriumAddressInputField(
                    searchEngineTitle: store.library.searchEngine.title,
                    text: $address,
                    isFocused: $addressFocused,
                    canReload: canReload,
                    isLoading: tab?.isLoading == true,
                    isInteractive: !collapsed,
                    onSubmit: submit,
                    onReloadOrStop: { tab?.reloadOrStop() }
                )
                .frame(width: span, height: CuriumSpace.tapTarget)
                .scaleEffect(fieldScale)
                .opacity(fieldOpacity)
                .allowsHitTesting(!collapsed)
                .accessibilityHidden(collapsed)

                Text(verbatim: cachedSite)
                    .font(CuriumSpace.pillFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: max(0, pillWidth - 24))
                    .scaleEffect(1.18 - 0.18 * collapse)
                    .opacity(min(1, max(0, (collapse - 0.25) / 0.5)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: width, height: height)
            .clipShape(Capsule())
            .background {
                // Keep the Liquid Glass capsule and progress tint strictly behind the UIKit
                // address container with hit-testing disabled so focus changes never mutate
                // glass interactivity or intercept touches meant for Clear/Reload.
                Color.clear
                    .overlay {
                        CuriumLoadingFill(tab: tab)
                            .id(tab?.id)
                    }
                    .clipShape(Capsule())
                    .glassEffect(.regular, in: Capsule())
                    .allowsHitTesting(false)
            }
            .overlay {
                if collapsed {
                    Button(action: expand) { Color.clear.contentShape(Capsule()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Address")
                        .accessibilityValue(Text(verbatim: cachedSite))
                        .accessibilityHint("Shows the full address bar.")
                        .accessibilityIdentifier("curium.address.compact")
                }
            }
            .offset(x: pillShift * collapse, y: (pillTop - restingTop) * collapse)
            .padding(.top, restingTop)

            if addressFocused {
                CuriumAddressMatches(library: store.library, text: text, submit: submit, open: openMatch)
            }
        }
        .onChange(of: tab?.id, initial: true) {
            addressFocused = false
            address = Self.addressDisplayText(for: tab)
            refreshCachedSite(for: tab)
        }
        .onChange(of: tab?.displayURL, initial: true) {
            if !addressFocused { address = Self.addressDisplayText(for: tab) }
            refreshCachedSite(for: tab)
        }
        .onChange(of: tab?.isShowingPDF) {
            if !addressFocused { address = Self.addressDisplayText(for: tab) }
            refreshCachedSite(for: tab)
        }
        .onChange(of: dismissKeyboardTrigger) {
            addressFocused = false
        }
        .onChange(of: addressFocused) {
            if !addressFocused {
                // An abandoned edit gives way to the page's address.
                address = Self.addressDisplayText(for: tab)
            }
        }
    }

    private func submit() {
        addressFocused = false
        store.submitAddress(text)
    }

    private func openMatch(_ url: URL) {
        addressFocused = false
        if let tab = store.activeTab {
            tab.load(url)
        } else {
            store.newTab(url: url)
        }
    }
}

/// Unified UIKit address-bar representable hosting `CuriumAddressUITextField` alongside
/// dedicated sibling `UIButton`s for Clear and Reload so touches never fall through to
/// Blink's `RenderWidgetUIView` and an edit-time Clear press can never mutate into Reload.
private struct CuriumAddressInputField: UIViewRepresentable {
    let searchEngineTitle: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let canReload: Bool
    let isLoading: Bool
    let isInteractive: Bool
    let onSubmit: () -> Void
    let onReloadOrStop: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> CuriumAddressFieldContainerView {
        let container = CuriumAddressFieldContainerView()
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.textField.delegate = context.coordinator
        container.textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        container.onClear = { [weak coordinator = context.coordinator] in
            coordinator?.handleClear()
        }
        container.onReloadOrStop = { [weak coordinator = context.coordinator] in
            coordinator?.handleReloadOrStop()
        }
        applyConfiguration(to: container)
        return container
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: CuriumAddressFieldContainerView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? uiView.intrinsicContentSize.width,
            height: proposal.height ?? CuriumSpace.tapTarget
        )
    }

    func updateUIView(_ container: CuriumAddressFieldContainerView, context: Context) {
        context.coordinator.parent = self
        applyConfiguration(to: container)

        let field = container.textField
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }

        if isFocused, !field.isFirstResponder {
            if field.window != nil {
                field.becomeFirstResponder()
            } else {
                DispatchQueue.main.async { [weak field] in
                    guard let field, !field.isFirstResponder, field.window != nil else { return }
                    field.becomeFirstResponder()
                }
            }
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }

        container.updateTrailingState(
            isFocused: isFocused,
            canReload: canReload,
            isLoading: isLoading,
            isInteractive: isInteractive
        )
    }

    private func applyConfiguration(to container: CuriumAddressFieldContainerView) {
        let field = container.textField
        let promptText = "Search \(searchEngineTitle) or enter address"
        if field.placeholderText != promptText {
            field.placeholderText = promptText
            field.attributedPlaceholder = NSAttributedString(
                string: promptText,
                attributes: [
                    .foregroundColor: UIColor.secondaryLabel,
                    .font: UIFont.preferredFont(forTextStyle: .body),
                ]
            )
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CuriumAddressInputField

        init(parent: CuriumAddressInputField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            let next = textField.text ?? ""
            if parent.text != next {
                parent.text = next
            }
            (textField.superview as? CuriumAddressFieldContainerView)?.refreshTrailingVisibility()
        }

        func handleClear() {
            if parent.text != "" {
                parent.text = ""
            }
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func handleReloadOrStop() {
            parent.onReloadOrStop()
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused {
                parent.isFocused = true
            }
            (textField.superview as? CuriumAddressFieldContainerView)?.markEditingBegan()
            guard let curiumField = textField as? CuriumAddressUITextField else { return }
            let session = curiumField.beginEditSession()
            if !(curiumField.text?.isEmpty ?? true) {
                DispatchQueue.main.async { [weak curiumField] in
                    guard let curiumField,
                          curiumField.editSessionID == session,
                          curiumField.isFirstResponder,
                          !(curiumField.text?.isEmpty ?? true) else { return }
                    curiumField.selectAll(nil)
                }
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            (textField.superview as? CuriumAddressFieldContainerView)?.recordEditingEnded()
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

/// Opaque UIKit container owning `textField` alongside distinct sibling `clearButton`
/// and `reloadButton` controls so every point inside the capsule returns a UIKit view
/// (never falling through to Blink), Clear preserves first responder & clears IME marked
/// text synchronously, and Reload cannot fire from an edit-session press or focus-loss race.
@MainActor
final class CuriumAddressFieldContainerView: UIView {
    static let trailingButtonWidth: CGFloat = CuriumSpace.tapTarget + 4
    static let reloadCooldownAfterEditing: CFTimeInterval = 0.25

    let textField = CuriumAddressUITextField()
    let clearButton = UIButton(type: .system)
    let reloadButton = UIButton(type: .system)

    var onClear: (() -> Void)?
    var onReloadOrStop: (() -> Void)?
    var clock: () -> CFTimeInterval = CACurrentMediaTime

    private var isFocusedState = false
    private var canReloadState = false
    private var isLoadingState = false
    private var lastIsLoadingRendered: Bool?
    private var lastEditingEndedAt: CFTimeInterval = -.greatestFiniteMagnitude

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        configureClearButton()
        configureReloadButton()

        addSubview(textField)
        addSubview(clearButton)
        addSubview(reloadButton)

        refreshTrailingVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    private func configureClearButton() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        )
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 2)
        clearButton.configuration = config
        clearButton.isPointerInteractionEnabled = true
        clearButton.accessibilityLabel = "Clear Address"
        clearButton.accessibilityIdentifier = "curium.address.clear"
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
    }

    private func configureReloadButton() {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 2)
        reloadButton.configuration = config
        reloadButton.isPointerInteractionEnabled = true
        reloadButton.accessibilityIdentifier = "curium.address.reload"
        reloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)
        syncReloadAppearance(isLoading: false)
    }

    private func syncReloadAppearance(isLoading: Bool) {
        guard lastIsLoadingRendered != isLoading else { return }
        lastIsLoadingRendered = isLoading
        var config = reloadButton.configuration ?? .plain()
        config.image = UIImage(
            systemName: isLoading ? "xmark" : "arrow.clockwise",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)
        )
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 2)
        reloadButton.configuration = config
        reloadButton.accessibilityLabel = isLoading ? "Stop Loading" : "Reload"
    }

    func updateTrailingState(isFocused: Bool, canReload: Bool, isLoading: Bool, isInteractive: Bool) {
        isFocusedState = isFocused
        canReloadState = canReload
        isLoadingState = isLoading
        isUserInteractionEnabled = isInteractive
        syncReloadAppearance(isLoading: isLoading)
        refreshTrailingVisibility()
    }

    func markEditingBegan() {
        isFocusedState = true
        refreshTrailingVisibility()
    }

    func recordEditingEnded() {
        lastEditingEndedAt = clock()
        isFocusedState = false
        refreshTrailingVisibility()
    }

    func refreshTrailingVisibility() {
        let editing = isFocusedState || textField.isFirstResponder
        let hasText = !(textField.text?.isEmpty ?? true)
        let showClear = editing && hasText
        let showReload = !editing && canReloadState
        let visibilityChanged = (clearButton.isHidden == showClear) || (reloadButton.isHidden == showReload)

        clearButton.isHidden = !showClear
        clearButton.isEnabled = showClear
        reloadButton.isHidden = !showReload
        reloadButton.isEnabled = showReload

        let hasButton = showClear || showReload
        textField.updateInsets(leading: 14, trailing: hasButton ? 18 : 14)

        if !isUserInteractionEnabled {
            accessibilityElements = []
        } else if showClear {
            accessibilityElements = [textField, clearButton]
        } else if showReload {
            accessibilityElements = [textField, reloadButton]
        } else {
            accessibilityElements = [textField]
        }

        if visibilityChanged {
            setNeedsLayout()
        }
    }

    @objc func clearTapped() {
        textField.clearAddressText()
        refreshTrailingVisibility()
        onClear?()
    }

    @objc func reloadTapped() {
        guard !textField.isFirstResponder,
              !isFocusedState,
              canReloadState,
              clock() - lastEditingEndedAt >= Self.reloadCooldownAfterEditing else { return }
        onReloadOrStop?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let slotWidth = min(bounds.width, Self.trailingButtonWidth)
        let hasButton = !clearButton.isHidden || !reloadButton.isHidden
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft

        let buttonFrame: CGRect
        let fieldFrame: CGRect
        if hasButton {
            if isRTL {
                buttonFrame = CGRect(x: 0, y: 0, width: slotWidth, height: bounds.height)
                fieldFrame = CGRect(
                    x: slotWidth,
                    y: 0,
                    width: max(0, bounds.width - slotWidth),
                    height: bounds.height
                )
            } else {
                buttonFrame = CGRect(x: bounds.width - slotWidth, y: 0, width: slotWidth, height: bounds.height)
                fieldFrame = CGRect(
                    x: 0,
                    y: 0,
                    width: max(0, bounds.width - slotWidth),
                    height: bounds.height
                )
            }
        } else {
            buttonFrame = CGRect(
                x: isRTL ? 0 : bounds.width - slotWidth,
                y: 0,
                width: slotWidth,
                height: bounds.height
            )
            fieldFrame = bounds
        }

        if textField.frame != fieldFrame { textField.frame = fieldFrame }
        if clearButton.frame != buttonFrame { clearButton.frame = buttonFrame }
        if reloadButton.frame != buttonFrame { reloadButton.frame = buttonFrame }
    }
}

final class CuriumAddressUITextField: UITextField {
    var placeholderText = ""
    private(set) var editSessionID: UInt = 0

    private var leadingInset: CGFloat = 14
    private var trailingInset: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        borderStyle = .none
        backgroundColor = .clear
        font = UIFont.preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textColor = .label
        keyboardType = .webSearch
        returnKeyType = .go
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        enablesReturnKeyAutomatically = false
        clearButtonMode = .never
        rightView = nil
        accessibilityIdentifier = "curium.address"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    func beginEditSession() -> UInt {
        editSessionID &+= 1
        return editSessionID
    }

    func updateInsets(leading: CGFloat, trailing: CGFloat) {
        guard leadingInset != leading || trailingInset != trailing else { return }
        leadingInset = leading
        trailingInset = trailing
        setNeedsLayout()
    }

    func clearAddressText() {
        editSessionID &+= 1
        unmarkText()
        selectedTextRange = nil
        text = ""
        if isFirstResponder, let start = textRange(from: beginningOfDocument, to: beginningOfDocument) {
            selectedTextRange = start
        }
    }

    private func directionalInsets() -> UIEdgeInsets {
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        return UIEdgeInsets(
            top: 0,
            left: isRTL ? trailingInset : leadingInset,
            bottom: 0,
            right: isRTL ? leadingInset : trailingInset
        )
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: directionalInsets())
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: directionalInsets())
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        textRect(forBounds: bounds)
    }
}

private struct CuriumLoadingFill: View {
    let tab: CuriumTabModel?

    private struct LoadSample: Equatable {
        let url: URL?
        let isLoading: Bool
        let progress: Double
    }

    @State private var fraction = 0.0
    @State private var visible = false

    var body: some View {
        let sample = LoadSample(url: tab?.url, isLoading: tab?.isLoading == true, progress: tab?.progress ?? 0)
        Rectangle()
            .fill(.tint.opacity(0.24))
            // A horizontal scale animates on the render server without relayout.
            .scaleEffect(x: fraction, anchor: .leading)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: sample, initial: true) { previous, current in
                if current.isLoading {
                    // Blink can replace a load without dropping isLoading.
                    let restarted = current.progress <= previous.progress - 0.20
                    let changedURL = current.url != previous.url
                    if !visible || !previous.isLoading || restarted || changedURL {
                        let progress = changedURL && previous.isLoading && !restarted ? 0 : current.progress
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            fraction = max(0.06, progress)
                            visible = true
                        }
                    } else if current.progress > fraction {
                        withAnimation(.smooth(duration: 0.35)) { fraction = current.progress }
                    }
                } else if visible {
                    withAnimation(.smooth(duration: 0.2)) { fraction = 1 }
                    withAnimation(.easeOut(duration: 0.35).delay(0.2)) { visible = false }
                }
            }
    }
}

struct CuriumStandbyPage: View {
    let tab: CuriumTabModel?
    let topInset: CGFloat
    let engineReady: Bool
    let palette: CuriumPalette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("96").font(.system(.caption, design: .monospaced).weight(.semibold))
                    Text("Cm").font(.system(size: 40, weight: .medium, design: .serif))
                        .tracking(-2.5)
                }
                .foregroundStyle(palette.tint)
                .frame(width: 96, height: 96)
                .background(palette.tile, in: .rect(cornerRadius: 22))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Curium, element 96")

                VStack(alignment: .leading, spacing: 9) {
                    Text(tab?.url?.host() ?? "Curium")
                        .font(.system(.largeTitle, design: .serif).weight(.medium))
                    Text(engineReady ? "Waiting for Blink to open a tab." :
                         "Tabs and address history are available for this session. Loading websites requires Blink.")
                        .font(.callout)
                        .foregroundStyle(CuriumSpace.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label("ENGINE STANDBY", systemImage: "circle.dotted")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(palette.tint)
            }
            .frame(maxWidth: 380, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, topInset + 46)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
