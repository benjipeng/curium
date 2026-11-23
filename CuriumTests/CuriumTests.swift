import CoreMedia
import CuriumEngineContract
import Darwin
import Foundation
import PDFKit
import Testing
import UIKit

// MARK: - Protocol Mocks

@MainActor
private final class MockTabHost: NSObject, CrIOSTabHostingV1, CrIOSTabBrowserControlsV1 {
    let tabID: String
    var extensionTabID: Int32
    let webView: UIView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let scrollView: UIScrollView? = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    var currentURL: URL?
    var title: String
    var isLoading = false
    var estimatedProgress = 0.0
    var canGoBack = false
    var canGoForward = false
    var usesDesktopUserAgent = false
    var pageCanvasColor: UIColor?
    var isWebFullscreen = false
    var topControlsHeight: CGFloat = 0
    var topControlsShownRatio: CGFloat = 1.0
    var hasPlayingVideo = false
    var isPictureInPictureActive = false

    private(set) var loadedURLs: [URL] = []
    private(set) var goBackCallCount = 0
    private(set) var snapshotCallCount = 0
    var snapshotImageToReturn: UIImage?

    init(
        tabID: String = UUID().uuidString,
        extensionTabID: Int32 = 1,
        url: URL? = nil,
        title: String = ""
    ) {
        self.tabID = tabID
        self.extensionTabID = extensionTabID
        self.currentURL = url
        self.title = title
        super.init()
    }

    func load(_ url: URL) {
        loadedURLs.append(url)
        currentURL = url
    }

    func goBack() { goBackCallCount += 1 }
    func goForward() {}
    func reload() {}
    func stopLoading() {}
    func setUsesDesktopUserAgent(_ desktop: Bool) { usesDesktopUserAgent = desktop }
    func presentFindInPage() {}
    func setPageZoomScale(_ scale: CGFloat) {}

    func takeSnapshot(completion: @escaping @MainActor (UIImage?) -> Void) {
        snapshotCallCount += 1
        completion(snapshotImageToReturn)
    }

    var isolatedEvalHandler: ((String, Bool) -> ([[String: Any]]?, Error?))?

    func evaluateJavaScript(
        inIsolatedWorld script: String,
        allFrames: Bool,
        completion: @escaping @MainActor ([[String: Any]]?, Error?) -> Void
    ) {
        if let handler = isolatedEvalHandler {
            let (results, error) = handler(script, allFrames)
            completion(results, error)
        } else {
            completion([], nil)
        }
    }
}

@MainActor
private final class MockBrowserHost: NSObject, CrIOSBrowserHostV1 {
    weak var delegate: (any CrIOSBrowserHostDelegateV1)?
    var tabs: [any CrIOSTabHostingV1] = []
    var activeTab: (any CrIOSTabHostingV1)?
    var failCreateTab = false

    func createTab(with url: URL?, activate: Bool) -> (any CrIOSTabHostingV1)? {
        guard !failCreateTab else { return nil }
        let tab = MockTabHost(extensionTabID: Int32(tabs.count + 1), url: url)
        tabs.append(tab)
        if activate || activeTab == nil { activeTab = tab }
        return tab
    }

    func activateTab(withID tabID: String) -> Bool {
        guard let target = tabs.first(where: { $0.tabID == tabID }) else { return false }
        activeTab = target
        return true
    }

    func closeTab(withID tabID: String) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.tabID == tabID }) else { return false }
        let removed = tabs.remove(at: idx)
        if activeTab?.tabID == removed.tabID {
            activeTab = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)]
        }
        return true
    }

    func clearBrowsingData(
        of types: CrIOSBrowsingDataTypes,
        modifiedSince date: Date,
        completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) {
        completion(nil)
    }

    func cookieHeader(
        for url: URL,
        inTabWithID tabID: String,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        completion(nil)
    }
}

private final class MockExtensionManager: NSObject, CrIOSExtensionManagingV1 {
    var entries: [[String: Any]] = []
    var actionSnapshots: [String: [String: Any]] = [:]
    var blockedCounts: [String: NSNumber] = [:]
    var actionCalls: [(String, Int32)] = []
    var extensionsCalls = 0
    var actionObserver: (@MainActor (String?) -> Void)?

    func extensions() throws -> [[String: Any]] {
        extensionsCalls += 1
        return entries
    }

    func setExtensionWithID(_ extensionId: String?, enabled: Bool) throws {
        if let extensionId,
           let idx = entries.firstIndex(where: { ($0["id"] as? String) == extensionId }) {
            entries[idx]["enabled"] = enabled
        }
    }

    func actionPresentationForExtension(withID extensionID: String, tabID: Int32) throws -> [String: Any] {
        actionCalls.append((extensionID, tabID))
        return actionSnapshots[extensionID] ?? [:]
    }

    func observeActionPresentationChanges(handler: @escaping @MainActor (String?) -> Void) -> (any NSObjectProtocol)? {
        actionObserver = handler
        return NSObject()
    }

    func blockedRequestCountForExtension(withID extensionID: String, tabID: Int32) throws -> NSNumber {
        blockedCounts[extensionID] ?? 0
    }

    func popupForExtension(withID extensionID: String, tabID: Int32) throws -> any CrIOSExtensionPopupHostingV1 {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }

    func commandsForExtension(withID extensionID: String) throws -> [[String: String]] { [] }
    func dispatchCommandNamed(_ commandName: String, toExtensionWithID extensionID: String) throws {}
}

@MainActor
private final class MockDownloadTask: NSObject, CrIOSDownloadTaskV1 {
    let downloadID: String
    let sourceTabID: String?
    let originalURL: URL?
    let suggestedFilename: String
    let mimeType: String?
    var isExplicitDownload: Bool
    var isMainFrame: Bool
    var httpMethod: String
    var totalBytes: Int64
    var receivedBytes: Int64
    var state: CrIOSDownloadState

    var payloadToWrite: Data?
    var errorToReturn: (any Error)?
    var holdInProgressUntilCancelled = false
    private(set) var startedDestinationURL: URL?
    private(set) var startCallCount = 0
    private(set) var cancelCount = 0
    private var pendingCompletion: (@MainActor (URL?, (any Error)?) -> Void)?

    init(
        downloadID: String = UUID().uuidString,
        sourceTabID: String? = nil,
        originalURL: URL? = nil,
        suggestedFilename: String,
        mimeType: String? = nil,
        isExplicitDownload: Bool = false,
        isMainFrame: Bool = true,
        httpMethod: String = "GET",
        totalBytes: Int64 = -1,
        payloadToWrite: Data? = nil,
        errorToReturn: (any Error)? = nil,
        holdInProgressUntilCancelled: Bool = false
    ) {
        self.downloadID = downloadID
        self.sourceTabID = sourceTabID
        self.originalURL = originalURL
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.isExplicitDownload = isExplicitDownload
        self.isMainFrame = isMainFrame
        self.httpMethod = httpMethod
        self.totalBytes = totalBytes >= 0 ? totalBytes : Int64(payloadToWrite?.count ?? -1)
        self.receivedBytes = 0
        self.state = .pending
        self.payloadToWrite = payloadToWrite
        self.errorToReturn = errorToReturn
        self.holdInProgressUntilCancelled = holdInProgressUntilCancelled
        super.init()
    }

    func start(
        withDestinationURL destinationURL: URL,
        completion: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) {
        startCallCount += 1
        startedDestinationURL = destinationURL
        state = .inProgress

        if holdInProgressUntilCancelled {
            pendingCompletion = completion
            return
        }

        if let errorToReturn {
            state = .failed
            completion(nil, errorToReturn)
            return
        }

        do {
            let data = payloadToWrite ?? Data()
            try data.write(to: destinationURL, options: .atomic)
            receivedBytes = Int64(data.count)
            totalBytes = Int64(data.count)
            state = .completed
            completion(destinationURL, nil)
        } catch {
            state = .failed
            completion(nil, error)
        }
    }

    func cancel() {
        cancelCount += 1
        state = .cancelled
        if let completion = pendingCompletion {
            pendingCompletion = nil
            completion(nil, CancellationError())
        }
    }
}

// MARK: - Suites

@Suite("Chrome State")
struct CuriumStateTests {
    @Test("Chrome collapse clamps, quantizes sub-pixel noise, and respects pin/focus")
    func chromeCollapseQuantizationAndPin() {
        var chrome = CuriumChromeState()
        #expect(chrome.collapse(focused: false, hasPage: true) == 0)

        chrome.engineReported(collapse: 0.002)
        #expect(chrome.collapse(focused: false, hasPage: true) == 0)

        chrome.engineReported(collapse: 0.997)
        #expect(chrome.collapse(focused: false, hasPage: true) == 1)

        chrome.engineReported(collapse: 0.4)
        #expect(chrome.collapse(focused: true, hasPage: true) == 0)
        #expect(chrome.collapse(focused: false, hasPage: false) == 0)

        chrome.pin()
        #expect(chrome.pinnedOpen)
        #expect(chrome.collapse(focused: false, hasPage: true) == 0)

        chrome.engineReported(collapse: 0.0)
        #expect(!chrome.pinnedOpen)
    }
}

@Suite("SQLite Library & WAL Protection")
struct CuriumDatabaseTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Bookmarks, history visits, frecency search, and suspend-locked xattr")
    func databaseVisitsBookmarksAndXattr() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appending(path: "curium.sqlite", directoryHint: .notDirectory)
        let db = CuriumDatabase(databaseURL: dbURL)

        let exampleURL = URL(string: "https://example.com/docs")!
        try await db.recordVisit(url: exampleURL, title: "Example Docs", at: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await db.updateTitle("Example Reference", for: exampleURL)

        let tree = try await db.saveBookmark(
            url: URL(string: "https://webkit.org/")!,
            title: "WebKit",
            in: CuriumBookmarkFolder.favoritesID,
            at: Date(timeIntervalSince1970: 1_700_000_100)
        )
        #expect(tree.favorites.count == 1)
        #expect(tree.isBookmarked(URL(string: "https://webkit.org/")!))

        let days = try await db.historyDays(matching: "reference", limit: 10, calendar: .current)
        #expect(days.count == 1)
        #expect(days[0].entries.first?.title == "Example Reference")

        let matches = try await db.addressMatches(for: "example", limit: 6, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(matches.contains { $0.url == exampleURL && $0.kind == .history })

        try await db.checkpoint()

        // Verify runningboard suspend-locked xattr is applied to the main SQLite file.
        var flag: UInt8 = 0
        let xattrSize = getxattr(dbURL.path, "com.apple.runningboard.can-suspend-locked", &flag, 1, 0, 0)
        #expect(xattrSize == 1)
        #expect(flag == 1)
    }

    @Test("Folder cycle guard rejects moving folder inside itself")
    func bookmarkFolderCycleGuard() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = CuriumDatabase(databaseURL: dir.appending(path: "curium.sqlite", directoryHint: .notDirectory))
        let tree1 = try await db.saveBookmarkFolder(id: nil, title: "Parent", in: nil, at: .now)
        let parentID = try #require(tree1.items(in: nil).compactMap { item -> Int64? in
            if case .folder(let folder) = item, folder.title == "Parent" { return folder.id }
            return nil
        }.first)

        let tree2 = try await db.saveBookmarkFolder(id: nil, title: "Child", in: parentID, at: .now)
        let childID = try #require(tree2.items(in: parentID).compactMap { item -> Int64? in
            if case .folder(let folder) = item, folder.title == "Child" { return folder.id }
            return nil
        }.first)

        await #expect(throws: Error.self) {
            _ = try await db.saveBookmarkFolder(id: parentID, title: "Parent", in: childID, at: .now)
        }
    }

    @Test("Legacy adoption skips corrupt source without creating empty target")
    func legacyAdoptionFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let corruptLegacy = dir.appending(path: "legacy.sqlite", directoryHint: .notDirectory)
        try Data("not-a-sqlite-db".utf8).write(to: corruptLegacy)
        let target = dir.appending(path: "target/curium.sqlite", directoryHint: .notDirectory)

        let resolution = CuriumLibraryLocation.Resolution(database: target, legacy: [corruptLegacy])
        _ = CuriumLibraryLocation.adoptLegacyIfNeeded(resolution)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

@Suite("Browser & Extension Stores")
@MainActor
struct CuriumStoreTests {
    @Test("Browser store invalidates closed tabs and recovers from last-tab close")
    func browserStoreTabLifecycle() {
        let host = MockBrowserHost()
        let first = MockTabHost(tabID: "t1", extensionTabID: 10, url: URL(string: "https://example.com"))
        let second = MockTabHost(tabID: "t2", extensionTabID: 11, url: URL(string: "https://curium.test"))
        host.tabs = [first, second]
        host.activeTab = first

        let store = CuriumBrowserStore(host: host, extensionManager: MockExtensionManager())
        #expect(store.tabs.count == 2)
        #expect(store.activeTab?.id == "t1")

        let firstModel = store.tabs[0]
        let secondModel = store.tabs[1]
        store.close(firstModel)
        #expect(firstModel.engine == nil)
        #expect(firstModel.webView == nil)
        #expect(store.tabs.count == 1)
        #expect(store.activeTab?.id == "t2")

        // Simulating last tab closed by webpage `window.close()`
        _ = host.closeTab(withID: "t2")
        store.browserHostDidUpdateTabs(host)
        #expect(secondModel.engine == nil)
        #expect(store.tabs.count == 1)
        #expect(store.activeTab != nil)
        #expect(store.activeTab?.id != "t2")
    }

    @Test("Extension store parses Chrome Web Store URLs and refreshes targeted actions")
    func extensionStoreTargetedRefresh() async throws {
        let extID = String(repeating: "a", count: 32)
        let storeURL = URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(extID)")!
        #expect(CuriumExtensionStore.storeExtensionID(from: storeURL) == extID)
        #expect(CuriumExtensionStore.storeExtensionID(from: URL(string: "https://example.com/\(extID)")) == nil)

        let manager = MockExtensionManager()
        manager.entries = [
            ["id": extID, "name": "uBOL", "version": "1.0", "enabled": true, "removable": true]
        ]
        manager.actionSnapshots[extID] = ["badgeText": "3", "isEnabled": true, "hasPopup": true]

        let store = CuriumExtensionStore(manager: manager)
        store.refresh(tabID: 1, includeBlockedCounts: false)
        #expect(store.installed.count == 1)
        #expect(store.badge == "3")
        let initialListCalls = manager.extensionsCalls

        manager.actionSnapshots[extID] = ["badgeText": "7", "isEnabled": true, "hasPopup": true]
        manager.actionObserver?(extID)
        try await Task.sleep(for: .milliseconds(200))

        #expect(manager.extensionsCalls == initialListCalls)
        #expect(store.badge == "7")
    }
}

@Suite("Diagnostics & Compact Pill Layout")
struct CuriumDiagnosticsAndLayoutTests {
    @Test("Diagnostics ring buffer caps lines and rotates log file at maxFileBytes")
    func diagnosticsRingBufferAndRotation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-diag-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let diag = CuriumDiagnostics(
            directory: dir,
            maxFileBytes: 1200,
            maxRingLines: 5,
            observeSystemNotifications: false
        )
        for idx in 0..<25 {
            diag.record("test", "event-\(idx) payload=0123456789abcdef0123456789abcdef")
        }
        diag.flushSync()
        for idx in 25..<40 {
            diag.record("test", "event-\(idx) payload=0123456789abcdef0123456789abcdef")
        }
        diag.flushSync()

        let lines = diag.currentLines()
        #expect(lines.count == 5)
        #expect(lines.last?.contains("event-39") == true)

        let logURL = try #require(diag.logFileURL)
        let prevURL = dir.appending(path: CuriumDiagnostics.rotatedFileName, directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: logURL.path))
        #expect(FileManager.default.fileExists(atPath: prevURL.path))
    }

    @Test("Compact pill shifts below centered cutout and narrows beside side occlusion")
    @MainActor
    func compactPillGeometry() {
        let normal = CuriumBrowserView.compactPill(centerX: 200, maxWidth: 360, obstacles: [])
        #expect(normal.top == CuriumSpace.compactPillTop)
        #expect(normal.maxWidth == 360)

        let sideCluster = CuriumBrowserView.compactPill(
            centerX: 300,
            maxWidth: 500,
            obstacles: [CGRect(x: 420, y: 0, width: 160, height: 60)]
        )
        #expect(sideCluster.top == CuriumSpace.compactPillTop)
        #expect(sideCluster.maxWidth == 240)

        let centeredCutout = CuriumBrowserView.compactPill(
            centerX: 200,
            maxWidth: 360,
            obstacles: [CGRect(x: 150, y: 0, width: 100, height: 48)]
        )
        #expect(centeredCutout.top == 54)
    }

    @Test("Diagnostics hook summary distinguishes all-active, skipped, and failed hooks")
    func diagnosticsHookSummary() {
        let allActive = [
            CuriumDiagnostics.HookStatus(name: "A", status: "active", detail: ""),
            CuriumDiagnostics.HookStatus(name: "B", status: "active", detail: ""),
        ]
        #expect(CuriumDiagnostics.summarizeHooks(allActive) == ("2/2 active", false))

        let withSkipped = [
            CuriumDiagnostics.HookStatus(name: "A", status: "active", detail: ""),
            CuriumDiagnostics.HookStatus(name: "V8 JIT Probe", status: "skipped", detail: "no debugger"),
        ]
        #expect(CuriumDiagnostics.summarizeHooks(withSkipped) == ("1 active · 1 skipped", false))

        let withFailed = [
            CuriumDiagnostics.HookStatus(name: "A", status: "active", detail: ""),
            CuriumDiagnostics.HookStatus(name: "V8 JIT Probe", status: "failed", detail: "TXM probe returned 0"),
        ]
        #expect(CuriumDiagnostics.summarizeHooks(withFailed) == ("1 failed · 1/2 active", true))
    }

    @Test("Accept-Language normalization preserves BCP-47 scripts, deduplicates, validates, and caps at 4")
    func acceptLanguageNormalization() {
        #expect(
            CuriumNormalizedAcceptLanguages(["zh-Hant-HK", "zh_hans_cn", "en-US", "es-419", "fr-FR"])
                == "zh-Hant-HK,zh-Hans-CN,en-US,es-419"
        )
        #expect(
            CuriumNormalizedAcceptLanguages(["en-us", "EN_US", " zh-Hant-TW ", "zh-hant-tw"])
                == "en-US,zh-Hant-TW"
        )
        #expect(
            CuriumNormalizedAcceptLanguages(["", "en--US", "en;q=0.9", "123-US", "en-u", "sr-Latn-RS"])
                == "sr-Latn-RS"
        )
        #expect(CuriumNormalizedAcceptLanguages(nil) == "en-US,en")
        #expect(CuriumNormalizedAcceptLanguages(["bad;header"]) == "en-US,en")
    }
}

