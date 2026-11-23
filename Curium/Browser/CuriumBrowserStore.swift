import CuriumEngineContract
import Observation
import UIKit

@MainActor
@Observable
final class CuriumTabModel: Identifiable {
    private static let maxSnapshotPixels: CGFloat = 768

    let id: String
    private(set) var engine: (any CrIOSTabHostingV1)?
    private(set) var webView: UIView?
    private(set) var scrollView: UIScrollView?
    private(set) var url: URL?
    private(set) var title = "New Tab"
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var usesDesktopSite = false
    private(set) var zoomScale: CGFloat = 1.0
    private(set) var pageCanvasColor: UIColor?
    private(set) var isFullscreen = false
    /// Coarse flag mirroring whether this tab is currently showing the blank start page,
    /// so root browser chrome doesn't re-evaluate on every webpage URL/loading update.
    private(set) var isBlankStartPage = false
    /// Coarse flag mirroring `chrome.pinnedOpen` without exposing 120Hz `collapse` ticks
    /// to the viewport host.
    private(set) var isChromePinned = false
    /// The address bar's collapse. Updated every compositor frame while scrolling, so
    /// only the address bar's leaf views read it.
    private(set) var chrome = CuriumChromeState()
    private(set) var hasPlayingVideo = false
    private(set) var isPictureInPictureActive = false
    private(set) var extensionTabID: Int32 = -1
    private(set) var thumbnail: UIImage?
    private(set) var pdfSession: CuriumTabPDFSession?

    var isShowingPDF: Bool { pdfSession != nil }
    var displayURL: URL? { pdfSession?.displayURL ?? url }
    /// Bookmarkable web URL (excludes local `file://` URLs when viewing a saved PDF offline).
    var bookmarkableURL: URL? {
        if let pdfSession { return pdfSession.originalURL }
        return url
    }
    var displayTitle: String { pdfSession?.displayTitle ?? title }
    var effectiveCanGoBack: Bool { pdfSession != nil || canGoBack }
    var effectiveCanGoForward: Bool { pdfSession == nil && canGoForward }
    var effectiveZoomScale: CGFloat { pdfSession?.zoomScale ?? zoomScale }

    @ObservationIgnored private var history: [URL?] = [nil]
    @ObservationIgnored private var historyIndex = 0
    @ObservationIgnored private(set) var snapshotRevision = 0
    @ObservationIgnored private var configuredInitialSiteMode = false
    @ObservationIgnored private var lastRawTitle: String?

    init(id: String = UUID().uuidString) { self.id = id }

    fileprivate func matchesViewport(of engine: any CrIOSTabHostingV1) -> Bool {
        self.engine === engine && webView === engine.webView && scrollView === engine.scrollView
    }

    /// Releases engine/view references and cancels timers once the tab has been closed.
    func invalidate() {
        dismissPDFSession()
        clearSnapshot()
        if engine != nil { engine = nil }
        if webView != nil { webView = nil }
        if scrollView != nil { scrollView = nil }
        updateChrome { $0 = CuriumChromeState() }
        syncBlankStartPage()
    }

    func presentPDFSession(_ session: CuriumTabPDFSession) {
        if let existing = pdfSession, existing !== session {
            existing.cleanup()
        }
        pdfSession = session
        updateChrome { $0.unpin(.navigated) }
        clearSnapshot()
        syncBlankStartPage()
    }

    func dismissPDFSession() {
        guard let existing = pdfSession else { return }
        existing.cleanup()
        pdfSession = nil
        clearSnapshot()
        syncBlankStartPage()
    }

