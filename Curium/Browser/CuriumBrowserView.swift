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
    private var isFullscreen: Bool { tab?.isFullscreen == true }
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
                .allowsHitTesting(!showsStartPage)
                .accessibilityHidden(showsStartPage)

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

                if !isFullscreen {
                    CuriumStoreInstallPillOverlay(
                        store: store,
                        palette: palette,
                        bottomPadding: placement == .none ? CuriumSpace.bottomToolbarClearance : 14,
                        openExtensions: { present(.extensions) }
                    )
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
            CuriumOcclusionReader { frames in
                if occlusions == nil {
                    occlusions = frames
                } else {
                    withAnimation(.smooth(duration: 0.4)) { occlusions = frames }
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
                    currentPage: store.activeTab?.url.map {
                        CuriumBookmarkPage(url: $0, title: store.activeTab?.title ?? "")
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

    private struct TopChromeClearance: Equatable {
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

        let baseSide: CGFloat = width < 420 ? 16 : 24
        let remLeading = max(0, corner.topLeading.width - proxy.safeAreaInsets.leading)
        let remTrailing = max(0, corner.topTrailing.width - proxy.safeAreaInsets.trailing)

        // A non-zero top inset is the system status band (inner portrait and other
        // horizontal-bar postures). The address bar lives inside that band, centered
        // on the status cluster's line, and stops short of the cluster; web content
        // starts at the band's floor. The reserve covers a cluster widened by a Live
        // Activity; a wider reported occlusion region widens it further.
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

        guard #available(iOS 27.1, *) else {
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
        // A region's frame already includes the margins UIKit wants kept clear of
        // interactive content, so the bar meets it exactly, as Safari's toolbar does.
        let origin = proxy.frame(in: .global).origin
        let topBand = CGRect(x: 0, y: 0, width: width, height: 110)
        var obstacles: [CGRect] = []
        if hasStatusBand, occlusions == nil {
            let reserve = CuriumSpace.statusClusterReserve
            obstacles.append(CGRect(x: width - reserve, y: 0, width: reserve, height: safeTop))
        }
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
                    right = max(right, width - clampedMinX)
                } else {
                    left = max(left, clampedMaxX)
                }
                asymmetricHorizontalConstraint = true
                bandFloor = max(bandFloor, min(110, frame.maxY))
            } else {
                top = max(top, min(110, frame.maxY + 8))
                bandFloor = max(bandFloor, top + CuriumSpace.tapTarget + 10)
            }
        }

        // 2. Keep the chrome within one pane when a fold is active.
        for region in proxy.reservedRegions(kind: .division, options: [.includeInactive]) where region.isActive {
            let frame = region.frame
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
        .disabled(store.activeTab?.canGoBack != true)
    }
}

private struct CuriumForwardToolbarButton: View {
    let store: CuriumBrowserStore

    var body: some View {
        Button {
            store.activeTab?.goForward()
        } label: { Label("Forward", systemImage: "chevron.right") }
        .disabled(store.activeTab?.canGoForward != true)
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
    private var canScalePage: Bool { tab?.url != nil && tab?.engine != nil }

    var body: some View {
        Menu {
            pageScaleControls
            Button {
                tab?.engine?.presentFindInPage()
            } label: {
                Label("Find in Page", systemImage: "magnifyingglass")
            }
            .disabled(tab?.url == nil || tab?.engine == nil)

            Button {
                tab?.toggleDesktopSite()
            } label: {
                Label(
                    tab?.usesDesktopSite == true ? "Request Mobile Site" : "Request Desktop Site",
                    systemImage: tab?.usesDesktopSite == true ? "iphone" : "desktopcomputer"
                )
            }
            .disabled(tab?.engine == nil)

            Button { present(.bookmarks) } label: { Label("Bookmarks", systemImage: "book") }
                .accessibilityIdentifier("curium.menu.bookmarks")
            Button { present(.history) } label: { Label("History", systemImage: "clock") }
                .accessibilityIdentifier("curium.menu.history")

            Button { present(.downloads) } label: { Label("Downloads", systemImage: "arrow.down.circle") }
            Button { present(.settings) } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    /// One compact inline row, as Safari's: steps keep the menu open; the percentage resets to 100%.
    @ViewBuilder private var pageScaleControls: some View {
        let percentage = Int(((tab?.zoomScale ?? 1) * 100).rounded())
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
        let collapse = tab?.chrome.collapse(focused: focused, hasPage: tab?.url != nil) ?? 0
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
    @State private var fieldController = CuriumAddressFieldController()

    private var text: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var showsPictureInPictureButton: Bool {
        !addressFocused && (tab?.pictureInPicture.phase ?? .unavailable) != .unavailable
    }

    private var showsClearButton: Bool {
        addressFocused && !address.isEmpty
    }

    private var showsReloadButton: Bool {
        !addressFocused && tab?.engine != nil && (tab?.url != nil || tab?.isLoading == true)
    }

    private var showsTrailingActionButton: Bool {
        showsClearButton || showsReloadButton
    }

    private static func hostLabel(for url: URL?) -> String {
        let host = url?.host(percentEncoded: false) ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func refreshCachedSite(for url: URL?) {
        let nextSite = Self.hostLabel(for: url)
        guard nextSite != cachedSite else { return }
        cachedSite = nextSite
        siteWidth = (nextSite as NSString).size(withAttributes: [.font: CuriumSpace.pillUIFont]).width.rounded(.up)
    }

    var body: some View {
        // One capsule morphs between the bar and the pill; every dimension is a
        // function of the collapse, so the motion follows the page exactly.
        let collapse = tab?.chrome.collapse(focused: addressFocused, hasPage: tab?.url != nil) ?? 0
        let pillWidth = min(pillMaxWidth, siteWidth + 24)
        let width = span + (pillWidth - span) * collapse
        let height = CuriumSpace.tapTarget + (CuriumSpace.compactPillHeight - CuriumSpace.tapTarget) * collapse
        let collapsed = collapse >= 0.5
        let fieldOpacity = max(0, 1 - collapse / 0.6)
        let fieldScale = 1 - 0.22 * collapse

        VStack(spacing: 6) {
            ZStack {
                CuriumAddressInputField(
                    controller: fieldController,
                    searchEngineTitle: store.library.searchEngine.title,
                    text: $address,
                    isFocused: $addressFocused,
                    leadingInset: showsPictureInPictureButton ? CuriumSpace.tapTarget + 6 : 14,
                    trailingInset: showsClearButton
                        ? CuriumSpace.tapTarget + 24
                        : (showsReloadButton ? CuriumSpace.tapTarget + 6 : 14),
                    leadingPassthroughWidth: showsPictureInPictureButton ? CuriumSpace.tapTarget + 2 : 0,
                    trailingPassthroughWidth: showsTrailingActionButton ? CuriumSpace.tapTarget + 6 : 0,
                    onSubmit: submit
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
            .background {
                // The bar itself is the progress indicator: tint fills the glass
                // from the leading edge, under the text, then fades when the page is done.
                CuriumLoadingFill(tab: tab)
                    .id(tab?.id)
            }
            .clipShape(Capsule())
            .glassEffect(addressFocused ? .regular : .regular.interactive(), in: Capsule())
            // Keep leading/trailing controls strictly outside UITextField and above the glass
            // capsule in Z-order so neither UITextInteraction nor interactive Liquid Glass can
            // cancel touches, while UITextField passes through hits across the trailing button zone.
            .overlay(alignment: .leading) {
                if showsPictureInPictureButton, let tab {
                    let active = tab.pictureInPicture.phase == .active
                    Button { withAnimation(.smooth(duration: 0.25)) { tab.togglePictureInPicture() } } label: {
                        Label(active ? "Exit Picture in Picture" : "Picture in Picture",
                              systemImage: active ? "pip.exit" : "pip.enter")
                            .labelStyle(.iconOnly)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: CuriumSpace.tapTarget, height: CuriumSpace.tapTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                    .scaleEffect(fieldScale)
                    .opacity(fieldOpacity)
                    .allowsHitTesting(!collapsed)
                    .accessibilityHidden(collapsed)
                    .accessibilitySortPriority(2)
                    .accessibilityIdentifier("curium.address.pip")
                }
            }
            .overlay(alignment: .trailing) {
                if showsClearButton {
                    Button {
                        fieldController.clear()
                        address = ""
                        addressFocused = true
                    } label: {
                        Label("Clear Address", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: CuriumSpace.tapTarget + 4, height: CuriumSpace.tapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 2)
                    .accessibilitySortPriority(2)
                    .accessibilityIdentifier("curium.address.clear")
                } else if showsReloadButton, let tab {
                    Button { tab.reloadOrStop() } label: {
                        Label(tab.isLoading ? "Stop Loading" : "Reload",
                              systemImage: tab.isLoading ? "xmark" : "arrow.clockwise")
                            .labelStyle(.iconOnly)
                            .frame(width: CuriumSpace.tapTarget, height: CuriumSpace.tapTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 2)
                    .scaleEffect(fieldScale)
                    .opacity(fieldOpacity)
                    .allowsHitTesting(!collapsed)
                    .accessibilityHidden(collapsed)
                    .accessibilitySortPriority(2)
                    .accessibilityIdentifier("curium.address.reload")
                }
            }
            .overlay {
                Button(action: expand) { Color.clear.contentShape(Capsule()) }
                    .buttonStyle(.plain)
                    .allowsHitTesting(collapsed)
                    .accessibilityLabel("Address")
                    .accessibilityValue(Text(verbatim: cachedSite))
                    .accessibilityHint("Shows the full address bar.")
                    .accessibilityIdentifier("curium.address.compact")
                    .accessibilityHidden(!collapsed)
            }
            .offset(x: pillShift * collapse, y: (pillTop - restingTop) * collapse)
            .padding(.top, restingTop)

            if addressFocused {
                CuriumAddressMatches(library: store.library, text: text, submit: submit, open: openMatch)
            } else if tab?.pictureInPicture.phase == .refused {
                Text("Play the video you want, with sound, then try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onChange(of: tab?.id, initial: true) {
            addressFocused = false
            address = tab?.url?.absoluteString ?? ""
            refreshCachedSite(for: tab?.url)
        }
        .onChange(of: tab?.url, initial: true) {
            if !addressFocused { address = tab?.url?.absoluteString ?? "" }
            refreshCachedSite(for: tab?.url)
        }
        .onChange(of: dismissKeyboardTrigger) {
            addressFocused = false
        }
        .onChange(of: addressFocused) {
            if !addressFocused {
                // An abandoned edit gives way to the page's address.
                address = tab?.url?.absoluteString ?? ""
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

@MainActor
private final class CuriumAddressFieldController {
    weak var field: CuriumAddressUITextField?

    func clear() {
        field?.clearAddressText()
    }
}

/// Native UIKit address input paired with an imperative controller so the external
/// overlay Clear button clears selected URLs and active IME compositions synchronously
/// without ever living inside UITextField's gesture hierarchy or interactive Liquid Glass.
private struct CuriumAddressInputField: UIViewRepresentable {
    let controller: CuriumAddressFieldController
    let searchEngineTitle: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let leadingPassthroughWidth: CGFloat
    let trailingPassthroughWidth: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> CuriumAddressUITextField {
        let field = CuriumAddressUITextField()
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        controller.field = field
        applyConfiguration(to: field)
        return field
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: CuriumAddressUITextField,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? uiView.intrinsicContentSize.width,
            height: proposal.height ?? CuriumSpace.tapTarget
        )
    }

    func updateUIView(_ field: CuriumAddressUITextField, context: Context) {
        context.coordinator.parent = self
        controller.field = field
        applyConfiguration(to: field)

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
    }

    private func applyConfiguration(to field: CuriumAddressUITextField) {
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
        field.updateInsets(
            leading: leadingInset,
            trailing: trailingInset,
            leadingPassthrough: leadingPassthroughWidth,
            trailingPassthrough: trailingPassthroughWidth
        )
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
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused {
                parent.isFocused = true
            }
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

private final class CuriumAddressUITextField: UITextField {
    /// Generous clearance between the text editing rect and the trailing Clear overlay so
    /// UIKit's trailing text-selection grabber never overlaps or pulls touches from Clear.
    private static let clearEditingInset: CGFloat = CuriumSpace.tapTarget + 24

    var placeholderText = ""
    private(set) var editSessionID: UInt = 0

    private var leadingInset: CGFloat = 14
    private var trailingInset: CGFloat = 14
    private var leadingPassthroughWidth: CGFloat = 0
    private var trailingPassthroughWidth: CGFloat = 0

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

    func updateInsets(
        leading: CGFloat,
        trailing: CGFloat,
        leadingPassthrough: CGFloat,
        trailingPassthrough: CGFloat
    ) {
        let changed = leadingInset != leading
            || trailingInset != trailing
            || leadingPassthroughWidth != leadingPassthrough
            || trailingPassthroughWidth != trailingPassthrough
        guard changed else { return }
        leadingInset = leading
        trailingInset = trailing
        leadingPassthroughWidth = leadingPassthrough
        trailingPassthroughWidth = trailingPassthrough
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

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        let right = (isFirstResponder && !(text?.isEmpty ?? true))
            ? max(trailingInset, Self.clearEditingInset)
            : trailingInset
        return bounds.inset(by: UIEdgeInsets(top: 0, left: leadingInset, bottom: 0, right: right))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        let right = !(text?.isEmpty ?? true)
            ? max(trailingInset, Self.clearEditingInset)
            : trailingInset
        return bounds.inset(by: UIEdgeInsets(top: 0, left: leadingInset, bottom: 0, right: right))
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        textRect(forBounds: bounds)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if leadingPassthroughWidth > 0, point.x < leadingPassthroughWidth {
            return nil
        }
        if trailingPassthroughWidth > 0, point.x > bounds.width - trailingPassthroughWidth {
            return nil
        }
        return super.hitTest(point, with: event)
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