@Suite("Modular Fingerprint Profiles & Validation")
struct CuriumFingerprintTests {
    @Test("All built-in presets pass structural validation and preserve native hardware unless opted in")
    func builtInPresetsValidate() throws {
        for preset in CuriumFingerprintPresets.allBuiltIns {
            let report = CuriumFingerprintValidator.validate(preset)
            #expect(report.isValid, "Preset \(preset.id) errors: \(report.errors)")
            let wireData = try preset.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US", "zh-Hans-CN"])
            #expect(wireData.count <= CuriumFingerprintSchema.maxPayloadBytes)
            let obj = try #require(JSONSerialization.jsonObject(with: wireData) as? [String: Any])
            #expect((obj["schemaVersion"] as? Int) == CuriumFingerprintSchema.version)
            #expect((obj["profileId"] as? String) == preset.id)
            // UI-only keys must never leak into the strict engine wire payload.
            #expect(obj["displayName"] == nil)
            #expect(obj["notes"] == nil)
            #expect(obj["isBuiltIn"] == nil)
        }
        #expect(CuriumFingerprintPresets.allBuiltIns.count == 7)
        #expect(CuriumFingerprintPresets.defaultAuthenticChrome.usesNativeHardwareAndGPU)
        #expect(CuriumFingerprintPresets.iosBlinkAuthentic.usesNativeHardwareAndGPU)
        #expect(CuriumFingerprintPresets.macosDesktopFirst.usesNativeHardwareAndGPU)
        #expect(CuriumFingerprintPresets.pixelAndroid.usesNativeHardwareAndGPU)
        #expect(CuriumFingerprintPresets.pixelAndroid.mobile.model == "Pixel 9")
        #expect(CuriumFingerprintPresets.pixelAndroid.mobile.architecture == "")
        #expect(CuriumFingerprintPresets.privacyHardened.usesNativeHardwareAndGPU)
        #expect(!CuriumFingerprintPresets.windowsWorkstation.usesNativeHardwareAndGPU)
        #expect(!CuriumFingerprintPresets.linuxDesktop.usesNativeHardwareAndGPU)
        #expect(CuriumFingerprintPresets.linuxDesktop.desktop.platform == "Linux")
        #expect(CuriumFingerprintPresets.linuxDesktop.desktop.platformVersion == "")
        #expect(CuriumFingerprintPresets.linuxDesktop.desktop.navigatorPlatform == "Linux x86_64")
    }

    @Test("Validator rejects unsafe profile IDs, bad W3C deviceMemory buckets, invalid proxies, and bad timezones")
    func validatorRejectsInvalidConfigs() {
        #expect(CuriumFingerprintValidator.isValidProfileID("default"))
        #expect(CuriumFingerprintValidator.isValidProfileID("work_01-us"))
        #expect(!CuriumFingerprintValidator.isValidProfileID("Default"))
        #expect(!CuriumFingerprintValidator.isValidProfileID("../escape"))
        #expect(!CuriumFingerprintValidator.isValidProfileID("-leading-dash"))
        #expect(!CuriumFingerprintValidator.isValidProfileID(String(repeating: "a", count: 33)))

        var bad = CuriumFingerprintPresets.defaultAuthenticChrome
        bad.id = "bad/slash"
        bad.hardware.hardwareConcurrency = 0
        bad.hardware.deviceMemoryGB = 6
        bad.hardware.timezone = "Mars/Olympus"
        bad.proxy = .fixed(rules: "   ", bypassRules: nil)
        bad.languages = ["en-US,fr-FR"]
        let report = CuriumFingerprintValidator.validate(bad)
        #expect(!report.isValid)
        #expect(report.errors.count >= 6)

        // Fixed proxy syntax parity with C++ ProxyRules::ParseFromString.
        #expect(CuriumFingerprintValidator.isValidFixedProxyRules("socks5://127.0.0.1:1080"))
        #expect(CuriumFingerprintValidator.isValidFixedProxyRules("http=127.0.0.1:8080;https=socks5://[::1]:1080"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("direct://"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("bad_scheme://127.0.0.1:99999"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("socks5://127.0.0.1:70000"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("http=127.0.0.1:8080,direct://"))
    }

    @Test("Validator emits coherence warnings for mismatched Windows/Apple GPU or Android > 8 GB RAM")
    func validatorCoherenceWarnings() {
        var winNativeGPU = CuriumFingerprintPresets.windowsWorkstation
        winNativeGPU.desktop.webglVendor = nil
        winNativeGPU.desktop.webglRenderer = nil
        winNativeGPU.mobile.webglVendor = nil
        winNativeGPU.mobile.webglRenderer = nil
        let winReport = CuriumFingerprintValidator.validate(winNativeGPU)
        #expect(winReport.isValid)
        #expect(winReport.warnings.contains { $0.contains("Windows identity with native Apple Metal GPU") })

        var android16 = CuriumFingerprintPresets.defaultAuthenticChrome
        android16.hardware.deviceMemoryGB = 16
        let androidReport = CuriumFingerprintValidator.validate(android16)
        #expect(androidReport.isValid)
        #expect(androidReport.warnings.contains { $0.contains("caps navigator.deviceMemory at 8 GB") })

        var linuxNativeGPU = CuriumFingerprintPresets.linuxDesktop
        linuxNativeGPU.desktop.webglVendor = nil
        linuxNativeGPU.desktop.webglRenderer = nil
        linuxNativeGPU.mobile.webglVendor = nil
        linuxNativeGPU.mobile.webglRenderer = nil
        linuxNativeGPU.mobile.mobile = true
        let linuxReport = CuriumFingerprintValidator.validate(linuxNativeGPU)
        #expect(linuxReport.isValid)
        #expect(linuxReport.warnings.contains { $0.contains("Linux identity with native Apple Metal GPU") })
        #expect(linuxReport.warnings.contains { $0.contains("Linux x86_64") })
    }

    @Test("Proxy wire encoding stays strictly mutually exclusive across system, direct, and fixed modes")
    func proxyEncodingMutuallyExclusive() throws {
        var profile = CuriumFingerprintPresets.defaultAuthenticChrome
        profile.proxy = .system
        let sysObj = try #require(JSONSerialization.jsonObject(with: try profile.makeEngineLaunchJSON()) as? [String: Any])
        let sysProxy = try #require(sysObj["proxy"] as? [String: Any])
        #expect((sysProxy["mode"] as? String) == "system")
        #expect(sysProxy["rules"] == nil)

        profile.proxy = .direct
        let dirObj = try #require(JSONSerialization.jsonObject(with: try profile.makeEngineLaunchJSON()) as? [String: Any])
        let dirProxy = try #require(dirObj["proxy"] as? [String: Any])
        #expect((dirProxy["mode"] as? String) == "direct")
        #expect(dirProxy["rules"] == nil)

        profile.proxy = .fixed(rules: "socks5://127.0.0.1:1080", bypassRules: "localhost;127.0.0.1")
        let fixObj = try #require(JSONSerialization.jsonObject(with: try profile.makeEngineLaunchJSON()) as? [String: Any])
        let fixProxy = try #require(fixObj["proxy"] as? [String: Any])
        #expect((fixProxy["mode"] as? String) == "fixed")
        #expect((fixProxy["rules"] as? String) == "socks5://127.0.0.1:1080")
        #expect((fixProxy["bypassRules"] as? String) == "localhost;127.0.0.1")
    }

    @Test("Fingerprint store persists selection, duplicates, bumps revisions, exports/imports, and protects default")
    func storePersistenceAndLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-fp-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)

        let store = CuriumFingerprintStore(fileURL: fileURL)
        #expect(store.selectedProfileID == nil)
        #expect(store.profiles.map(\.id) == ["default"])
        #expect(store.profiles.first?.displayName == "Personal")
        #expect(!store.deleteProfile(id: "default"))

        let templateInstance = try #require(
            store.createProfile(fromTemplate: "win11-workstation", displayName: "Windows Base")
        )
        let custom = try #require(
            store.duplicateProfile(from: templateInstance.id, newID: "office-win", displayName: "Office Win")
        )
        #expect(custom.id == "office-win")
        #expect(store.selectProfile(id: "office-win"))

        var edited = custom
        edited.hardware.timezone = "America/New_York"
        let upsertReport = store.upsert(edited)
        #expect(upsertReport.isValid)

        let reloaded = CuriumFingerprintStore(fileURL: fileURL)
        #expect(reloaded.selectedProfileID == "office-win")
        let loadedCustom = try #require(reloaded.profiles.first { $0.id == "office-win" })
        #expect(loadedCustom.revision == 2)
        #expect(loadedCustom.hardware.timezone == "America/New_York")

        let exported = try reloaded.exportProfileJSON(id: "office-win")
        #expect(try reloaded.importProfileJSON(exported).isValid)

        #expect(reloaded.deleteProfile(id: "office-win"))
        #expect(reloaded.selectedProfileID == nil)
        #expect(reloaded.retiredProfileIDs.contains("office-win"))

        // Reserved built-in template IDs stay protected against direct upsert as new profiles
        // (including case variants on APFS); v2 exposes all 7 archetypes via `templates`.
        var builtInAttempt = CuriumFingerprintPresets.linuxDesktop
        builtInAttempt.displayName = "Tampered Linux"
        #expect(!reloaded.upsert(builtInAttempt).isValid)
        var builtInCaseAttempt = CuriumFingerprintPresets.iosBlinkAuthentic
        builtInCaseAttempt.id = "IOS-Blink"
        #expect(!reloaded.upsert(builtInCaseAttempt).isValid)
        #expect(!reloaded.deleteProfile(id: "linux-desktop"))
        #expect(reloaded.builtInProfiles.isEmpty)
        #expect(reloaded.profiles.first?.id == "default")
        #expect(reloaded.templates.count == CuriumFingerprintPresets.allBuiltIns.count)
        #expect(Set(reloaded.templates.map(\.id)) == CuriumFingerprintPresets.builtInIDs)

        // Engine wire JSON import creates a valid custom profile, and case-insensitive APFS collisions are rejected.
        let wireJSON = Data("""
        {
          "schemaVersion": 1,
          "revision": 3,
          "profileId": "wire-import-01",
          "defaultSlot": "desktop",
          "desktop": { "platform": "macOS", "navigatorPlatform": "MacIntel" },
          "languages": ["ja-JP", "en-US"],
          "proxy": { "mode": "direct" },
          "webrtcIpHandlingPolicy": "disable_non_proxied_udp",
          "enableDoNotTrack": true,
          "enableGlobalPrivacyControl": true
        }
        """.utf8)
        let wireReport = try reloaded.importProfileJSON(wireJSON)
        #expect(wireReport.isValid)
        let importedWire = try #require(reloaded.profiles.first { $0.id == "wire-import-01" })
        #expect(importedWire.proxy == .direct)
        #expect(importedWire.enableGlobalPrivacyControl)
        #expect(!importedWire.isBuiltIn)

        var apfsCollision = importedWire
        apfsCollision.id = "Wire-Import-01"
        #expect(!reloaded.upsert(apfsCollision).isValid)
        #expect(reloaded.duplicateProfile(from: "default", newID: "WIRE-IMPORT-01", displayName: "Collision") == nil)

        let nextID = reloaded.nextAvailableID(base: "wire-import-01")
        #expect(CuriumFingerprintValidator.isValidProfileID(nextID))
        #expect(nextID.lowercased() != "wire-import-01")
    }

    @Test("Profile storage measures usage safely and refuses active, default, locked, or symlinked wipes")
    func profileStorageSafetyAndWipe() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "curium-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        let loc = try #require(CuriumFingerprintProfileStorage.locations(
            for: "iso-work",
            applicationSupportRoot: appSupport,
            cachesRoot: caches
        ))
        try FileManager.default.createDirectory(at: loc.supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loc.cacheDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: loc.supportDirectory.appending(path: "Cookies"))
        try Data(repeating: 0x42, count: 2048).write(to: loc.cacheDirectory.appending(path: "cache.bin"))

        let usage = CuriumFingerprintProfileStorage.measureUsage(
            for: "iso-work",
            applicationSupportRoot: appSupport,
            cachesRoot: caches
        )
        #expect(usage.exists)
        #expect(usage.totalBytes >= 4096)

        // Default and active profiles must always fail closed.
        #expect(throws: CuriumFingerprintProfileStorage.WipeError.defaultProfileProtected) {
            try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                "default",
                isActiveInCurrentProcess: false,
                applicationSupportRoot: appSupport,
                cachesRoot: caches
            )
        }
        #expect(throws: CuriumFingerprintProfileStorage.WipeError.activeProfileProtected) {
            try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                "iso-work",
                isActiveInCurrentProcess: true,
                applicationSupportRoot: appSupport,
                cachesRoot: caches
            )
        }

        // Advisory flock held by another process must block wiping.
        let lockPath = try #require(loc.lockFile).path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        // Same-process second fd on flock is independent on Darwin, so flock(LOCK_EX|LOCK_NB) fails with EWOULDBLOCK.
        #expect(throws: CuriumFingerprintProfileStorage.WipeError.profileLockedByAnotherInstance) {
            try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                "iso-work",
                isActiveInCurrentProcess: false,
                applicationSupportRoot: appSupport,
                cachesRoot: caches
            )
        }
        close(fd)

        // Once unlocked and inactive, wipe clears both Application Support and Caches cleanly.
        try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
            "iso-work",
            isActiveInCurrentProcess: false,
            applicationSupportRoot: appSupport,
            cachesRoot: caches
        )
        #expect(!FileManager.default.fileExists(atPath: loc.supportDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: loc.cacheDirectory.path))

        // Symlinked profile root must be refused cleanly.
        let decoy = root.appending(path: "decoy", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        let symLoc = try #require(CuriumFingerprintProfileStorage.locations(
            for: "sym-escape",
            applicationSupportRoot: appSupport,
            cachesRoot: caches
        ))
        try FileManager.default.createSymbolicLink(at: symLoc.supportDirectory, withDestinationURL: decoy)
        #expect(throws: CuriumFingerprintProfileStorage.WipeError.unsafeSymlinkDetected) {
            try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                "sym-escape",
                isActiveInCurrentProcess: false,
                applicationSupportRoot: appSupport,
                cachesRoot: caches
            )
        }
        #expect(FileManager.default.fileExists(atPath: decoy.path))
    }

    @Test("Diagnostics report embeds Build 40 fingerprint contract status and capabilities")
    func diagnosticsReportIncludesFingerprintContract() {
        let diag = CuriumDiagnostics(directory: nil, observeSystemNotifications: false)
        let status = CuriumEngineFingerprintStatus(dictionary: [
            "contractVersion": 1,
            "state": "configured",
            "appliedProfileId": "linux-desktop",
            "profileDirectoryOpened": true,
            "appliedConfigRevision": 4,
            "defaultSlot": "desktop",
            "proxyMode": "fixed",
            "hardwareOverridesActive": true,
        ])
        let caps = CuriumEngineFingerprintCapabilities(dictionary: [
            "contractVersion": 1,
            "maxConfigBytes": 65536,
            "features": ["zstdBaseline": true, "oopifDesktopInheritance": true],
        ])
        let report = diag.formattedReport(
            hooks: [],
            lines: [],
            fingerprintStatus: status,
            fingerprintCapabilities: caps,
            nextLaunchProfile: "pixel-android"
        )
        #expect(report.contains("Fingerprint Contract: v1 state=configured profile=linux-desktop rev=4"))
        #expect(report.contains("proxy=fixed hw=override"))
        #expect(report.contains("Next Launch Profile: pixel-android"))
        #expect(report.contains("Fingerprint Capabilities: v1 maxBytes=65536 features=[oopifDesktopInheritance,zstdBaseline]"))
    }

    @Test("Bootstrap fails closed when an explicit profile is selected without a Build 40+ engine")
    @MainActor
    func bootstrapFailsClosedWithoutEngineSupport() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-fp-boot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)

        let store = CuriumFingerprintStore(fileURL: fileURL)
        #expect(CuriumFingerprintBootstrap.prepareEngineLaunch(store: store) == .defaultBuild39)

        let macProfile = try #require(
            store.createProfile(fromTemplate: "macos-desktop", displayName: "macOS Desktop")
        )
        #expect(store.selectProfile(id: macProfile.id))
        let outcome = CuriumFingerprintBootstrap.prepareEngineLaunch(store: store)
        if case .rejected(let profileID, _) = outcome {
            #expect(profileID == macProfile.id)
        } else {
            Issue.record("Expected fail-closed rejection when engine lacks Build 40 fingerprint contract, got \(outcome)")
        }
    }
}