    /// Evaluates a synchronous JavaScript expression in Build 42's isolated content world
    /// across the primary main frame (`allFrames == false`) or all active live frames
    /// (`allFrames == true`). Returns an empty array on Build <= 41 engines or detached tabs.
    func evaluateJavaScriptInIsolatedWorld(
        _ script: String,
        allFrames: Bool = true
    ) async throws -> [CuriumIsolatedFrameEvalResult] {
        try await withCheckedThrowingContinuation { continuation in
            startIsolatedWorldEvaluation(script, allFrames: allFrames) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func startIsolatedWorldEvaluation(
        _ script: String,
        allFrames: Bool,
        completion: @escaping @MainActor (Result<[CuriumIsolatedFrameEvalResult], Error>) -> Void
    ) {
        guard let engine,
              let evaluate = engine.evaluateJavaScript(inIsolatedWorld:allFrames:completion:) else {
            completion(.success([]))
            return
        }
        evaluate(script, allFrames) { rawResults, error in
            if let error {
                completion(.failure(error))
                return
            }
            completion(.success((rawResults ?? []).map(CuriumIsolatedFrameEvalResult.parse(from:))))
        }
    }

    /// Reports the engine title when history needs to reconsider this tab.
    fileprivate func refresh(from engine: any CrIOSTabHostingV1) -> (title: String, titleChanged: Bool)? {
        let nextView = engine.webView
        let nextScroll = engine.scrollView
        if self.engine !== engine || webView !== nextView || scrollView !== nextScroll {
            clearSnapshot()
        }
        if self.engine !== engine {
            self.engine = engine
            updateChrome { $0 = CuriumChromeState() }
        }
        if webView !== nextView { webView = nextView }
        if scrollView !== nextScroll { scrollView = nextScroll }

        let newURL = engine.currentURL
        let urlChanged = url != newURL
        if urlChanged {
            url = newURL
            if newURL != nil { configuredInitialSiteMode = true }
            updateChrome { $0.unpin(.navigated) }
            clearSnapshot()
        }

        let rawTitle = engine.title
        let titleChanged = lastRawTitle != rawTitle
        if titleChanged { lastRawTitle = rawTitle }
        let newTitle = rawTitle.isEmpty ? (newURL?.host() ?? "New Tab") : rawTitle
        if title != newTitle { title = newTitle }

        let newIsLoading = engine.isLoading
        let loadingChanged = isLoading != newIsLoading
        if loadingChanged {
            isLoading = newIsLoading
            clearSnapshot()
        }

        // Update the fill in 2% steps so small samples don't retarget its animation.
        let newProgress = (min(1, max(0, engine.estimatedProgress)) * 50).rounded(.down) / 50
        if progress != newProgress { progress = newProgress }

        let newCanGoBack = engine.canGoBack
        if canGoBack != newCanGoBack { canGoBack = newCanGoBack }

        let newCanGoForward = engine.canGoForward
        if canGoForward != newCanGoForward { canGoForward = newCanGoForward }

        let newDesktop = engine.usesDesktopUserAgent
        if usesDesktopSite != newDesktop { usesDesktopSite = newDesktop }

        let newCanvas = Self.resolvedCanvasColor(from: engine, hasURL: newURL != nil)
        if pageCanvasColor != newCanvas { pageCanvasColor = newCanvas }

        let newFullscreen = engine.isWebFullscreen
        if isFullscreen != newFullscreen {
            isFullscreen = newFullscreen
            clearSnapshot()
        }

        let newHasVideo = engine.hasPlayingVideo ?? false
        if hasPlayingVideo != newHasVideo { hasPlayingVideo = newHasVideo }

        let newPiP = engine.isPictureInPictureActive ?? false
        if isPictureInPictureActive != newPiP { isPictureInPictureActive = newPiP }

        let newExtTabID = engine.extensionTabID
        if extensionTabID != newExtTabID { extensionTabID = newExtTabID }

        syncBlankStartPage()
        return urlChanged || titleChanged || loadingChanged ? (rawTitle, titleChanged) : nil
    }

    private func syncBlankStartPage() {
        let next = !isFullscreen && engine != nil && url == nil && !isLoading && pdfSession == nil
        if isBlankStartPage != next { isBlankStartPage = next }
    }

    private func updateChrome(_ transition: (inout CuriumChromeState) -> Void) {
        update(\.chrome, transition)
        let pinned = chrome.pinnedOpen
        if isChromePinned != pinned { isChromePinned = pinned }
    }

    private static func isPureWhite(_ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return r > 0.995 && g > 0.995 && b > 0.995 && a > 0.995
    }

    private static func resolvedCanvasColor(from engine: any CrIOSTabHostingV1, hasURL: Bool) -> UIColor? {
        guard hasURL else { return nil }
        // ContentWebState::GetUnderPageBackgroundColor() defaults to opaque white even on dark
        // pages without <meta name="theme-color">, whereas RenderWidgetHostViewIOS updates
        // scrollView.backgroundColor with the live SkColor from Blink's RenderFrameMetadata.
        let theme = engine.pageCanvasColor
        if let theme, !isPureWhite(theme) {
            return theme
        }
        if let liveBg = engine.scrollView?.backgroundColor {
            return liveBg
        }
        return theme
    }

    func syncScrollCanvasColor() {
        guard let engine else { return }
        let next = Self.resolvedCanvasColor(from: engine, hasURL: url != nil)
        if pageCanvasColor != next {
            pageCanvasColor = next
        }
    }

    func applyDefaultSiteModeIfBlank(_ preferDesktop: Bool) {
        guard !configuredInitialSiteMode, url == nil, let engine else { return }
        if usesDesktopSite != preferDesktop {
            CuriumSetDesktopSite(engine, preferDesktop)
            usesDesktopSite = preferDesktop
        }
    }

    func load(_ url: URL, preferDesktop: Bool? = nil) {
        dismissPDFSession()
        if let engine {
            if let preferDesktop, !configuredInitialSiteMode || self.url == nil {
                if usesDesktopSite != preferDesktop {
                    CuriumSetDesktopSite(engine, preferDesktop)
                    usesDesktopSite = preferDesktop
                }
            }
            configuredInitialSiteMode = true
            engine.load(url)
            return
        }
        guard self.url != url else { return }
        history.removeSubrange((historyIndex + 1)..<history.count)
        history.append(url)
        historyIndex += 1
        updateStandbyHistory()
    }

    func goBack() {
        if pdfSession != nil {
            dismissPDFSession()
            return
        }
        guard canGoBack else { return }
        if let engine { engine.goBack(); return }
        historyIndex -= 1
        updateStandbyHistory()
    }

    func goForward() {
        guard pdfSession == nil, canGoForward else { return }
        if let engine { engine.goForward(); return }
        historyIndex += 1
        updateStandbyHistory()
    }

    /// Blink's compositor reports the shown fraction of the top controls; nil means the
    /// engine has none.
    func reportChromeCollapse(_ collapse: CGFloat?) {
        updateChrome { $0.engineReported(collapse: collapse) }
    }

    func pinChromeOpen() { updateChrome { $0.pin() } }

    func unpinChrome(_ reason: CuriumChromeState.UnpinReason) { updateChrome { $0.unpin(reason) } }

    /// Writes a state value only when a transition changed it, so observers of an
    /// unchanged value are not woken on every engine update.
    private func update<State: Equatable>(_ keyPath: ReferenceWritableKeyPath<CuriumTabModel, State>,
                                          _ transition: (inout State) -> Void) {
        var next = self[keyPath: keyPath]
        transition(&next)
        if next != self[keyPath: keyPath] { self[keyPath: keyPath] = next }
    }

    func toggleDesktopSite() {
        guard let engine else { return }
        configuredInitialSiteMode = true
        let next = !usesDesktopSite
        usesDesktopSite = next
        CuriumSetDesktopSite(engine, next)
    }

    func setZoomScale(_ scale: CGFloat) {
        if let pdfSession {
            pdfSession.setZoomScale(scale)
            return
        }
        let clamped = min(2.0, max(0.5, scale))
        guard abs(zoomScale - clamped) > 0.001 else { return }
        zoomScale = clamped
        if let engine {
            CuriumSetPageZoom(engine, clamped)
        }
    }

    func reloadOrStop() {
        if let pdfSession {
            if let remoteURL = pdfSession.originalURL {
                load(remoteURL)
            } else if case .loading = pdfSession.phase {
                dismissPDFSession()
            }
            return
        }
        guard let engine else { return }
        if isLoading { engine.stopLoading() } else { engine.reload() }
    }

    func clearSnapshot() {
        if thumbnail != nil { thumbnail = nil }
        snapshotRevision += 1
    }

    @MainActor
    private final class SnapshotResumeGate {
        var resumed = false
    }

    /// Captures a compact SDR thumbnail asynchronously via the engine's compositor snapshot
    /// path, downscaling off the main thread so browsing never stalls.
    fileprivate func captureSnapshotAsync() async -> Bool {
        if let pdfSession {
            guard case .ready = pdfSession.phase, thumbnail == nil else { return false }
            let revision = snapshotRevision
            if let rendered = await pdfSession.makeTabThumbnailAsync(maxPixels: Self.maxSnapshotPixels) {
                guard !Task.isCancelled,
                      revision == snapshotRevision,
                      self.pdfSession === pdfSession,
                      thumbnail == nil else {
                    return false
                }
                thumbnail = rendered
                return true
            }
            return false
        }
        guard let engine, let webView, url != nil, !isLoading, !isFullscreen, thumbnail == nil else { return false }
        let bounds = webView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return false }
        guard UIApplication.shared.applicationState == .active else { return false }

        let revision = snapshotRevision
        let gate = SnapshotResumeGate()
        let rawImage: UIImage? = await withCheckedContinuation { continuation in
            engine.takeSnapshot { image in
                guard !gate.resumed else { return }
                gate.resumed = true
                continuation.resume(returning: image)
            }
        }

        guard !Task.isCancelled,
              revision == snapshotRevision,
              self.engine === engine,
              url != nil, !isLoading, !isFullscreen, thumbnail == nil else {
            return false
        }

        if let rawImage {
            let maxPixels = Self.maxSnapshotPixels
            let scaled = await Task.detached(priority: .utility) {
                Self.downscaleToSDRThumbnail(rawImage, maxPixels: maxPixels)
            }.value
            guard !Task.isCancelled,
                  revision == snapshotRevision,
                  self.engine === engine,
                  thumbnail == nil else {
                return false
            }
            thumbnail = scaled
            return true
        }

        // Fallback only when the app is still foreground-active and the view is mounted.
        guard UIApplication.shared.applicationState == .active,
              let mountedView = self.webView,
              mountedView.window != nil else {
            return false
        }
        let fallbackBounds = mountedView.bounds
        guard fallbackBounds.width > 1, fallbackBounds.height > 1 else { return false }
        let longest = max(fallbackBounds.width, fallbackBounds.height)
        let scaleFactor = min(1.0, Self.maxSnapshotPixels / longest)
        let targetSize = CGSize(
            width: max(1, (fallbackBounds.width * scaleFactor).rounded()),
            height: max(1, (fallbackBounds.height * scaleFactor).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        var complete = false
        let image = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            complete = mountedView.drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: false)
        }
        guard complete, revision == snapshotRevision, self.engine === engine, thumbnail == nil else { return false }
        thumbnail = image
        return true
    }

    private nonisolated static func downscaleToSDRThumbnail(_ image: UIImage, maxPixels: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 1, pixelHeight > 1 else { return image }
        let longest = max(pixelWidth, pixelHeight)
        let scaleFactor = min(1.0, maxPixels / longest)
        let targetSize = CGSize(
            width: max(1, (pixelWidth * scaleFactor).rounded()),
            height: max(1, (pixelHeight * scaleFactor).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func updateStandbyHistory() {
        let newURL = history[historyIndex]
        if url != newURL { url = newURL }
        let newTitle = newURL?.host() ?? "New Tab"
        if title != newTitle { title = newTitle }
        let newCanGoBack = historyIndex > 0
        if canGoBack != newCanGoBack { canGoBack = newCanGoBack }
        let newCanGoForward = historyIndex < history.count - 1
        if canGoForward != newCanGoForward { canGoForward = newCanGoForward }
        syncBlankStartPage()
    }
}

@MainActor
@Observable
final class CuriumBrowserStore: NSObject, CrIOSBrowserHostDelegateV1 {
    private static let maxRetainedSnapshots = 12
    private static let maxLiveTabs = 24
    private static let minTabAdmissionHeadroomBytes: UInt64 = 192 * 1024 * 1024
    private static let repeatVisitInterval: Duration = .seconds(2)
    private static let idleSnapshotDelay: Duration = .milliseconds(1500)
    private static let sessionSaveDebounceDelay: Duration = .milliseconds(400)

    private struct ObservedVisit {
        let url: URL
        var title: String
        var recordedAt: ContinuousClock.Instant
        var isRepeatLoad = false
    }

    private struct CommittedHistory {
        let url: URL
        var visitURL: URL?
        var title: String
    }

    private let host: (any CrIOSBrowserHostV1)?
    private let reportsNavigationCommits: Bool
    let activeProfileID: String
    let extensions: CuriumExtensionStore
    let library: CuriumLibrary
    let mediaRadar = CuriumMediaRadar()
    private(set) var tabs: [CuriumTabModel] = []
    private(set) var activeTab: CuriumTabModel?
    private(set) var downloads: [CuriumDownload] = []
    private(set) var savedDownloads: [CuriumSavedDownload] = []
    private(set) var activeDownloadBanner: CuriumDownload?
    private(set) var backgroundEpoch = 0
    private(set) var activeMediaPermissionPrompt: CuriumMediaPermissionPrompt?
    private var rootErrorMessage: String?
    /// Error triggered while a modal sheet is presented; surfaced inside the active sheet
    /// so UIKit never drops it behind the modal or leaves root `errorMessage` wedged.
    var sheetErrorMessage: String?
    var errorMessage: String? {
        get { rootErrorMessage }
        set {
            if isSheetPresented, let message = newValue {
                if rootErrorMessage != nil { rootErrorMessage = nil }
                sheetErrorMessage = message
            } else {
                rootErrorMessage = newValue
            }
            syncMediaPermissionPresentationGate()
        }
    }
    var requestShowTabs = false
    private(set) var deletedDownloadIDs: Set<String> = []

    @ObservationIgnored private var tabsByID: [String: CuriumTabModel] = [:]
    @ObservationIgnored private var historyByTabID: [String: ObservedVisit] = [:]
    @ObservationIgnored private var committedHistoryByTabID: [String: CommittedHistory] = [:]
    @ObservationIgnored private var snapshotLRU: [String] = []
    @ObservationIgnored private var lastExtensionTabID: Int32 = -1
    @ObservationIgnored private var isUnderMemoryPressure = false
    @ObservationIgnored private var isSceneBackgrounded = false
    @ObservationIgnored private var isSheetPresented = false
    @ObservationIgnored private var isRecoveringEmptyTabs = false
    @ObservationIgnored private var isRestoringSession = false
    @ObservationIgnored private var hasSyncedInitialViewportWidth = false
    @ObservationIgnored private var idleSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var idleSnapshotToken: UUID?
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var onDemandSnapshotTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var onDemandSnapshotTokens: [String: UUID] = [:]
    @ObservationIgnored private var savedDownloadsGeneration = 0
    @ObservationIgnored private var mediaPermissions: CuriumMediaPermissionCoordinator!
    @ObservationIgnored private let fingerprintStore: CuriumFingerprintStore
    @ObservationIgnored private let downloadsRootOverride: URL?
    @ObservationIgnored private let pdfPreviewCacheRootOverride: URL?
    @ObservationIgnored private let sessionDirectoryOverride: URL?
    @ObservationIgnored private(set) var viewportWidth: CGFloat = 669

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private var shouldPersistSession: Bool {
        sessionDirectoryOverride != nil || !Self.isRunningTests
    }

    var downloadsRoot: URL? { downloadsRootOverride }
    var isEngineReady: Bool { host != nil }
    var pendingOrActiveDownloadCount: Int {
        downloads.reduce(into: 0) { count, item in
            if item.state == .pending || item.isActive { count += 1 }
        }
    }

    init(
        host: (any CrIOSBrowserHostV1)? = nil,
        extensionManager: (any CrIOSExtensionManagingV1)? = nil,
        captureAuthorizer: @escaping CuriumMediaPermissionCoordinator.CaptureAuthorizer =
            CuriumMediaPermissionCoordinator.liveCaptureAuthorizer,
        downloadsRoot: URL? = nil,
        pdfPreviewCacheRoot: URL? = nil,
        activeProfileID: String = "default",
        library: CuriumLibrary? = nil,
        fingerprintStore: CuriumFingerprintStore? = nil,
        sessionDirectoryOverride: URL? = nil,
        restoreSession: Bool = true
    ) {
        let trimmedProfileID = activeProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedProfileID = trimmedProfileID.isEmpty ? "default" : trimmedProfileID
        let resolvedFingerprintStore = fingerprintStore ?? CuriumFingerprintStore.shared

        self.host = host
        self.activeProfileID = resolvedProfileID
        self.fingerprintStore = resolvedFingerprintStore
        self.library = library ?? CuriumLibrary(profileID: resolvedProfileID, fingerprintStore: resolvedFingerprintStore)
        self.downloadsRootOverride = downloadsRoot
        self.pdfPreviewCacheRootOverride = pdfPreviewCacheRoot
            ?? (try? CuriumDownloadStorage.pdfPreviewCacheRoot(profileID: resolvedProfileID))
        self.sessionDirectoryOverride = sessionDirectoryOverride
        // The optional delegate method is ours, so probing it cannot tell us
        // whether Blink sends it. Patch 0097 adds this forwarder to the host.
        reportsNavigationCommits = host?.responds(to: NSSelectorFromString(
            "tabHost:didCommitNavigationToURL:navigationID:isSameDocument:isReload:"
        )) == true
        extensions = CuriumExtensionStore(manager: host == nil ? nil : (extensionManager ?? CuriumSharedExtensionManager()))
        super.init()
        mediaPermissions = CuriumMediaPermissionCoordinator(
            isRequestCurrent: { [weak self] tabID, originKey in
                self?.isMediaPermissionRequestCurrent(tabID: tabID, originKey: originKey) == true
            },
            authorizeCapture: captureAuthorizer,
            onPromptChange: { [weak self] prompt in
                self?.activeMediaPermissionPrompt = prompt
            }
        )
        if let host {
            host.delegate = self
            updateTabs(from: host)
            let canRestoreIntoHost = tabs.isEmpty || (tabs.count == 1 && tabs[0].url == nil && !tabs[0].isLoading)
            if restoreSession, canRestoreIntoHost {
                _ = restoreSavedSessionIfAvailable()
            }
            if tabs.isEmpty { newTab() }
        } else {
            let restored = restoreSession ? restoreSavedSessionIfAvailable() : false
            if !restored && tabs.isEmpty {
                newTab()
            }
        }
        let previewRoot = pdfPreviewCacheRootOverride
        let shouldAdoptLegacyDownloads = downloadsRootOverride == nil
        Task.detached(priority: .utility) { [weak self] in
            CuriumDownloadStorage.cleanupStalePDFPreviews(cacheRoot: previewRoot)
            CuriumDownloadStorage.cleanupStaleDownloadStaging()
            if shouldAdoptLegacyDownloads, CuriumDownloadStorage.adoptLegacyGuestDownloadsIfNeeded() > 0 {
                await MainActor.run {
                    self?.refreshSavedDownloads()
                }
            }
        }
        refreshSavedDownloads()
    }

    func updateViewportWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let changed = abs(viewportWidth - width) >= 0.5
        guard changed || !hasSyncedInitialViewportWidth else { return }
        viewportWidth = width
        hasSyncedInitialViewportWidth = true
        syncDefaultSiteModeForBlankTabs()
    }

    func syncDefaultSiteModeForBlankTabs() {
        let preferDesktop = prefersDesktopByDefault()
        for tab in tabs {
            tab.applyDefaultSiteModeIfBlank(preferDesktop)
        }
    }

    private func prefersDesktopByDefault() -> Bool {
        let mode = fingerprintStore.profile(id: activeProfileID)?.resolvedSiteMode
            ?? fingerprintStore.activeProfile.resolvedSiteMode
        return mode.prefersDesktop(forViewportWidth: viewportWidth)
    }

    func handleMemoryWarning() {
        isUnderMemoryPressure = true
        cancelAllSnapshotCaptures()
        snapshotLRU.removeAll()
        for tab in tabs {
            tab.clearSnapshot()
        }
    }

    func handleSceneWillDeactivate() {
        cancelAllSnapshotCaptures()
        saveOpenTabsSession()
    }

    func handleSceneDidEnterBackground() {
        isSceneBackgrounded = true
        syncMediaPermissionPresentationGate()
        cancelAllSnapshotCaptures()
        saveOpenTabsSession()
        backgroundEpoch += 1
        // Retain at most the active tab's thumbnail in background to minimize idle footprint.
        let keepID = activeTab?.id
        snapshotLRU.removeAll { $0 != keepID }
        for tab in tabs where tab.id != keepID {
            tab.clearSnapshot()
        }
    }

    // MARK: - Per-Profile Session & Profile Switching

    func saveOpenTabsSession() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        guard shouldPersistSession, !isRestoringSession else { return }
        let activeID = activeTab?.id
        var urls: [URL] = []
        urls.reserveCapacity(tabs.count)
        var mappedActiveIndex = 0
        for tab in tabs {
            guard let candidate = tab.bookmarkableURL ?? tab.url,
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  candidate.host()?.isEmpty == false else {
                continue
            }
            if tab.id == activeID {
                mappedActiveIndex = urls.count
            }
            urls.append(candidate)
        }
        CuriumSessionStorage.save(
            urls: urls,
            activeIndex: mappedActiveIndex,
            forProfile: activeProfileID,
            directory: sessionDirectoryOverride
        )
    }

    private func scheduleSessionSave() {
        guard shouldPersistSession, !isRestoringSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.sessionSaveDebounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.sessionSaveTask = nil
            self.saveOpenTabsSession()
        }
    }

    @discardableResult
    private func restoreSavedSessionIfAvailable() -> Bool {
        guard shouldPersistSession,
              let saved = CuriumSessionStorage.load(
                  forProfile: activeProfileID,
                  directory: sessionDirectoryOverride
              ) else {
            return false
        }
        let validURLs = Array(saved.openTabURLs.compactMap(URL.init(string:)).prefix(Self.maxLiveTabs))
        guard !validURLs.isEmpty else { return false }

        isRestoringSession = true
        defer { isRestoringSession = false }

        let preferDesktop = prefersDesktopByDefault()
        let targetActiveIndex = min(max(0, saved.activeTabIndex), validURLs.count - 1)

        if let host {
            var restoredTabIDs: [String] = []
            restoredTabIDs.reserveCapacity(validURLs.count)
            for (index, url) in validURLs.enumerated() {
                if index == 0, tabs.count == 1, let existingBlank = tabs.first, existingBlank.url == nil {
                    existingBlank.load(url, preferDesktop: preferDesktop)
                    restoredTabIDs.append(existingBlank.id)
                    continue
                }
                guard let createdEngine = host.createTab(with: nil, activate: index == targetActiveIndex) else {
                    break
                }
                let createdID = createdEngine.tabID
                if tabsByID[createdID] == nil {
                    updateTabs(from: host)
                }
                if let model = tabsByID[createdID] {
                    if preferDesktop {
                        CuriumSetDesktopSite(createdEngine, true)
                        refresh(model, from: createdEngine)
                    }
                    model.load(url, preferDesktop: preferDesktop)
                    restoredTabIDs.append(createdID)
                }
            }
            updateTabs(from: host)
            if restoredTabIDs.indices.contains(targetActiveIndex) {
                let targetID = restoredTabIDs[targetActiveIndex]
                if activeTab?.id != targetID {
                    _ = host.activateTab(withID: targetID)
                    updateTabs(from: host)
                }
            }
            return !restoredTabIDs.isEmpty
        }

        for url in validURLs {
            let tab = CuriumTabModel()
            tab.load(url, preferDesktop: preferDesktop)
            tabs.append(tab)
            tabsByID[tab.id] = tab
        }
        setActiveTab(tabs.indices.contains(targetActiveIndex) ? tabs[targetActiveIndex] : tabs.first)
        return !tabs.isEmpty
    }

    @discardableResult
    func switchProfileForNextLaunch(to profileID: String) -> Bool {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard fingerprintStore.selectProfile(id: trimmed) else {
            errorMessage = fingerprintStore.lastPersistError ?? "Unable to select profile \"\(trimmed)\"."
            return false
        }
        return true
    }

    @discardableResult
    func prepareForProfileSwitchAndRelaunch(
        to profileID: String,
        relaunchHandler: (@MainActor () -> Void)? = nil
    ) async -> Bool {
        guard switchProfileForNextLaunch(to: profileID) else {
            return false
        }
        saveOpenTabsSession()
        await library.checkpointAsync()
        CuriumDiagnostics.shared.flushSync()
        CuriumProfileRelauncher.relaunchAfterFlush(customHandler: relaunchHandler)
        return true
    }

    func handleSceneWillEnterForeground() {
        isSceneBackgrounded = false
        isUnderMemoryPressure = false
        syncMediaPermissionPresentationGate()
        if let activeTab { scheduleSnapshot(for: activeTab) }
    }

    func setSheetPresented(_ presented: Bool) {
        isSheetPresented = presented
        if presented {
            if let pending = rootErrorMessage {
                rootErrorMessage = nil
                sheetErrorMessage = pending
            }
            cancelIdleSnapshotCapture()
        } else {
            if sheetErrorMessage != nil {
                sheetErrorMessage = nil
            }
            if let activeTab {
                scheduleSnapshot(for: activeTab)
            }
        }
        syncMediaPermissionPresentationGate()
    }

    func respondToActiveMediaPermissionPrompt(allowed: Bool) {
        mediaPermissions.respondToActivePrompt(allowed: allowed)
    }

    func dismissActiveMediaPermissionPromptWithoutAction() {
        mediaPermissions.dismissActivePromptWithoutAction()
    }

    private func syncMediaPermissionPresentationGate() {
        mediaPermissions?.setPresentationBlocked(
            isSheetPresented || isSceneBackgrounded || rootErrorMessage != nil
        )
    }

    private func isMediaPermissionRequestCurrent(tabID: String, originKey: String) -> Bool {
        guard !isSceneBackgrounded,
              let active = activeTab,
              active.id == tabID,
              let currentURL = active.engine?.currentURL ?? active.url,
              let currentOriginKey = CuriumMediaPermissionOrigin.key(for: currentURL) else {
            return false
        }
        return currentOriginKey == originKey
    }

    /// Captures the active tab's thumbnail on demand right as the Tabs sheet opens.
    func prepareSnapshotsForTabsSheet() {
        guard let tab = activeTab else { return }
        captureSnapshotOnDemand(for: tab)
    }

    /// Schedules a single calm idle snapshot after navigation settles. Reschedules calmly
    /// while the user is actively scrolling so snapshots are captured once scroll settles.
    func scheduleSnapshot(for tab: CuriumTabModel) {
        guard activeTab === tab else { return }
        cancelIdleSnapshotCapture()
        let pdfReady = tab.isShowingPDF && tab.pdfSession?.phase == .ready
        let pageReady = !tab.isShowingPDF && tab.engine != nil && tab.webView != nil && tab.url != nil && !tab.isLoading && !tab.isFullscreen
        guard !isUnderMemoryPressure, !isSceneBackgrounded, !isSheetPresented,
              UIApplication.shared.applicationState == .active,
              pdfReady || pageReady,
              tab.thumbnail == nil else { return }
        let targetID = tab.id
        let revision = tab.snapshotRevision
        let token = UUID()
        let initialOffset = tab.scrollView?.contentOffset
        idleSnapshotToken = token
        idleSnapshotTask = Task(priority: .utility) { @MainActor [weak self] in
            defer {
                if let self, self.idleSnapshotToken == token {
                    self.idleSnapshotToken = nil
                    self.idleSnapshotTask = nil
                }
            }
            var lastOffset = initialOffset
            let maxScrollRetries = 8
            for attempt in 0...maxScrollRetries {
                do { try await Task.sleep(for: Self.idleSnapshotDelay) } catch { return }
                guard !Task.isCancelled, let self else { return }
                guard !self.isUnderMemoryPressure, !self.isSceneBackgrounded, !self.isSheetPresented,
                      UIApplication.shared.applicationState == .active,
                      let current = self.activeTab,
                      current.id == targetID,
                      current.snapshotRevision == revision,
                      current.thumbnail == nil else { return }
                if !current.isShowingPDF, let scroll = current.scrollView {
                    let currentOffset = scroll.contentOffset
                    if scroll.isTracking || scroll.isDecelerating || currentOffset != lastOffset {
                        lastOffset = currentOffset
                        if attempt < maxScrollRetries {
                            continue
                        }
                        return
                    }
                }
                if await current.captureSnapshotAsync() {
                    guard !Task.isCancelled, self.tabsByID[targetID] === current else { return }
                    self.recordSnapshot(for: targetID)
                }
                return
            }
        }
    }

    private func captureSnapshotOnDemand(for tab: CuriumTabModel) {
        let pdfReady = tab.isShowingPDF && tab.pdfSession?.phase == .ready
        let pageReady = !tab.isShowingPDF && tab.engine != nil && tab.webView != nil && tab.url != nil && !tab.isLoading && !tab.isFullscreen
        guard !isUnderMemoryPressure, !isSceneBackgrounded,
              UIApplication.shared.applicationState == .active,
              pdfReady || pageReady,
              tab.thumbnail == nil else { return }
        let targetID = tab.id
        let revision = tab.snapshotRevision
        let token = UUID()
        onDemandSnapshotTasks[targetID]?.cancel()
        onDemandSnapshotTokens[targetID] = token
        onDemandSnapshotTasks[targetID] = Task(priority: .utility) { @MainActor [weak self] in
            defer {
                if let self, self.onDemandSnapshotTokens[targetID] == token {
                    self.onDemandSnapshotTokens.removeValue(forKey: targetID)
                    self.onDemandSnapshotTasks.removeValue(forKey: targetID)
                }
            }
            guard !Task.isCancelled, let self else { return }
            guard !self.isUnderMemoryPressure, !self.isSceneBackgrounded,
                  UIApplication.shared.applicationState == .active,
                  self.tabsByID[targetID] === tab,
                  tab.snapshotRevision == revision else { return }
            if await tab.captureSnapshotAsync() {
                guard !Task.isCancelled, self.tabsByID[targetID] === tab else { return }
                self.recordSnapshot(for: targetID)
            }
        }
    }

    private func cancelIdleSnapshotCapture() {
        idleSnapshotTask?.cancel()
        idleSnapshotTask = nil
        idleSnapshotToken = nil
    }

    private func cancelAllSnapshotCaptures() {
        cancelIdleSnapshotCapture()
        for task in onDemandSnapshotTasks.values {
            task.cancel()
        }
        onDemandSnapshotTasks.removeAll()
        onDemandSnapshotTokens.removeAll()
    }

    private func setActiveTab(_ tab: CuriumTabModel?) {
        guard activeTab !== tab else { return }
        if let previousID = activeTab?.id {
            mediaPermissions.invalidate(tabID: previousID)
        }
        cancelIdleSnapshotCapture()
        activeTab = tab
        scheduleSessionSave()
    }

    func submitAddress(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if let candidate = URL(string: text),
           let scheme = candidate.scheme?.lowercased(), ["https", "http", "chrome"].contains(scheme),
           candidate.host() != nil {
            url = candidate
        } else if !text.contains(where: \.isWhitespace), !text.contains("://"),
                  let candidate = URL(string: "https://" + text),
                  let host = candidate.host(), host.contains(".") || host == "localhost" {
            url = candidate
        } else {
            url = library.searchEngine.searchURL(for: text)
        }
        guard let url else { return }
        let preferDesktop = prefersDesktopByDefault()
        if let activeTab {
            activeTab.load(url, preferDesktop: preferDesktop)
            scheduleSessionSave()
        } else {
            newTab(url: url)
        }
    }

    private func canAdmitNewTab() -> Bool {
        if tabs.count >= Self.maxLiveTabs {
            errorMessage = "Single-process memory guard: close an unused tab before opening more than \(Self.maxLiveTabs) live tabs."
            if !isSheetPresented { requestShowTabs = true }
            return false
        }
        let avail = CuriumAvailableMemoryBytes()
        if avail > 0 && avail < Self.minTabAdmissionHeadroomBytes {
            handleMemoryWarning()
            let recheck = CuriumAvailableMemoryBytes()
            if recheck > 0 && recheck < Self.minTabAdmissionHeadroomBytes {
                errorMessage = "Low device memory headroom. Close an existing tab to keep Blink responsive."
                if !isSheetPresented { requestShowTabs = true }
                return false
            }
        }
        return true
    }

    @discardableResult
    func newTab(url: URL? = nil) -> Bool {
        if !tabs.isEmpty && !canAdmitNewTab() {
            return false
        }
        if let outgoing = activeTab {
            captureSnapshotOnDemand(for: outgoing)
        }
        let preferDesktop = prefersDesktopByDefault()
        if let host {
            // Create the tab without immediately loading a mobile-UA URL so Desktop Site
            // preference can be applied before the initial navigation commits.
            guard let createdEngine = host.createTab(with: nil, activate: true) else {
                errorMessage = "Blink could not open a new tab."
                return false
            }
            let createdID = createdEngine.tabID
            if activeTab?.id != createdID { updateTabs(from: host) }
            if let model = tabsByID[createdID] {
                if preferDesktop {
                    CuriumSetDesktopSite(createdEngine, true)
                    refresh(model, from: createdEngine)
                }
                if let url {
                    model.load(url, preferDesktop: preferDesktop)
                }
            }
        } else {
            let tab = CuriumTabModel()
            if let url { tab.load(url, preferDesktop: preferDesktop) }
            tabs.append(tab)
            tabsByID[tab.id] = tab
            setActiveTab(tab)
        }
        scheduleSessionSave()
        return true
    }

    func select(_ tab: CuriumTabModel) {
        guard activeTab?.id != tab.id else { return }
        if let outgoing = activeTab {
            captureSnapshotOnDemand(for: outgoing)
        }
        if let host {
            guard host.activateTab(withID: tab.id) else { return }
            if activeTab?.id != tab.id { updateTabs(from: host) }
        } else {
            setActiveTab(tab)
        }
    }

    func close(_ tab: CuriumTabModel) {
        onDemandSnapshotTasks.removeValue(forKey: tab.id)?.cancel()
        onDemandSnapshotTokens.removeValue(forKey: tab.id)
        mediaPermissions.invalidate(tabID: tab.id)
        mediaRadar.clear(tabID: tab.id)
        if let host {
            _ = host.closeTab(withID: tab.id)
            if tabsByID[tab.id] != nil { updateTabs(from: host) }
        } else if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            let removed = tabs.remove(at: index)
            removed.invalidate()
            tabsByID.removeValue(forKey: tab.id)
            snapshotLRU.removeAll { $0 == tab.id }
            if activeTab?.id == tab.id { setActiveTab(tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]) }
        }
        if tabs.isEmpty { newTab() }
        scheduleSessionSave()
    }

    /// Clears cookies, cache, and site storage written since `start` (all of it when nil).
    func clearWebsiteData(since start: Date?) async {
        guard let host else { return }
        do {
            try await host.clearBrowsingData(of: [.cookies, .cache, .siteStorage], modifiedSince: start ?? .distantPast)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func browserHostDidUpdateTabs(_ host: any CrIOSBrowserHostV1) {
        updateTabs(from: host)
    }

    func browserHost(_ host: any CrIOSBrowserHostV1, didUpdateTab tab: any CrIOSTabHostingV1) {
        guard let model = tabsByID[tab.tabID] else { return }
        let oldURL = model.url
        let oldExtID = model.extensionTabID
        refresh(model, from: tab)
        mediaPermissions.invalidateIfOriginChanged(tabID: tab.tabID, currentURL: model.url)
        let urlChanged = model.url != oldURL
        let contextChanged = urlChanged || model.extensionTabID != oldExtID
        if urlChanged { scheduleSessionSave() }
        if activeTab === model && contextChanged { updateExtensionContext(force: true) }
    }

    func browserHost(
        _ host: any CrIOSBrowserHostV1,
        requestMediaPermissions permissions: CrIOSMediaPermissionTypes,
        origin: URL,
        forTab tab: any CrIOSTabHostingV1,
        completion: @escaping @MainActor (CrIOSMediaPermissionTypes) -> Void
    ) {
        mediaPermissions.enqueue(
            permissions: CuriumMediaPermissions(engineTypes: permissions),
            originURL: origin,
            tabID: tab.tabID
        ) { granted in
            completion(granted.engineTypes)
        }
    }

    func browserHost(
        _ host: any CrIOSBrowserHostV1,
        tab: any CrIOSTabHostingV1,
        didLoadResourceEvent event: [String: Any]
    ) {
        if let captured = mediaRadar.ingest(
            rawEvent: event,
            tabID: tab.tabID,
            effectiveUserAgent: tab.effectiveUserAgent ?? nil
        ) {
            CuriumDiagnostics.shared.record(
                "media-radar",
                "[\(captured.kind.rawValue)] method=\(captured.httpMethod ?? "-") mime=\(captured.mimeType ?? "-") status=\(captured.httpStatusCode) len=\(captured.contentLength)"
            )
        }
    }

    func browserHost(
        _ host: any CrIOSBrowserHostV1, tab: any CrIOSTabHostingV1,
        didCommitNavigationTo url: URL, navigationID _: Int64, isSameDocument: Bool, isReload _: Bool
    ) {
        if !isSameDocument {
            mediaPermissions.invalidate(tabID: tab.tabID)
            mediaRadar.clear(tabID: tab.tabID)
            tabsByID[tab.tabID]?.dismissPDFSession()
            scheduleSessionSave()
        }
        guard reportsNavigationCommits else { return }
        let tabID = tab.tabID
        let previous = committedHistoryByTabID[tabID]
        var history = CommittedHistory(url: url, visitURL: nil, title: "")
        // A fragment-only commit still belongs to the last recorded visit.
        if isSameDocument && !Self.changedPathOrQuery(from: previous?.url, to: url) {
            history.visitURL = previous?.visitURL
            history.title = previous?.title ?? ""
        } else if Self.isHistoryURL(url) {
            history.visitURL = url
            // A new document can still expose the previous page's title while loading.
            if tab.currentURL == url && (isSameDocument || !tab.isLoading) {
                history.title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            library.recordVisit(url: url, title: history.title)
        }
        committedHistoryByTabID[tabID] = history
    }

    private static func changedPathOrQuery(from previous: URL?, to url: URL) -> Bool {
        guard let previous else { return false }
        return previous.path(percentEncoded: true) != url.path(percentEncoded: true)
            || previous.query(percentEncoded: true) != url.query(percentEncoded: true)
    }

    private static func isHistoryURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && url.host()?.isEmpty == false
    }

    private func refresh(_ tab: CuriumTabModel, from engine: any CrIOSTabHostingV1) {
        let revision = tab.snapshotRevision
        let wasLoading = tab.isLoading
        if let update = tab.refresh(from: engine) {
            if reportsNavigationCommits {
                updateCommittedTitle(for: tab, rawTitle: update.title, titleChanged: update.titleChanged)
            } else {
                noteHistory(for: tab, rawTitle: update.title, titleChanged: update.titleChanged, wasLoading: wasLoading)
            }
        }
        if tab.snapshotRevision != revision {
            scheduleSnapshot(for: tab)
        }
    }

    private func updateCommittedTitle(for tab: CuriumTabModel, rawTitle: String, titleChanged: Bool) {
        guard var history = committedHistoryByTabID[tab.id], history.url == tab.url,
              let visitURL = history.visitURL, !tab.isLoading || titleChanged else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, history.title != title else { return }
        history.title = title
        committedHistoryByTabID[tab.id] = history
        library.updateTitle(title, for: visitURL)
    }

    private func noteHistory(for tab: CuriumTabModel, rawTitle: String, titleChanged: Bool, wasLoading: Bool) {
        // Older engines expose only the visible URL, which can be provisional.
        guard let url = tab.url, Self.isHistoryURL(url) else {
            historyByTabID.removeValue(forKey: tab.id)
            return
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPageTitle = !tab.isLoading || titleChanged
        let now = ContinuousClock.now
        guard var visit = historyByTabID[tab.id], visit.url == url else {
            // A pending URL may still be paired with the previous page's title.
            let initialTitle = hasPageTitle ? title : ""
            historyByTabID[tab.id] = ObservedVisit(url: url, title: initialTitle, recordedAt: now)
            library.recordVisit(url: url, title: initialTitle)
            return
        }
        if !wasLoading && tab.isLoading {
            // Require a new loading cycle after the first visit's coalesced updates.
            visit.isRepeatLoad = now - visit.recordedAt > Self.repeatVisitInterval
        } else if wasLoading && !tab.isLoading && visit.isRepeatLoad {
            visit.isRepeatLoad = false
            visit.recordedAt = now
            if !title.isEmpty { visit.title = title }
            library.recordVisit(url: url, title: title)
        } else if hasPageTitle, !title.isEmpty, visit.title != title {
            visit.title = title
            library.updateTitle(title, for: url)
        }
        historyByTabID[tab.id] = visit
    }

    func browserHost(_ host: any CrIOSBrowserHostV1, didCreateDownload download: any CrIOSDownloadTaskV1) {
        let filename = CuriumDownloadStorage.sanitizedFilename(download.suggestedFilename)
        let isExplicit = download.isExplicitDownload ?? false
        let isMainFrame = download.isMainFrame ?? true
        let httpMethod = (download.httpMethod ?? "GET")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let shouldPreviewPDFInline = CuriumDownloadStorage.isPDF(
            mimeType: download.mimeType,
            filename: filename,
            url: download.originalURL
        ) && !isExplicit && isMainFrame && (httpMethod.isEmpty || httpMethod == "GET")

        if shouldPreviewPDFInline,
           let targetTab = (download.sourceTabID.flatMap { tabsByID[$0] }) ?? activeTab {
            // Stream implicit main-frame GET PDFs into an isolated temporary preview cache
            // inside the tab so casually viewing a PDF never pollutes Documents/Curium/Downloads/.
            // Explicit downloads (<a download> / Content-Disposition: attachment), subframe
            // downloads, and POST responses fall through to the explicit download banner.
            let session = CuriumTabPDFSession(
                downloadTask: download,
                cacheRoot: pdfPreviewCacheRootOverride,
                onReady: { [weak self, weak targetTab] in
                    guard let self, let targetTab else { return }
                    targetTab.clearSnapshot()
                    self.scheduleSnapshot(for: targetTab)
                }
            )
            targetTab.presentPDFSession(session)
            return
        }

        let item = CuriumDownload(task: download)
        guard !downloads.contains(where: { $0.id == item.id }) else { return }
        downloads.insert(item, at: 0)
        activeDownloadBanner = item
    }

    func startDownload(_ item: CuriumDownload) async {
        let saved = await item.start(downloadsRoot: downloadsRootOverride)
        if saved != nil {
            refreshSavedDownloads()
        }
    }

    func dismissDownloadBanner() {
        activeDownloadBanner = nil
    }

    func openSavedPDFInActiveTab(_ item: CuriumSavedDownload) {
        guard item.isPDF else { return }
        let targetTab: CuriumTabModel?
        if let active = activeTab {
            targetTab = active
        } else {
            newTab()
            targetTab = activeTab
        }
        guard let targetTab else { return }
        let session = CuriumTabPDFSession(
            savedFileURL: item.url,
            filename: item.filename,
            onReady: { [weak self, weak targetTab] in
                guard let self, let targetTab else { return }
                targetTab.clearSnapshot()
                self.scheduleSnapshot(for: targetTab)
            }
        )
        targetTab.presentPDFSession(session)
    }

    /// Returns the saved file URL for an in-session download only if it has not been deleted.
    func savedURL(for item: CuriumDownload) -> URL? {
        guard !deletedDownloadIDs.contains(item.id) else { return nil }
        return item.savedURL
    }

    func refreshSavedDownloads() {
        savedDownloadsGeneration += 1
        let generation = savedDownloadsGeneration
        let rootOverride = downloadsRootOverride
        Task.detached(priority: .utility) {
            let items = CuriumDownloadStorage.listSavedDownloads(in: rootOverride)
            await MainActor.run { [weak self] in
                guard let self, self.savedDownloadsGeneration == generation else { return }
                if self.savedDownloads != items {
                    self.savedDownloads = items
                }
            }
        }
    }

    func deleteSavedDownload(_ item: CuriumSavedDownload) {
        let rootOverride = downloadsRootOverride
        do {
            try CuriumDownloadStorage.deleteSavedDownload(at: item.url, downloadsRoot: rootOverride)
            savedDownloadsGeneration += 1
            savedDownloads.removeAll { $0.id == item.id }
            let deletedCanonical = item.url.resolvingSymlinksInPath().standardizedFileURL
            for download in downloads {
                if let saved = download.savedURL,
                   saved.resolvingSymlinksInPath().standardizedFileURL == deletedCanonical {
                    deletedDownloadIDs.insert(download.id)
                    if activeDownloadBanner?.id == download.id {
                        activeDownloadBanner = nil
                    }
                }
            }
            for tab in tabs {
                if tab.pdfSession?.handleSavedFileDeleted(at: item.url) == true {
                    tab.dismissPDFSession()
                }
            }
        } catch {
            errorMessage = "Couldn’t delete “\(item.filename)”: \(error.localizedDescription)"
        }
    }

    func clearFinishedDownloadTasks() {
        downloads.removeAll { !$0.isActive && $0.state != .pending }
        let remainingIDs = Set(downloads.map(\.id))
        deletedDownloadIDs.formIntersection(remainingIDs)
        if let banner = activeDownloadBanner, !remainingIDs.contains(banner.id) {
            activeDownloadBanner = nil
        }
    }

    private func recordSnapshot(for tabID: String) {
        guard tabsByID[tabID] != nil else { return }
        snapshotLRU.removeAll { $0 == tabID }
        snapshotLRU.append(tabID)
        while snapshotLRU.count > Self.maxRetainedSnapshots {
            guard let evictIndex = snapshotLRU.firstIndex(where: { $0 != activeTab?.id }) else { break }
            let evictID = snapshotLRU.remove(at: evictIndex)
            tabsByID[evictID]?.clearSnapshot()
        }
    }

    private func updateTabs(from host: any CrIOSBrowserHostV1) {
        let hostTabs = host.tabs
        let activeEngine = host.activeTab
        let activeID = activeEngine?.tabID

        let orderMatches = hostTabs.count == tabs.count
            && zip(hostTabs, tabs).allSatisfy { $0.tabID == $1.id }
        let activeMatches = activeTab?.id == activeID
        let viewportsMatch = orderMatches
            && zip(hostTabs, tabs).allSatisfy { $1.matchesViewport(of: $0) }
        let activeViewportMatches = activeEngine.map { activeTab?.matchesViewport(of: $0) == true } ?? true

        if viewportsMatch && activeMatches && activeViewportMatches && !hostTabs.isEmpty {
            updateExtensionContext(force: false)
            return
        }

        if viewportsMatch, let activeEngine, let nextActive = tabsByID[activeEngine.tabID] {
            refresh(nextActive, from: activeEngine)
            setActiveTab(nextActive)
            updateExtensionContext(force: true)
            return
        }

        var nextTabs: [CuriumTabModel] = []
        nextTabs.reserveCapacity(hostTabs.count)
        var nextIndex: [String: CuriumTabModel] = [:]
        nextIndex.reserveCapacity(hostTabs.count)

        for listedEngine in hostTabs {
            let tabID = listedEngine.tabID
            let engine = activeEngine.flatMap { $0.tabID == tabID ? $0 : nil } ?? listedEngine
            if let existing = tabsByID[tabID] {
                if tabID == activeID || !existing.matchesViewport(of: engine) {
                    refresh(existing, from: engine)
                }
                nextTabs.append(existing)
                nextIndex[tabID] = existing
            } else {
                let created = CuriumTabModel(id: tabID)
                refresh(created, from: engine)
                nextTabs.append(created)
                nextIndex[tabID] = created
            }
        }

        var evictedAny = false
        for (evictedID, evictedTab) in tabsByID where nextIndex[evictedID] == nil {
            evictedAny = true
            onDemandSnapshotTasks.removeValue(forKey: evictedID)?.cancel()
            onDemandSnapshotTokens.removeValue(forKey: evictedID)
            mediaPermissions.invalidate(tabID: evictedID)
            mediaRadar.clear(tabID: evictedID)
            evictedTab.invalidate()
            historyByTabID.removeValue(forKey: evictedID)
            committedHistoryByTabID.removeValue(forKey: evictedID)
        }

        if !orderMatches { tabs = nextTabs }
        tabsByID = nextIndex
        if evictedAny {
            snapshotLRU.removeAll { nextIndex[$0] == nil }
        }

        setActiveTab(activeID.flatMap { nextIndex[$0] })
        updateExtensionContext(force: !activeMatches || !activeViewportMatches)
        if !orderMatches || evictedAny {
            scheduleSessionSave()
        }

        if hostTabs.isEmpty && !isRecoveringEmptyTabs {
            isRecoveringEmptyTabs = true
            defer { isRecoveringEmptyTabs = false }
            newTab()
        }
    }

    private func updateExtensionContext(force: Bool) {
        let currentExtTabID = activeTab?.extensionTabID ?? -1
        guard force || currentExtTabID != lastExtensionTabID else { return }
        lastExtensionTabID = currentExtTabID
        extensions.scheduleContextRefresh(tabID: currentExtTabID)
    }
}
