import CuriumEngineContract
import Darwin
import Foundation
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

    func goBack() {}
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

// MARK: - Suites

@Suite("Chrome & PiP State")
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

    @Test("PiP state transitions through available, starting, refused, active, and unsupported")
    func pipStateTransitions() {
        var unsupported = CuriumPictureInPictureState(systemSupported: false)
        unsupported.engineReported(hasVideo: true, active: false)
        #expect(unsupported.phase == .unavailable)
        #expect(unsupported.requested() == nil)

        var pip = CuriumPictureInPictureState(systemSupported: true)
        pip.engineReported(hasVideo: true, active: false)
        #expect(pip.phase == .available)
        #expect(pip.requested() == .enter)
        #expect(pip.phase == .starting)

        pip.confirmationTimedOut()
        #expect(pip.phase == .refused)

        pip.hintExpired()
        #expect(pip.phase == .available)

        _ = pip.requested()
        pip.engineReported(hasVideo: true, active: true)
        #expect(pip.phase == .active)
        #expect(pip.requested() == .exit)
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
            #expect((obj["schemaVersion"] as? Int) == 1)
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
        #expect(!store.deleteProfile(id: "default"))

        let custom = try #require(store.duplicateProfile(from: "win11-workstation", newID: "office-win", displayName: "Office Win"))
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

        // Built-ins stay protected against direct overwrite and deletion (including case variants on APFS),
        // and always sort before custom profiles.
        var builtInAttempt = CuriumFingerprintPresets.linuxDesktop
        builtInAttempt.displayName = "Tampered Linux"
        #expect(!reloaded.upsert(builtInAttempt).isValid)
        var builtInCaseAttempt = CuriumFingerprintPresets.iosBlinkAuthentic
        builtInCaseAttempt.id = "IOS-Blink"
        #expect(!reloaded.upsert(builtInCaseAttempt).isValid)
        #expect(!reloaded.deleteProfile(id: "linux-desktop"))
        #expect(reloaded.builtInProfiles.map(\.id) == CuriumFingerprintPresets.allBuiltIns.map(\.id))

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
    func bootstrapFailsClosedWithoutEngineSupport() {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-fp-boot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)

        let store = CuriumFingerprintStore(fileURL: fileURL)
        #expect(CuriumFingerprintBootstrap.prepareEngineLaunch(store: store) == .defaultBuild39)

        #expect(store.selectProfile(id: "macos-desktop"))
        let outcome = CuriumFingerprintBootstrap.prepareEngineLaunch(store: store)
        if case .rejected(let profileID, _) = outcome {
            #expect(profileID == "macos-desktop")
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