@Suite("Media Permission Prompts")
struct CuriumMediaPermissionTests {
    @Test("Origin parser rejects non-HTTP(S)/opaque URLs and normalizes display labels")
    func originParsingAndFormatting() throws {
        let blankURL = try #require(URL(string: "about:blank"))
        let dataURL = try #require(URL(string: "data:text/html,hi"))
        let fileURL = try #require(URL(string: "file:///tmp/test.html"))
        #expect(CuriumMediaPermissionOrigin.parse(blankURL) == nil)
        #expect(CuriumMediaPermissionOrigin.parse(dataURL) == nil)
        #expect(CuriumMediaPermissionOrigin.parse(fileURL) == nil)

        let googleURL = try #require(URL(string: "https://WWW.Google.COM:443/search?q=1"))
        let google = try #require(CuriumMediaPermissionOrigin.parse(googleURL))
        #expect(google.key == "https://www.google.com:443")
        #expect(google.displaySite == "www.google.com")

        let customPortURL = try #require(URL(string: "https://localhost:8443/call"))
        let customPort = try #require(CuriumMediaPermissionOrigin.parse(customPortURL))
        #expect(customPort.key == "https://localhost:8443")
        #expect(customPort.displaySite == "localhost:8443")

        let insecureURL = try #require(URL(string: "http://127.0.0.1:8080/mic"))
        let insecure = try #require(CuriumMediaPermissionOrigin.parse(insecureURL))
        #expect(insecure.key == "http://127.0.0.1:8080")
        #expect(insecure.displaySite == "http://127.0.0.1:8080")
    }

    @Test("Site approval precedes iOS authorization; site denial never asks iOS")
    @MainActor
    func siteApprovalPrecedesOSAuthorization() async throws {
        var osRequests: [CuriumCaptureMediaKind] = []
        let coordinator = CuriumMediaPermissionCoordinator(
            isRequestCurrent: { _, _ in true },
            authorizeCapture: { kind in
                osRequests.append(kind)
                return true
            }
        )
        let origin = try #require(URL(string: "https://meet.example.com/"))

        // 1. Site denial must never invoke AVCaptureDevice authorization.
        var deniedResult: CuriumMediaPermissions?
        coordinator.enqueue(permissions: [.microphone], originURL: origin, tabID: "tab-1") { granted in
            deniedResult = granted
        }
        #expect(coordinator.activePrompt?.title == "Allow meet.example.com to use your microphone?")
        coordinator.respondToActivePrompt(allowed: false)
        #expect(deniedResult == [])
        #expect(osRequests.isEmpty)
        #expect(coordinator.activePrompt == nil)

        // 2. Site allow for camera + microphone requests video then audio in order.
        let granted: CuriumMediaPermissions = await withCheckedContinuation { cont in
            coordinator.enqueue(permissions: [.camera, .microphone], originURL: origin, tabID: "tab-1") { result in
                cont.resume(returning: result)
            }
            #expect(coordinator.activePrompt?.title == "Allow meet.example.com to use your camera and microphone?")
            coordinator.respondToActivePrompt(allowed: true)
            #expect(coordinator.activePrompt == nil)
        }
        #expect(granted == [.camera, .microphone])
        #expect(osRequests == [.video, .audio])
    }

    @Test("Concurrent duplicate requests coalesce while distinct requests queue without cache poisoning")
    @MainActor
    func coalescingAndQueuingBehavior() async throws {
        let coordinator = CuriumMediaPermissionCoordinator(
            isRequestCurrent: { _, _ in true },
            authorizeCapture: { _ in true }
        )
        let origin = try #require(URL(string: "https://voice.example.com/"))

        var firstMicResult: CuriumMediaPermissions?
        var secondMicResult: CuriumMediaPermissions?
        var cameraResult: CuriumMediaPermissions?

        coordinator.enqueue(permissions: [.microphone], originURL: origin, tabID: "tab-1") { firstMicResult = $0 }
        // Duplicate mic request coalesces onto the active prompt.
        coordinator.enqueue(permissions: [.microphone], originURL: origin, tabID: "tab-1") { secondMicResult = $0 }
        // Distinct camera request queues cleanly behind mic rather than failing immediately.
        coordinator.enqueue(permissions: [.camera], originURL: origin, tabID: "tab-1") { cameraResult = $0 }

        #expect(coordinator.activePrompt?.permissions == [.microphone])
        coordinator.respondToActivePrompt(allowed: true)

        // Wait for async OS authorization task to complete and drain the camera prompt.
        for _ in 0..<20 where coordinator.activePrompt?.permissions != [.camera] {
            await Task.yield()
        }
        #expect(firstMicResult == [.microphone])
        #expect(secondMicResult == [.microphone])
        #expect(cameraResult == nil)
        #expect(coordinator.activePrompt?.permissions == [.camera])

        coordinator.respondToActivePrompt(allowed: false)
        #expect(cameraResult == [])
        #expect(coordinator.activePrompt == nil)
    }

    @Test("Navigation, origin change, and tab close dismiss prompts and fail closed even mid-OS authorization")
    @MainActor
    func navigationAndTabLifecycleFailClosed() async throws {
        let host = MockBrowserHost()
        var pendingOSContinuation: CheckedContinuation<Bool, Never>?
        let store = CuriumBrowserStore(
            host: host,
            captureAuthorizer: { _ in
                await withCheckedContinuation { cont in
                    pendingOSContinuation = cont
                }
            }
        )
        let tab = try #require(host.activeTab as? MockTabHost)
        let siteA = try #require(URL(string: "https://site-a.example/page"))
        let siteASameDoc = try #require(URL(string: "https://site-a.example/page#section"))
        let siteB = try #require(URL(string: "https://site-b.example/"))
        tab.currentURL = siteA
        store.browserHost(host, didUpdateTab: tab)

        // Presentation blocked while a sheet is open; prompt waits and appears once dismissed.
        store.setSheetPresented(true)
        var firstResult: CrIOSMediaPermissionTypes?
        store.browserHost(host, requestMediaPermissions: .microphone, origin: siteA, forTab: tab) {
            firstResult = $0
        }
        #expect(store.activeMediaPermissionPrompt == nil)
        #expect(firstResult == nil)

        store.setSheetPresented(false)
        #expect(store.activeMediaPermissionPrompt?.displaySite == "site-a.example")

        // Same-document hash navigation must NOT dismiss the prompt.
        tab.currentURL = siteASameDoc
        store.browserHost(host, tab: tab, didCommitNavigationTo: siteASameDoc, navigationID: 1, isSameDocument: true, isReload: false)
        #expect(store.activeMediaPermissionPrompt?.displaySite == "site-a.example")

        // Cross-document navigation immediately dismisses and denies fail-closed.
        tab.currentURL = siteB
        store.browserHost(host, tab: tab, didCommitNavigationTo: siteB, navigationID: 2, isSameDocument: false, isReload: false)
        #expect(store.activeMediaPermissionPrompt == nil)
        #expect(firstResult == [])

        // Navigating away while awaiting iOS AVCaptureDevice dialog must still fail closed.
        var midOSResult: CrIOSMediaPermissionTypes?
        store.browserHost(host, requestMediaPermissions: .microphone, origin: siteB, forTab: tab) {
            midOSResult = $0
        }
        #expect(store.activeMediaPermissionPrompt?.displaySite == "site-b.example")
        store.respondToActiveMediaPermissionPrompt(allowed: true)
        for _ in 0..<20 where pendingOSContinuation == nil {
            await Task.yield()
        }
        #expect(pendingOSContinuation != nil)

        // Tab navigates back to siteA before iOS returns "granted".
        tab.currentURL = siteA
        store.browserHost(host, tab: tab, didCommitNavigationTo: siteA, navigationID: 3, isSameDocument: false, isReload: false)
        #expect(midOSResult == [])
        pendingOSContinuation?.resume(returning: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(midOSResult == [])
    }
}

@Suite("Inline PDF & Downloads")
struct CuriumInlinePDFAndDownloadsTests {
    private func makeTempDir(_ prefix: String = "curium-dl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func makeSamplePDFData(pageTexts: [String]) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { ctx in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20),
                .foregroundColor: UIColor.black,
            ]
            for text in pageTexts {
                ctx.beginPage()
                (text as NSString).draw(in: pageRect.insetBy(dx: 48, dy: 64), withAttributes: attrs)
            }
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test("DownloadStorage sanitizes filenames, dotfiles, long UTF-8 names, MIME precedence, LiveContainer root, and flat dedup")
    func storageSanitizationDetectionAndFlatDedup() throws {
        // Filename sanitization (path traversal, control chars, dotfiles, UTF-8 byte clamping)
        #expect(CuriumDownloadStorage.sanitizedFilename(nil) == "Download")
        #expect(CuriumDownloadStorage.sanitizedFilename("") == "Download")
        #expect(CuriumDownloadStorage.sanitizedFilename("   \n\t ") == "Download")
        #expect(CuriumDownloadStorage.sanitizedFilename(".") == "Download")
        #expect(CuriumDownloadStorage.sanitizedFilename("..") == "Download")
        #expect(CuriumDownloadStorage.sanitizedFilename("/") == "Download")
        #expect(CuriumDownloadStorage.sanitizedFilename("", fallback: "Document.pdf") == "Document.pdf")
        #expect(CuriumDownloadStorage.sanitizedFilename("../../etc/passwd") == "passwd")
        #expect(CuriumDownloadStorage.sanitizedFilename("nested/dir/report.pdf") == "report.pdf")
        #expect(CuriumDownloadStorage.sanitizedFilename("bad\0name.pdf") == "badname.pdf")
        #expect(CuriumDownloadStorage.sanitizedFilename("\u{0001}sub\u{007F}/clean\u{0007}.pdf") == "clean.pdf")
        #expect(CuriumDownloadStorage.sanitizedFilename("  paper.pdf  ") == "paper.pdf")
        #expect(CuriumDownloadStorage.sanitizedFilename(".secret.pdf") == "secret.pdf")
        #expect(CuriumDownloadStorage.sanitizedFilename("..hidden") == "hidden")
        #expect(CuriumDownloadStorage.sanitizedFilename(".pdf") == "pdf")
        #expect(CuriumDownloadStorage.sanitizedFilename(". .pdf") == "pdf")

        // Long ASCII and multi-byte UTF-8 names clamp cleanly below APFS NAME_MAX while preserving extension
        let longASCII = String(repeating: "a", count: 300) + ".pdf"
        let clampedASCII = CuriumDownloadStorage.sanitizedFilename(longASCII)
        #expect(clampedASCII.hasSuffix(".pdf"))
        #expect((clampedASCII as NSString).deletingPathExtension.utf8.count <= 200)
        #expect(clampedASCII.utf8.count < 255)

        let longCJK = String(repeating: "文", count: 100) + ".pdf" // 300 UTF-8 bytes in stem
        let clampedCJK = CuriumDownloadStorage.sanitizedFilename(longCJK)
        #expect(clampedCJK.hasSuffix(".pdf"))
        #expect((clampedCJK as NSString).deletingPathExtension.utf8.count <= 200)
        #expect(clampedCJK.utf8.count < 255)

        // PDF detection & MIME precedence
        #expect(CuriumDownloadStorage.isPDF(mimeType: "application/pdf", filename: "download"))
        #expect(CuriumDownloadStorage.isPDF(mimeType: "APPLICATION/PDF; charset=utf-8", filename: "blob"))
        #expect(CuriumDownloadStorage.isPDF(mimeType: "application/x-pdf", filename: "blob"))
        #expect(CuriumDownloadStorage.isPDF(mimeType: "application/octet-stream", filename: "Spec.PDF"))
        #expect(CuriumDownloadStorage.isPDF(
            mimeType: "application/octet-stream",
            filename: "attachment",
            url: URL(string: "https://example.com/files/manual.pdf?dl=1")
        ))
        // Explicit non-PDF MIME must beat a `.pdf` URL path when the filename is non-PDF
        #expect(!CuriumDownloadStorage.isPDF(
            mimeType: "application/zip",
            filename: "archive.zip",
            url: URL(string: "https://example.com/export.pdf")
        ))
        #expect(!CuriumDownloadStorage.isPDF(
            mimeType: "text/csv",
            filename: "download",
            url: URL(string: "https://example.com/report.pdf")
        ))
        // Generic binary MIME with a conflicting non-PDF filename extension must NOT use URL `.pdf` fallback
        #expect(!CuriumDownloadStorage.isPDF(
            mimeType: "application/octet-stream",
            filename: "notes.txt",
            url: URL(string: "https://example.com/manual.pdf")
        ))
        #expect(!CuriumDownloadStorage.isPDF(
            mimeType: "text/plain",
            filename: "notes.txt",
            url: URL(string: "https://example.com/notes.txt")
        ))

        // LiveContainer host Downloads root resolution
        let lcRoot = try CuriumDownloadStorage.downloadsRootDirectory(environment: ["LC_HOME_PATH": "/tmp/lc-host"])
        #expect(lcRoot.path == "/tmp/lc-host/Documents/Curium/Downloads")

        // Flat collision dedup + concurrent in-flight reservation: paper.pdf -> paper (2).pdf -> paper (3).pdf
        let root = try makeTempDir("curium-dl-dedup")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try CuriumDownloadStorage.uniqueDownloadDestination(filename: "paper.pdf", in: root)
        defer { CuriumDownloadStorage.releaseDownloadReservation(at: first) }
        #expect(first.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(first.lastPathComponent == "paper.pdf")

        // Concurrent reservation before `first` is written still yields `paper (2).pdf`
        let second = try CuriumDownloadStorage.uniqueDownloadDestination(filename: "paper.pdf", in: root)
        defer { CuriumDownloadStorage.releaseDownloadReservation(at: second) }
        #expect(second.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(second.lastPathComponent == "paper (2).pdf")

        try Data("v1".utf8).write(to: first)
        try Data("v2".utf8).write(to: second)

        let third = try CuriumDownloadStorage.uniqueDownloadDestination(filename: "paper.pdf", in: root)
        defer { CuriumDownloadStorage.releaseDownloadReservation(at: third) }
        #expect(third.lastPathComponent == "paper (3).pdf")

        let noExt1 = try CuriumDownloadStorage.uniqueDownloadDestination(filename: "README", in: root)
        defer { CuriumDownloadStorage.releaseDownloadReservation(at: noExt1) }
        #expect(noExt1.lastPathComponent == "README")
        try Data("r1".utf8).write(to: noExt1)
        let noExt2 = try CuriumDownloadStorage.uniqueDownloadDestination(filename: "README", in: root)
        defer { CuriumDownloadStorage.releaseDownloadReservation(at: noExt2) }
        #expect(noExt2.lastPathComponent == "README (2)")
    }

    @Test("DownloadStorage preserves active previews across stale cleanup, lists legacy folders safely, and refuses symlinks/dirs/traversals")
    func storagePreviewCacheListingAndSafeDeletion() throws {
        let sandbox = try makeTempDir("curium-dl-storage")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let previewRoot = sandbox.appending(path: "Caches/CuriumPDFPreview", directoryHint: .isDirectory)
        let outsideDir = sandbox.appending(path: "Outside", directoryHint: .isDirectory)
        let outsideFile = sandbox.appending(path: "secret.txt", directoryHint: .notDirectory)
        let outsideNestedPDF = outsideDir.appending(path: "escape.pdf", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try Data("keep-me".utf8).write(to: outsideFile)
        try Data("outside-pdf".utf8).write(to: outsideNestedPDF)

        // Isolated temp preview cache (strictly outside Downloads)
        let preview = try CuriumDownloadStorage.makePreviewDestination(filename: "whitepaper", cacheRoot: previewRoot)
        defer { CuriumDownloadStorage.removePreviewSessionDirectory(preview.sessionDirectory, cacheRoot: previewRoot) }
        #expect(preview.sessionDirectory.standardizedFileURL.path.hasPrefix(previewRoot.standardizedFileURL.path + "/"))
        #expect(!preview.fileURL.standardizedFileURL.path.hasPrefix(downloadsRoot.standardizedFileURL.path + "/"))
        #expect(preview.fileURL.lastPathComponent == "whitepaper.pdf")
        #expect(FileManager.default.fileExists(atPath: preview.sessionDirectory.path))
        let payload = Data("%PDF-1.4\npreview".utf8)
        try payload.write(to: preview.fileURL)
        #expect(CuriumDownloadStorage.listSavedDownloads(in: downloadsRoot).isEmpty)

        // Explicit promotion from preview cache into durable Downloads
        let saved1 = try CuriumDownloadStorage.savePreviewFileToDownloads(
            sourceURL: preview.fileURL,
            suggestedFilename: "whitepaper.pdf",
            downloadsRoot: downloadsRoot
        )
        #expect(saved1.deletingLastPathComponent().standardizedFileURL == downloadsRoot.standardizedFileURL)
        #expect(saved1.lastPathComponent == "whitepaper.pdf")
        #expect(try Data(contentsOf: saved1) == payload)
        #expect(FileManager.default.fileExists(atPath: preview.fileURL.path))

        let saved2 = try CuriumDownloadStorage.savePreviewFileToDownloads(
            sourceURL: preview.fileURL,
            suggestedFilename: "whitepaper.pdf",
            downloadsRoot: downloadsRoot
        )
        #expect(saved2.lastPathComponent == "whitepaper (2).pdf")

        // Stale preview cleanup removes orphaned preview folders while preserving active in-process sessions
        let orphanDir = previewRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: orphanDir.appending(path: "stale.pdf"))
        CuriumDownloadStorage.cleanupStalePDFPreviews(cacheRoot: previewRoot)
        #expect(FileManager.default.fileExists(atPath: preview.sessionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: orphanDir.path))
        #expect(FileManager.default.fileExists(atPath: saved1.path))

        // removePreviewSessionDirectory enforces cacheRoot containment (no-op outside cacheRoot)
        CuriumDownloadStorage.removePreviewSessionDirectory(outsideDir, cacheRoot: previewRoot)
        #expect(FileManager.default.fileExists(atPath: outsideDir.path))
        CuriumDownloadStorage.removePreviewSessionDirectory(preview.sessionDirectory, cacheRoot: previewRoot)
        #expect(!FileManager.default.fileExists(atPath: preview.sessionDirectory.path))

        // Disk listing discovers flat files + legacy <UUID>/<file> subdirectories and skips symlinks
        let flatNote = downloadsRoot.appending(path: "notes.txt", directoryHint: .notDirectory)
        try Data("hello".utf8).write(to: flatNote)
        let legacyDir = downloadsRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyPDF = legacyDir.appending(path: "legacy.pdf", directoryHint: .notDirectory)
        try Data("legacy-pdf".utf8).write(to: legacyPDF)

        let symlinkFile = downloadsRoot.appending(path: "link-secret.txt", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: outsideFile)
        let symlinkSubdir = downloadsRoot.appending(path: "link-dir", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: symlinkSubdir, withDestinationURL: outsideDir)

        let listed = CuriumDownloadStorage.listSavedDownloads(in: downloadsRoot)
        let names = Set(listed.map(\.filename))
        #expect(names == Set(["whitepaper.pdf", "whitepaper (2).pdf", "notes.txt", "legacy.pdf"]))
        #expect(!names.contains("link-secret.txt"))
        #expect(!names.contains("escape.pdf"))
        let listedNote = try #require(listed.first { $0.filename == "notes.txt" })
        #expect(!listedNote.isPDF)
        #expect(listedNote.byteCount == 5)
        let listedLegacy = try #require(listed.first { $0.filename == "legacy.pdf" })
        #expect(listedLegacy.isPDF)

        // Safe deletion prunes empty legacy UUID parent dir and deletes regular flat files
        try CuriumDownloadStorage.deleteSavedDownload(at: legacyPDF, downloadsRoot: downloadsRoot)
        #expect(!FileManager.default.fileExists(atPath: legacyPDF.path))
        #expect(!FileManager.default.fileExists(atPath: legacyDir.path))

        try CuriumDownloadStorage.deleteSavedDownload(at: flatNote, downloadsRoot: downloadsRoot)
        #expect(!FileManager.default.fileExists(atPath: flatNote.path))

        // Symlinks, symlinked subdirs, directories, out-of-root traversals, and root-self deletion must all be refused
        let nonEmptySubdir = downloadsRoot.appending(path: "subdir", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nonEmptySubdir, withIntermediateDirectories: true)
        let traversalURL = downloadsRoot.appending(path: "../secret.txt")
        let symlinkEscapeFile = symlinkSubdir.appending(path: "escape.pdf", directoryHint: .notDirectory)

        #expect(throws: Error.self) {
            try CuriumDownloadStorage.deleteSavedDownload(at: symlinkFile, downloadsRoot: downloadsRoot)
        }
        #expect(throws: Error.self) {
            try CuriumDownloadStorage.deleteSavedDownload(at: symlinkEscapeFile, downloadsRoot: downloadsRoot)
        }
        #expect(throws: Error.self) {
            try CuriumDownloadStorage.deleteSavedDownload(at: nonEmptySubdir, downloadsRoot: downloadsRoot)
        }
        #expect(throws: Error.self) {
            try CuriumDownloadStorage.deleteSavedDownload(at: traversalURL, downloadsRoot: downloadsRoot)
        }
        #expect(throws: Error.self) {
            try CuriumDownloadStorage.deleteSavedDownload(at: outsideFile, downloadsRoot: downloadsRoot)
        }
        #expect(throws: Error.self) {
            try CuriumDownloadStorage.deleteSavedDownload(at: downloadsRoot, downloadsRoot: downloadsRoot)
        }
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
        #expect(FileManager.default.fileExists(atPath: outsideNestedPDF.path))
        #expect(FileManager.default.fileExists(atPath: nonEmptySubdir.path))
    }

    @Test("PDF download streams to isolated preview cache, supports Find & explicit Save, and Back dismisses and cleans temp cache")
    @MainActor
    func pdfInlineStreamingSaveAndBackCleanup() async throws {
        let sandbox = try makeTempDir("curium-pdf-e2e")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let previewRoot = sandbox.appending(path: "Caches/CuriumPDFPreview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)

        let host = MockBrowserHost()
        let pageURL = try #require(URL(string: "https://docs.example/index.html"))
        let pdfURL = try #require(URL(string: "https://docs.example/sample.pdf"))
        let engineTab = MockTabHost(tabID: "tab-pdf", extensionTabID: 1, url: pageURL, title: "Docs")
        engineTab.canGoBack = true
        host.tabs = [engineTab]
        host.activeTab = engineTab

        let store = CuriumBrowserStore(
            host: host,
            extensionManager: MockExtensionManager(),
            downloadsRoot: downloadsRoot,
            pdfPreviewCacheRoot: previewRoot
        )
        // Let init's detached stale-preview cleanup finish before creating a new session.
        try await Task.sleep(for: .milliseconds(80))

        let pdfData = makeSamplePDFData(pageTexts: [
            "Page One Intro",
            "Page Two CuriumQuantumNeedle Details",
            "Page Three Appendix",
        ])
        let task = MockDownloadTask(
            sourceTabID: "tab-pdf",
            originalURL: pdfURL,
            suggestedFilename: "sample.pdf",
            mimeType: "application/pdf",
            payloadToWrite: pdfData
        )

        store.browserHost(host, didCreateDownload: task)

        // Must stream into tab.pdfSession, NOT store.downloads or activeDownloadBanner or Downloads folder.
        #expect(store.downloads.isEmpty)
        #expect(store.activeDownloadBanner == nil)
        let tab = try #require(store.activeTab)
        let session = try #require(tab.pdfSession)
        #expect(tab.isShowingPDF)
        #expect(tab.displayURL == pdfURL)
        #expect(tab.effectiveCanGoBack)
        #expect(!tab.effectiveCanGoForward)

        let ready = await waitUntil { session.phase == .ready }
        #expect(ready)
        #expect(session.pageCount == 3)
        #expect(session.currentPageIndex == 0)
        #expect(!session.isSavedToDownloads)

        let previewFile = try #require(session.localFileURL)
        let previewSessionDir = previewFile.deletingLastPathComponent()
        #expect(previewFile.standardizedFileURL.path.hasPrefix(previewRoot.standardizedFileURL.path + "/"))
        #expect(!previewFile.standardizedFileURL.path.hasPrefix(downloadsRoot.standardizedFileURL.path + "/"))
        #expect(CuriumDownloadStorage.listSavedDownloads(in: downloadsRoot).isEmpty)
        #expect(store.savedDownloads.isEmpty)

        // Find-in-PDF locates text on page 2 and updates currentPageIndex.
        session.openSearch()
        session.performSearch(query: "CuriumQuantumNeedle")
        let searchDone = await waitUntil { !session.isSearchInProgress && !session.searchMatches.isEmpty }
        #expect(searchDone)
        #expect(session.searchMatches.count == 1)
        #expect(session.currentPageIndex == 1)

        // Explicit Save promotes the file into durable Downloads and refreshes store.savedDownloads.
        let savedURL = try #require(await session.saveToDownloads(downloadsRoot: downloadsRoot))
        #expect(savedURL.deletingLastPathComponent().standardizedFileURL == downloadsRoot.standardizedFileURL)
        #expect(savedURL.lastPathComponent == "sample.pdf")
        #expect(session.isSavedToDownloads)
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
        // Repeated save is idempotent and does not duplicate the file.
        let repeatedSave = await session.saveToDownloads(downloadsRoot: downloadsRoot)
        #expect(repeatedSave == savedURL)

        store.refreshSavedDownloads()
        let listedInStore = await waitUntil { store.savedDownloads.contains { $0.filename == "sample.pdf" && $0.isPDF } }
        #expect(listedInStore)

        // Back dismisses the inline PDF (without navigating the underlying web tab back) and deletes temp cache.
        tab.goBack()
        #expect(tab.pdfSession == nil)
        #expect(!tab.isShowingPDF)
        #expect(engineTab.goBackCallCount == 0)
        let previewCleaned = await waitUntil { !FileManager.default.fileExists(atPath: previewSessionDir.path) }
        #expect(previewCleaned)
        // Durable saved copy remains intact after dismissing inline preview.
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
    }

    @Test("Cross-document navigation and tab close dismiss/cancel PDF sessions and delete temp preview directories")
    @MainActor
    func pdfNavigationDismissalAndTabCloseCleanup() async throws {
        let sandbox = try makeTempDir("curium-pdf-lifecycle")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let previewRoot = sandbox.appending(path: "Caches/CuriumPDFPreview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)

        let host = MockBrowserHost()
        let tab1Engine = MockTabHost(tabID: "t1", extensionTabID: 1, url: URL(string: "https://site.test/a"))
        let tab2Engine = MockTabHost(tabID: "t2", extensionTabID: 2, url: URL(string: "https://site.test/b"))
        host.tabs = [tab1Engine, tab2Engine]
        host.activeTab = tab1Engine

        let store = CuriumBrowserStore(
            host: host,
            extensionManager: MockExtensionManager(),
            downloadsRoot: downloadsRoot,
            pdfPreviewCacheRoot: previewRoot
        )
        try await Task.sleep(for: .milliseconds(80))

        // 1. Cross-document didCommitNavigationTo dismisses PDF; same-document commit preserves it.
        let pdfData = makeSamplePDFData(pageTexts: ["Single Page"])
        let readyTask = MockDownloadTask(
            sourceTabID: "t1",
            originalURL: URL(string: "https://site.test/doc.pdf"),
            suggestedFilename: "doc.pdf",
            mimeType: "application/pdf",
            payloadToWrite: pdfData
        )
        store.browserHost(host, didCreateDownload: readyTask)
        let tab1 = try #require(store.tabs.first { $0.id == "t1" })
        let session1 = try #require(tab1.pdfSession)
        #expect(await waitUntil { session1.phase == .ready })
        let dir1 = try #require(session1.localFileURL).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir1.path))

        let sameDocURL = try #require(URL(string: "https://site.test/a#hash"))
        store.browserHost(host, tab: tab1Engine, didCommitNavigationTo: sameDocURL, navigationID: 1, isSameDocument: true, isReload: false)
        #expect(tab1.pdfSession != nil)

        let crossDocURL = try #require(URL(string: "https://site.test/next"))
        store.browserHost(host, tab: tab1Engine, didCommitNavigationTo: crossDocURL, navigationID: 2, isSameDocument: false, isReload: false)
        #expect(tab1.pdfSession == nil)
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: dir1.path) })

        // 2. Closing a tab cancels an in-flight PDF download and removes its temp preview directory.
        let inflightTask = MockDownloadTask(
            sourceTabID: "t2",
            originalURL: URL(string: "https://site.test/large.pdf"),
            suggestedFilename: "large.pdf",
            mimeType: "application/pdf",
            totalBytes: 10_000_000,
            holdInProgressUntilCancelled: true
        )
        store.browserHost(host, didCreateDownload: inflightTask)
        let tab2 = try #require(store.tabs.first { $0.id == "t2" })
        #expect(tab2.pdfSession != nil)
        #expect(await waitUntil { inflightTask.startedDestinationURL != nil })
        let dir2 = try #require(inflightTask.startedDestinationURL).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir2.path))

        store.close(tab2)
        #expect(tab2.pdfSession == nil)
        #expect(inflightTask.cancelCount == 1)
        #expect(inflightTask.state == .cancelled)
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: dir2.path) })
    }

    @Test("Corrupt PDF fails gracefully while non-PDF downloads populate store.downloads and activeDownloadBanner")
    @MainActor
    func corruptPDFAndNonPDFDownloadFlow() async throws {
        let sandbox = try makeTempDir("curium-pdf-corrupt-and-bin")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let previewRoot = sandbox.appending(path: "Caches/CuriumPDFPreview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)

        let host = MockBrowserHost()
        let engineTab = MockTabHost(tabID: "t1", extensionTabID: 1, url: URL(string: "https://files.test/"))
        host.tabs = [engineTab]
        host.activeTab = engineTab

        let store = CuriumBrowserStore(
            host: host,
            extensionManager: MockExtensionManager(),
            downloadsRoot: downloadsRoot,
            pdfPreviewCacheRoot: previewRoot
        )
        try await Task.sleep(for: .milliseconds(80))

        // 1. Corrupt non-PDF bytes served as application/pdf fail gracefully without crashing or polluting Downloads.
        let corruptTask = MockDownloadTask(
            sourceTabID: "t1",
            originalURL: URL(string: "https://files.test/broken.pdf"),
            suggestedFilename: "broken.pdf",
            mimeType: "application/pdf",
            payloadToWrite: Data("<html>Not actually a PDF</html>".utf8)
        )
        store.browserHost(host, didCreateDownload: corruptTask)
        let tab = try #require(store.activeTab)
        let corruptSession = try #require(tab.pdfSession)
        let settled = await waitUntil {
            if case .loading = corruptSession.phase { return false }
            return true
        }
        #expect(settled)
        if case .failed(let message) = corruptSession.phase {
            #expect(!message.isEmpty)
        } else {
            Issue.record("Expected corrupt PDF to transition to .failed, got \(corruptSession.phase)")
        }
        #expect(corruptSession.document == nil)
        #expect(corruptSession.pageCount == 0)
        #expect(corruptSession.canRetry)
        #expect(store.downloads.isEmpty)
        #expect(CuriumDownloadStorage.listSavedDownloads(in: downloadsRoot).isEmpty)
        tab.dismissPDFSession()

        // 2. Non-PDF download populates store.downloads + store.activeDownloadBanner and saves flat to Downloads on start.
        let textPayload = Data("Curium release notes\n".utf8)
        let nonPDFTask = MockDownloadTask(
            downloadID: "dl-notes-1",
            sourceTabID: "t1",
            originalURL: URL(string: "https://files.test/notes.txt"),
            suggestedFilename: "notes.txt",
            mimeType: "application/octet-stream",
            payloadToWrite: textPayload
        )
        store.browserHost(host, didCreateDownload: nonPDFTask)

        #expect(tab.pdfSession == nil)
        #expect(store.downloads.count == 1)
        let item = try #require(store.downloads.first)
        #expect(store.activeDownloadBanner?.id == item.id)
        #expect(item.filename == "notes.txt")
        #expect(!item.isPDF)
        #expect(item.state == .pending)
        #expect(store.pendingOrActiveDownloadCount == 1)
        #expect(CuriumDownloadStorage.listSavedDownloads(in: downloadsRoot).isEmpty)

        await store.startDownload(item)
        #expect(item.state == .completed)
        let savedTextURL = try #require(item.savedURL)
        #expect(savedTextURL.deletingLastPathComponent().standardizedFileURL == downloadsRoot.standardizedFileURL)
        #expect(savedTextURL.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: savedTextURL) == textPayload)
        #expect(store.pendingOrActiveDownloadCount == 0)

        let refreshed = await waitUntil { store.savedDownloads.contains { $0.filename == "notes.txt" && !$0.isPDF } }
        #expect(refreshed)

        store.clearFinishedDownloadTasks()
        #expect(store.downloads.isEmpty)
        #expect(store.activeDownloadBanner == nil)
    }

    @Test("bookmarkableURL excludes file:// URLs, deleteSavedDownload syncs preview/local sessions, and zoom/page requests stay mutually exclusive")
    @MainActor
    func bookmarkableURLDeletedDownloadSyncAndNavigationMutualExclusion() async throws {
        let sandbox = try makeTempDir("curium-pdf-hardening")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let downloadsRoot = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)
        let previewRoot = sandbox.appending(path: "Caches/CuriumPDFPreview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)

        let host = MockBrowserHost()
        let tab1Engine = MockTabHost(tabID: "t1", extensionTabID: 1, url: URL(string: "https://docs.test/"))
        let tab2Engine = MockTabHost(tabID: "t2", extensionTabID: 2, url: nil)
        host.tabs = [tab1Engine, tab2Engine]
        host.activeTab = tab1Engine

        let store = CuriumBrowserStore(
            host: host,
            extensionManager: MockExtensionManager(),
            downloadsRoot: downloadsRoot,
            pdfPreviewCacheRoot: previewRoot
        )

        // 1. Remote PDF: bookmarkableURL exposes https:// URL; zoom vs page requests mutually clear.
        let pdfData = makeSamplePDFData(pageTexts: ["Page 1", "Page 2"])
        let remoteURL = try #require(URL(string: "https://docs.test/guide.pdf"))
        let task = MockDownloadTask(
            sourceTabID: "t1",
            originalURL: remoteURL,
            suggestedFilename: "guide.pdf",
            mimeType: "application/pdf",
            payloadToWrite: pdfData
        )
        store.browserHost(host, didCreateDownload: task)
        let tab1 = try #require(store.tabs.first { $0.id == "t1" })
        let previewSession = try #require(tab1.pdfSession)
        #expect(await waitUntil { previewSession.phase == .ready })
        #expect(tab1.bookmarkableURL == remoteURL)

        previewSession.setZoomScale(1.5)
        #expect(previewSession.requestedZoomScale == 1.5)
        #expect(previewSession.requestedPageIndex == nil)
        previewSession.jumpToPage(1)
        #expect(previewSession.requestedPageIndex == 1)
        #expect(previewSession.requestedZoomScale == nil)
        previewSession.setZoomScale(1.25)
        #expect(previewSession.requestedZoomScale == 1.25)
        #expect(previewSession.requestedPageIndex == nil)
        #expect(previewSession.requestedSelection == nil)

        // Save from preview into durable Downloads, then delete from Downloads:
        // preview session stays open in Tab 1 but clears savedDownloadURL so Save re-enables.
        let savedGuideURL = try #require(await previewSession.saveToDownloads(downloadsRoot: downloadsRoot))
        #expect(previewSession.isSavedToDownloads)
        store.refreshSavedDownloads()
        #expect(await waitUntil { store.savedDownloads.contains { $0.filename == "guide.pdf" } })
        let savedGuide = try #require(store.savedDownloads.first { $0.filename == "guide.pdf" })

        store.deleteSavedDownload(savedGuide)
        #expect(!FileManager.default.fileExists(atPath: savedGuideURL.path))
        #expect(tab1.pdfSession === previewSession)
        #expect(!previewSession.isSavedToDownloads)
        #expect(previewSession.savedDownloadURL == nil)

        // 2. Local saved PDF opened in Tab 2: displayURL is file://, bookmarkableURL is nil,
        // and deleting the saved file dismisses Tab 2's PDF session cleanly.
        let offlineURL = downloadsRoot.appending(path: "offline.pdf", directoryHint: .notDirectory)
        try pdfData.write(to: offlineURL)
        store.refreshSavedDownloads()
        #expect(await waitUntil { store.savedDownloads.contains { $0.filename == "offline.pdf" } })
        let savedOffline = try #require(store.savedDownloads.first { $0.filename == "offline.pdf" })

        let tab2 = try #require(store.tabs.first { $0.id == "t2" })
        store.select(tab2)
        store.openSavedPDFInActiveTab(savedOffline)
        let localSession = try #require(tab2.pdfSession)
        #expect(await waitUntil { localSession.phase == .ready })
        #expect(tab2.displayURL == offlineURL)
        #expect(tab2.bookmarkableURL == nil)
        #expect(localSession.isOpenedFromSavedFile)

        store.deleteSavedDownload(savedOffline)
        #expect(!FileManager.default.fileExists(atPath: offlineURL.path))
        #expect(tab2.pdfSession == nil)
        tab1.dismissPDFSession()
    }
}

@Suite("Build 41 Contracts: Schema v2, PDFKit Handoff & Media Radar")
struct CuriumBuild41ContractTests {
    @Test("Schema v2 wire serialization includes anti-fingerprinting fields and v1 downgrade strips them cleanly")
    func schemaV2WireAndV1Downgrade() throws {
        let win = CuriumFingerprintPresets.windowsWorkstation
        let v2Data = try win.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US"], schemaVersion: 2)
        let v2Obj = try #require(JSONSerialization.jsonObject(with: v2Data) as? [String: Any])
        #expect((v2Obj["schemaVersion"] as? Int) == 2)
        #expect((v2Obj["fontProfile"] as? String) == "windows")
        #expect((v2Obj["hideSpeechVoices"] as? Bool) == true)
        let desktopV2 = try #require(v2Obj["desktop"] as? [String: Any])
        #expect((desktopV2["webglProfile"] as? String) == "desktop_windows")
        #expect((desktopV2["pdfViewerEnabled"] as? Bool) == true)
        let screenV2 = try #require(desktopV2["screen"] as? [String: Any])
        #expect((screenV2["width"] as? Int) == 1920)
        #expect((screenV2["availHeight"] as? Int) == 1040)

        let v1Data = try win.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US"], schemaVersion: 1)
        let v1Obj = try #require(JSONSerialization.jsonObject(with: v1Data) as? [String: Any])
        #expect((v1Obj["schemaVersion"] as? Int) == 1)
        #expect(v1Obj["fontProfile"] == nil)
        #expect(v1Obj["hideSpeechVoices"] == nil)
        #expect(v1Obj["fingerprintSeed"] == nil)
        let desktopV1 = try #require(v1Obj["desktop"] as? [String: Any])
        #expect(desktopV1["screen"] == nil)
        #expect(desktopV1["webglProfile"] == nil)
        #expect(desktopV1["pdfViewerEnabled"] == nil)

        // Static template ships without a hardcoded public seed; creating from template materializes a unique 64-hex seed.
        let privacyTemplate = CuriumFingerprintPresets.privacyHardened
        #expect(privacyTemplate.fingerprintSeed == nil)
        #expect(privacyTemplate.farbling == .allEnabled)
        let privacyDir = FileManager.default.temporaryDirectory
            .appending(path: "curium-privacy-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: privacyDir) }
        let privacyStore = CuriumFingerprintStore(fileURL: privacyDir.appending(path: "profiles.json"))
        let privacy = try #require(
            privacyStore.createProfile(fromTemplate: "privacy-hardened", displayName: "Privacy Hardened")
        )
        #expect(privacy.isFarblingActive)
        let privData = try privacy.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US"], schemaVersion: 2)
        let privObj = try #require(JSONSerialization.jsonObject(with: privData) as? [String: Any])
        #expect((privObj["fingerprintSeed"] as? String)?.count == 64)
        let farbling = try #require(privObj["farbling"] as? [String: Bool])
        #expect(farbling["canvas"] == true)
        #expect(farbling["audio"] == true)
        #expect(farbling["webgl"] == true)
        #expect(farbling["textMetrics"] == true)
    }

    @Test("Validator rejects bad fingerprintSeed, out-of-range screen metrics, and invalid WebGL limits")
    func validatorEnforcesSchemaV2Bounds() {
        var bad = CuriumFingerprintPresets.defaultAuthenticChrome
        bad.id = "custom-v2-bad"
        bad.isBuiltIn = false
        bad.fingerprintSeed = "not-64-hex"
        bad.desktop.screen = CuriumScreenOverride(width: 100, height: 800, availWidth: 900, availHeight: 800, colorDepth: 16)
        bad.desktop.webglMaxTextureSize = 256

        let report = CuriumFingerprintValidator.validate(bad)
        #expect(!report.isValid)
        #expect(report.errors.contains { $0.contains("fingerprintSeed") })
        #expect(report.errors.contains { $0.contains("desktop.screen width and height") })
        #expect(report.errors.contains { $0.contains("availWidth/availHeight") })
        #expect(report.errors.contains { $0.contains("colorDepth") })
        #expect(report.errors.contains { $0.contains("webglMaxTextureSize") })

        let generatedSeed = CuriumFingerprintSchema.generateRandomSeedHex()
        #expect(CuriumFingerprintSchema.isValidSeedHex(generatedSeed))
    }

    @Test("Store imports both schemaVersion 1 and schemaVersion 2 engine wire payloads")
    func storeImportsV1AndV2Wire() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-v2-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CuriumFingerprintStore(fileURL: dir.appending(path: "profiles.json"))

        let seed = CuriumFingerprintSchema.generateRandomSeedHex()
        let v2JSON = """
        {
          "schemaVersion": 2,
          "revision": 3,
          "profileId": "lab-v2",
          "defaultSlot": "desktop",
          "mobile": {},
          "desktop": {
            "platform": "Windows",
            "navigatorPlatform": "Win32",
            "webglProfile": "desktop_windows",
            "pdfViewerEnabled": true,
            "screen": { "width": 1920, "height": 1080, "availWidth": 1920, "availHeight": 1040, "colorDepth": 24 }
          },
          "languages": ["en-US", "en"],
          "proxy": { "mode": "system" },
          "webrtcIpHandlingPolicy": "default_public_interface_only",
          "enableDoNotTrack": false,
          "enableGlobalPrivacyControl": true,
          "hardware": {},
          "fingerprintSeed": "\(seed)",
          "farbling": { "canvas": true, "audio": true, "webgl": true, "textMetrics": false },
          "fontProfile": "windows",
          "hideSpeechVoices": true
        }
        """
        let report = try store.importProfileJSON(Data(v2JSON.utf8))
        #expect(report.isValid, "Errors: \(report.errors)")
        let imported = try #require(store.profiles.first { $0.id == "lab-v2" })
        #expect(imported.fingerprintSeed == seed)
        #expect(imported.farbling?.textMetrics == false)
        #expect(imported.fontProfile == .windows)
        #expect(imported.hideSpeechVoices == true)
        #expect(imported.desktop.screen?.availHeight == 1040)
        #expect(imported.desktop.webglProfile == .desktopWindows)
        #expect(imported.desktop.pdfViewerEnabled == true)
    }

    @Test("Build 41 PDFKit handoff honors isExplicitDownload, isMainFrame, and httpMethod")
    @MainActor
    func pdfDownloadMetadataRouting() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-b41-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = MockBrowserHost()
        let tab = MockTabHost(tabID: "t1", url: URL(string: "https://example.com"))
        host.tabs = [tab]
        host.activeTab = tab
        let store = CuriumBrowserStore(
            host: host,
            downloadsRoot: dir.appending(path: "Downloads", directoryHint: .isDirectory),
            pdfPreviewCacheRoot: dir.appending(path: "PDFCache", directoryHint: .isDirectory)
        )

        // 1. Explicit download (<a download> / Content-Disposition: attachment) -> Download Banner, NOT inline preview.
        let explicitPDF = MockDownloadTask(
            sourceTabID: "t1",
            originalURL: URL(string: "https://example.com/invoice.pdf"),
            suggestedFilename: "invoice.pdf",
            mimeType: "application/pdf",
            isExplicitDownload: true,
            isMainFrame: true,
            httpMethod: "GET"
        )
        store.browserHost(host, didCreateDownload: explicitPDF)
        #expect(store.activeTab?.pdfSession == nil)
        #expect(store.activeDownloadBanner?.id == explicitPDF.downloadID)
        #expect(store.activeDownloadBanner?.isExplicitDownload == true)

        // 2. Subframe PDF download -> Download Banner, never hijacks main tab.
        let subframePDF = MockDownloadTask(
            sourceTabID: "t1",
            originalURL: URL(string: "https://example.com/embed.pdf"),
            suggestedFilename: "embed.pdf",
            mimeType: "application/pdf",
            isExplicitDownload: false,
            isMainFrame: false,
            httpMethod: "GET"
        )
        store.browserHost(host, didCreateDownload: subframePDF)
        #expect(store.activeTab?.pdfSession == nil)
        #expect(store.activeDownloadBanner?.id == subframePDF.downloadID)
        #expect(store.activeDownloadBanner?.isMainFrame == false)

        // 3. POST PDF response -> Download Banner (never lost on Back/reload).
        let postPDF = MockDownloadTask(
            sourceTabID: "t1",
            originalURL: URL(string: "https://example.com/report.pdf"),
            suggestedFilename: "report.pdf",
            mimeType: "application/pdf",
            isExplicitDownload: false,
            isMainFrame: true,
            httpMethod: "POST"
        )
        store.browserHost(host, didCreateDownload: postPDF)
        #expect(store.activeTab?.pdfSession == nil)
        #expect(store.activeDownloadBanner?.id == postPDF.downloadID)
        #expect(store.activeDownloadBanner?.httpMethod == "POST")

        // 4. Implicit main-frame GET PDF -> inline PDFKit preview.
        let inlinePDF = MockDownloadTask(
            sourceTabID: "t1",
            originalURL: URL(string: "https://example.com/paper.pdf"),
            suggestedFilename: "paper.pdf",
            mimeType: "application/pdf",
            isExplicitDownload: false,
            isMainFrame: true,
            httpMethod: "GET",
            holdInProgressUntilCancelled: true
        )
        store.browserHost(host, didCreateDownload: inlinePDF)
        #expect(store.activeTab?.pdfSession != nil)
        store.activeTab?.dismissPDFSession()
    }

    @Test("CuriumMediaRadar classifies HLS/DASH/video/audio, deduplicates, captures UA, and clears on navigation")
    @MainActor
    func mediaRadarIngestAndLifecycle() throws {
        let host = MockBrowserHost()
        let tab = MockTabHost(tabID: "t1", url: URL(string: "https://video.example/watch"))
        host.tabs = [tab]
        host.activeTab = tab
        let store = CuriumBrowserStore(host: host)

        let hlsURL = try #require(URL(string: "https://cdn.example/master.m3u8"))
        let mp4URL = try #require(URL(string: "https://cdn.example/clip.mp4"))
        let segTSURL = try #require(URL(string: "https://cdn.example/seg001.ts"))
        let segM4SURL = try #require(URL(string: "https://cdn.example/chunk01.m4s"))
        let errURL = try #require(URL(string: "https://cdn.example/missing.mp4"))
        let jsonURL = try #require(URL(string: "https://api.example/data.json"))

        // Non-media JSON, 404 video, non-GET preflights/POSTs, and .ts/.m4s segments are ignored.
        #expect(store.mediaRadar.ingest(rawEvent: ["url": jsonURL, "mimeType": "application/json", "httpMethod": "GET", "httpStatusCode": 200], tabID: "t1", effectiveUserAgent: "CuriumTest/1") == nil)
        #expect(store.mediaRadar.ingest(rawEvent: ["url": errURL, "mimeType": "video/mp4", "httpMethod": "GET", "httpStatusCode": 404], tabID: "t1", effectiveUserAgent: "CuriumTest/1") == nil)
        #expect(store.mediaRadar.ingest(rawEvent: ["url": hlsURL, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "OPTIONS", "httpStatusCode": 204], tabID: "t1", effectiveUserAgent: "CuriumTest/1") == nil)
        #expect(store.mediaRadar.ingest(rawEvent: ["url": mp4URL, "mimeType": "video/mp4", "httpMethod": "POST", "httpStatusCode": 200], tabID: "t1", effectiveUserAgent: "CuriumTest/1") == nil)
        #expect(store.mediaRadar.ingest(rawEvent: ["url": segTSURL, "mimeType": "video/mp2t", "httpMethod": "GET", "httpStatusCode": 200], tabID: "t1", effectiveUserAgent: "CuriumTest/1") == nil)
        #expect(store.mediaRadar.ingest(rawEvent: ["url": segM4SURL, "mimeType": "video/iso.segment", "httpMethod": "GET", "httpStatusCode": 200], tabID: "t1", effectiveUserAgent: "CuriumTest/1") == nil)

        // HLS & MP4 are captured with httpMethod + UA and deduplicated.
        let e1 = try #require(store.mediaRadar.ingest(
            rawEvent: ["url": hlsURL, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200, "contentLength": 4096, "requestDestination": "empty"],
            tabID: "t1",
            effectiveUserAgent: "CuriumTest/160"
        ))
        #expect(e1.kind == .hls)
        #expect(e1.httpMethod == "GET")
        #expect(e1.effectiveUserAgent == "CuriumTest/160")

        store.browserHost(host, tab: tab, didLoadResourceEvent: [
            "url": mp4URL,
            "mimeType": "video/mp4",
            "httpStatusCode": 206,
            "contentLength": 1_048_576,
            "requestDestination": "video",
        ])
        // Re-ingesting same HLS URL updates in place without duplicating.
        _ = store.mediaRadar.ingest(
            rawEvent: ["url": hlsURL, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200, "contentLength": 8192, "requestDestination": "empty"],
            tabID: "t1",
            effectiveUserAgent: "CuriumTest/160"
        )
        #expect(store.mediaRadar.events(for: "t1").count == 2)

        // Same-document navigation preserves captured media; cross-document navigation clears it.
        store.browserHost(host, tab: tab, didCommitNavigationTo: URL(string: "https://video.example/watch#t=10")!, navigationID: 1, isSameDocument: true, isReload: false)
        #expect(store.mediaRadar.events(for: "t1").count == 2)

        store.browserHost(host, tab: tab, didCommitNavigationTo: URL(string: "https://video.example/other")!, navigationID: 2, isSameDocument: false, isReload: false)
        #expect(store.mediaRadar.events(for: "t1").isEmpty)
    }

    @Test("Build 42 isolated-world JS evaluator wrapper parses main and subframe results")
    @MainActor
    func isolatedWorldEvaluatorWrapper() async throws {
        let host = MockBrowserHost()
        let tab = MockTabHost(tabID: "t1", url: URL(string: "https://page.example/watch"))
        let iframeURL = try #require(URL(string: "https://player.cdn.example/embed"))
        tab.isolatedEvalHandler = { script, allFrames in
            #expect(script == "1+1")
            #expect(allFrames == true)
            return ([
                [
                    "isMainFrame": NSNumber(value: true),
                    "frameURL": URL(string: "https://page.example/watch")!,
                    "frameOrigin": "https://page.example",
                    "result": ["videos": 1],
                ],
                [
                    "isMainFrame": NSNumber(value: false),
                    "frameURL": iframeURL,
                    "frameOrigin": "https://player.cdn.example",
                    "result": ["videos": 2],
                ],
            ], nil)
        }
        host.tabs = [tab]
        host.activeTab = tab
        let store = CuriumBrowserStore(host: host)

        let active = try #require(store.activeTab)
        let frames = try await active.evaluateJavaScriptInIsolatedWorld("1+1", allFrames: true)
        #expect(frames.count == 2)
        #expect(frames[0].isMainFrame == true)
        #expect(frames[0].frameOrigin == "https://page.example")
        #expect(frames[1].isMainFrame == false)
        #expect(frames[1].frameURL == iframeURL)
        #expect(frames[1].result == .object(["videos": .number(2)]))
    }
}

@Suite("Address Bar Container & Inner-Portrait Clearance")
@MainActor
struct CuriumAddressBarAndClearanceTests {
    @Test("Inner portrait clearance keeps an interactive gap before status cluster and guards empty/stale occlusions")
    func innerPortraitClearanceAndFallbacks() {
        // Idle inner portrait (669x951, safeTop = 82) with status cluster occlusion (525, 0, 144x82).
        let idle = CuriumBrowserView.resolveTopChromeClearance(
            width: 669,
            safeTop: 82,
            remLeading: 59,
            remTrailing: 59,
            origin: CGPoint(x: 0, y: 82),
            occlusions: [CGRect(x: 525, y: 0, width: 144, height: 82)],
            activeDivisions: []
        )
        #expect(idle.leading == 24)
        #expect(idle.trailing == 152) // (669 - 525) + 8 pt safety gap
        #expect(idle.top == 26)
        #expect(idle.bandFloor == 82)

        // Live Activity widened cluster (467, 0, 202x82).
        let liveActivity = CuriumBrowserView.resolveTopChromeClearance(
            width: 669,
            safeTop: 82,
            remLeading: 59,
            remTrailing: 59,
            origin: CGPoint(x: 0, y: 82),
            occlusions: [CGRect(x: 467, y: 0, width: 202, height: 82)],
            activeDivisions: []
        )
        #expect(liveActivity.trailing == 210) // (669 - 467) + 8 pt safety gap

        // Before first UIKit report (nil) uses widest statusClusterReserve (210).
        let initial = CuriumBrowserView.resolveTopChromeClearance(
            width: 669,
            safeTop: 82,
            remLeading: 59,
            remTrailing: 59,
            origin: CGPoint(x: 0, y: 82),
            occlusions: nil,
            activeDivisions: []
        )
        #expect(initial.trailing == CuriumSpace.statusClusterReserve)

        // Empty [] report or 1-frame stale landscape occlusion (x = 867 > width = 669) keeps idle cluster floor.
        let emptyOcclusions = CuriumBrowserView.resolveTopChromeClearance(
            width: 669,
            safeTop: 82,
            remLeading: 59,
            remTrailing: 59,
            origin: CGPoint(x: 0, y: 82),
            occlusions: [],
            activeDivisions: []
        )
        #expect(emptyOcclusions.trailing == CuriumSpace.statusClusterIdleReserve)

        let staleLandscape = CuriumBrowserView.resolveTopChromeClearance(
            width: 669,
            safeTop: 82,
            remLeading: 59,
            remTrailing: 59,
            origin: CGPoint(x: 0, y: 82),
            occlusions: [CGRect(x: 867, y: 0, width: 84, height: 124)],
            activeDivisions: []
        )
        #expect(staleLandscape.trailing == CuriumSpace.statusClusterIdleReserve)

        // Inner landscape (951x669 -> 867 safe width, safeTop = 0, remLeading = 59) stays symmetric.
        let innerLandscape = CuriumBrowserView.resolveTopChromeClearance(
            width: 867,
            safeTop: 0,
            remLeading: 59,
            remTrailing: 0,
            origin: CGPoint(x: 0, y: 0),
            occlusions: [CGRect(x: 867, y: 0, width: 84, height: 124)],
            activeDivisions: []
        )
        #expect(innerLandscape.leading == 36)
        #expect(innerLandscape.trailing == 36)
        #expect(innerLandscape.top == 20)
    }

    @Test("Address container owns trailing hit-testing, clears synchronously, and blocks post-blur reload misfires")
    func addressFieldContainerHitTestClearAndReloadGuard() {
        var now: CFTimeInterval = 100.0
        var clearCalls = 0
        var reloadCalls = 0

        let container = CuriumAddressFieldContainerView(frame: CGRect(x: 0, y: 0, width: 493, height: 44))
        container.clock = { now }
        container.onClear = { clearCalls += 1 }
        container.onReloadOrStop = { reloadCalls += 1 }
        container.textField.text = "https://www.youtube.com/watch?v=8_xmC3_UkyM"

        // Unfocused with reloadable page: reload button covers trailing 48 pt flush to bounds.maxX.
        container.updateTrailingState(isFocused: false, canReload: true, isLoading: false, isInteractive: true)
        container.layoutIfNeeded()
        #expect(container.clearButton.isHidden)
        #expect(!container.reloadButton.isHidden)
        #expect(container.reloadButton.frame == CGRect(x: 445, y: 0, width: 48, height: 44))
        #expect(container.textField.frame == CGRect(x: 0, y: 0, width: 445, height: 44))
        #expect(container.hitTest(CGPoint(x: 492, y: 22), with: nil) === container.reloadButton)

        // Focused with URL: clear button owns trailing 48 pt (including 1 pt inside right edge), reload hidden.
        container.updateTrailingState(isFocused: true, canReload: true, isLoading: false, isInteractive: true)
        container.layoutIfNeeded()
        #expect(!container.clearButton.isHidden)
        #expect(container.reloadButton.isHidden)
        #expect(container.hitTest(CGPoint(x: 446, y: 22), with: nil) === container.clearButton)
        #expect(container.hitTest(CGPoint(x: 470, y: 22), with: nil) === container.clearButton)
        #expect(container.hitTest(CGPoint(x: 492, y: 22), with: nil) === container.clearButton)
        #expect(container.hitTest(CGPoint(x: 200, y: 22), with: nil) === container.textField)

        // Tapping Clear empties text synchronously, bumps editSessionID, hides Clear, and never fires Reload.
        let sessionBefore = container.textField.editSessionID
        container.clearTapped()
        #expect(container.textField.text == "")
        #expect(container.textField.editSessionID != sessionBefore)
        #expect(clearCalls == 1)
        #expect(reloadCalls == 0)
        #expect(container.clearButton.isHidden)
        #expect(container.reloadButton.isHidden)

        // Even if editing ends immediately before a stray reload tap, the post-blur cooldown suppresses it.
        container.textField.text = "https://www.youtube.com/watch?v=8_xmC3_UkyM"
        container.markEditingBegan()
        container.recordEditingEnded()
        now += 0.05
        container.reloadTapped()
        #expect(reloadCalls == 0)

        // Once the cooldown elapses after editing ends, Reload works cleanly.
        now += 0.30
        container.reloadTapped()
        #expect(reloadCalls == 1)

        // Collapsed state disables interaction so the compact expand pill receives hits directly.
        container.updateTrailingState(isFocused: false, canReload: true, isLoading: false, isInteractive: false)
        #expect(!container.isUserInteractionEnabled)
        #expect(container.hitTest(CGPoint(x: 200, y: 22), with: nil) == nil)
    }
}

@Suite("Wave 1 Hardening")
@MainActor
struct CuriumWave1HardeningTests {
    @Test("Corrupt fingerprint-profiles.json fails closed without overwriting and recovers via .bak")
    func corruptStoreFailsClosedAndRecovers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-w1-corrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let storeURL = dir.appending(path: "fingerprint-profiles.json")
        let corruptPayload = Data("{ truncated json".utf8)
        try corruptPayload.write(to: storeURL)

        let store = CuriumFingerprintStore(fileURL: storeURL)
        #expect(store.loadError != nil)
        #expect(!store.selectProfile(id: "default"))
        #expect(!store.resetToBuild39Default())
        #expect(try Data(contentsOf: storeURL) == corruptPayload)

        let outcome = CuriumFingerprintBootstrap.prepareEngineLaunch(store: store)
        if case .rejected(let profileID, _) = outcome {
            #expect(profileID == "store")
        } else {
            Issue.record("Expected .rejected for corrupt store, got \(outcome)")
        }

        #expect(store.backupCorruptStoreAndReset())
        #expect(store.loadError == nil)
        let backupFiles = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") && $0.pathExtension == "bak" }
        #expect(backupFiles.count == 1)
        #expect(try Data(contentsOf: backupFiles[0]) == corruptPayload)
        #expect(CuriumFingerprintBootstrap.prepareEngineLaunch(store: store) == .defaultBuild39)
    }

    @Test("Duplicating a farbled profile rotates fingerprintSeed and blocks orphaned slug reuse")
    func seedRotationAndOrphanGuard() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-w1-seed-orphan-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let supportRoot = dir.appending(path: "Support", directoryHint: .isDirectory)
        let cachesRoot = dir.appending(path: "Caches", directoryHint: .isDirectory)
        let orphanA = supportRoot.appending(path: "ChromiumProfiles/orphan-2", directoryHint: .isDirectory)
        let orphanB = cachesRoot.appending(path: "ChromiumProfiles/orphan-b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphanA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanB, withIntermediateDirectories: true)

        let store1 = CuriumFingerprintStore(
            fileURL: dir.appending(path: "p1.json"),
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot
        )
        let store2 = CuriumFingerprintStore(
            fileURL: dir.appending(path: "p2.json"),
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot
        )

        let priv1 = try #require(
            store1.createProfile(fromTemplate: "privacy-hardened", displayName: "Privacy One")
        )
        let priv2 = try #require(
            store2.createProfile(fromTemplate: "privacy-hardened", displayName: "Privacy Two")
        )
        let seed1 = try #require(priv1.fingerprintSeed)
        let seed2 = try #require(priv2.fingerprintSeed)
        #expect(CuriumFingerprintSchema.isValidSeedHex(seed1))
        #expect(CuriumFingerprintSchema.isValidSeedHex(seed2))
        #expect(seed1 != seed2)

        let cloned = try #require(
            store1.duplicateProfile(from: priv1.id, newID: "work-private", displayName: "Work Private")
        )
        let clonedSeed = try #require(cloned.fingerprintSeed)
        #expect(CuriumFingerprintSchema.isValidSeedHex(clonedSeed))
        #expect(clonedSeed != seed1)

        let orphans = CuriumFingerprintProfileStorage.discoverOrphanedProfiles(
            knownIDs: Set(store1.profiles.map(\.id)),
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot
        )
        #expect(orphans == ["orphan-2", "orphan-b"])
        #expect(store1.nextAvailableID(base: "orphan") == "orphan-3")
        #expect(store1.duplicateProfile(from: priv1.id, newID: "orphan-2", displayName: "Collide") == nil)
    }

    @Test("RTL top clearance keeps physical pillShift and unedited Row 0 direct-open is suppressed")
    func rtlClearanceAndDirectOpenSuppression() {
        let ltr = CuriumBrowserView.resolveTopChromeClearance(
            width: 669,
            safeTop: 82,
            remLeading: 59,
            remTrailing: 59,
            origin: .zero,
            occlusions: [CGRect(x: 525, y: 0, width: 144, height: 82)],
            activeDivisions: [],
            layoutDirection: .leftToRight,
            ignoresTopSafeArea: true
        )
        #expect(ltr.leading == 24)
        #expect(ltr.trailing == 152)
        #expect(ltr.pillShift == 64)

        let rtl = CuriumBrowserView.resolveTopChromeClearance(
            width: 669,
            safeTop: 82,
            remLeading: 59,
            remTrailing: 59,
            origin: .zero,
            occlusions: [CGRect(x: 0, y: 0, width: 144, height: 82)],
            activeDivisions: [],
            layoutDirection: .rightToLeft,
            ignoresTopSafeArea: true
        )
        #expect(rtl.leading == 24)
        #expect(rtl.trailing == 152)
        #expect(rtl.pillShift == -64)

        #expect(CuriumAddressMatches.shouldSuppressDirectOpenRow(
            text: "https://www.youtube.com/watch?v=8_xmC3_UkyM",
            currentAddress: "https://www.youtube.com/watch?v=8_xmC3_UkyM"
        ))
        #expect(!CuriumAddressMatches.shouldSuppressDirectOpenRow(
            text: "https://www.youtube.com/watch?v=edited",
            currentAddress: "https://www.youtube.com/watch?v=8_xmC3_UkyM"
        ))
        #expect(!CuriumAddressMatches.shouldSuppressDirectOpenRow(text: "", currentAddress: ""))
    }

    @Test("Media permission preemption re-queues prompt without auto-denying and sheet errors unblock queue")
    func mediaPermissionPreemptionRequeueAndSheetErrors() async {
        var presented: CuriumMediaPermissionPrompt?
        var results: [CuriumMediaPermissions] = []
        let coordinator = CuriumMediaPermissionCoordinator(
            isRequestCurrent: { _, _ in true },
            authorizeCapture: { _ in true },
            onPromptChange: { presented = $0 }
        )

        coordinator.enqueue(
            permissions: .camera,
            originURL: URL(string: "https://meet.example")!,
            tabID: "t1"
        ) { granted in
            results.append(granted)
        }
        #expect(presented != nil)
        #expect(results.isEmpty)

        // Sheet presentation preempts the active alert: prompt hides without failing closed.
        coordinator.setPresentationBlocked(true)
        #expect(presented == nil)
        #expect(results.isEmpty)

        // Sheet dismissal re-presents the exact same prompt so the user can still grant it.
        coordinator.setPresentationBlocked(false)
        #expect(presented != nil)
        #expect(results.isEmpty)

        coordinator.respondToActivePrompt(allowed: true)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(results == [.camera])

        // Sheet-local error routing keeps root errorMessage clear and exposes downloadsRoot.
        let customRoot = FileManager.default.temporaryDirectory
            .appending(path: "curium-w1-dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        let host = MockBrowserHost()
        let store = CuriumBrowserStore(host: host, downloadsRoot: customRoot)
        #expect(store.downloadsRoot == customRoot)
        store.setSheetPresented(true)
        for _ in 0..<25 {
            _ = store.newTab()
        }
        #expect(store.errorMessage == nil)
        #expect(store.sheetErrorMessage != nil)
        store.setSheetPresented(false)
        #expect(store.sheetErrorMessage == nil)
    }

    @Test("Offscreen outgoing tab snapshot captures via engine even when webView.window is nil")
    func offscreenOutgoingTabSnapshotCaptures() async throws {
        let host = MockBrowserHost()
        let t1 = MockTabHost(tabID: "t1", url: URL(string: "https://a.example"))
        let t2 = MockTabHost(tabID: "t2", url: URL(string: "https://b.example"))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        t1.snapshotImageToReturn = renderer.image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        host.tabs = [t1, t2]
        host.activeTab = t1

        let store = CuriumBrowserStore(host: host)
        let model1 = try #require(store.tabs.first { $0.id == "t1" })
        let model2 = try #require(store.tabs.first { $0.id == "t2" })
        #expect(t1.webView.window == nil)

        store.select(model2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model1.thumbnail != nil)
    }
}

@Suite("Wave 2 Multi-Profile & LiveContainer Downloads")
struct CuriumWave2MultiProfileAndDownloadsTests {
    private func makeTempDir(_ prefix: String = "curium-w2") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct V1PersistedFixture: Encodable {
        let version: Int
        let selectedProfileID: String?
        let profiles: [CuriumFingerprintProfile]
    }

    @Test("v1 store automatically migrates to v2 retaining default, custom, selected, and on-disk profiles")
    func v1ToV2AutomaticMigration() throws {
        let root = try makeTempDir("curium-w2-migrate")
        defer { try? FileManager.default.removeItem(at: root) }

        let supportRoot = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let cachesRoot = root.appending(path: "Caches", directoryHint: .isDirectory)
        let onDiskPrivacyDir = supportRoot.appending(path: "ChromiumProfiles/privacy-hardened", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: onDiskPrivacyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cachesRoot, withIntermediateDirectories: true)

        let retiredSeed = try #require(CuriumFingerprintSchema.retiredStaticSeeds.first)
        var v1Profiles = CuriumFingerprintPresets.allBuiltIns
        if let privacyIdx = v1Profiles.firstIndex(where: { $0.id == "privacy-hardened" }) {
            v1Profiles[privacyIdx].fingerprintSeed = retiredSeed
        }

        var workEU = CuriumFingerprintPresets.defaultAuthenticChrome
        workEU.id = "work-eu"
        workEU.displayName = "Work EU"
        workEU.isBuiltIn = false
        workEU.hardware.timezone = "Europe/Berlin"
        v1Profiles.append(workEU)

        let fileURL = root.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)
        let fixture = V1PersistedFixture(
            version: 1,
            selectedProfileID: "macos-desktop",
            profiles: v1Profiles
        )
        let encodedFixture = try JSONEncoder().encode(fixture)
        try encodedFixture.write(to: fileURL, options: .atomic)

        let store = CuriumFingerprintStore(
            fileURL: fileURL,
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot
        )
        #expect(store.loadError == nil)
        #expect(store.selectedProfileID == "macos-desktop")
        #expect(store.nextLaunchProfileID == "macos-desktop")

        let retainedIDs = Set(store.profiles.map(\.id))
        #expect(retainedIDs == Set(["default", "macos-desktop", "privacy-hardened", "work-eu"]))
        #expect(store.profiles.count == 4)

        let defaultProfile = try #require(store.profiles.first)
        #expect(defaultProfile.id == "default")
        #expect(defaultProfile.displayName == "Personal")
        #expect(!defaultProfile.isBuiltIn)
        #expect(defaultProfile.templateID == "default")
        #expect(defaultProfile.symbolName == "person.crop.circle")
        #expect(defaultProfile.palette != nil)
        #expect(defaultProfile.siteMode != nil)
        #expect(defaultProfile.searchEngine != nil)

        let migratedWork = try #require(store.profile(id: "work-eu"))
        #expect(migratedWork.displayName == "Work EU")
        #expect(migratedWork.hardware.timezone == "Europe/Berlin")
        #expect(!migratedWork.isBuiltIn)

        let migratedMac = try #require(store.profile(id: "macos-desktop"))
        #expect(migratedMac.id == "macos-desktop")
        #expect(!migratedMac.isBuiltIn)
        #expect(migratedMac.templateID == "macos-desktop")

        let migratedPrivacy = try #require(store.profile(id: "privacy-hardened"))
        #expect(migratedPrivacy.id == "privacy-hardened")
        #expect(!migratedPrivacy.isBuiltIn)
        #expect(migratedPrivacy.templateID == "privacy-hardened")
        let upgradedSeed = try #require(migratedPrivacy.fingerprintSeed)
        #expect(CuriumFingerprintSchema.isValidSeedHex(upgradedSeed))
        #expect(!CuriumFingerprintSchema.isRetiredStaticSeed(upgradedSeed))
        #expect(upgradedSeed != retiredSeed)

        for unusedID in ["linux-desktop", "win11-workstation", "ios-blink", "pixel-android"] {
            #expect(store.profile(id: unusedID) == nil)
        }

        // Persisted file upgrades immediately to schema v2 and survives reload identically.
        let persistedData = try Data(contentsOf: fileURL)
        let persistedState = try JSONDecoder().decode(CuriumFingerprintStore.PersistedState.self, from: persistedData)
        #expect(persistedState.version == 2)
        #expect(persistedState.selectedProfileID == "macos-desktop")
        #expect(Set(persistedState.profiles.map(\.id)) == retainedIDs)

        let reloaded = CuriumFingerprintStore(
            fileURL: fileURL,
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot
        )
        #expect(reloaded.loadError == nil)
        #expect(reloaded.selectedProfileID == "macos-desktop")
        #expect(reloaded.profile(id: "privacy-hardened")?.fingerprintSeed == upgradedSeed)
    }

    @Test("Immutable p-<8hex> creation, tombstone ledger, persona metadata, delete guards, and actinide palettes")
    func immutableSlugCreationTombstonesPersonaMetadataAndDeleteGuards() throws {
        let root = try makeTempDir("curium-w2-slugs")
        defer { try? FileManager.default.removeItem(at: root) }

        let supportRoot = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let cachesRoot = root.appending(path: "Caches", directoryHint: .isDirectory)
        let fileURL = root.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)

        let store = CuriumFingerprintStore(
            fileURL: fileURL,
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot
        )
        #expect(store.profiles.count == 1)
        #expect(store.profiles.first?.id == "default")
        #expect(store.templates.count == 7)

        let created = try #require(
            store.createProfile(
                fromTemplate: "privacy-hardened",
                displayName: "Shopping",
                symbolName: "bag",
                palette: .americium
            )
        )
        #expect(created.id.hasPrefix("p-"))
        let hexSuffix = String(created.id.dropFirst(2))
        #expect(hexSuffix.count == 8)
        #expect(hexSuffix.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 48 && v <= 57) || (v >= 97 && v <= 102)
        })
        #expect(CuriumFingerprintValidator.isValidProfileID(created.id))
        #expect(created.displayName == "Shopping")
        #expect(created.symbolName == "bag")
        #expect(created.palette == .americium)
        #expect(created.templateID == "privacy-hardened")

        let seed = try #require(created.fingerprintSeed)
        #expect(CuriumFingerprintSchema.isValidSeedHex(seed))
        #expect(!CuriumFingerprintSchema.isRetiredStaticSeed(seed))
        #expect(created.isFarblingActive)

        #expect(store.updatePersonaMetadata(
            for: created.id,
            displayName: "Shopping EU",
            symbolName: "sparkles",
            palette: .berkelium,
            siteMode: .desktop,
            searchEngine: .brave
        ))
        #expect(store.selectProfile(id: created.id))

        let reloaded = CuriumFingerprintStore(
            fileURL: fileURL,
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot
        )
        #expect(reloaded.selectedProfileID == created.id)
        let loaded = try #require(reloaded.profile(id: created.id))
        #expect(loaded.displayName == "Shopping EU")
        #expect(loaded.symbolName == "sparkles")
        #expect(loaded.palette == .berkelium)
        #expect(loaded.siteMode == .desktop)
        #expect(loaded.searchEngine == .brave)
        #expect(loaded.templateID == "privacy-hardened")
        #expect(loaded.fingerprintSeed == seed)

        // Engine wire payload must strictly exclude all v2 UI persona & lifecycle metadata.
        let wireData = try loaded.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US"])
        let wireObj = try #require(JSONSerialization.jsonObject(with: wireData) as? [String: Any])
        #expect((wireObj["profileId"] as? String) == created.id)
        #expect((wireObj["fingerprintSeed"] as? String) == seed)
        for forbiddenKey in [
            "symbolName", "palette", "siteMode", "searchEngine", "templateID",
            "createdAt", "lastUsedAt", "displayName", "notes", "isBuiltIn",
        ] {
            #expect(wireObj[forbiddenKey] == nil, "Engine wire JSON leaked UI key \(forbiddenKey)")
        }

        // Default cannot be deleted; deleting an isolated profile records its slug in `retiredProfileIDs`,
        // redirects selection back to default, and blocks reusing the retired slug.
        #expect(!reloaded.deleteProfile(id: "default"))
        #expect(reloaded.profile(id: "default") != nil)

        #expect(reloaded.deleteProfile(id: created.id))
        #expect(reloaded.profile(id: created.id) == nil)
        #expect(reloaded.retiredProfileIDs.contains(created.id.lowercased()))
        #expect(reloaded.selectedProfileID == nil)
        #expect(reloaded.nextLaunchProfileID == "default")

        let reuseReport = reloaded.upsert(loaded)
        #expect(!reuseReport.isValid)
        #expect(reuseReport.errors.contains { $0.contains("retired") })

        var upperReuse = loaded
        upperReuse.id = created.id.uppercased()
        #expect(!reloaded.upsert(upperReuse).isValid)
        #expect(reloaded.duplicateProfile(from: "default", newID: created.id, displayName: "Reuse") == nil)

        let afterDelete = CuriumFingerprintStore(
            fileURL: fileURL,
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot
        )
        #expect(afterDelete.retiredProfileIDs.contains(created.id.lowercased()))
        #expect(afterDelete.selectedProfileID == nil)
        #expect(!afterDelete.upsert(loaded).isValid)

        // All 6 actinide palettes and per-profile enums encode/decode cleanly; curated SF Symbols are populated.
        let expectedPalettes: [CuriumPalette] = [
            .violet, .thorium, .neptunium, .americium, .berkelium, .californium,
        ]
        #expect(CuriumPalette.allCases == expectedPalettes)
        for accent in expectedPalettes {
            let encoded = try JSONEncoder().encode(accent)
            let decoded = try JSONDecoder().decode(CuriumPalette.self, from: encoded)
            #expect(decoded == accent)
            #expect(!accent.title.isEmpty)
            #expect(!accent.notation.isEmpty)
        }
        for mode in CuriumSiteMode.allCases {
            let decoded = try JSONDecoder().decode(CuriumSiteMode.self, from: try JSONEncoder().encode(mode))
            #expect(decoded == mode)
        }
        for engine in CuriumSearchEngine.allCases {
            let decoded = try JSONDecoder().decode(CuriumSearchEngine.self, from: try JSONEncoder().encode(engine))
            #expect(decoded == engine)
        }
        #expect(!CuriumProfileSymbols.curated.isEmpty)
        #expect(CuriumProfileSymbols.curated.contains("person.crop.circle"))
        #expect(CuriumProfileSymbols.curated.contains("bag"))
    }

    @Test("Per-profile SQLite resolution skips legacy adoption and isolates bookmarks and history")
    func perProfileSQLiteIsolation() async throws {
        let isolatedResolution = try CuriumLibraryLocation.resolve(profileID: "p-a1b2c3d4")
        #expect(isolatedResolution.database.path.hasSuffix("Curium/Profiles/p-a1b2c3d4/curium.sqlite"))
        #expect(isolatedResolution.legacy.isEmpty)
        #expect(throws: Error.self) {
            _ = try CuriumLibraryLocation.resolve(profileID: "../escape")
        }

        let root = try makeTempDir("curium-w2-sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseSupportRoot = root.appending(path: "Curium", directoryHint: .isDirectory)

        let defaultDir = try CuriumLibraryLocation.profileSupportDirectory(
            for: "default",
            baseSupportRoot: baseSupportRoot
        )
        let isolatedDir = try CuriumLibraryLocation.profileSupportDirectory(
            for: "p-a1b2c3d4",
            baseSupportRoot: baseSupportRoot
        )
        #expect(defaultDir.standardizedFileURL == baseSupportRoot.standardizedFileURL)
        #expect(isolatedDir.path.hasSuffix("Curium/Profiles/p-a1b2c3d4"))

        let defaultDB = CuriumDatabase(
            databaseURL: defaultDir.appending(path: CuriumLibraryLocation.fileName, directoryHint: .notDirectory),
            profileID: "default"
        )
        let isolatedDB = CuriumDatabase(
            databaseURL: isolatedDir.appending(path: CuriumLibraryLocation.fileName, directoryHint: .notDirectory),
            profileID: "p-a1b2c3d4"
        )

        let personalBookmark = try #require(URL(string: "https://personal.example/home"))
        let personalVisit = try #require(URL(string: "https://personal-news.example/article"))
        let workBookmark = try #require(URL(string: "https://work-portal.example/dashboard"))
        let workVisit = try #require(URL(string: "https://work-docs.example/spec"))
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)

        _ = try await defaultDB.saveBookmark(
            url: personalBookmark,
            title: "Personal Home",
            in: CuriumBookmarkFolder.favoritesID,
            at: timestamp
        )
        try await defaultDB.recordVisit(url: personalVisit, title: "Personal News", at: timestamp)

        _ = try await isolatedDB.saveBookmark(
            url: workBookmark,
            title: "Work Portal",
            in: CuriumBookmarkFolder.favoritesID,
            at: timestamp
        )
        try await isolatedDB.recordVisit(url: workVisit, title: "Work Spec", at: timestamp)

        let defaultTree = try await defaultDB.bookmarkTree()
        let isolatedTree = try await isolatedDB.bookmarkTree()
        #expect(defaultTree.isBookmarked(personalBookmark))
        #expect(!defaultTree.isBookmarked(workBookmark))
        #expect(isolatedTree.isBookmarked(workBookmark))
        #expect(!isolatedTree.isBookmarked(personalBookmark))

        let defaultHistoryURLs = try await defaultDB
            .historyDays(matching: "", limit: 20, calendar: .current)
            .flatMap(\.entries)
            .map(\.url)
        let isolatedHistoryURLs = try await isolatedDB
            .historyDays(matching: "", limit: 20, calendar: .current)
            .flatMap(\.entries)
            .map(\.url)
        #expect(defaultHistoryURLs == [personalVisit])
        #expect(isolatedHistoryURLs == [workVisit])

        let defaultWorkMatches = try await defaultDB.addressMatches(for: "work", limit: 6, now: timestamp)
        let isolatedPersonalMatches = try await isolatedDB.addressMatches(for: "personal", limit: 6, now: timestamp)
        #expect(defaultWorkMatches.isEmpty)
        #expect(isolatedPersonalMatches.isEmpty)
    }

    @Test("Per-profile CuriumSessionStorage filters non-web schemes, clamps activeIndex, caps at 24 tabs, and clears on empty")
    func perProfileSessionStorageSaveRestoreAndCap() throws {
        let root = try makeTempDir("curium-w2-session")
        defer { try? FileManager.default.removeItem(at: root) }

        let profileDir = root.appending(path: "p-a1b2c3d4", directoryHint: .isDirectory)
        let siblingDir = root.appending(path: "default", directoryHint: .isDirectory)

        let mixedURLs: [URL] = try [
            #require(URL(string: "https://example.com")),
            #require(URL(string: "chrome://settings")),
            #require(URL(string: "https://webkit.org")),
            #require(URL(string: "file:///etc/passwd")),
        ]
        CuriumSessionStorage.save(urls: mixedURLs, activeIndex: 2, forProfile: "p-a1b2c3d4", directory: profileDir)
        CuriumSessionStorage.save(
            urls: [try #require(URL(string: "http://personal.local/page"))],
            activeIndex: 0,
            forProfile: "default",
            directory: siblingDir
        )

        let loaded = try #require(CuriumSessionStorage.load(forProfile: "p-a1b2c3d4", directory: profileDir))
        #expect(loaded.openTabURLs == ["https://example.com", "https://webkit.org"])
        #expect(loaded.activeTabIndex == 1)

        // Sibling profile session stays isolated.
        let siblingLoaded = try #require(CuriumSessionStorage.load(forProfile: "default", directory: siblingDir))
        #expect(siblingLoaded.openTabURLs == ["http://personal.local/page"])
        #expect(siblingLoaded.activeTabIndex == 0)

        // Out-of-range activeIndex clamps cleanly.
        CuriumSessionStorage.save(urls: mixedURLs, activeIndex: 99, forProfile: "p-a1b2c3d4", directory: profileDir)
        #expect(CuriumSessionStorage.load(forProfile: "p-a1b2c3d4", directory: profileDir)?.activeTabIndex == 1)

        CuriumSessionStorage.save(urls: mixedURLs, activeIndex: -4, forProfile: "p-a1b2c3d4", directory: profileDir)
        #expect(CuriumSessionStorage.load(forProfile: "p-a1b2c3d4", directory: profileDir)?.activeTabIndex == 0)

        // 24-tab cap is enforced deterministically.
        let thirtyURLs = try (0..<30).map { idx in
            try #require(URL(string: "https://tab-\(idx).example/"))
        }
        CuriumSessionStorage.save(urls: thirtyURLs, activeIndex: 28, forProfile: "p-a1b2c3d4", directory: profileDir)
        let capped = try #require(CuriumSessionStorage.load(forProfile: "p-a1b2c3d4", directory: profileDir))
        #expect(capped.openTabURLs.count == CuriumSessionStorage.maxSavedTabs)
        #expect(capped.openTabURLs.first == "https://tab-0.example/")
        #expect(capped.openTabURLs.last == "https://tab-23.example/")
        #expect(capped.activeTabIndex == CuriumSessionStorage.maxSavedTabs - 1)

        // Saving [] deletes session.json on disk.
        let sessionFile = try CuriumSessionStorage.sessionFileURL(forProfile: "p-a1b2c3d4", directory: profileDir)
        #expect(FileManager.default.fileExists(atPath: sessionFile.path))
        CuriumSessionStorage.save(urls: [], activeIndex: 0, forProfile: "p-a1b2c3d4", directory: profileDir)
        #expect(!FileManager.default.fileExists(atPath: sessionFile.path))
        #expect(CuriumSessionStorage.load(forProfile: "p-a1b2c3d4", directory: profileDir) == nil)
    }

    @Test("Profile switch handoff builds LiveContainer 1/2 relaunch URLs and flushes tabs, SQLite, and selection safely")
    @MainActor
    func profileSwitchHandoffAndLiveContainerRelaunchURLs() async throws {
        let bundlePath = "/var/containers/Bundle/Application/12345678/com.appautomaton.curium.app"
        let lc1URL = try #require(
            CuriumProfileRelauncher.liveContainerRelaunchURL(bundlePath: bundlePath, scheme: "livecontainer")
        )
        #expect(lc1URL.absoluteString == "livecontainer://livecontainer-launch?bundle-name=com.appautomaton.curium.app")

        let lc2URL = try #require(
            CuriumProfileRelauncher.liveContainerRelaunchURL(bundlePath: bundlePath, scheme: "livecontainer2")
        )
        #expect(lc2URL.absoluteString == "livecontainer2://livecontainer-launch?bundle-name=com.appautomaton.curium.app")

        let fallbackBundleURL = try #require(
            CuriumProfileRelauncher.liveContainerRelaunchURL(bundlePath: "/tmp/not-a-bundle", scheme: "livecontainer")
        )
        #expect(fallbackBundleURL.absoluteString == "livecontainer://livecontainer-launch?bundle-name=com.appautomaton.curium.app")
        #expect(CuriumProfileRelauncher.liveContainerRelaunchURL(bundlePath: bundlePath, scheme: "   ") == nil)

        let root = try makeTempDir("curium-w2-handoff")
        defer { try? FileManager.default.removeItem(at: root) }

        let fpFileURL = root.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)
        let dbURL = root.appending(path: CuriumLibraryLocation.fileName, directoryHint: .notDirectory)
        let sessionDir = root.appending(path: "Session", directoryHint: .isDirectory)
        let downloadsDir = root.appending(path: "Downloads", directoryHint: .isDirectory)
        let previewDir = root.appending(path: "PDFPreview", directoryHint: .isDirectory)

        let fpStore = CuriumFingerprintStore(
            fileURL: fpFileURL,
            applicationSupportRoot: root.appending(path: "Support", directoryHint: .isDirectory),
            cachesRoot: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let targetProfile = try #require(
            fpStore.createProfile(fromTemplate: "macos-desktop", displayName: "Work Mac")
        )

        let db = CuriumDatabase(databaseURL: dbURL, profileID: "default")
        let library = CuriumLibrary(profileID: "default", database: db, fingerprintStore: fpStore)
        let checkpointURL = try #require(URL(string: "https://checkpoint.example/handoff"))
        library.recordVisit(url: checkpointURL, title: "Handoff Check")

        let host = MockBrowserHost()
        let tab1URL = try #require(URL(string: "https://example.com"))
        let tab2URL = try #require(URL(string: "chrome://settings"))
        let tab3URL = try #require(URL(string: "https://webkit.org"))
        let tab1 = MockTabHost(tabID: "t1", extensionTabID: 1, url: tab1URL)
        let tab2 = MockTabHost(tabID: "t2", extensionTabID: 2, url: tab2URL)
        let tab3 = MockTabHost(tabID: "t3", extensionTabID: 3, url: tab3URL)
        host.tabs = [tab1, tab2, tab3]
        host.activeTab = tab3

        let browserStore = CuriumBrowserStore(
            host: host,
            extensionManager: MockExtensionManager(),
            downloadsRoot: downloadsDir,
            pdfPreviewCacheRoot: previewDir,
            activeProfileID: "default",
            library: library,
            fingerprintStore: fpStore,
            sessionDirectoryOverride: sessionDir,
            restoreSession: false
        )

        var relaunchCalls = 0
        // Unknown target fails closed without triggering relaunch.
        let invalidSwitch = await browserStore.prepareForProfileSwitchAndRelaunch(to: "p-00000000") {
            relaunchCalls += 1
        }
        #expect(!invalidSwitch)
        #expect(relaunchCalls == 0)

        let switched = await browserStore.prepareForProfileSwitchAndRelaunch(to: targetProfile.id) {
            relaunchCalls += 1
        }
        #expect(switched)
        #expect(relaunchCalls == 1)
        #expect(fpStore.selectedProfileID == targetProfile.id)

        let reloadedFPStore = CuriumFingerprintStore(fileURL: fpFileURL)
        #expect(reloadedFPStore.selectedProfileID == targetProfile.id)

        // Open web tabs persisted to session.json with non-web tabs stripped and active tab mapped cleanly.
        let savedSession = try #require(CuriumSessionStorage.load(forProfile: "default", directory: sessionDir))
        #expect(savedSession.openTabURLs == ["https://example.com", "https://webkit.org"])
        #expect(savedSession.activeTabIndex == 1)

        // Library write was flushed & checkpointed cleanly before relaunch.
        let flushedVisits = try await db
            .historyDays(matching: "checkpoint.example", limit: 10, calendar: .current)
            .flatMap(\.entries)
            .map(\.url)
        #expect(flushedVisits == [checkpointURL])
        let walPath = dbURL.path + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            let walAttrs = try FileManager.default.attributesOfItem(atPath: walPath)
            #expect(((walAttrs[.size] as? NSNumber)?.int64Value ?? 0) == 0)
        }

        // Fresh store restores the saved session into standby tabs cleanly.
        let restoredStore = CuriumBrowserStore(
            host: nil,
            downloadsRoot: downloadsDir,
            pdfPreviewCacheRoot: previewDir,
            activeProfileID: "default",
            library: library,
            fingerprintStore: fpStore,
            sessionDirectoryOverride: sessionDir,
            restoreSession: true
        )
        #expect(restoredStore.tabs.compactMap(\.url).map(\.absoluteString) == ["https://example.com", "https://webkit.org"])
        #expect(restoredStore.activeTab?.url?.absoluteString == "https://webkit.org")
    }

    @Test("LiveContainer Tier A 3-parent walk, Tier B bookmark record, per-profile PDF cache, and staged commit")
    func liveContainerTierATierBPDFCacheAndStagedCommit() throws {
        // 1. Tier A Private LiveContainer 3-parent walk -> <HostContainer>/Documents/Curium/Downloads.
        let privateLCPath = "/var/mobile/Containers/Data/Application/HOST-1/Documents/Data/Application/GUEST-1"
        let privateRoot = try CuriumDownloadStorage.defaultDownloadsRootDirectory(
            environment: ["LC_HOME_PATH": privateLCPath],
            homeDirectory: privateLCPath,
            sharedAppGroupURL: nil
        )
        #expect(privateRoot.path == "/var/mobile/Containers/Data/Application/HOST-1/Documents/Curium/Downloads")
        #expect(CuriumDownloadStorage.isPrivateHostDocumentsLayout(fromCandidatePaths: [privateLCPath]))

        // Even when an App Group URL is present, Private host Documents layout keeps Files.app visibility.
        let sharedGroupURL = URL(fileURLWithPath: "/var/mobile/Containers/Shared/AppGroup/GRP-1", isDirectory: true)
        let privateWithGroup = try CuriumDownloadStorage.defaultDownloadsRootDirectory(
            environment: ["LC_HOME_PATH": privateLCPath],
            homeDirectory: privateLCPath,
            sharedAppGroupURL: sharedGroupURL
        )
        #expect(privateWithGroup.path == "/var/mobile/Containers/Data/Application/HOST-1/Documents/Curium/Downloads")

        // 2. Tier A Shared LiveContainer App Group layout -> <SharedAppGroup>/Documents/Curium/Downloads.
        let sharedLCPath = "/var/mobile/Containers/Shared/AppGroup/GRP-1/LiveContainer/Data/Application/GUEST-1"
        let sharedRoot = try CuriumDownloadStorage.defaultDownloadsRootDirectory(
            environment: ["LC_HOME_PATH": sharedLCPath],
            homeDirectory: sharedLCPath,
            sharedAppGroupURL: sharedGroupURL
        )
        #expect(sharedRoot.path == "/var/mobile/Containers/Shared/AppGroup/GRP-1/Documents/Curium/Downloads")
        #expect(!CuriumDownloadStorage.isPrivateHostDocumentsLayout(fromCandidatePaths: [sharedLCPath]))

        let sharedFallbackRoot = try CuriumDownloadStorage.defaultDownloadsRootDirectory(
            environment: ["LC_HOME_PATH": sharedLCPath],
            homeDirectory: sharedLCPath,
            sharedAppGroupURL: nil
        )
        #expect(sharedFallbackRoot.path == "/var/mobile/Containers/Shared/AppGroup/GRP-1/Documents/Curium/Downloads")

        // 3. Per-profile PDF preview cache isolation and sibling-safe stale cleanup.
        let defaultPDFRoot = try CuriumDownloadStorage.pdfPreviewCacheRoot(profileID: "default")
        let profilePDFRoot = try CuriumDownloadStorage.pdfPreviewCacheRoot(profileID: "p-12345678")
        #expect(defaultPDFRoot.lastPathComponent == CuriumDownloadStorage.previewCacheDirectoryName)
        #expect(profilePDFRoot.path.hasSuffix("/\(CuriumDownloadStorage.previewCacheDirectoryName)/p-12345678"))
        #expect(profilePDFRoot.deletingLastPathComponent().standardizedFileURL == defaultPDFRoot.standardizedFileURL)

        let sandbox = try makeTempDir("curium-w2-downloads")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let tempPreviewBase = sandbox.appending(path: CuriumDownloadStorage.previewCacheDirectoryName, directoryHint: .isDirectory)
        let staleDefaultSession = tempPreviewBase.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let isolatedProfileDir = tempPreviewBase.appending(path: "p-12345678", directoryHint: .isDirectory)
        let isolatedSessionDir = isolatedProfileDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let isolatedPDF = isolatedSessionDir.appending(path: "spec.pdf", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: staleDefaultSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: isolatedSessionDir, withIntermediateDirectories: true)
        try Data("%PDF-1.4\nisolated".utf8).write(to: isolatedPDF)

        CuriumDownloadStorage.cleanupStalePDFPreviews(cacheRoot: tempPreviewBase)
        #expect(!FileManager.default.fileExists(atPath: staleDefaultSession.path))
        #expect(FileManager.default.fileExists(atPath: isolatedProfileDir.path))
        #expect(FileManager.default.fileExists(atPath: isolatedPDF.path))

        CuriumDownloadStorage.cleanupStalePDFPreviews(cacheRoot: isolatedProfileDir)
        #expect(!FileManager.default.fileExists(atPath: isolatedSessionDir.path))

        // 4. Staged download commit with collision-free naming and source cleanup.
        let stagingRoot = sandbox.appending(path: "Staging", directoryHint: .isDirectory)
        let destDir = sandbox.appending(path: "Downloads", directoryHint: .isDirectory)

        let staged1 = try CuriumDownloadStorage.makeDownloadStagingDestination(
            filename: "report.bin",
            stagingRoot: stagingRoot
        )
        defer { CuriumDownloadStorage.removeDownloadStagingDirectory(staged1.sessionDirectory, stagingRoot: stagingRoot) }
        let payload1 = Data("payload-one".utf8)
        try payload1.write(to: staged1.fileURL)

        let committed1 = try CuriumDownloadStorage.commitStagedFile(
            from: staged1.fileURL,
            toDirectory: destDir,
            preferredFilename: "report.bin",
            removeSource: true
        )
        #expect(committed1.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL)
        #expect(committed1.lastPathComponent == "report.bin")
        #expect(try Data(contentsOf: committed1) == payload1)
        #expect(!FileManager.default.fileExists(atPath: staged1.fileURL.path))

        let staged2 = try CuriumDownloadStorage.makeDownloadStagingDestination(
            filename: "report.bin",
            stagingRoot: stagingRoot
        )
        defer { CuriumDownloadStorage.removeDownloadStagingDirectory(staged2.sessionDirectory, stagingRoot: stagingRoot) }
        let payload2 = Data("payload-two".utf8)
        try payload2.write(to: staged2.fileURL)

        let committed2 = try CuriumDownloadStorage.commitStagedFile(
            from: staged2.fileURL,
            toDirectory: destDir,
            preferredFilename: "report.bin",
            removeSource: true
        )
        #expect(committed2.lastPathComponent == "report (2).bin")
        #expect(try Data(contentsOf: committed2) == payload2)
        #expect(!FileManager.default.fileExists(atPath: staged2.fileURL.path))

        let staged3 = try CuriumDownloadStorage.makeDownloadStagingDestination(
            filename: "report.bin",
            stagingRoot: stagingRoot
        )
        defer { CuriumDownloadStorage.removeDownloadStagingDirectory(staged3.sessionDirectory, stagingRoot: stagingRoot) }
        let payload3 = Data("payload-three".utf8)
        try payload3.write(to: staged3.fileURL)

        let committed3 = try CuriumDownloadStorage.commitStagedFile(
            from: staged3.fileURL,
            toDirectory: destDir,
            preferredFilename: "report.bin",
            removeSource: false
        )
        #expect(committed3.lastPathComponent == "report (3).bin")
        #expect(try Data(contentsOf: committed3) == payload3)
        #expect(FileManager.default.fileExists(atPath: staged3.fileURL.path))

        // 5. Tier B Inbox/tmp rejection and multi-host SharedFolderRecord round-trip in isolated UserDefaults.
        #expect(CuriumDownloadsFolderManager.isRejectedInboxOrTemporaryURL(
            URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/A1/tmp/com.appautomaton.curium-Inbox")
        ))
        #expect(CuriumDownloadsFolderManager.isRejectedInboxOrTemporaryURL(
            URL(fileURLWithPath: "/var/mobile/Documents/com.kdt.livecontainer-Inbox/Downloads")
        ))
        #expect(CuriumDownloadsFolderManager.isRejectedInboxOrTemporaryURL(
            URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/A1/tmp/PickedFolder")
        ))
        #expect(CuriumDownloadsFolderManager.isRejectedInboxOrTemporaryURL(
            FileManager.default.temporaryDirectory.appending(path: "EphemeralFolder", directoryHint: .isDirectory)
        ))
        #expect(!CuriumDownloadsFolderManager.isRejectedInboxOrTemporaryURL(
            URL(fileURLWithPath: "/var/mobile/Containers/Shared/AppGroup/FP-1/File Provider Storage/Curium Downloads")
        ))
        #expect(!CuriumDownloadsFolderManager.isRejectedInboxOrTemporaryURL(
            URL(fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Curium Downloads")
        ))

        let suiteName = "com.appautomaton.curium.tests.downloads-folder.\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            CuriumDownloadsFolderManager.clearRecord(defaults: isolatedDefaults)
            isolatedDefaults.removePersistentDomain(forName: suiteName)
        }

        #expect(CuriumDownloadsFolderManager.loadRecord(defaults: isolatedDefaults) == nil)
        let record = CuriumDownloadsFolderManager.SharedFolderRecord(
            folderName: "Curium Downloads",
            breadcrumb: "iCloud Drive › Curium Downloads",
            canonicalPathHint: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Curium Downloads",
            bookmarksByHost: [
                "com.kdt.livecontainer.host1": Data([0x01, 0x02, 0x03, 0x04]),
                "com.kdt.LiveContainer2.host2": Data([0xAA, 0xBB, 0xCC, 0xDD]),
            ]
        )
        CuriumDownloadsFolderManager.saveRecord(record, defaults: isolatedDefaults)

        let reloadedRecord = try #require(CuriumDownloadsFolderManager.loadRecord(defaults: isolatedDefaults))
        #expect(reloadedRecord == record)
        #expect(reloadedRecord.bookmarksByHost["com.kdt.livecontainer.host1"] == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(reloadedRecord.bookmarksByHost["com.kdt.LiveContainer2.host2"] == Data([0xAA, 0xBB, 0xCC, 0xDD]))
        #expect(reloadedRecord.bookmarksByHost["com.kdt.LiveContainer3.host3"] == nil)

        CuriumDownloadsFolderManager.clearRecord(defaults: isolatedDefaults)
        #expect(CuriumDownloadsFolderManager.loadRecord(defaults: isolatedDefaults) == nil)

        // 6. Legacy pre-Wave-2 guest Downloads adoption (symlink-safe, moves regular files into host Documents/Curium/Downloads).
        let hostRoot = sandbox.appending(path: "LCHost", directoryHint: .isDirectory)
        let guestHome = hostRoot.appending(path: "Documents/Data/Application/GUEST-UUID", directoryHint: .isDirectory)
        let legacyGuestDownloads = guestHome.appending(path: "Documents/Curium/Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyGuestDownloads, withIntermediateDirectories: true)
        let oldDownload = legacyGuestDownloads.appending(path: "legacy-paper.pdf", directoryHint: .notDirectory)
        try Data("legacy-pdf-bytes".utf8).write(to: oldDownload)
        let outsideFile = sandbox.appending(path: "outside.txt", directoryHint: .notDirectory)
        try Data("do-not-move".utf8).write(to: outsideFile)
        let symlinkEntry = legacyGuestDownloads.appending(path: "escape-link.txt", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: symlinkEntry, withDestinationURL: outsideFile)

        let adopted = CuriumDownloadStorage.adoptLegacyGuestDownloadsIfNeeded(
            environment: ["LC_HOME_PATH": guestHome.path],
            homeDirectory: guestHome.path,
            sharedAppGroupURL: nil
        )
        #expect(adopted == 1)
        let promotedFile = hostRoot.appending(path: "Documents/Curium/Downloads/legacy-paper.pdf", directoryHint: .notDirectory)
        #expect(try Data(contentsOf: promotedFile) == Data("legacy-pdf-bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: oldDownload.path))
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
        #expect(!FileManager.default.fileExists(atPath: hostRoot.appending(path: "Documents/Curium/Downloads/escape-link.txt").path))
    }
}
