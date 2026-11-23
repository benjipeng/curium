import AVFAudio
import AVFoundation
import CommonCrypto
import CoreMedia
import CuriumEngineContract
import Darwin
import Foundation
import JavaScriptCore
import PDFKit
import Testing
import UIKit
import os

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
    @Test("All built-in presets pass zero-warning validation, mask non-Apple hardware, and preserve native Apple on Apple platforms")
    func builtInPresetsValidate() throws {
        for preset in CuriumFingerprintPresets.allBuiltIns {
            let report = CuriumFingerprintValidator.validate(preset)
            #expect(report.isValid, "Preset \(preset.id) errors: \(report.errors)")
            #expect(report.warnings.isEmpty, "Preset \(preset.id) warnings: \(report.warnings)")
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
        #expect(CuriumFingerprintPresets.allBuiltIns.count == 2)
        #expect(CuriumProfileTemplate.allTemplates.map(\.id) == ["macos-desktop", "privacy-hardened"])
        // All verified built-in presets anchor on Apple Silicon macOS Chrome 158 Stable.
        for preset in CuriumFingerprintPresets.allBuiltIns {
            #expect(preset.defaultSlot == .desktop)
            #expect(preset.mobile == CuriumFingerprintPresets.stableMacOSDesktopSlot)
            #expect(preset.desktop == CuriumFingerprintPresets.stableMacOSDesktopSlot)
            #expect(preset.desktop.majorVersion == CuriumChromeStableBaseline.majorVersion)
            #expect(preset.desktop.fullVersion == CuriumChromeStableBaseline.fullVersion)
            #expect(preset.desktop.productVersion == CuriumChromeStableBaseline.productVersion)
            #expect(preset.desktop.webglProfile == .native)
            #expect(preset.fontProfile == .apple)
            #expect(preset.hideSpeechVoices == false)
        }
        // Apple-platform presets anchor on a coherent Apple M3 14" (8c / 16 GB / 1512×982 30-bit) baseline by default.
        for preset in [CuriumFingerprintPresets.macosDesktopFirst, CuriumFingerprintPresets.privacyHardened] {
            #expect(!preset.usesNativeHardwareAndGPU)
            #expect(preset.desktop.webglVendor == "Google Inc. (Apple)")
            #expect(preset.desktop.webglRenderer == "ANGLE (Apple, ANGLE Metal Renderer: Apple M3, Unspecified Version)")
            #expect(
                preset.desktop.screen
                    == CuriumScreenOverride(width: 1512, height: 982, availWidth: 1512, availHeight: 944, colorDepth: 30)
            )
            #expect(preset.hardware.hardwareConcurrency == 8)
            #expect(preset.hardware.deviceMemoryGB == 16)
            #expect(preset.shortArchetypeSummary.contains("Apple M3"))
        }
        #expect(CuriumFingerprintPresets.macosDesktopFirst.desktop.platformVersion == CuriumChromeStableBaseline.macOSPlatformVersion)
        #expect(CuriumFingerprintPresets.privacyHardened.webrtcIpHandlingPolicy == .disableNonProxiedUdp)
        #expect(CuriumFingerprintPresets.privacyHardened.enableGlobalPrivacyControl == true)
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
        var winNativeGPU = CuriumFingerprintPresets.macosDesktopFirst
        winNativeGPU.id = "custom-win"
        winNativeGPU.desktop.platform = "Windows"
        winNativeGPU.desktop.navigatorPlatform = "Win32"
        winNativeGPU.desktop.webglVendor = nil
        winNativeGPU.desktop.webglRenderer = nil
        winNativeGPU.mobile.platform = "Windows"
        winNativeGPU.mobile.navigatorPlatform = "Win32"
        winNativeGPU.mobile.webglVendor = nil
        winNativeGPU.mobile.webglRenderer = nil
        let winReport = CuriumFingerprintValidator.validate(winNativeGPU)
        #expect(winReport.isValid)
        #expect(winReport.warnings.contains { $0.contains("Windows identity with native Apple Metal GPU") })

        var android16 = CuriumFingerprintPresets.defaultAuthenticChrome
        android16.hardware.deviceMemoryGB = 16
        android16.mobile.webglVendor = nil
        android16.mobile.webglRenderer = nil
        let androidReport = CuriumFingerprintValidator.validate(android16)
        #expect(androidReport.isValid)
        #expect(androidReport.warnings.contains { $0.contains("caps navigator.deviceMemory at 8 GB") })
        #expect(androidReport.warnings.contains { $0.contains("Android identity with native Apple Metal GPU") })

        var linuxNativeGPU = CuriumFingerprintPresets.macosDesktopFirst
        linuxNativeGPU.id = "custom-linux"
        linuxNativeGPU.desktop.platform = "Linux"
        linuxNativeGPU.desktop.navigatorPlatform = "Linux x86_64"
        linuxNativeGPU.desktop.webglVendor = nil
        linuxNativeGPU.desktop.webglRenderer = nil
        linuxNativeGPU.mobile.platform = "Linux"
        linuxNativeGPU.mobile.navigatorPlatform = "Linux x86_64"
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
    @MainActor
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
            store.createProfile(fromTemplate: "macos-desktop", displayName: "Mac Base")
        )
        #expect(templateInstance.isFarblingActive)
        #expect(!templateInstance.usesNativeHardwareAndGPU)
        let custom = try #require(
            store.duplicateProfile(from: templateInstance.id, newID: "office-mac", displayName: "Office Mac")
        )
        #expect(custom.id == "office-mac")
        #expect(custom.isFarblingActive)
        #expect(custom.fingerprintSeed != templateInstance.fingerprintSeed)
        #expect(store.selectProfile(id: "office-mac"))

        var edited = custom
        edited.hardware.timezone = "America/New_York"
        let upsertReport = store.upsert(edited)
        #expect(upsertReport.isValid)

        let reloaded = CuriumFingerprintStore(fileURL: fileURL)
        #expect(reloaded.selectedProfileID == "office-mac")
        let loadedCustom = try #require(reloaded.profiles.first { $0.id == "office-mac" })
        #expect(loadedCustom.revision == 2)
        #expect(loadedCustom.hardware.timezone == "America/New_York")

        let exported = try reloaded.exportProfileJSON(id: "office-mac")
        #expect(try reloaded.importProfileJSON(exported).isValid)

        #expect(reloaded.deleteProfile(id: "office-mac"))
        #expect(reloaded.selectedProfileID == nil)
        #expect(reloaded.retiredProfileIDs.contains("office-mac"))

        // Reserved built-in & retired legacy template IDs stay protected against direct upsert as new profiles
        // (including case variants on APFS); v2 exposes the 3 verified archetypes via `templates`.
        var builtInAttempt = CuriumFingerprintPresets.macosDesktopFirst
        builtInAttempt.id = "linux-desktop"
        builtInAttempt.displayName = "Tampered Linux"
        #expect(!reloaded.upsert(builtInAttempt).isValid)
        var builtInCaseAttempt = CuriumFingerprintPresets.macosDesktopFirst
        builtInCaseAttempt.id = "IOS-Blink"
        #expect(!reloaded.upsert(builtInCaseAttempt).isValid)
        #expect(!reloaded.deleteProfile(id: "linux-desktop"))
        #expect(reloaded.builtInProfiles.isEmpty)
        #expect(reloaded.profiles.first?.id == "default")
        #expect(reloaded.templates.count == CuriumFingerprintPresets.allBuiltIns.count)
        #expect(Set(reloaded.templates.map(\.id)) == Set(CuriumFingerprintPresets.allBuiltIns.map(\.id)))

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
        defer { CuriumFingerprintBootstrap.resetStateForTesting() }
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

    @Test("Validator enforces HTTPS fixed-proxy coverage, WebRTC STUN coherence warning, and C++ bounds/charset parity")
    func validatorFixedProxyHTTPSWebRTCAndCppParity() throws {
        // P0-1: Scheme-less rules cover all schemes; per-scheme rules must cover HTTP+HTTPS or socks=.
        #expect(CuriumFingerprintValidator.isValidFixedProxyRules("socks5://127.0.0.1:1080"))
        #expect(CuriumFingerprintValidator.isValidFixedProxyRules("http://127.0.0.1:8080"))
        #expect(CuriumFingerprintValidator.isValidFixedProxyRules("127.0.0.1:8080"))
        #expect(CuriumFingerprintValidator.isValidFixedProxyRules("socks=127.0.0.1:1080"))
        #expect(CuriumFingerprintValidator.isValidFixedProxyRules("http=127.0.0.1:8080;https=127.0.0.1:8080"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("http=127.0.0.1:8080"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("https=127.0.0.1:8080"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("ftp=127.0.0.1:2121"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("http=127.0.0.1:8080;ftp=127.0.0.1:2121"))
        #expect(!CuriumFingerprintValidator.isValidFixedProxyRules("http=127.0.0.1:8080;socks5://127.0.0.1:1080"))

        // P1-3: Instantiating with a fixed proxy defaults WebRTC to `.disableNonProxiedUdp` (zero warnings),
        // and pairing `.fixed` with any weaker policy emits a STUN/UDP coherence warning.
        for templateID in ["macos-desktop", "privacy-hardened"] {
            let template = try #require(CuriumProfileTemplate.template(for: templateID))
            let instantiated = template.instantiate(
                id: "p-a1b2c3d4",
                displayName: "Proxy \(templateID)",
                proxy: .fixed(rules: "http=127.0.0.1:8080;https=127.0.0.1:8080", bypassRules: nil)
            )
            #expect(instantiated.webrtcIpHandlingPolicy == .disableNonProxiedUdp)
            let cleanReport = CuriumFingerprintValidator.validate(instantiated)
            #expect(cleanReport.errors.isEmpty)
            #expect(cleanReport.warnings.isEmpty)

            var leaky = instantiated
            leaky.webrtcIpHandlingPolicy = .default
            let warnReport = CuriumFingerprintValidator.validate(leaky)
            #expect(warnReport.isValid)
            #expect(warnReport.warnings.contains { $0.contains("STUN/UDP") || $0.contains("Disable Non-Proxied UDP") })
        }

        // P1-4: Exact C++ `patches/0106` bounds and charsets.
        #expect(CuriumFingerprintValidator.isValidClientHintToken("macOS"))
        #expect(!CuriumFingerprintValidator.isValidClientHintToken(" macOS"))
        #expect(!CuriumFingerprintValidator.isValidClientHintToken("macOS "))

        var maxOk = CuriumFingerprintPresets.macosDesktopFirst
        maxOk.id = "p-11223344"
        maxOk.revision = CuriumFingerprintValidator.maxSafeJSONRevision
        maxOk.desktop.platform = String(repeating: "A", count: 64)
        maxOk.desktop.platformVersion = String(repeating: "1", count: 64)
        maxOk.desktop.architecture = String(repeating: "x", count: 32)
        maxOk.desktop.fullVersion = String(repeating: "9", count: 32)
        maxOk.desktop.uaString = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        maxOk.hardware.timezone = "Etc/GMT+8"
        #expect(CuriumFingerprintValidator.validate(maxOk).isValid)

        var badBounds = maxOk
        badBounds.revision = CuriumFingerprintValidator.maxSafeJSONRevision + 1
        badBounds.desktop.platform = String(repeating: "A", count: 65)
        badBounds.desktop.platformVersion = String(repeating: "1", count: 65)
        badBounds.desktop.architecture = String(repeating: "x", count: 33)
        badBounds.desktop.uaString = "Mozilla/5.0 Café"
        badBounds.hardware.timezone = "GMT+08:00"
        let badReport = CuriumFingerprintValidator.validate(badBounds)
        #expect(!badReport.isValid)
        #expect(badReport.errors.contains { $0.contains("revision") })
        #expect(badReport.errors.contains { $0.contains("desktop.platform ") })
        #expect(badReport.errors.contains { $0.contains("desktop.platformVersion") })
        #expect(badReport.errors.contains { $0.contains("desktop.architecture") })
        #expect(badReport.errors.contains { $0.contains("desktop.uaString") })
        #expect(badReport.errors.contains { $0.contains("Invalid IANA timezone") })

        var untrimmedUA = maxOk
        untrimmedUA.desktop.uaString = " Mozilla/5.0"
        #expect(!CuriumFingerprintValidator.validate(untrimmedUA).isValid)
    }

    @Test("Bootstrap freezes launch proxy/engine snapshot, detects active-profile engine edits, holds companion lock, and fails closed on seed persist failure")
    @MainActor
    func bootstrapFrozenSnapshotCompanionLockAndSeedPersistFailClosed() throws {
        defer { CuriumFingerprintBootstrap.resetStateForTesting() }

        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-fp-freeze-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let supportRoot = dir.appending(path: "Application Support", directoryHint: .isDirectory)
        let cachesRoot = dir.appending(path: "Caches", directoryHint: .isDirectory)
        let curiumRoot = dir.appending(path: "SharedCurium", directoryHint: .isDirectory)
        let fileURL = curiumRoot.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)

        let store = CuriumFingerprintStore(
            fileURL: fileURL,
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot,
            curiumSupportRoot: curiumRoot
        )
        let fixedProxy = CuriumProxyConfig.fixed(rules: "socks5://127.0.0.1:1080", bypassRules: "localhost")
        let work = try #require(
            store.createProfile(
                fromTemplate: "macos-desktop",
                displayName: "Work Proxy",
                proxy: fixedProxy
            )
        )
        #expect(store.selectProfile(id: work.id))

        let v2Caps = CuriumEngineFingerprintCapabilities(dictionary: [
            "contractVersion": 2,
            "supportedSchemaVersions": [1, 2],
            "maxConfigBytes": 65_536,
        ])
        let outcome = CuriumFingerprintBootstrap.prepareEngineLaunch(
            store: store,
            capabilitiesProvider: { v2Caps },
            configureEngine: { data, _ in data != nil }
        )
        guard case .configured(let launchedID, _, _) = outcome else {
            Issue.record("Expected .configured outcome, got \(outcome)")
            return
        }
        #expect(launchedID == work.id)
        #expect(CuriumFingerprintBootstrap.activeLaunchProxy == fixedProxy)
        #expect(CuriumFingerprintBootstrap.frozenLaunchProxy == fixedProxy)
        #expect(CuriumFingerprintBootstrap.frozenLaunchProfile?.id == work.id)
        #expect(!store.hasPendingProfileSwitch)
        #expect(!store.hasPendingActiveProfileEngineChanges)

        // Companion shared support lock must be held with `can-suspend-locked` xattr and block wipes.
        let sharedLockURL = try #require(
            CuriumFingerprintProfileStorage.sharedLockFileURL(for: work.id, curiumSupportRoot: curiumRoot)
        )
        #expect(FileManager.default.fileExists(atPath: sharedLockURL.path))
        var suspendXattr: UInt8 = 0
        let xattrSize = getxattr(
            sharedLockURL.path,
            "com.apple.runningboard.can-suspend-locked",
            &suspendXattr,
            1,
            0,
            0
        )
        #expect(xattrSize == 1)
        #expect(suspendXattr == 1)
        #expect(throws: CuriumFingerprintProfileStorage.WipeError.profileLockedByAnotherInstance) {
            try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                work.id,
                isActiveInCurrentProcess: false,
                applicationSupportRoot: supportRoot,
                cachesRoot: cachesRoot,
                curiumSupportRoot: curiumRoot
            )
        }

        // P0-2 + P2-1: Mid-session proxy edit keeps `activeLaunchProxy` frozen and lights up `hasPendingProfileSwitch`.
        var editedProxy = try #require(store.profile(id: work.id))
        editedProxy.proxy = .direct
        #expect(store.upsert(editedProxy).isValid)
        #expect(CuriumFingerprintBootstrap.activeLaunchProxy == fixedProxy)
        #expect(!store.hasPendingProfileIDChange)
        #expect(store.hasPendingActiveProfileEngineChanges)
        #expect(store.hasPendingProfileSwitch)

        // Reverting engine fields and changing only persona metadata clears `hasPendingProfileSwitch`.
        var personaOnly = try #require(store.profile(id: work.id))
        personaOnly.proxy = fixedProxy
        personaOnly.displayName = "Work Proxy Renamed"
        personaOnly.palette = .californium
        #expect(store.upsert(personaOnly).isValid)
        #expect(!store.hasPendingActiveProfileEngineChanges)
        #expect(!store.hasPendingProfileSwitch)

        // P0-3: External process holding the shared support lock rejects launch before configuring Blink.
        let other = try #require(store.createProfile(fromTemplate: "privacy-hardened", displayName: "Contended"))
        let externalFD = try CuriumFingerprintProfileStorage.acquireSharedProfileLock(
            for: other.id,
            curiumSupportRoot: curiumRoot
        )
        defer { close(externalFD) }
        #expect(store.selectProfile(id: other.id))
        var engineCalledWhenLocked = false
        let lockedOutcome = CuriumFingerprintBootstrap.prepareEngineLaunch(
            store: store,
            capabilitiesProvider: { v2Caps },
            configureEngine: { _, _ in
                engineCalledWhenLocked = true
                return true
            }
        )
        if case .rejected(let rejectedID, _) = lockedOutcome {
            #expect(rejectedID == other.id)
        } else {
            Issue.record("Expected .rejected when companion lock is held by another session, got \(lockedOutcome)")
        }
        #expect(!engineCalledWhenLocked)

        // P2-3: Failing to persist a newly materialized farbling seed fails closed before engine launch.
        let unseededDir = dir.appending(path: "unseeded", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unseededDir, withIntermediateDirectories: true)
        let unseededURL = unseededDir.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)
        var unseededProfile = CuriumFingerprintPresets.privacyHardened
        unseededProfile.id = "p-feedface"
        unseededProfile.isBuiltIn = false
        unseededProfile.fingerprintSeed = nil
        unseededProfile.farbling = .allEnabled
        let rawState = CuriumFingerprintStore.PersistedState(
            version: 2,
            selectedProfileID: "p-feedface",
            profiles: [CuriumFingerprintStore.makeDefaultPersonalProfile(), unseededProfile]
        )
        try JSONEncoder().encode(rawState).write(to: unseededURL, options: .atomic)
        // Lock `unseededDir` read-only BEFORE opening the store so `init()` can read the
        // unseeded file, materializes a seed in memory, fails `persist()`, and leaves the
        // profile in `migratedSeedIDs`; `prepareEngineLaunch` must then fail closed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unseededDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unseededDir.path) }
        let unseededStore = CuriumFingerprintStore(fileURL: unseededURL)
        var engineCalledOnSeedFailure = false
        let seedFailOutcome = CuriumFingerprintBootstrap.prepareEngineLaunch(
            store: unseededStore,
            capabilitiesProvider: { v2Caps },
            configureEngine: { _, _ in
                engineCalledOnSeedFailure = true
                return true
            }
        )
        if case .rejected(let rejectedID, _) = seedFailOutcome {
            #expect(rejectedID == "p-feedface")
        } else {
            Issue.record("Expected .rejected when seed persistence fails, got \(seedFailOutcome)")
        }
        #expect(!engineCalledOnSeedFailure)
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
    @MainActor
    func schemaV2WireAndV1Downgrade() throws {
        var macSample = CuriumFingerprintPresets.macosDesktopFirst
        macSample.desktop.screen = CuriumScreenOverride(width: 2560, height: 1440, availWidth: 2560, availHeight: 1409, colorDepth: 24)
        macSample.fontProfile = .apple
        macSample.hideSpeechVoices = false
        let v2Data = try macSample.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US"], schemaVersion: 2)
        let v2Obj = try #require(JSONSerialization.jsonObject(with: v2Data) as? [String: Any])
        #expect((v2Obj["schemaVersion"] as? Int) == 2)
        #expect((v2Obj["fontProfile"] as? String) == "apple")
        #expect((v2Obj["hideSpeechVoices"] as? Bool) == false)
        let desktopV2 = try #require(v2Obj["desktop"] as? [String: Any])
        #expect((desktopV2["webglProfile"] as? String) == "native")
        #expect((desktopV2["pdfViewerEnabled"] as? Bool) == true)
        #expect((desktopV2["majorVersion"] as? String) == CuriumChromeStableBaseline.majorVersion)
        #expect((desktopV2["fullVersion"] as? String) == CuriumChromeStableBaseline.fullVersion)
        let screenV2 = try #require(desktopV2["screen"] as? [String: Any])
        #expect((screenV2["width"] as? Int) == 2560)
        #expect((screenV2["availHeight"] as? Int) == 1409)

        let v1Data = try macSample.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US"], schemaVersion: 1)
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
    @MainActor
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
        defer { CuriumFingerprintBootstrap.resetStateForTesting() }
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

    @Test("Persist maintains verified .bak shadow copy, auto-recovers corrupt primary, and preserves tombstones and legacy defaults on reset")
    func shadowBackupRecoveryAndTombstonePreservation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-w1-bak-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let storeURL = dir.appending(path: CuriumFingerprintStore.fileName)
        let shadowURL = CuriumFingerprintStore.lastKnownGoodBackupURL(for: storeURL)
        let store = CuriumFingerprintStore(fileURL: storeURL)
        let retiredTarget = try #require(store.createProfile(fromTemplate: "macos-desktop", displayName: "Retire Me"))
        let survivor = try #require(store.createProfile(fromTemplate: "privacy-hardened", displayName: "Survivor"))
        #expect(store.deleteProfile(id: retiredTarget.id))
        #expect(FileManager.default.fileExists(atPath: shadowURL.path))

        // Corrupt primary while valid shadow `.bak` exists -> auto-recovers cleanly and preserves tombstones.
        try Data("{ truncated primary".utf8).write(to: storeURL)
        let recovered = CuriumFingerprintStore(fileURL: storeURL)
        #expect(recovered.loadError == nil)
        #expect(recovered.recoveredFromBackup)
        #expect(recovered.profile(id: survivor.id)?.displayName == "Survivor")
        #expect(recovered.retiredProfileIDs.contains(retiredTarget.id.lowercased()))
        let healedState = try JSONDecoder().decode(
            CuriumFingerprintStore.PersistedState.self,
            from: try Data(contentsOf: storeURL)
        )
        #expect(healedState.profiles.contains { $0.id == survivor.id })

        // Unrecoverable corruption (no valid `.bak`): reset preserves extracted tombstones + legacy defaults.
        try? FileManager.default.removeItem(at: shadowURL)
        let brokenSchemaJSON = Data("""
        {
          "version": 2,
          "retiredProfileIDs": ["p-deadbeef", "p-cafebabe"],
          "profiles": [{ "id": "corrupt-entry-missing-fields" }]
        }
        """.utf8)
        try brokenSchemaJSON.write(to: storeURL)

        let failedStore = CuriumFingerprintStore(fileURL: storeURL)
        #expect(failedStore.loadError != nil)
        #expect(failedStore.retiredProfileIDs.contains("p-deadbeef"))
        #expect(failedStore.retiredProfileIDs.contains("p-cafebabe"))

        let suiteName = "curium.reset.legacy.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(CuriumPalette.americium.rawValue, forKey: "curium.palette")
        suite.set(CuriumSiteMode.desktop.rawValue, forKey: "curium.siteMode")
        suite.set(CuriumSearchEngine.brave.rawValue, forKey: "curium.searchEngine")
        suite.set("chromium", forKey: "curium.uaBrand")
        suite.set("ios", forKey: "curium.mobileUA")

        #expect(failedStore.backupCorruptStoreAndReset(preserveLegacyDefaults: true, defaults: suite))
        #expect(failedStore.loadError == nil)
        #expect(failedStore.retiredProfileIDs.contains("p-deadbeef"))
        #expect(failedStore.retiredProfileIDs.contains("p-cafebabe"))

        var retiredReuse = CuriumFingerprintPresets.macosDesktopFirst
        retiredReuse.id = "p-deadbeef"
        #expect(!failedStore.upsert(retiredReuse).isValid)

        let personal = try #require(failedStore.profile(id: "default"))
        #expect(personal.defaultSlot == .desktop)
        #expect(personal.mobile == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(personal.desktop == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(personal.palette == .americium)
        #expect(personal.siteMode == .desktop)
        #expect(personal.searchEngine == .brave)
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
    @MainActor
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
        for retiredID in CuriumFingerprintPresets.retiredLegacyBuiltInIDs.sorted() {
            var retiredEntry = CuriumFingerprintPresets.macosDesktopFirst
            retiredEntry.id = retiredID
            retiredEntry.displayName = "Legacy \(retiredID)"
            retiredEntry.isBuiltIn = true
            v1Profiles.append(retiredEntry)
        }
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
        #expect(defaultProfile.templateID == "macos-desktop")
        #expect(defaultProfile.defaultSlot == .desktop)
        #expect(defaultProfile.mobile == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(defaultProfile.desktop == CuriumFingerprintPresets.stableMacOSDesktopSlot)
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
    @MainActor
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
        #expect(store.templates.count == 2)

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

    @Test("CuriumLibraryLocation walks 3 parents above LC_HOME_PATH and shared companion lock blocks cross-instance wipes")
    func liveContainerHostFallbackAndSharedLockWipeProtection() throws {
        let privateGuest = "/var/mobile/Containers/Data/Application/HOST-UUID-1/Documents/Data/Application/GUEST-UUID-1"
        let privateRoot = try CuriumLibraryLocation.supportRootDirectory(
            environment: ["LC_HOME_PATH": privateGuest],
            sharedAppGroupURL: nil
        )
        #expect(privateRoot.path == "/var/mobile/Containers/Data/Application/HOST-UUID-1/Library/Application Support/Curium")

        let privateRes = try CuriumLibraryLocation.resolve(
            profileID: "default",
            environment: ["LC_HOME_PATH": privateGuest],
            sharedAppGroupURL: nil
        )
        #expect(privateRes.database.path == "/var/mobile/Containers/Data/Application/HOST-UUID-1/Library/Application Support/Curium/curium.sqlite")
        #expect(privateRes.legacy.contains { $0.path == "\(privateGuest)/Library/Application Support/Curium/curium.sqlite" })

        let sharedGuest = "/var/mobile/Containers/Shared/AppGroup/GROUP-UUID-2/LiveContainer/Data/Application/GUEST-UUID-2"
        let sharedFallbackRoot = try CuriumLibraryLocation.supportRootDirectory(
            environment: ["LC_HOME_PATH": sharedGuest],
            sharedAppGroupURL: nil
        )
        #expect(sharedFallbackRoot.path == "/var/mobile/Containers/Shared/AppGroup/GROUP-UUID-2/Library/Application Support/Curium")

        let appGroupURL = URL(fileURLWithPath: "/var/mobile/Containers/Shared/AppGroup/REAL-GROUP", isDirectory: true)
        let appGroupRes = try CuriumLibraryLocation.resolve(
            profileID: "default",
            environment: ["LC_HOME_PATH": privateGuest],
            sharedAppGroupURL: appGroupURL
        )
        #expect(appGroupRes.database.path == "/var/mobile/Containers/Shared/AppGroup/REAL-GROUP/Library/Application Support/Curium/curium.sqlite")
        #expect(appGroupRes.legacy.contains { $0.path == "/var/mobile/Containers/Data/Application/HOST-UUID-1/Library/Application Support/Curium/curium.sqlite" })
        #expect(appGroupRes.legacy.contains { $0.path == "\(privateGuest)/Library/Application Support/Curium/curium.sqlite" })

        // Cross-instance LiveContainer wipe protection: even when ChromiumProfiles/<slug> has NO lock file,
        // holding the shared support lock in <CuriumSupportRoot>/Profiles/<slug>/.curium_profile.lock
        // blocks wiping ALL directories.
        let root = try makeTempDir("curium-w2-shared-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let appSupport = root.appending(path: "HostB-AppSupport", directoryHint: .isDirectory)
        let caches = root.appending(path: "HostB-Caches", directoryHint: .isDirectory)
        let sharedCurium = root.appending(path: "SharedAppGroup-Curium", directoryHint: .isDirectory)

        let loc = try #require(
            CuriumFingerprintProfileStorage.locations(
                for: "p-1234abcd",
                applicationSupportRoot: appSupport,
                cachesRoot: caches,
                curiumSupportRoot: sharedCurium
            )
        )
        try FileManager.default.createDirectory(at: loc.supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loc.cacheDirectory, withIntermediateDirectories: true)
        try Data("cookies".utf8).write(to: loc.supportDirectory.appending(path: "Cookies"))

        let sharedFD = try CuriumFingerprintProfileStorage.acquireSharedProfileLock(
            for: "p-1234abcd",
            curiumSupportRoot: sharedCurium
        )
        #expect(throws: CuriumFingerprintProfileStorage.WipeError.profileLockedByAnotherInstance) {
            try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                "p-1234abcd",
                isActiveInCurrentProcess: false,
                applicationSupportRoot: appSupport,
                cachesRoot: caches,
                curiumSupportRoot: sharedCurium
            )
        }
        #expect(FileManager.default.fileExists(atPath: loc.supportDirectory.path))
        #expect(FileManager.default.fileExists(atPath: try #require(loc.curiumProfileDirectory).path))

        close(sharedFD)
        try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
            "p-1234abcd",
            isActiveInCurrentProcess: false,
            applicationSupportRoot: appSupport,
            cachesRoot: caches,
            curiumSupportRoot: sharedCurium
        )
        #expect(!FileManager.default.fileExists(atPath: loc.supportDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: loc.cacheDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(loc.curiumProfileDirectory).path))
    }

    @Test("Legacy Build 39 Android/iOS Personal profiles auto-upgrade to Apple Silicon macOS while preserving user preferences")
    @MainActor
    func legacyIdentityDefaultsSyncWithPersonal() throws {
        let suiteName = "curium.legacy.sync.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        suite.set("chromium", forKey: "curium.uaBrand")
        suite.set("ios", forKey: "curium.mobileUA")
        suite.set(CuriumPalette.americium.rawValue, forKey: "curium.palette")
        suite.set(CuriumSiteMode.desktop.rawValue, forKey: "curium.siteMode")
        suite.set(CuriumSearchEngine.brave.rawValue, forKey: "curium.searchEngine")

        // Fresh default Personal ignores deprecated Android/iOS/Chromium UA keys and uses pure macOS Chrome 158,
        // while preserving palette, layout, and search engine preferences.
        let freshPersonal = CuriumFingerprintStore.makeDefaultPersonalProfile(
            preserveLegacyDefaults: true,
            defaults: suite
        )
        #expect(freshPersonal.defaultSlot == .desktop)
        #expect(freshPersonal.mobile == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(freshPersonal.desktop == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(freshPersonal.fontProfile == .apple)
        #expect(freshPersonal.hideSpeechVoices == false)
        #expect(freshPersonal.palette == .americium)
        #expect(freshPersonal.siteMode == .desktop)
        #expect(freshPersonal.searchEngine == .brave)

        // Existing v2 store on disk carrying an untouched Build 39 Android 15 Personal profile
        // automatically upgrades its identity slots and hardware to coherent M3 macOS while keeping proxy/timezone/palette/notes.
        let root = try makeTempDir("curium-w2-legacy-upgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: CuriumFingerprintStore.fileName)
        var legacyAndroid = CuriumFingerprintPresets.build39NativeBaseline
        legacyAndroid.displayName = "Personal"
        legacyAndroid.isBuiltIn = false
        legacyAndroid.palette = .thorium
        legacyAndroid.siteMode = .adaptive
        legacyAndroid.searchEngine = .duckDuckGo
        legacyAndroid.hardware.timezone = "Europe/London"
        legacyAndroid.proxy = .fixed(rules: "socks5://127.0.0.1:1080", bypassRules: nil)
        legacyAndroid.notes = "Keep my note"
        let persisted = CuriumFingerprintStore.PersistedState(
            version: 2,
            selectedProfileID: nil,
            profiles: [legacyAndroid],
            retiredProfileIDs: []
        )
        try JSONEncoder().encode(persisted).write(to: fileURL)

        let upgradedStore = CuriumFingerprintStore(fileURL: fileURL)
        let upgraded = try #require(upgradedStore.profile(id: "default"))
        #expect(upgraded.defaultSlot == .desktop)
        #expect(upgraded.mobile == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(upgraded.desktop == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(upgraded.hardware.hardwareConcurrency == 8)
        #expect(upgraded.hardware.deviceMemoryGB == 16)
        #expect(upgraded.hardware.timezone == "Europe/London")
        #expect(upgraded.fontProfile == .apple)
        #expect(upgraded.hideSpeechVoices == false)
        #expect(upgraded.palette == .thorium)
        #expect(upgraded.searchEngine == .duckDuckGo)
        #expect(upgraded.proxy == .fixed(rules: "socks5://127.0.0.1:1080", bypassRules: nil))
        #expect(upgraded.notes == "Keep my note")

        // Untouched earlier pure-macOS Personal profile (`screen == nil`, `webglRenderer == nil`, native hardware)
        // auto-upgrades in place to coherent M3 1512×982 30-bit / 8c / 16 GB while preserving timezone/proxy/notes.
        let unrolledMacFileURL = root.appending(path: "unrolled-mac-\(CuriumFingerprintStore.fileName)")
        var unrolledMacSlot = CuriumFingerprintPresets.stableMacOSDesktopSlot
        unrolledMacSlot.webglVendor = nil
        unrolledMacSlot.webglRenderer = nil
        unrolledMacSlot.screen = nil
        var unrolledMacDefault = CuriumFingerprintStore.makeDefaultPersonalProfile()
        unrolledMacDefault.mobile = unrolledMacSlot
        unrolledMacDefault.desktop = unrolledMacSlot
        unrolledMacDefault.hardware = CuriumHardwareOverrides(
            hardwareConcurrency: nil,
            deviceMemoryGB: nil,
            timezone: "Asia/Tokyo"
        )
        unrolledMacDefault.proxy = .fixed(rules: "socks5://127.0.0.1:1088", bypassRules: "localhost")
        unrolledMacDefault.notes = "Preserve user note"
        unrolledMacDefault.palette = .californium
        let unrolledState = CuriumFingerprintStore.PersistedState(
            version: 2,
            selectedProfileID: nil,
            profiles: [unrolledMacDefault],
            retiredProfileIDs: []
        )
        try JSONEncoder().encode(unrolledState).write(to: unrolledMacFileURL)

        let upgradedMacStore = CuriumFingerprintStore(fileURL: unrolledMacFileURL)
        let upgradedMac = try #require(upgradedMacStore.profile(id: "default"))
        #expect(upgradedMac.desktop == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(upgradedMac.mobile == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(upgradedMac.desktop.screen?.width == 1512)
        #expect(upgradedMac.desktop.screen?.height == 982)
        #expect(upgradedMac.desktop.screen?.availHeight == 944)
        #expect(upgradedMac.desktop.screen?.colorDepth == 30)
        #expect(upgradedMac.hardware.hardwareConcurrency == 8)
        #expect(upgradedMac.hardware.deviceMemoryGB == 16)
        #expect(upgradedMac.hardware.timezone == "Asia/Tokyo")
        #expect(upgradedMac.proxy == .fixed(rules: "socks5://127.0.0.1:1088", bypassRules: "localhost"))
        #expect(upgradedMac.notes == "Preserve user note")
        #expect(upgradedMac.palette == .californium)

        // Reloading confirms the upgraded M3 defaults were persisted and an explicit custom variant on Personal stays untouched.
        let m4ProVariant = try #require(
            CuriumFingerprintDevicePools.variant(
                forTemplateID: "macos-desktop",
                variantID: "macos-desktop-m4pro-14c-32g-1728x1117"
            )
        )
        let explicitPersonal = m4ProVariant.apply(to: upgradedMac)
        #expect(upgradedMacStore.upsert(explicitPersonal).isValid)
        let reloadedCustomStore = CuriumFingerprintStore(fileURL: unrolledMacFileURL)
        let reloadedCustomPersonal = try #require(reloadedCustomStore.profile(id: "default"))
        #expect(reloadedCustomPersonal.desktop.webglRenderer?.contains("Apple M4 Pro") == true)
        #expect(reloadedCustomPersonal.hardware.hardwareConcurrency == 14)
        #expect(reloadedCustomPersonal.hardware.deviceMemoryGB == 32)
        #expect(reloadedCustomPersonal.hardware.timezone == "Asia/Tokyo")
    }

    @Test("Store resolves profile IDs case-insensitively across export, duplicate, delete, and deleteAndWipe")
    @MainActor
    func caseInsensitiveStoreMutations() throws {
        let root = try makeTempDir("curium-w2-case")
        defer { try? FileManager.default.removeItem(at: root) }
        let appSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        let curiumRoot = root.appending(path: "Curium", directoryHint: .isDirectory)
        let store = CuriumFingerprintStore(
            fileURL: curiumRoot.appending(path: CuriumFingerprintStore.fileName),
            applicationSupportRoot: appSupport,
            cachesRoot: caches,
            curiumSupportRoot: curiumRoot
        )

        let created = try #require(store.createProfile(fromTemplate: "macos-desktop", displayName: "Case Test"))
        let upperID = created.id.uppercased()

        let exported = try store.exportProfileJSON(id: upperID)
        #expect(!exported.isEmpty)

        let dup = try #require(store.duplicateProfile(from: upperID, displayName: "Case Copy"))
        #expect(dup.id != created.id)

        let loc = try #require(
            CuriumFingerprintProfileStorage.locations(
                for: created.id,
                applicationSupportRoot: appSupport,
                cachesRoot: caches,
                curiumSupportRoot: curiumRoot
            )
        )
        try FileManager.default.createDirectory(at: loc.supportDirectory, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: loc.supportDirectory.appending(path: "Cookies"))

        let wipedAndDeleted = try store.deleteProfileAndWipeStorage(
            id: upperID,
            isActiveInCurrentProcess: false
        )
        #expect(wipedAndDeleted)
        #expect(!FileManager.default.fileExists(atPath: loc.supportDirectory.path))
        #expect(store.profile(id: created.id) == nil)
        #expect(store.retiredProfileIDs.contains(created.id.lowercased()))

        #expect(store.deleteProfile(id: dup.id.uppercased()))
        #expect(store.profile(id: dup.id) == nil)

        // Unknown slug must return false without wiping an unrelated on-disk directory.
        let orphanDir = appSupport.appending(path: "ChromiumProfiles/orphan-keep", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let missingDeleted = try store.deleteProfileAndWipeStorage(
            id: "orphan-keep",
            isActiveInCurrentProcess: false
        )
        #expect(!missingDeleted)
        #expect(FileManager.default.fileExists(atPath: orphanDir.path))
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

@Suite("Phase A Fingerprint Differentiation & Reliable Switch")
struct CuriumPhaseAFingerprintAndSwitchTests {
    private func makeTempDir(_ prefix: String = "curium-pa") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct HardwareSignature: Hashable {
        let webglVendor: String?
        let webglRenderer: String?
        let width: Int?
        let height: Int?
        let availWidth: Int?
        let availHeight: Int?
        let colorDepth: Int?
        let model: String?
        let platformVersion: String?
        let cores: Int?
        let memoryGB: Double?

        init(profile: CuriumFingerprintProfile) {
            let slot = profile.defaultSlot == .desktop ? profile.desktop : profile.mobile
            self.webglVendor = slot.webglVendor
            self.webglRenderer = slot.webglRenderer
            self.width = slot.screen?.width
            self.height = slot.screen?.height
            self.availWidth = slot.screen?.availWidth
            self.availHeight = slot.screen?.availHeight
            self.colorDepth = slot.screen?.colorDepth
            self.model = slot.model
            self.platformVersion = slot.platformVersion
            self.cores = profile.hardware.hardwareConcurrency
            self.memoryGB = profile.hardware.deviceMemoryGB
        }
    }

    @Test("All hardware variant pools pass zero-error zero-warning validation and emit strict schema v2 wire JSON")
    @MainActor
    func allHardwareVariantPoolsValidateAndSerializeSchemaV2() throws {
        let expectedMultiVariantMinimums: [String: Int] = [
            "macos-desktop": 8,
            "privacy-hardened": 8,
        ]
        #expect(Set(CuriumFingerprintDevicePools.allPools.keys) == Set(expectedMultiVariantMinimums.keys))

        // Retired unverified templates (`ios-blink`, x86_64 Windows/Linux, Android) are no longer offered.
        for retiredID in CuriumFingerprintPresets.retiredLegacyBuiltInIDs.union(["default"]) {
            #expect(CuriumProfileTemplate.template(for: retiredID) == nil)
            #expect(CuriumFingerprintDevicePools.variants(forTemplateID: retiredID).isEmpty)
        }

        // Apple Silicon pool covers M1–M5 Max chips and 8 / 16 / 32 GB RAM tiers with 30-bit wide-gamut P3 displays.
        let macPool = CuriumFingerprintDevicePools.macosDesktop
        #expect(Set(macPool.map(\.deviceMemoryGB)) == Set([8.0, 16.0, 32.0]))
        #expect(macPool.contains { $0.webglRenderer.contains("Apple M5 Max") && $0.hardwareConcurrency == 18 && $0.deviceMemoryGB == 32 })
        #expect(macPool.allSatisfy { $0.webglProfile == .native && $0.screen.colorDepth == 30 })

        // Exact Build 42 C++ schema v2 key allowlists from patches/0106 & patches/0110.
        let allowedTopKeys: Set<String> = [
            "schemaVersion", "revision", "profileId", "defaultSlot", "mobile", "desktop",
            "languages", "proxy", "webrtcIpHandlingPolicy", "enableDoNotTrack",
            "enableGlobalPrivacyControl", "hardware", "fingerprintSeed", "farbling",
            "fontProfile", "hideSpeechVoices",
        ]
        let allowedSlotKeys: Set<String> = [
            "uaString", "osCpu", "productVersion", "appendMobileToken", "primaryBrand",
            "majorVersion", "fullVersion", "brands", "fullVersionBrands", "platform",
            "platformVersion", "architecture", "bitness", "model", "mobile", "wow64",
            "formFactors", "navigatorPlatform", "maxTouchPoints", "pointerType",
            "hoverType", "webglVendor", "webglRenderer", "screen", "webglProfile",
            "webglMaxTextureSize", "webglMaxRenderbufferSize", "webglMaxCubeMapTextureSize",
            "pdfViewerEnabled",
        ]
        let allowedScreenKeys: Set<String> = [
            "width", "height", "availWidth", "availHeight", "colorDepth",
        ]
        let allowedHardwareKeys: Set<String> = [
            "hardwareConcurrency", "deviceMemoryGB", "timezone",
        ]
        let allowedFarblingKeys: Set<String> = [
            "canvas", "audio", "webgl", "textMetrics",
        ]
        let allowedProxyKeys: Set<String> = [
            "mode", "rules", "bypassRules",
        ]

        for (templateID, minCount) in expectedMultiVariantMinimums {
            let template = try #require(CuriumProfileTemplate.template(for: templateID))
            let variants = CuriumFingerprintDevicePools.variants(forTemplateID: templateID)
            #expect(template.hasHardwareVariantPool)
            #expect(template.hardwareVariantCount == variants.count)
            #expect(variants.count >= minCount, "Pool \(templateID) has \(variants.count) < \(minCount)")
            #expect(Set(variants.map(\.id)).count == variants.count)

            let baseInstantiated = template.instantiate(
                id: "p-a1b2c3d4",
                displayName: "Audit \(templateID)",
                enableFarbling: true,
                randomizeHardwareVariant: false
            )

            for variant in variants {
                let candidate = variant.apply(to: baseInstantiated).normalizedForPersistence()
                let report = CuriumFingerprintValidator.validate(candidate)
                #expect(report.errors.isEmpty, "Variant \(variant.id) errors: \(report.errors)")
                #expect(report.warnings.isEmpty, "Variant \(variant.id) warnings: \(report.warnings)")

                let wireData = try candidate.makeEngineLaunchJSON(
                    preferredSystemLanguages: ["en-US"],
                    schemaVersion: 2
                )
                #expect(wireData.count <= CuriumFingerprintSchema.maxPayloadBytes)

                let root = try #require(JSONSerialization.jsonObject(with: wireData) as? [String: Any])
                #expect(Set(root.keys).isSubset(of: allowedTopKeys), "Unknown top keys in \(variant.id): \(root.keys)")
                #expect((root["schemaVersion"] as? Int) == 2)
                #expect((root["profileId"] as? String) == "p-a1b2c3d4")

                for slotKey in ["mobile", "desktop"] {
                    let slotDict = try #require(root[slotKey] as? [String: Any])
                    #expect(
                        Set(slotDict.keys).isSubset(of: allowedSlotKeys),
                        "Unknown \(slotKey) keys in \(variant.id): \(slotDict.keys)"
                    )
                    if let screenDict = slotDict["screen"] as? [String: Any] {
                        #expect(Set(screenDict.keys).isSubset(of: allowedScreenKeys))
                        let w = try #require(screenDict["width"] as? Int)
                        let h = try #require(screenDict["height"] as? Int)
                        let aw = (screenDict["availWidth"] as? Int) ?? w
                        let ah = (screenDict["availHeight"] as? Int) ?? h
                        let depth = (screenDict["colorDepth"] as? Int) ?? 24
                        #expect((240...16384).contains(w))
                        #expect((240...16384).contains(h))
                        #expect((240...w).contains(aw))
                        #expect((240...h).contains(ah))
                        #expect(CuriumFingerprintSchema.validColorDepths.contains(depth))
                    }
                    for glKey in ["webglVendor", "webglRenderer"] {
                        if let glStr = slotDict[glKey] as? String {
                            #expect(!glStr.isEmpty && glStr.utf8.count <= 256)
                            #expect(glStr.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E })
                        }
                    }
                }

                let hwDict = try #require(root["hardware"] as? [String: Any])
                #expect(Set(hwDict.keys).isSubset(of: allowedHardwareKeys))
                if templateID == "default",
                   let mem = (hwDict["deviceMemoryGB"] as? NSNumber)?.doubleValue {
                    #expect(mem <= 8.0)
                }

                let proxyDict = try #require(root["proxy"] as? [String: Any])
                #expect(Set(proxyDict.keys).isSubset(of: allowedProxyKeys))

                let farblingDict = try #require(root["farbling"] as? [String: Any])
                #expect(Set(farblingDict.keys).isSubset(of: allowedFarblingKeys))
            }
        }

        // Default Personal baseline launches as pure Apple Silicon macOS Chrome 158 on Build 40+/42 engines
        // (and falls back gracefully to Build 39 only when engine contractVersion == 0).
        defer { CuriumFingerprintBootstrap.resetStateForTesting() }
        let rootDir = try makeTempDir("curium-pa-default")
        defer { try? FileManager.default.removeItem(at: rootDir) }
        let store = CuriumFingerprintStore(fileURL: rootDir.appending(path: CuriumFingerprintStore.fileName))
        let personal = try #require(store.profile(id: "default"))
        #expect(personal.defaultSlot == .desktop)
        #expect(personal.mobile == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(personal.desktop == CuriumFingerprintPresets.stableMacOSDesktopSlot)
        #expect(personal.fingerprintSeed == nil)
        #expect(!personal.isFarblingActive)
        let v2Caps = CuriumEngineFingerprintCapabilities(dictionary: [
            "contractVersion": 2,
            "supportedSchemaVersions": [1, 2],
            "maxConfigBytes": 65536,
        ])
        var sentPayload: Data?
        let configuredOutcome = CuriumFingerprintBootstrap.prepareEngineLaunch(
            store: store,
            capabilitiesProvider: { v2Caps },
            configureEngine: { data, _ in
                sentPayload = data
                return true
            }
        )
        #expect(configuredOutcome == .configured(profileID: "default", revision: 1, nativeHardware: false))
        let payloadObj = try #require(
            sentPayload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        )
        #expect((payloadObj["defaultSlot"] as? String) == "desktop")
        #expect(((payloadObj["desktop"] as? [String: Any])?["platform"] as? String) == "macOS")
        #expect(((payloadObj["mobile"] as? [String: Any])?["platform"] as? String) == "macOS")
    }

    @Test("Default createProfile across all verified templates enables farbling with unique 256-bit seeds, supports explicit chip/RAM selection, and honors enableFarbling: false")
    @MainActor
    func createProfileDefaultFarblingAndExplicitOptOut() throws {
        let rootDir = try makeTempDir("curium-pa-seeds")
        defer { try? FileManager.default.removeItem(at: rootDir) }
        let store = CuriumFingerprintStore(fileURL: rootDir.appending(path: CuriumFingerprintStore.fileName))
        #expect(CuriumProfileTemplate.allTemplates.count == 2)
        #expect(CuriumProfileTemplate.allTemplates.first?.id == "macos-desktop")

        // Explicit Apple Silicon chip & RAM variant selection works deterministically.
        let explicitM4Pro = try #require(
            store.createProfile(
                fromTemplate: "macos-desktop",
                displayName: "M4 Pro Workstation",
                hardwareVariantID: "macos-desktop-m4pro-14c-32g-1728x1117"
            )
        )
        #expect(explicitM4Pro.desktop.webglRenderer?.contains("Apple M4 Pro") == true)
        #expect(explicitM4Pro.hardware.hardwareConcurrency == 14)
        #expect(explicitM4Pro.hardware.deviceMemoryGB == 32)
        #expect(explicitM4Pro.desktop.majorVersion == CuriumChromeStableBaseline.majorVersion)
        #expect(explicitM4Pro.desktop.fullVersion == CuriumChromeStableBaseline.fullVersion)
        #expect(explicitM4Pro.desktop.webglProfile == .native)

        var mintedSeeds: Set<String> = []
        for template in CuriumProfileTemplate.allTemplates {
            let created = try #require(
                store.createProfile(fromTemplate: template.id, displayName: "Farbled \(template.title)")
            )
            #expect(created.isFarblingActive)
            #expect(created.hasFarblingEnabled)
            #expect(created.farbling == .allEnabled)
            let seed = try #require(created.fingerprintSeed)
            #expect(CuriumFingerprintSchema.isValidSeedHex(seed))
            #expect(!CuriumFingerprintSchema.isRetiredStaticSeed(seed))
            mintedSeeds.insert(seed)

            let report = CuriumFingerprintValidator.validate(created)
            #expect(report.errors.isEmpty)
            #expect(report.warnings.isEmpty)

            let wireObj = try #require(
                JSONSerialization.jsonObject(
                    with: try created.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US"], schemaVersion: 2)
                ) as? [String: Any]
            )
            #expect((wireObj["fingerprintSeed"] as? String) == seed)
            let farblingObj = try #require(wireObj["farbling"] as? [String: Bool])
            #expect(farblingObj == ["canvas": true, "audio": true, "webgl": true, "textMetrics": true])
        }
        #expect(mintedSeeds.count == CuriumProfileTemplate.allTemplates.count)

        for template in CuriumProfileTemplate.allTemplates {
            let unfarbled = try #require(
                store.createProfile(
                    fromTemplate: template.id,
                    displayName: "Plain \(template.title)",
                    enableFarbling: false
                )
            )
            #expect(unfarbled.fingerprintSeed == nil)
            #expect(unfarbled.farbling == nil)
            #expect(!unfarbled.isFarblingActive)
            #expect(!unfarbled.hasFarblingEnabled)

            let report = CuriumFingerprintValidator.validate(unfarbled)
            #expect(report.errors.isEmpty)
            #expect(report.warnings.isEmpty)

            let wireObj = try #require(
                JSONSerialization.jsonObject(
                    with: try unfarbled.makeEngineLaunchJSON(preferredSystemLanguages: ["en-US"], schemaVersion: 2)
                ) as? [String: Any]
            )
            #expect(wireObj["fingerprintSeed"] == nil)
            #expect(wireObj["farbling"] == nil)
        }
    }

    @Test("Consecutive createProfile calls from multi-variant templates yield distinct GPU, screen, and hardware signatures")
    @MainActor
    func consecutiveCreateProfileCollisionFreeDifferentiation() throws {
        let multiVariantIDs = [
            "macos-desktop",
            "privacy-hardened",
        ]

        for templateID in multiVariantIDs {
            let rootDir = try makeTempDir("curium-pa-diff-\(templateID)")
            defer { try? FileManager.default.removeItem(at: rootDir) }
            let store = CuriumFingerprintStore(fileURL: rootDir.appending(path: CuriumFingerprintStore.fileName))

            let template = try #require(CuriumProfileTemplate.template(for: templateID))
            let poolSize = template.hardwareVariantCount
            #expect(poolSize >= 8)
            let personal = try #require(store.profile(id: "default"))
            let personalSignature = HardwareSignature(profile: personal)

            // Personal ("default") already occupies 1 of the 8 Apple Silicon pool variants (M3 1512×982),
            // so the next `poolSize - 1` created profiles exhaust the remaining 7 distinct variants with
            // zero collisions against Personal or each other (`store.profiles` reaches all `poolSize` variants).
            var createdProfiles: [CuriumFingerprintProfile] = []
            for idx in 0..<(poolSize - 1) {
                let profile = try #require(
                    store.createProfile(fromTemplate: templateID, displayName: "\(templateID)-\(idx)")
                )
                let report = CuriumFingerprintValidator.validate(profile)
                #expect(report.errors.isEmpty)
                #expect(report.warnings.isEmpty)
                createdProfiles.append(profile)
            }

            let signatures = createdProfiles.map(HardwareSignature.init(profile:))
            let allStoreSignatures = store.profiles.map(HardwareSignature.init(profile:))
            let seeds = try createdProfiles.map { try #require($0.fingerprintSeed) }
            #expect(!signatures.contains(personalSignature))
            #expect(Set(signatures).count == poolSize - 1)
            #expect(
                Set(allStoreSignatures).count == poolSize,
                "Expected \(poolSize) unique hardware variants across Personal + created profiles for \(templateID), got \(Set(allStoreSignatures).count)"
            )
            #expect(Set(seeds).count == poolSize - 1)

            // Wrapping past poolSize still mints a unique seed and avoids repeating the immediately preceding variant.
            let wrapped = try #require(
                store.createProfile(fromTemplate: templateID, displayName: "\(templateID)-wrap")
            )
            let wrappedSeed = try #require(wrapped.fingerprintSeed)
            #expect(!Set(seeds).contains(wrappedSeed))
            #expect(HardwareSignature(profile: wrapped) != signatures.last)
            let wrappedReport = CuriumFingerprintValidator.validate(wrapped)
            #expect(wrappedReport.errors.isEmpty)
            #expect(wrappedReport.warnings.isEmpty)

            // Direct pool exhaustion from an empty existing set deals all `poolSize` unique variants before wrap.
            var standalone: [CuriumFingerprintProfile] = []
            for idx in 0..<poolSize {
                let next = template.instantiate(
                    id: String(format: "p-%08x", idx + 1),
                    displayName: "Standalone \(idx)",
                    avoidingExisting: standalone
                )
                standalone.append(next)
            }
            #expect(Set(standalone.map(HardwareSignature.init(profile:))).count == poolSize)
        }

        // Explicit randomizeHardwareVariant: false preserves the coherent Apple M3 14" template baseline,
        // and the retired Android ("default") template cannot be instantiated.
        let optOutDir = try makeTempDir("curium-pa-hw-optout")
        defer { try? FileManager.default.removeItem(at: optOutDir) }
        let optOutStore = CuriumFingerprintStore(fileURL: optOutDir.appending(path: CuriumFingerprintStore.fileName))
        for appleID in ["macos-desktop", "privacy-hardened"] {
            let plainMac = try #require(
                optOutStore.createProfile(
                    fromTemplate: appleID,
                    displayName: "Baseline \(appleID)",
                    randomizeHardwareVariant: false
                )
            )
            #expect(!plainMac.usesNativeHardwareAndGPU)
            #expect(plainMac.desktop == CuriumFingerprintPresets.stableMacOSDesktopSlot)
            #expect(plainMac.hardware.hardwareConcurrency == 8)
            #expect(plainMac.hardware.deviceMemoryGB == 16)
        }
        #expect(
            optOutStore.createProfile(
                fromTemplate: "default",
                displayName: "Retired Android",
                randomizeHardwareVariant: false
            ) == nil
        )
    }

    @Test("createProfile persists custom Fixed Proxy, timezone, and languages and fails closed on invalid inputs")
    @MainActor
    func createProfileNetworkLocalePersistenceAndFailClosedValidation() throws {
        let rootDir = try makeTempDir("curium-pa-net")
        defer { try? FileManager.default.removeItem(at: rootDir) }
        let fileURL = rootDir.appending(path: CuriumFingerprintStore.fileName)
        let store = CuriumFingerprintStore(fileURL: fileURL)

        let validProxy = CuriumProxyConfig.fixed(
            rules: "socks5://127.0.0.1:1080",
            bypassRules: "localhost,127.0.0.1"
        )
        let created = try #require(
            store.createProfile(
                fromTemplate: "macos-desktop",
                displayName: "Berlin Mac",
                symbolName: "network",
                palette: .americium,
                proxy: validProxy,
                timezone: "Europe/Berlin",
                languages: ["de-DE", "de", "en"]
            )
        )
        #expect(created.proxy == validProxy)
        #expect(created.hardware.timezone == "Europe/Berlin")
        #expect(created.languages == ["de-DE", "de", "en"])

        let reloaded = CuriumFingerprintStore(fileURL: fileURL)
        let persisted = try #require(reloaded.profile(id: created.id))
        #expect(persisted.proxy == validProxy)
        #expect(persisted.hardware.timezone == "Europe/Berlin")
        #expect(persisted.languages == ["de-DE", "de", "en"])

        let wireObj = try #require(
            JSONSerialization.jsonObject(with: try persisted.makeEngineLaunchJSON()) as? [String: Any]
        )
        let wireProxy = try #require(wireObj["proxy"] as? [String: Any])
        #expect((wireProxy["mode"] as? String) == "fixed")
        #expect((wireProxy["rules"] as? String) == "socks5://127.0.0.1:1080")
        #expect((wireProxy["bypassRules"] as? String) == "localhost,127.0.0.1")
        let wireHW = try #require(wireObj["hardware"] as? [String: Any])
        #expect((wireHW["timezone"] as? String) == "Europe/Berlin")
        #expect((wireObj["languages"] as? [String]) == ["de-DE", "de", "en"])

        let countBefore = store.profiles.count
        let diskBytesBefore = try Data(contentsOf: fileURL)

        // Malformed fixed proxy rules fail closed without mutating profiles or disk.
        for badProxy in [
            CuriumProxyConfig.fixed(rules: "   ", bypassRules: nil),
            CuriumProxyConfig.fixed(rules: "direct://", bypassRules: nil),
            CuriumProxyConfig.fixed(rules: "bad_scheme://127.0.0.1:1080", bypassRules: nil),
            CuriumProxyConfig.fixed(rules: "socks5://127.0.0.1:99999", bypassRules: nil),
            CuriumProxyConfig.fixed(rules: "socks5://127.0.0.1:1080", bypassRules: "localhost\n127.0.0.1"),
        ] {
            let rejected = store.createProfile(
                fromTemplate: "macos-desktop",
                displayName: "Bad Proxy",
                proxy: badProxy
            )
            #expect(rejected == nil)
            #expect(store.lastPersistError?.isEmpty == false)
        }

        // Invalid IANA timezones fail closed.
        for badTimezone in ["Mars/Olympus", "../UTC", "/America/New_York"] {
            let rejected = store.createProfile(
                fromTemplate: "macos-desktop",
                displayName: "Bad TZ",
                timezone: badTimezone
            )
            #expect(rejected == nil)
            #expect(store.lastPersistError?.isEmpty == false)
        }

        // Invalid BCP-47 language tags or >8 tags fail closed.
        for badLanguages in [
            ["bad;header"],
            ["en-US,fr-FR"],
            ["en-US", "en-GB", "fr-FR", "de-DE", "ja-JP", "zh-CN", "es-ES", "it-IT", "pt-BR"],
        ] {
            let rejected = store.createProfile(
                fromTemplate: "privacy-hardened",
                displayName: "Bad Lang",
                languages: badLanguages
            )
            #expect(rejected == nil)
            #expect(store.lastPersistError?.isEmpty == false)
        }

        // Retired legacy & unknown template IDs fail closed.
        for unknownID in ["unknown-archetype", "ios-blink", "win11-workstation", "linux-desktop"] {
            #expect(store.createProfile(fromTemplate: unknownID, displayName: "Rejected") == nil)
            #expect(store.lastPersistError?.isEmpty == false)
        }

        #expect(store.profiles.count == countBefore)
        #expect(try Data(contentsOf: fileURL) == diskBytesBefore)
    }

    @Test("rollCoherentHardwareVariant rotates to a distinct variant while preserving identity, proxy, timezone, languages, and seed")
    @MainActor
    func rollCoherentHardwareVariantRotatesAndPreservesMetadata() throws {
        let rootDir = try makeTempDir("curium-pa-roll")
        defer { try? FileManager.default.removeItem(at: rootDir) }
        let store = CuriumFingerprintStore(fileURL: rootDir.appending(path: CuriumFingerprintStore.fileName))

        // Unverified / legacy custom platforms (e.g. Windows x64) have no verified variant pool and return nil cleanly.
        var customLegacy = CuriumFingerprintPresets.macosDesktopFirst
        customLegacy.id = "p-legacy01"
        customLegacy.templateID = "win11-workstation"
        customLegacy.desktop.platform = "Windows"
        customLegacy.mobile.platform = "Windows"
        #expect(CuriumFingerprintPresets.rollCoherentHardwareVariant(for: customLegacy) == nil)

        // Rolling Personal (`default`) assigns a coherent Apple Silicon macOS Chrome 158 variant across both slots.
        let personal = try #require(store.profile(id: "default"))
        let rolledPersonal = try #require(CuriumFingerprintPresets.rollCoherentHardwareVariant(for: personal))
        #expect(rolledPersonal.id == "default")
        #expect(!rolledPersonal.usesNativeHardwareAndGPU)
        #expect(rolledPersonal.desktop.hasWebGLOverride)
        #expect(rolledPersonal.mobile == rolledPersonal.desktop)
        #expect(rolledPersonal.desktop.webglProfile == .native)
        #expect(rolledPersonal.desktop.majorVersion == CuriumChromeStableBaseline.majorVersion)
        #expect(rolledPersonal.fontProfile == .apple)
        #expect(rolledPersonal.hideSpeechVoices == false)
        #expect(CuriumFingerprintValidator.validate(rolledPersonal).errors.isEmpty)
        #expect(CuriumFingerprintValidator.validate(rolledPersonal).warnings.isEmpty)

        let fixedProxy = CuriumProxyConfig.fixed(rules: "socks5://127.0.0.1:1080", bypassRules: "localhost")
        for templateID in ["macos-desktop", "privacy-hardened"] {
            let original = try #require(
                store.createProfile(
                    fromTemplate: templateID,
                    displayName: "Roll \(templateID)",
                    symbolName: "globe",
                    palette: .berkelium,
                    proxy: fixedProxy,
                    timezone: "Asia/Tokyo",
                    languages: ["ja-JP", "ja", "en"]
                )
            )
            var current = original
            for _ in 0..<3 {
                let others = store.profiles.filter { $0.id != current.id }
                let rolled = try #require(
                    CuriumFingerprintPresets.rollCoherentHardwareVariant(for: current, avoiding: others)
                )
                #expect(HardwareSignature(profile: rolled) != HardwareSignature(profile: current))
                #expect(rolled.id == original.id)
                #expect(rolled.displayName == original.displayName)
                #expect(rolled.proxy == fixedProxy)
                #expect(rolled.hardware.timezone == "Asia/Tokyo")
                #expect(rolled.languages == ["ja-JP", "ja", "en"])
                #expect(rolled.fingerprintSeed == original.fingerprintSeed)
                #expect(rolled.farbling == original.farbling)
                #expect(rolled.symbolName == "globe")
                #expect(rolled.palette == .berkelium)

                let report = CuriumFingerprintValidator.validate(rolled)
                #expect(report.errors.isEmpty)
                #expect(report.warnings.isEmpty)
                current = rolled
            }
        }
    }

    @Test("CuriumProfileRelauncher exposes honest close-to-switch copy and LiveContainer launch/menu URLs")
    @MainActor
    func relauncherCopyAndLiveContainerURLs() throws {
        #expect(CuriumProfileRelauncher.primaryRelaunchButtonTitle == "Save & Close to Switch")
        #expect(CuriumProfileRelauncher.shortActionButtonTitle == "Close & Switch")
        #expect(CuriumProfileRelauncher.recoveryCloseButtonTitle == "Close Curium")

        let handoffCopy = CuriumProfileRelauncher.switchHandoffDescription(
            activeProfileName: "Personal",
            targetProfileName: "Work Mac"
        )
        #expect(handoffCopy.contains("Personal"))
        #expect(handoffCopy.contains("Work Mac"))
        #expect(handoffCopy.contains("save open tabs and library data"))
        #expect(handoffCopy.contains("close cleanly"))
        #expect(handoffCopy.contains("isolated Blink process"))

        let relaunchLC1 = try #require(
            CuriumProfileRelauncher.liveContainerRelaunchURL(
                bundlePath: "/var/containers/Bundle/Application/1234/com.appautomaton.curium.app",
                scheme: "livecontainer"
            )
        )
        #expect(relaunchLC1.absoluteString == "livecontainer://livecontainer-launch?bundle-name=com.appautomaton.curium.app")

        let menuLC1 = try #require(CuriumProfileRelauncher.liveContainerMenuURL(scheme: "livecontainer"))
        #expect(menuLC1.absoluteString == "livecontainer://livecontainer-launch?bundle-name=ui")

        let menuLC2 = try #require(CuriumProfileRelauncher.liveContainerMenuURL(scheme: "livecontainer2"))
        #expect(menuLC2.absoluteString == "livecontainer2://livecontainer-launch?bundle-name=ui")
        #expect(CuriumProfileRelauncher.liveContainerMenuURL(scheme: "   ") == nil)

        var customHandlerCalled = false
        CuriumProfileRelauncher.relaunchAfterFlush {
            customHandlerCalled = true
        }
        #expect(customHandlerCalled)
    }
}

@Suite("Media Radar, HLS Parser & Authenticated Media Downloads")
struct CuriumMediaRadarAndDownloaderTests {
    private actor StagedCommitTestGate {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var released = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func markEnteredAndWaitForRelease() async {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            if !released {
                await withCheckedContinuation { cont in
                    releaseWaiter = cont
                }
            }
        }

        func waitUntilEntered() async {
            if !entered {
                await withCheckedContinuation { cont in
                    enteredWaiter = cont
                }
            }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
    private func makeTempDir(_ prefix: String = "curium-mr") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func encryptAES128CBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        let outCapacity = plaintext.count + kCCBlockSizeAES128
        var outData = Data(count: outCapacity)
        var outLength = 0
        let status: CCCryptorStatus = outData.withUnsafeMutableBytes { outBuf in
            plaintext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress,
                            kCCKeySizeAES128,
                            ivBuf.baseAddress,
                            inBuf.baseAddress,
                            plaintext.count,
                            outBuf.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        #expect(status == kCCSuccess)
        outData.count = outLength
        return outData
    }

    @Test("HLS Master Playlist parses variants, sorts by resolution and bandwidth, binds DEFAULT audio renditions, and resolves relative URLs")
    func hlsMasterPlaylistParsingSortingAudioBindingAndRelativeURLs() throws {
        let baseURL = try #require(URL(string: "https://cdn.video.example/streams/v2/master.m3u8?token=xyz"))
        let masterText = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud-hi",NAME="Commentary",DEFAULT=NO,AUTOSELECT=YES,URI="../audio/commentary.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud-hi",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="../audio/en/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1800000,AVERAGE-BANDWIDTH=1500000,RESOLUTION=1280x720,FRAME-RATE=29.970,CODECS="avc1.4d401f,mp4a.40.2"
        /hls/720p/prog.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6200000,AVERAGE-BANDWIDTH=5400000,RESOLUTION=1920x1080,FRAME-RATE=59.940,CODECS="avc1.64002a,mp4a.40.2",AUDIO="aud-hi"
        1080p/prog.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=14500000,RESOLUTION=3840x2160,FRAME-RATE=60.000,CODECS="hvc1.1.6.L150.90",AUDIO="aud-hi"
        //edge.video.example/uhd/2160p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=950000,RESOLUTION=1000x500
        custom/prog.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
        audio-only.m3u8
        """

        let inspection = try CuriumHLSParser.parseMasterOrMedia(text: masterText, baseURL: baseURL)
        #expect(inspection.isMasterPlaylist)
        #expect(inspection.isDownloadable)
        #expect(inspection.unavailableReason == nil)
        #expect(!inspection.isLiveStream)
        #expect(inspection.variants.count == 5)

        // Sorted highest resolution / bandwidth first: 2160p -> 1080p -> 720p -> 1000×500 -> 128 kbps.
        let v4K = inspection.variants[0]
        #expect(v4K.url.absoluteString == "https://edge.video.example/uhd/2160p.m3u8")
        #expect(v4K.resolutionLabel == "2160p")
        #expect(v4K.bitrateLabel == "14.5 Mbps")
        #expect(v4K.displayTitle == "2160p · 14.5 Mbps")
        #expect(v4K.audioGroupID == "aud-hi")
        #expect(v4K.audioURI?.absoluteString == "https://cdn.video.example/streams/audio/en/index.m3u8")

        let v1080 = inspection.variants[1]
        #expect(v1080.url.absoluteString == "https://cdn.video.example/streams/v2/1080p/prog.m3u8")
        #expect(v1080.resolutionLabel == "1080p")
        #expect(v1080.bitrateLabel == "5.4 Mbps")
        #expect(v1080.displayTitle == "1080p · 5.4 Mbps")
        #expect(v1080.codecs == "avc1.64002a,mp4a.40.2")
        #expect(v1080.audioURI?.absoluteString == "https://cdn.video.example/streams/audio/en/index.m3u8")

        let v720 = inspection.variants[2]
        #expect(v720.url.absoluteString == "https://cdn.video.example/hls/720p/prog.m3u8")
        #expect(v720.resolutionLabel == "720p")
        #expect(v720.audioURI == nil)

        let vCustom = inspection.variants[3]
        #expect(vCustom.resolutionLabel == "1000×500")
        #expect(vCustom.bitrateLabel == "950 kbps")
        #expect(vCustom.displayTitle == "1000×500 · 950 kbps")

        let vAudioOnly = inspection.variants[4]
        #expect(vAudioOnly.resolutionLabel == nil)
        #expect(vAudioOnly.bitrateLabel == "128 kbps")
        #expect(vAudioOnly.displayTitle == "128 kbps")

        // Master-level FairPlay SESSION-KEY marks inspection non-downloadable with DRM reason.
        let drmMaster = """
        #EXTM3U
        #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://fps.example/asset-1",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080
        1080p.m3u8
        """
        let drmInspection = try CuriumHLSParser.parseMasterOrMedia(text: drmMaster, baseURL: baseURL)
        #expect(!drmInspection.isDownloadable)
        #expect(drmInspection.encryption == .unsupportedDRM(method: "SAMPLE-AES"))
        #expect(drmInspection.unavailableReason?.contains("SAMPLE-AES") == true)
    }

    @Test("HLS Media Playlist handles TS vs fMP4 EXT-X-MAP, EXT-X-BYTERANGE, VOD vs Live, SAMPLE-AES DRM, and SSRF scheme/size/count bounds")
    func hlsMediaPlaylistFormatsByteRangeLiveDRMAndSSRFRejection() throws {
        let baseURL = try #require(URL(string: "https://cdn.video.example/vod/1080p/index.m3u8"))

        // 1. MPEG-TS VOD playlist with contiguous EXT-X-BYTERANGE.
        let tsPlaylistText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:42
        #EXTINF:5.5,
        #EXT-X-BYTERANGE:1000@200
        main.ts
        #EXTINF:4.5,
        #EXT-X-BYTERANGE:1500
        main.ts
        #EXT-X-ENDLIST
        """
        let tsMedia = try CuriumHLSParser.parseMediaPlaylist(text: tsPlaylistText, baseURL: baseURL)
        #expect(!tsMedia.isFMP4)
        #expect(!tsMedia.isLiveStream)
        #expect(tsMedia.isEndList)
        #expect(tsMedia.mediaSequence == 42)
        #expect(tsMedia.totalDurationSeconds == 10.0)
        #expect(tsMedia.segments.count == 2)
        #expect(tsMedia.segments[0].mediaSequence == 42)
        #expect(tsMedia.segments[0].byteRange?.length == 1000)
        #expect(tsMedia.segments[0].byteRange?.offset == 200)
        #expect(tsMedia.segments[1].mediaSequence == 43)
        #expect(tsMedia.segments[1].byteRange?.length == 1500)
        #expect(tsMedia.segments[1].byteRange?.offset == 1200)

        // 2. fMP4 playlist with EXT-X-MAP + BYTERANGE and PLAYLIST-TYPE:VOD (even without ENDLIST).
        let fmp4Text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="../init/header.mp4",BYTERANGE="720@0"
        #EXTINF:4.0,
        seg0.m4s
        #EXTINF:3.25,
        seg1.m4s
        """
        let fmp4Inspection = try CuriumHLSParser.parseMasterOrMedia(text: fmp4Text, baseURL: baseURL)
        #expect(!fmp4Inspection.isMasterPlaylist)
        #expect(fmp4Inspection.isFMP4)
        #expect(!fmp4Inspection.isLiveStream)
        #expect(fmp4Inspection.isDownloadable)
        #expect(fmp4Inspection.directSegmentCount == 2)
        #expect(fmp4Inspection.estimatedDurationSeconds == 7.25)

        let fmp4Media = try CuriumHLSParser.parseMediaPlaylist(text: fmp4Text, baseURL: baseURL)
        #expect(fmp4Media.isFMP4)
        #expect(fmp4Media.segments[0].mapURL?.absoluteString == "https://cdn.video.example/vod/init/header.mp4")
        #expect(fmp4Media.segments[0].mapByteRange?.length == 720)
        #expect(fmp4Media.segments[0].mapByteRange?.offset == 0)
        #expect(fmp4Media.segments[0].mapEncryption == .none)

        // RFC 8216 §4.3.2.5: #EXT-X-KEY preceding #EXT-X-MAP binds AES-128 encryption to the init section too.
        let encryptedMapText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=AES-128,URI="keys/init.key",IV=0x0000000000000000000000000000000a
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        seg0.m4s
        #EXT-X-ENDLIST
        """
        let encryptedMapMedia = try CuriumHLSParser.parseMediaPlaylist(text: encryptedMapText, baseURL: baseURL)
        if case .aes128(let mapKeyURL, let mapIV) = encryptedMapMedia.segments[0].mapEncryption {
            #expect(mapKeyURL.absoluteString == "https://cdn.video.example/vod/1080p/keys/init.key")
            #expect(mapIV?.last == 0x0A)
        } else {
            Issue.record("Expected AES-128 mapEncryption when #EXT-X-KEY precedes #EXT-X-MAP")
        }

        // 3. Live stream (missing #EXT-X-ENDLIST and not VOD) is marked non-downloadable.
        let liveText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:9001
        #EXTINF:4.0,
        live9001.ts
        """
        let liveInspection = try CuriumHLSParser.parseMasterOrMedia(text: liveText, baseURL: baseURL)
        #expect(liveInspection.isLiveStream)
        #expect(!liveInspection.isDownloadable)
        #expect(liveInspection.unavailableReason?.localizedCaseInsensitiveContains("live") == true)

        // 4. SAMPLE-AES FairPlay DRM in media playlist reports unsupportedDRM cleanly without throwing on skd://.
        let sampleAESText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fairplay.example/key1"
        #EXTINF:6.0,
        drm0.ts
        #EXT-X-ENDLIST
        """
        let drmMedia = try CuriumHLSParser.parseMasterOrMedia(text: sampleAESText, baseURL: baseURL)
        #expect(!drmMedia.isDownloadable)
        #expect(drmMedia.encryption == .unsupportedDRM(method: "SAMPLE-AES"))
        #expect(drmMedia.unavailableReason?.contains("SAMPLE-AES") == true)

        // 5. Strict SSRF & non-HTTP(S) scheme rejection on baseURL, variants, segments, keys, and init maps.
        #expect(!CuriumHLSParser.isAllowedHTTPURL(URL(fileURLWithPath: "/etc/passwd")))
        #expect(!CuriumHLSParser.isAllowedHTTPURL(URL(string: "data:application/vnd.apple.mpegurl;base64,I0VYVE0zVQ==")!))
        #expect(!CuriumHLSParser.isAllowedHTTPURL(URL(string: "javascript:alert(1)")!))
        #expect(!CuriumHLSParser.isAllowedHTTPURL(URL(string: "http:///etc/passwd")!))
        #expect(CuriumHLSParser.isAllowedHTTPURL(baseURL))

        #expect(throws: CuriumHLSParserError.disallowedURLScheme("file")) {
            _ = try CuriumHLSParser.parseMasterOrMedia(
                text: "#EXTM3U\n#EXTINF:4.0,\nseg.ts\n#EXT-X-ENDLIST",
                baseURL: URL(fileURLWithPath: "/tmp/playlist.m3u8")
            )
        }
        for maliciousPlaylist in [
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nfile:///etc/passwd",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\ndata:text/plain,evil",
            "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"en\",URI=\"file:///etc/passwd\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO=\"a\"\nok.m3u8",
            "#EXTM3U\n#EXTINF:4.0,\nfile:///private/var/mobile/Library/Cookies.binarycookies\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXTINF:4.0,\njavascript:fetch('https://evil.example')\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXT-X-MAP:URI=\"file:///etc/hosts\"\n#EXTINF:4.0,\nseg.m4s\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"file:///etc/master.key\"\n#EXTINF:4.0,\nseg.ts\n#EXT-X-ENDLIST",
        ] {
            #expect(throws: CuriumHLSParserError.self) {
                _ = try CuriumHLSParser.parseMasterOrMedia(text: maliciousPlaylist, baseURL: baseURL)
            }
        }

        // 6. Bounded playlist size (4 MiB) and max segment count (5,000).
        let oversized = "#EXTM3U\n#" + String(repeating: "A", count: CuriumHLSParser.maxPlaylistBytes + 16)
        #expect(throws: CuriumHLSParserError.self) {
            _ = try CuriumHLSParser.parseMasterOrMedia(text: oversized, baseURL: baseURL)
        }

        var tooManyLines: [String] = ["#EXTM3U", "#EXT-X-TARGETDURATION:2"]
        tooManyLines.reserveCapacity(CuriumHLSParser.maxSegments * 2 + 6)
        for idx in 0...CuriumHLSParser.maxSegments {
            tooManyLines.append("#EXTINF:2.0,")
            tooManyLines.append("seg\(idx).ts")
        }
        tooManyLines.append("#EXT-X-ENDLIST")
        #expect(throws: CuriumHLSParserError.tooManySegments(CuriumHLSParser.maxSegments + 1)) {
            _ = try CuriumHLSParser.parseMediaPlaylist(text: tooManyLines.joined(separator: "\n"), baseURL: baseURL)
        }
    }

    @Test("AES-128-CBC decryption round-trips with explicit hex IV and RFC 8216 §5.2 sequence-number fallback")
    func aes128CBCRoundTripAndSequenceIVFallback() throws {
        let baseURL = try #require(URL(string: "https://cdn.video.example/enc/index.m3u8"))
        let key = Data((0..<16).map { UInt8(0xA0 + $0) })
        let plaintext1 = Data("Curium MPEG-TS Packet #1 — authenticated AES-128-CBC round-trip payload!".utf8)
        let plaintext2 = Data(repeating: 0x47, count: 188 * 3) // Three 188-byte MPEG-TS sync frames

        // 1. Explicit IV parsed from #EXT-X-KEY (including short hex left-padding).
        let encryptedPlaylistText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0x01020304
        #EXT-X-KEY:METHOD=AES-128,URI="keys/k1.bin",IV=0x000102030405060708090a0b0c0d0e0f
        #EXTINF:6.0,
        seg0.ts
        #EXT-X-KEY:METHOD=AES-128,URI="keys/k1.bin"
        #EXTINF:6.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let media = try CuriumHLSParser.parseMediaPlaylist(
            text: encryptedPlaylistText.replacingOccurrences(of: "0x01020304", with: "16909060"),
            baseURL: baseURL
        )
        #expect(media.segments.count == 2)

        guard case .aes128(let keyURL0, let explicitIV0) = media.segments[0].encryption else {
            Issue.record("Expected AES-128 encryption on segment 0")
            return
        }
        #expect(keyURL0.absoluteString == "https://cdn.video.example/enc/keys/k1.bin")
        let expectedExplicitIV = Data((0..<16).map(UInt8.init))
        #expect(explicitIV0 == expectedExplicitIV)
        let resolvedIV0 = CuriumHLSParser.resolveIV(
            explicitIV: explicitIV0,
            mediaSequence: media.segments[0].mediaSequence
        )
        #expect(resolvedIV0 == expectedExplicitIV)

        let ciphertext1 = try encryptAES128CBC(plaintext1, key: key, iv: resolvedIV0)
        let decrypted1 = try CuriumHLSParser.decryptAES128CBC(ciphertext1, key: key, iv: resolvedIV0)
        #expect(decrypted1 == plaintext1)

        // 2. Sequence-number IV fallback on segment 1 (mediaSequence = 16909061 = 0x01020305).
        guard case .aes128(_, let explicitIV1) = media.segments[1].encryption else {
            Issue.record("Expected AES-128 encryption on segment 1")
            return
        }
        #expect(explicitIV1 == nil)
        #expect(media.segments[1].mediaSequence == 0x0102_0305)
        let resolvedIV1 = CuriumHLSParser.resolveIV(
            explicitIV: explicitIV1,
            mediaSequence: media.segments[1].mediaSequence
        )
        let expectedSeqIV = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02, 0x03, 0x05])
        #expect(resolvedIV1 == expectedSeqIV)

        let ciphertext2 = try encryptAES128CBC(plaintext2, key: key, iv: resolvedIV1)
        let decrypted2 = try CuriumHLSParser.decryptAES128CBC(ciphertext2, key: key, iv: resolvedIV1)
        #expect(decrypted2 == plaintext2)

        // 3. Key/IV/alignment validation fails closed.
        #expect(throws: CuriumHLSParserError.invalidKeyLength(15)) {
            _ = try CuriumHLSParser.decryptAES128CBC(ciphertext1, key: Data(repeating: 1, count: 15), iv: resolvedIV0)
        }
        #expect(throws: CuriumHLSParserError.invalidIVLength(12)) {
            _ = try CuriumHLSParser.decryptAES128CBC(ciphertext1, key: key, iv: Data(repeating: 1, count: 12))
        }
        #expect(throws: CuriumHLSParserError.self) {
            _ = try CuriumHLSParser.decryptAES128CBC(Data([0x01, 0x02, 0x03]), key: key, iv: resolvedIV0)
        }
    }

    @Test("CuriumMediaDOMScanner parses isolated-world frames, deduplicates and enriches network events, sorts by stream priority, and sanitizes filenames")
    @MainActor
    func domScannerParseMergeEnrichmentPriorityAndFilenames() async throws {
        let mainPageURL = try #require(URL(string: "https://cinema.example/watch?v=99"))
        let embedURL = try #require(URL(string: "https://player.cinema.example/embed/99"))
        let hlsURL = try #require(URL(string: "https://cdn.cinema.example/hls/master.m3u8?sig=secret"))
        let mp4URL = try #require(URL(string: "https://cdn.cinema.example/files/a1b2c3d4e5f60718293a.mp4"))
        let domOnlyAudioURL = try #require(URL(string: "https://cdn.cinema.example/audio/theme-song.mp3"))
        let dashURL = try #require(URL(string: "https://cdn.cinema.example/dash/manifest.mpd"))

        let frames: [CuriumIsolatedFrameEvalResult] = [
            CuriumIsolatedFrameEvalResult(
                isMainFrame: true,
                frameURL: mainPageURL,
                frameOrigin: "https://cinema.example",
                result: .object([
                    "pageTitle": .string("  Keynote: Future of Liquid Glass / iOS 27  "),
                    "blobVideoCount": .number(2),
                    "entries": .array([
                        .object([
                            "url": .null,
                            "isBlob": .bool(true),
                            "tag": .string("video"),
                            "width": .number(1920),
                            "height": .number(1080),
                        ]),
                        .object([
                            "url": .string("file:///etc/passwd"),
                            "isBlob": .bool(false),
                            "tag": .string("video"),
                        ]),
                        .object([
                            "url": .string(domOnlyAudioURL.absoluteString),
                            "isBlob": .bool(false),
                            "tag": .string("audio"),
                            "title": .string("Opening Theme: Orchestra / Live"),
                            "duration": .number(185.4),
                            "mimeType": .string("audio/mpeg"),
                        ]),
                    ]),
                ])
            ),
            CuriumIsolatedFrameEvalResult(
                isMainFrame: false,
                frameURL: embedURL,
                frameOrigin: "https://player.cinema.example",
                result: .object([
                    "pageTitle": .string("Embedded Player"),
                    "blobVideoCount": .number(1),
                    "entries": .array([
                        .object([
                            "url": .string(mp4URL.absoluteString),
                            "isBlob": .bool(false),
                            "tag": .string("video"),
                            "width": .number(1920),
                            "height": .number(1080),
                            "duration": .number(3723.0),
                            "mimeType": .string("video/mp4; codecs=\"avc1\""),
                        ]),
                    ]),
                ])
            ),
        ]

        let parsed = CuriumMediaDOMScanner.parseProbeResults(frames)
        #expect(parsed.pageTitle == "Keynote: Future of Liquid Glass / iOS 27")
        #expect(parsed.blobVideoCount == 3)
        // file:///etc/passwd entry was rejected; 1 blob video + 1 audio + 1 mp4 video remain.
        #expect(parsed.entries.count == 3)
        #expect(!parsed.entries.contains { $0.url?.scheme == "file" })

        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let networkEvents: [CuriumMediaResourceEvent] = [
            try #require(CuriumMediaResourceEvent.parse(
                from: [
                    "url": dashURL,
                    "mimeType": "application/dash+xml",
                    "httpMethod": "GET",
                    "httpStatusCode": 200,
                    "contentLength": 2048,
                    "referrer": embedURL,
                    "frameOrigin": "https://player.cinema.example",
                ],
                effectiveUserAgent: "CuriumUA/146",
                now: t0.addingTimeInterval(30)
            )),
            try #require(CuriumMediaResourceEvent.parse(
                from: [
                    "url": mp4URL,
                    "mimeType": "video/mp4",
                    "httpMethod": "GET",
                    "httpStatusCode": 206,
                    "contentLength": 52_428_800,
                    "requestDestination": "video",
                    "referrer": embedURL,
                ],
                effectiveUserAgent: "CuriumUA/146",
                now: t0.addingTimeInterval(10)
            )),
            try #require(CuriumMediaResourceEvent.parse(
                from: [
                    "url": hlsURL,
                    "mimeType": "application/vnd.apple.mpegurl",
                    "httpMethod": "GET",
                    "httpStatusCode": 200,
                    "contentLength": 4096,
                    "referrer": mainPageURL,
                    "frameOrigin": "https://cinema.example",
                ],
                effectiveUserAgent: "CuriumUA/146",
                now: t0.addingTimeInterval(20)
            )),
        ]

        let snapshot = CuriumMediaDOMScanner.merge(
            tabID: "tab-1",
            pageTitle: parsed.pageTitle,
            networkEvents: networkEvents,
            domEntries: parsed.entries,
            blobVideoCount: parsed.blobVideoCount,
            effectiveUserAgent: "FallbackUA/1.0",
            now: t0.addingTimeInterval(40)
        )

        #expect(snapshot.tabID == "tab-1")
        #expect(snapshot.detectedBlobVideoCount == 3)
        // Deduped mp4 (network + DOM) + hls (network) + audio (DOM) + dash (network) == 4 candidates.
        #expect(snapshot.candidates.count == 4)
        #expect(snapshot.candidates.map(\.kind) == [.hls, .video, .audio, .dash])

        let hlsCandidate = snapshot.candidates[0]
        #expect(hlsCandidate.url == hlsURL)
        #expect(hlsCandidate.formatBadge == "HLS")
        #expect(hlsCandidate.fromNetwork && !hlsCandidate.fromDOM)
        // Generic "master" stem replaced by pageTitle; ":" and "/" sanitized out of suggestedFilename.
        #expect(hlsCandidate.title == "Keynote: Future of Liquid Glass / iOS 27")
        #expect(hlsCandidate.suggestedFilename == "Keynote- Future of Liquid Glass - iOS 27.ts")

        let videoCandidate = snapshot.candidates[1]
        #expect(videoCandidate.url == mp4URL)
        #expect(videoCandidate.fromDOM && videoCandidate.fromNetwork)
        #expect(videoCandidate.resolutionLabel == "1080p")
        #expect(videoCandidate.formattedDuration == "1:02:03")
        #expect(videoCandidate.contentLength == 52_428_800)
        #expect(videoCandidate.formattedByteSize != nil)
        #expect(videoCandidate.frameOrigin == "https://player.cinema.example")
        #expect(videoCandidate.effectiveUserAgent == "CuriumUA/146")
        // Opaque hex stem replaced with pageTitle; extension resolved to .mp4.
        #expect(videoCandidate.suggestedFilename == "Keynote- Future of Liquid Glass - iOS 27.mp4")

        let audioCandidate = snapshot.candidates[2]
        #expect(audioCandidate.url == domOnlyAudioURL)
        #expect(audioCandidate.fromDOM && !audioCandidate.fromNetwork)
        #expect(audioCandidate.title == "Opening Theme: Orchestra / Live")
        #expect(audioCandidate.formattedDuration == "3:05")
        #expect(audioCandidate.suggestedFilename == "Opening Theme- Orchestra - Live.mp3")

        let dashCandidate = snapshot.candidates[3]
        #expect(dashCandidate.formatBadge == "DASH")
        #expect(dashCandidate.suggestedFilename.hasSuffix(".mpd"))

        // Verify CuriumBrowserStore.scanActiveTabMedia() wires isolated-world eval + radar merge cleanly.
        let host = MockBrowserHost()
        let mockTab = MockTabHost(tabID: "t-scan", url: mainPageURL, title: "Fallback Title")
        mockTab.isolatedEvalHandler = { script, allFrames in
            #expect(script == CuriumMediaDOMScanner.probeScript)
            #expect(allFrames == true)
            return ([
                [
                    "isMainFrame": NSNumber(value: true),
                    "frameURL": mainPageURL,
                    "frameOrigin": "https://cinema.example",
                    "result": [
                        "pageTitle": "Live Concert",
                        "blobVideoCount": 1,
                        "entries": [
                            [
                                "url": domOnlyAudioURL.absoluteString,
                                "isBlob": false,
                                "tag": "audio",
                                "duration": 90.0,
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ],
            ], nil)
        }
        host.tabs = [mockTab]
        host.activeTab = mockTab
        let store = CuriumBrowserStore(host: host)
        _ = store.mediaRadar.ingest(
            rawEvent: ["url": hlsURL, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200],
            tabID: "t-scan",
            effectiveUserAgent: "CuriumUA/146"
        )
        #expect(store.activeTabMediaCount == 1)

        let liveScan = await store.scanActiveTabMedia()
        #expect(liveScan.pageTitle == "Live Concert")
        #expect(liveScan.detectedBlobVideoCount == 1)
        #expect(liveScan.candidates.map(\.kind) == [.hls, .audio])
    }

    @Test("CuriumMediaNetworking maps system/direct/fixed proxies, configures cookie-isolated ephemeral sessions, and attaches auth headers")
    @MainActor
    func mediaNetworkingProxyDictionaryEphemeralSessionAndAuthHeaders() throws {
        // 1. Proxy dictionary mapping (.system, .direct, .fixed for socks5://, http://, https://, IPv6, bypass).
        #expect(CuriumMediaNetworking.proxyDictionary(for: .system) == nil)
        let directDict = try #require(CuriumMediaNetworking.proxyDictionary(for: .direct))
        #expect(directDict.isEmpty)

        let socksDict = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "socks5://127.0.0.1:1080", bypassRules: "localhost,127.0.0.1;<local>")
        ))
        #expect((socksDict["SOCKSEnable"] as? Int) == 1)
        #expect((socksDict["SOCKSProxy"] as? String) == "127.0.0.1")
        #expect((socksDict["SOCKSPort"] as? Int) == 1080)
        #expect((socksDict["ExceptionsList"] as? [String]) == ["localhost", "127.0.0.1"])
        #expect((socksDict["ExcludeSimpleHostnames"] as? Int) == 1)

        let httpDict = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "http://proxy.internal:8080", bypassRules: nil)
        ))
        #expect((httpDict["HTTPEnable"] as? Int) == 1)
        #expect((httpDict["HTTPProxy"] as? String) == "proxy.internal")
        #expect((httpDict["HTTPPort"] as? Int) == 8080)
        #expect((httpDict["HTTPSEnable"] as? Int) == 1)
        #expect((httpDict["HTTPSProxy"] as? String) == "proxy.internal")
        #expect((httpDict["HTTPSPort"] as? Int) == 8080)

        // Explicit `https://` TLS-to-proxy scheme cannot be expressed in CFNetwork connectionProxyDictionary
        // (whose HTTPSProxy is plaintext HTTP CONNECT), so it fails closed rather than downgrading to cleartext.
        let httpsDict = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "https://tls-proxy.internal:8443", bypassRules: nil)
        ))
        #expect((httpsDict["SOCKSEnable"] as? Int) == 1)
        #expect((httpsDict["SOCKSProxy"] as? String) == "127.0.0.1")
        #expect((httpsDict["SOCKSPort"] as? Int) == 1)
        #expect(httpsDict["HTTPEnable"] == nil)
        #expect(httpsDict["HTTPSEnable"] == nil)

        let splitIPv6Dict = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "http=10.0.0.2:3128;https=socks5://[::1]:1085", bypassRules: nil)
        ))
        #expect((splitIPv6Dict["HTTPEnable"] as? Int) == 1)
        #expect((splitIPv6Dict["HTTPProxy"] as? String) == "10.0.0.2")
        #expect((splitIPv6Dict["HTTPPort"] as? Int) == 3128)
        #expect((splitIPv6Dict["SOCKSEnable"] as? Int) == 1)
        #expect((splitIPv6Dict["SOCKSProxy"] as? String) == "::1")
        #expect((splitIPv6Dict["SOCKSPort"] as? Int) == 1085)

        // Fixed proxy with unsupported-only scheme clause fails closed rather than degrading to direct [:] real IP.
        let failClosedFixed = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "ftp=127.0.0.1:2121", bypassRules: nil)
        ))
        #expect((failClosedFixed["SOCKSEnable"] as? Int) == 1)
        #expect((failClosedFixed["SOCKSProxy"] as? String) == "127.0.0.1")
        #expect((failClosedFixed["SOCKSPort"] as? Int) == 1)

        // 2. Ephemeral session enforces cookie & cache isolation on LiveContainer.
        let session = CuriumMediaNetworking.makeEphemeralSession(
            proxy: .fixed(rules: "socks5://127.0.0.1:1080", bypassRules: nil)
        )
        defer { session.invalidateAndCancel() }
        let cfg = session.configuration
        #expect(cfg.httpShouldSetCookies == false)
        #expect(cfg.httpCookieAcceptPolicy == .never)
        #expect(cfg.urlCache == nil)
        #expect((cfg.connectionProxyDictionary?["SOCKSProxy"] as? String) == "127.0.0.1")

        // 3. makeRequest attaches Cookie, User-Agent, Referer, Origin, and Range while blocking file:// Referer & "null" Origin.
        let targetURL = try #require(URL(string: "https://cdn.example/video/seg1.m4s"))
        let context = CuriumMediaRequestContext(
            cookieHeader: "  sid=abc123; theme=dark  ",
            userAgent: "Mozilla/5.0 CuriumTest/146",
            referrer: URL(string: "https://watch.example/player/42"),
            origin: "https://watch.example",
            proxy: .direct
        )
        let req = CuriumMediaNetworking.makeRequest(
            url: targetURL,
            context: context,
            byteRange: (length: 1024, offset: 512)
        )
        #expect(req.httpMethod == "GET")
        #expect(req.httpShouldHandleCookies == false)
        #expect(req.value(forHTTPHeaderField: "Cookie") == "sid=abc123; theme=dark")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 CuriumTest/146")
        #expect(req.value(forHTTPHeaderField: "Referer") == "https://watch.example/player/42")
        #expect(req.value(forHTTPHeaderField: "Origin") == "https://watch.example")
        #expect(req.value(forHTTPHeaderField: "Range") == "bytes=512-1535")

        let scrubbedContext = CuriumMediaRequestContext(
            cookieHeader: "   ",
            userAgent: nil,
            referrer: URL(fileURLWithPath: "/private/var/mobile/secret.html"),
            origin: "null",
            proxy: .system
        )
        let scrubbedReq = CuriumMediaNetworking.makeRequest(
            url: targetURL,
            context: scrubbedContext,
            byteRange: (length: 256, offset: nil)
        )
        #expect(scrubbedReq.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(scrubbedReq.value(forHTTPHeaderField: "Referer") == nil)
        #expect(scrubbedReq.value(forHTTPHeaderField: "Origin") == nil)
        #expect(scrubbedReq.value(forHTTPHeaderField: "Range") == "bytes=0-255")

        // 4. Direct & HLS tasks deterministically reject non-http(s) URLs before touching the network.
        let tempDir = try makeTempDir("curium-mr-scheme")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destFile = tempDir.appending(path: "out.mp4", directoryHint: .notDirectory)

        let directTask = CuriumDirectMediaDownloadTask(
            url: URL(fileURLWithPath: "/etc/passwd"),
            suggestedFilename: "passwd.mp4",
            context: context
        )
        var directError: (any Error)?
        directTask.start(withDestinationURL: destFile) { saved, err in
            #expect(saved == nil)
            directError = err
        }
        #expect(directTask.state == .failed)
        #expect((directError as? CuriumMediaDownloadError) == .disallowedURLScheme("file"))
        #expect(!FileManager.default.fileExists(atPath: destFile.path))

        let hlsTask = CuriumHLSMediaDownloadTask(
            playlistURL: URL(fileURLWithPath: "/etc/passwd"),
            suggestedFilename: "passwd.ts",
            context: context
        )
        var hlsError: (any Error)?
        hlsTask.start(withDestinationURL: destFile) { saved, err in
            #expect(saved == nil)
            hlsError = err
        }
        #expect(hlsTask.state == .failed)
        #expect((hlsError as? CuriumMediaDownloadError) == .disallowedURLScheme("file"))
        #expect(!FileManager.default.fileExists(atPath: destFile.path))
    }

    @Test("CuriumDownloadStorage classifies PDF/video/audio symbols and CuriumBackgroundKeepAlive gates strictly on background && activeTaskCount > 0")
    @MainActor
    func mediaTypeClassificationAndBackgroundKeepAliveGate() throws {
        // 1. CuriumDownloadStorage.isVideo / isAudio / symbolName classification.
        #expect(CuriumDownloadStorage.symbolName(mimeType: "application/pdf", filename: "paper.pdf") == "doc.richtext")
        #expect(!CuriumDownloadStorage.isVideo(mimeType: "application/pdf", filename: "paper.pdf"))
        #expect(!CuriumDownloadStorage.isAudio(mimeType: "application/pdf", filename: "paper.pdf"))

        for videoName in ["clip.mp4", "movie.m4v", "capture.mov", "vp9.webm", "anime.mkv", "segment.ts", "stream.m3u8"] {
            #expect(CuriumDownloadStorage.isVideo(mimeType: nil, filename: videoName), "Expected video for \(videoName)")
            #expect(!CuriumDownloadStorage.isAudio(mimeType: nil, filename: videoName))
            #expect(CuriumDownloadStorage.symbolName(mimeType: nil, filename: videoName) == "film")
        }
        #expect(CuriumDownloadStorage.isVideo(mimeType: "audio/mpegurl", filename: "live", url: URL(string: "https://cdn.example/live")))
        #expect(!CuriumDownloadStorage.isAudio(mimeType: "audio/mpegurl", filename: "live"))
        #expect(CuriumDownloadStorage.symbolName(mimeType: "application/octet-stream", filename: "lecture.mp4") == "film")

        for audioName in ["track.mp3", "podcast.m4a", "voice.aac", "vorbis.ogg", "speech.opus", "lossless.flac", "pcm.wav"] {
            #expect(CuriumDownloadStorage.isAudio(mimeType: nil, filename: audioName), "Expected audio for \(audioName)")
            #expect(!CuriumDownloadStorage.isVideo(mimeType: nil, filename: audioName))
            #expect(CuriumDownloadStorage.symbolName(mimeType: nil, filename: audioName) == "waveform")
        }
        #expect(CuriumDownloadStorage.symbolName(mimeType: "application/octet-stream", filename: "episode.m4a") == "waveform")
        #expect(CuriumDownloadStorage.symbolName(mimeType: "application/zip", filename: "archive.zip") == "doc")

        // 2. CuriumSavedDownload and CuriumDownload propagate classification & symbolName.
        let savedVideo = CuriumSavedDownload(
            url: URL(fileURLWithPath: "/tmp/keynote.mp4"),
            filename: "keynote.mp4",
            byteCount: 1024,
            modifiedAt: .now,
            isPDF: false
        )
        #expect(savedVideo.isVideo)
        #expect(!savedVideo.isAudio)
        #expect(savedVideo.symbolName == "film")

        let savedAudio = CuriumSavedDownload(
            url: URL(fileURLWithPath: "/tmp/song.flac"),
            filename: "song.flac",
            byteCount: 2048,
            modifiedAt: .now,
            isPDF: false
        )
        #expect(savedAudio.isAudio)
        #expect(!savedAudio.isVideo)
        #expect(savedAudio.symbolName == "waveform")

        let activeAudioDownload = CuriumDownload(
            task: MockDownloadTask(
                originalURL: URL(string: "https://cdn.example/mix.opus"),
                suggestedFilename: "mix.opus",
                mimeType: "audio/opus"
            )
        )
        #expect(activeAudioDownload.isAudio)
        #expect(!activeAudioDownload.isVideo)
        #expect(activeAudioDownload.symbolName == "waveform")

        // 3. CuriumBackgroundKeepAlive strictly requires BOTH isBackgrounded && activeTaskCount > 0.
        let keepAlive = CuriumBackgroundKeepAlive()
        defer { keepAlive.stopImmediately() }

        #expect(!keepAlive.shouldBeActive)
        #expect(!keepAlive.isEngineRunning)

        // Foreground + active tasks -> NEVER activates audio session.
        keepAlive.setActiveTaskCount(2)
        #expect(keepAlive.activeTaskCount == 2)
        #expect(!keepAlive.isBackgrounded)
        #expect(!keepAlive.shouldBeActive)
        #expect(!keepAlive.isEngineRunning)

        // Background + 0 tasks -> NEVER activates audio session.
        keepAlive.setActiveTaskCount(0)
        keepAlive.setBackgrounded(true)
        #expect(keepAlive.isBackgrounded)
        #expect(!keepAlive.shouldBeActive)
        #expect(!keepAlive.isEngineRunning)

        // Background + active tasks -> eligible (on headless Simulator 0Hz routes it fails safe without throwing).
        keepAlive.setActiveTaskCount(1)
        #expect(keepAlive.shouldBeActive)

        // Foreground return tears down immediately even while tasks remain active.
        keepAlive.setBackgrounded(false)
        #expect(!keepAlive.shouldBeActive)
        #expect(!keepAlive.isEngineRunning)

        // Task queue drain while backgrounded tears down immediately.
        keepAlive.setBackgrounded(true)
        keepAlive.setActiveTaskCount(0)
        #expect(!keepAlive.shouldBeActive)
        #expect(!keepAlive.isEngineRunning)
    }

    @Test("Real-site Media Radar regressions: audio/ogg typing, MSE 206 chunk filtering, master HLS prioritization, and AAC preference over AC-3")
    @MainActor
    func realSiteMediaRadarRegressions() throws {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)

        // 1. W3Schools Audio (`horse.ogg` served with `Content-Type: video/ogg` inside `<audio><source>`).
        let horseURL = try #require(URL(string: "https://www.w3schools.com/html/horse.ogg"))
        #expect(CuriumMediaResourceEvent.classify(url: horseURL, mimeType: "video/ogg", destination: "audio") == .audio)
        #expect(CuriumMediaDOMScanner.probeScript.contains("{ src: srcNode.src, type: srcNode.type || null, tag }"))

        // Even if the network callback arrived with ambiguous destination ("empty") and video/ogg,
        // merging with a DOM `<audio>` entry upgrades the candidate to `.audio` with OGG badge & .ogg filename.
        let horseNet = try #require(CuriumMediaResourceEvent.parse(
            from: [
                "url": horseURL,
                "mimeType": "video/ogg",
                "httpMethod": "GET",
                "httpStatusCode": 200,
                "contentLength": 13_889,
                "requestDestination": "empty",
            ],
            now: t0
        ))
        #expect(horseNet.kind == .video)
        let horseDOM = CuriumDOMMediaEntry(
            url: horseURL,
            isBlob: false,
            tag: "audio",
            title: nil,
            width: nil,
            height: nil,
            durationSeconds: 1.8,
            frameURL: URL(string: "https://www.w3schools.com/html/html5_audio.asp"),
            frameOrigin: "https://www.w3schools.com",
            mimeType: "audio/ogg"
        )
        let audioSnap = CuriumMediaDOMScanner.merge(
            tabID: "t-audio",
            pageTitle: "HTML Audio",
            networkEvents: [horseNet],
            domEntries: [horseDOM],
            blobVideoCount: 0,
            effectiveUserAgent: nil,
            now: t0
        )
        #expect(audioSnap.candidates.count == 1)
        let horseCandidate = try #require(audioSnap.candidates.first)
        #expect(horseCandidate.kind == .audio)
        #expect(horseCandidate.formatBadge == "OGG")
        #expect(horseCandidate.suggestedFilename == "horse.ogg")

        // Real OGG video retains `.video` with `OGG` badge and `.ogg` extension (not `.mp4`).
        let videoOggURL = try #require(URL(string: "https://www.w3schools.com/html/mov_bbb.ogg"))
        let videoOggNet = try #require(CuriumMediaResourceEvent.parse(
            from: [
                "url": videoOggURL,
                "mimeType": "video/ogg",
                "httpMethod": "GET",
                "httpStatusCode": 206,
                "contentLength": 600_000,
                "requestDestination": "video",
            ],
            now: t0
        ))
        let videoOggSnap = CuriumMediaDOMScanner.merge(
            tabID: "t-vogg",
            pageTitle: "HTML Video",
            networkEvents: [videoOggNet],
            domEntries: [],
            blobVideoCount: 0,
            effectiveUserAgent: nil,
            now: t0
        )
        #expect(videoOggSnap.candidates.first?.kind == .video)
        #expect(videoOggSnap.candidates.first?.formatBadge == "OGG")
        #expect(videoOggSnap.candidates.first?.suggestedFilename == "mov_bbb.ogg")

        // 2. Shaka DASH / Apple fMP4 HTTP 206 & tiny init chunks are filtered when adaptive streaming is active,
        // while real DOM/direct `<video>` elements remain visible and `activeTabMediaCount` stays in sync.
        let dashURL = try #require(URL(string: "https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd"))
        let chunk206Video = try #require(URL(string: "https://storage.googleapis.com/shaka-demo-assets/angel-one/v-0576p-1400k-vp9.webm"))
        let chunk206Audio = try #require(URL(string: "https://storage.googleapis.com/shaka-demo-assets/angel-one/a-eng-0128k-aac.mp4"))
        let chunkTinyInit = try #require(URL(string: "https://storage.googleapis.com/shaka-demo-assets/angel-one/init.webm"))
        let standaloneMP4 = try #require(URL(string: "https://cdn.example/promo.mp4"))

        let shakaEvents: [CuriumMediaResourceEvent] = [
            try #require(CuriumMediaResourceEvent.parse(
                from: ["url": dashURL, "mimeType": "video/vnd.mpeg.dash.mpd", "httpMethod": "GET", "httpStatusCode": 200, "requestDestination": "empty"],
                now: t0
            )),
            try #require(CuriumMediaResourceEvent.parse(
                from: ["url": chunk206Video, "mimeType": "video/webm", "httpMethod": "GET", "httpStatusCode": 206, "contentLength": 194_560, "requestDestination": "empty"],
                now: t0.addingTimeInterval(1)
            )),
            try #require(CuriumMediaResourceEvent.parse(
                from: ["url": chunk206Audio, "mimeType": "audio/mp4", "httpMethod": "GET", "httpStatusCode": 206, "contentLength": 66_560, "requestDestination": "empty"],
                now: t0.addingTimeInterval(2)
            )),
            try #require(CuriumMediaResourceEvent.parse(
                from: ["url": chunkTinyInit, "mimeType": "video/webm", "httpMethod": "GET", "httpStatusCode": 200, "contentLength": 314, "requestDestination": "empty"],
                now: t0.addingTimeInterval(3)
            )),
            try #require(CuriumMediaResourceEvent.parse(
                from: ["url": standaloneMP4, "mimeType": "video/mp4", "httpMethod": "GET", "httpStatusCode": 206, "contentLength": 788_493, "requestDestination": "video"],
                now: t0.addingTimeInterval(4)
            )),
        ]
        let shakaSnap = CuriumMediaDOMScanner.merge(
            tabID: "t-shaka",
            pageTitle: "Shaka Player",
            networkEvents: shakaEvents,
            domEntries: [],
            blobVideoCount: 1,
            effectiveUserAgent: nil,
            now: t0.addingTimeInterval(5)
        )
        #expect(shakaSnap.candidates.map(\.url) == [standaloneMP4, dashURL])
        #expect(shakaSnap.candidates.map(\.kind) == [.video, .dash])

        let host = MockBrowserHost()
        let tab = MockTabHost(tabID: "t-count", url: URL(string: "https://hlsjs.video-dev.org/demo/"), title: "hls.js demo")
        host.tabs = [tab]
        host.activeTab = tab
        let store = CuriumBrowserStore(host: host)
        let appleMaster = try #require(URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"))
        let appleInitChunk = try #require(URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/v5/main.mp4"))
        _ = store.mediaRadar.ingest(
            rawEvent: ["url": appleMaster, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200, "requestDestination": "empty"],
            tabID: "t-count",
            effectiveUserAgent: nil
        )
        _ = store.mediaRadar.ingest(
            rawEvent: ["url": appleInitChunk, "mimeType": "video/mp4", "httpMethod": "GET", "httpStatusCode": 206, "contentLength": 719, "requestDestination": "empty"],
            tabID: "t-count",
            effectiveUserAgent: nil
        )
        #expect(store.mediaRadar.events(for: "t-count").count == 2)
        #expect(store.activeTabMediaCount == 1)

        // 3. HLS Master Playlist sorts ahead of child variant/audio playlists and exposes disambiguating path hints.
        let appleVideoChild = try #require(URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/v5/prog_index.m3u8"))
        let appleAudioChild = try #require(URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/a1/prog_index.m3u8"))
        let hlsOrderSnap = CuriumMediaDOMScanner.merge(
            tabID: "t-hls-order",
            pageTitle: "hls.js demo",
            networkEvents: [
                try #require(CuriumMediaResourceEvent.parse(
                    from: ["url": appleVideoChild, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200],
                    now: t0
                )),
                try #require(CuriumMediaResourceEvent.parse(
                    from: ["url": appleAudioChild, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200],
                    now: t0.addingTimeInterval(1)
                )),
                try #require(CuriumMediaResourceEvent.parse(
                    from: ["url": appleMaster, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200],
                    now: t0.addingTimeInterval(5)
                )),
            ],
            domEntries: [],
            blobVideoCount: 1,
            effectiveUserAgent: nil,
            now: t0.addingTimeInterval(6)
        )
        #expect(hlsOrderSnap.candidates.map(\.url) == [appleMaster, appleVideoChild, appleAudioChild])
        #expect(hlsOrderSnap.candidates.compactMap(\.manifestPathHint) == ["master.m3u8", "v5/prog_index.m3u8", "a1/prog_index.m3u8"])

        // Shallower Mux-style master (`x36xhzz.m3u8`) also sorts ahead of nested child variant (`url_0/chunk.m3u8`).
        let muxMaster = try #require(URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"))
        let muxChild = try #require(URL(string: "https://test-streams.mux.dev/x36xhzz/url_0/193039199_mp4_h264_aac_hd_7.m3u8"))
        let muxOrderSnap = CuriumMediaDOMScanner.merge(
            tabID: "t-mux-order",
            pageTitle: "hls.js demo",
            networkEvents: [
                try #require(CuriumMediaResourceEvent.parse(
                    from: ["url": muxChild, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200],
                    now: t0.addingTimeInterval(2)
                )),
                try #require(CuriumMediaResourceEvent.parse(
                    from: ["url": muxMaster, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200],
                    now: t0
                )),
            ],
            domEntries: [],
            blobVideoCount: 1,
            effectiveUserAgent: nil,
            now: t0.addingTimeInterval(3)
        )
        #expect(muxOrderSnap.candidates.map(\.url) == [muxMaster, muxChild])

        // 4. Apple-style master playlist with duplicate video playlist URLs prefers universal AAC (`mp4a`)
        // over higher-bandwidth Dolby AC-3 / EC-3 and populates `referencedPlaylistURLs` for UI collapsing.
        let appleBipbopMaster = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",LANGUAGE="en",NAME="English",AUTOSELECT=YES,DEFAULT=YES,CHANNELS="2",URI="a1/prog_index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud2",LANGUAGE="en",NAME="English AC3",AUTOSELECT=YES,DEFAULT=YES,CHANNELS="6",URI="a2/prog_index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud3",LANGUAGE="en",NAME="English EC3",AUTOSELECT=YES,DEFAULT=YES,CHANNELS="6",URI="a3/prog_index.m3u8"
        #EXT-X-I-FRAME-STREAM-INF:AVERAGE-BANDWIDTH=183689,BANDWIDTH=187492,CODECS="avc1.640020",RESOLUTION=960x540,URI="v5/iframe_index.m3u8"
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2448647,BANDWIDTH=2484135,CODECS="avc1.640020,ac-3",RESOLUTION=960x540,FRAME-RATE=60.000,AUDIO="aud2"
        v5/prog_index.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2190673,BANDWIDTH=2227464,CODECS="avc1.640020,mp4a.40.2",RESOLUTION=960x540,FRAME-RATE=60.000,AUDIO="aud1"
        v5/prog_index.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2320647,BANDWIDTH=2356135,CODECS="avc1.640020,ec-3",RESOLUTION=960x540,FRAME-RATE=60.000,AUDIO="aud3"
        v5/prog_index.m3u8
        """
        let bipbopInspection = try CuriumHLSParser.parseMasterOrMedia(text: appleBipbopMaster, baseURL: appleMaster)
        #expect(bipbopInspection.isMasterPlaylist)
        #expect(bipbopInspection.variants.count == 1)
        let preferredVariant = try #require(bipbopInspection.variants.first)
        #expect(preferredVariant.url == appleVideoChild)
        #expect(preferredVariant.codecs == "avc1.640020,mp4a.40.2")
        #expect(preferredVariant.audioGroupID == "aud1")
        #expect(preferredVariant.audioURI == appleAudioChild)
        #expect(bipbopInspection.referencedPlaylistURLs.contains(appleVideoChild))
        #expect(bipbopInspection.referencedPlaylistURLs.contains(appleAudioChild))
        #expect(bipbopInspection.referencedPlaylistURLs.contains(
            try #require(URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/v5/iframe_index.m3u8"))
        ))
    }

    @Test("P0-1: Fixed proxy blackholes unconfigured HTTP/HTTPS slots, fails closed on https:// proxy scheme, and honors <-loopback>")
    func fixedProxyBlackholesMissingSlotsRejectsHTTPSProxyAndHonorsNegatedLoopback() throws {
        // Single-scheme http= must blackhole HTTPS to 127.0.0.1:1 so https:// never leaks direct.
        let httpOnly = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "http=10.0.0.1:8080", bypassRules: nil)
        ))
        #expect((httpOnly["HTTPEnable"] as? Int) == 1)
        #expect((httpOnly["HTTPProxy"] as? String) == "10.0.0.1")
        #expect((httpOnly["HTTPPort"] as? Int) == 8080)
        #expect((httpOnly["HTTPSEnable"] as? Int) == 1)
        #expect((httpOnly["HTTPSProxy"] as? String) == "127.0.0.1")
        #expect((httpOnly["HTTPSPort"] as? Int) == 1)

        // Single-scheme https= must blackhole HTTP to 127.0.0.1:1 so http:// never leaks direct.
        let httpsOnly = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "https=10.0.0.1:8443", bypassRules: nil)
        ))
        #expect((httpsOnly["HTTPSEnable"] as? Int) == 1)
        #expect((httpsOnly["HTTPSProxy"] as? String) == "10.0.0.1")
        #expect((httpsOnly["HTTPSPort"] as? Int) == 8443)
        #expect((httpsOnly["HTTPEnable"] as? Int) == 1)
        #expect((httpsOnly["HTTPProxy"] as? String) == "127.0.0.1")
        #expect((httpsOnly["HTTPPort"] as? Int) == 1)

        // Explicit `https://` TLS-to-proxy in a fallback list must fail closed instead of downgrading to plaintext.
        let httpsWithFallback = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "https://tls-proxy.internal:8443,http://cleartext-fallback:8080", bypassRules: nil)
        ))
        #expect((httpsWithFallback["SOCKSEnable"] as? Int) == 1)
        #expect((httpsWithFallback["SOCKSProxy"] as? String) == "127.0.0.1")
        #expect((httpsWithFallback["SOCKSPort"] as? Int) == 1)
        #expect(httpsWithFallback["HTTPProxy"] == nil)

        // Per-scheme https=https://tls-proxy fails closed on HTTPS while keeping explicit HTTP proxy.
        let mixedTLS = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "http=10.0.0.1:8080;https=https://tls-proxy.internal:8443", bypassRules: nil)
        ))
        #expect((mixedTLS["HTTPProxy"] as? String) == "10.0.0.1")
        #expect((mixedTLS["HTTPSProxy"] as? String) == "127.0.0.1")
        #expect((mixedTLS["HTTPSPort"] as? Int) == 1)

        // Unsupported ftp=socks5:// must not bind SOCKS for HTTP/HTTPS.
        let ftpSocks = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "ftp=socks5://10.0.0.9:1080", bypassRules: nil)
        ))
        #expect((ftpSocks["SOCKSProxy"] as? String) == "127.0.0.1")
        #expect((ftpSocks["SOCKSPort"] as? Int) == 1)

        // <-loopback> is stripped from ExceptionsList and removes explicit loopback bypasses.
        let loopbackOnly = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "socks5://127.0.0.1:1080", bypassRules: "<-loopback>")
        ))
        #expect(loopbackOnly["ExceptionsList"] == nil)

        let loopbackMixed = try #require(CuriumMediaNetworking.proxyDictionary(
            for: .fixed(rules: "socks5://127.0.0.1:1080", bypassRules: "localhost,127.0.0.1,[::1],sub.localhost,<-loopback>,*.internal")
        ))
        #expect((loopbackMixed["ExceptionsList"] as? [String]) == ["*.internal"])
    }

    @Test("P0-2: HostCookieCache scopes cookies by (scheme, host, directoryPath) and never leaks https cookies over http://")
    func hostCookieCacheEnforcesSchemeAndDirectoryPathScoping() async throws {
        let baseURL = try #require(URL(string: "https://media.example.com/private/v1/master.m3u8"))
        let sameDirSeg = try #require(URL(string: "https://media.example.com/private/v1/seg0.ts"))
        let downgradedHTTPSeg = try #require(URL(string: "http://media.example.com/private/v1/seg0.ts"))
        let siblingPathSeg = try #require(URL(string: "https://media.example.com/public/seg0.ts"))
        let traversalSeg = try #require(URL(string: "https://media.example.com/private/v1/../../public/seg1.ts"))
        let nestedSubSeg0 = try #require(URL(string: "https://media.example.com/private/v1/sub/seg0.ts"))
        let nestedSubSeg1 = try #require(URL(string: "https://media.example.com/private/v1/sub/seg1.ts"))

        // 1. With no provider: only exact (scheme, host, directoryPath) reuses baseCookie; scheme/path drift fails closed to nil.
        let noProviderCache = CuriumMediaNetworking.HostCookieCache(
            baseURL: baseURL,
            baseCookie: "sid=secret_https_private",
            provider: nil
        )
        #expect(await noProviderCache.cookieHeader(for: sameDirSeg) == "sid=secret_https_private")
        #expect(await noProviderCache.cookieHeader(for: downgradedHTTPSeg) == nil)
        #expect(await noProviderCache.cookieHeader(for: siblingPathSeg) == nil)
        #expect(await noProviderCache.cookieHeader(for: traversalSeg) == nil)
        #expect(await noProviderCache.cookieHeader(for: nestedSubSeg0) == nil)

        // 2. With provider: same scope avoids @MainActor hop; scheme downgrade & path divergence re-query and cache per scope.
        let queriedURLs = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let cache = CuriumMediaNetworking.HostCookieCache(
            baseURL: baseURL,
            baseCookie: "sid=secret_https_private",
            provider: { url in
                queriedURLs.withLock { $0.append(url) }
                if url.scheme == "http" {
                    return "public_nonsecure=1"
                }
                if url.path.hasPrefix("/private/v1/sub/") {
                    return "sid=secret_https_private; sub=yes"
                }
                return "public_https=1"
            }
        )

        #expect(await cache.cookieHeader(for: sameDirSeg) == "sid=secret_https_private")
        #expect(queriedURLs.withLock { $0.isEmpty })

        #expect(await cache.cookieHeader(for: downgradedHTTPSeg) == "public_nonsecure=1")
        #expect(await cache.cookieHeader(for: siblingPathSeg) == "public_https=1")
        // Dot-segment path normalizes to `/public/`, hitting the `/public/` cache without re-querying.
        #expect(await cache.cookieHeader(for: traversalSeg) == "public_https=1")
        // Nested subpath queries once and caches for sibling segments in `/private/v1/sub/`.
        #expect(await cache.cookieHeader(for: nestedSubSeg0) == "sid=secret_https_private; sub=yes")
        #expect(await cache.cookieHeader(for: nestedSubSeg1) == "sid=secret_https_private; sub=yes")

        let allQueried = queriedURLs.withLock { $0 }
        #expect(allQueried.count == 3)
        #expect(allQueried[0] == downgradedHTTPSeg)
        #expect(allQueried[1] == siblingPathSeg)
        #expect(allQueried[2] == nestedSubSeg0)
    }

    @Test("Profile-audit P0-2 consumer: makeMediaRequestContext uses immutable frozen launch proxy across mid-session edits")
    @MainActor
    func makeMediaRequestContextUsesFrozenLaunchProxyAcrossMidSessionProfileEdits() async throws {
        defer { CuriumFingerprintBootstrap.resetStateForTesting() }

        let dir = try makeTempDir("curium-mr-frozen-proxy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let supportRoot = dir.appending(path: "Application Support", directoryHint: .isDirectory)
        let cachesRoot = dir.appending(path: "Caches", directoryHint: .isDirectory)
        let curiumRoot = dir.appending(path: "SharedCurium", directoryHint: .isDirectory)
        let fileURL = curiumRoot.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)

        let fpStore = CuriumFingerprintStore(
            fileURL: fileURL,
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot,
            curiumSupportRoot: curiumRoot
        )
        let launchProxy = CuriumProxyConfig.fixed(rules: "socks5://127.0.0.1:1080", bypassRules: nil)
        let work = try #require(
            fpStore.createProfile(
                fromTemplate: "macos-desktop",
                displayName: "Proxy Locked",
                proxy: launchProxy
            )
        )
        #expect(fpStore.selectProfile(id: work.id))

        let v2Caps = CuriumEngineFingerprintCapabilities(dictionary: [
            "contractVersion": 2,
            "supportedSchemaVersions": [1, 2],
            "maxConfigBytes": 65_536,
        ])
        let outcome = CuriumFingerprintBootstrap.prepareEngineLaunch(
            store: fpStore,
            capabilitiesProvider: { v2Caps },
            configureEngine: { data, _ in data != nil }
        )
        guard case .configured(let launchedID, _, _) = outcome else {
            Issue.record("Expected configured launch outcome, got \(outcome)")
            return
        }
        #expect(launchedID == work.id)

        let host = MockBrowserHost()
        let tab = MockTabHost(tabID: "t-proxy", url: URL(string: "https://media.example/watch"))
        host.tabs = [tab]
        host.activeTab = tab
        let browserStore = CuriumBrowserStore(
            host: host,
            activeProfileID: work.id,
            fingerprintStore: fpStore,
            restoreSession: false
        )

        // Mutate the active running profile's proxy in the store to `.direct` mid-session.
        var edited = try #require(fpStore.profile(id: work.id))
        edited.proxy = .direct
        #expect(fpStore.upsert(edited).isValid)
        #expect(fpStore.profile(id: work.id)?.proxy == .direct)

        // Both synchronous accessor and async makeMediaRequestContext MUST stay pinned to frozen launchProxy.
        #expect(browserStore.effectiveMediaLaunchProxy() == launchProxy)
        let context = await browserStore.makeMediaRequestContext(
            for: try #require(URL(string: "https://cdn.media.example/stream.m3u8")),
            candidate: nil,
            inTabID: "t-proxy"
        )
        #expect(context.proxy == launchProxy)
    }

    @Test("P1-3: Separate-audio HLS preserves URI-less DEFAULT=YES muxed audio, detects packed audio extensions, and surfaces mux failures")
    func hlsSeparateAudioMuxedDefaultPackedExtensionsAndFailureSurfacing() async throws {
        let baseURL = try #require(URL(string: "https://cdn.video.example/master.m3u8"))

        // 1. Secondary commentary URI appearing BEFORE muxed DEFAULT=YES (no URI) must NOT overwrite primary muxed track.
        let commentaryFirstMaster = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Commentary",DEFAULT=NO,AUTOSELECT=YES,URI="commentary.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Main",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,AUDIO="aud"
        1080p.m3u8
        """
        let inspection1 = try CuriumHLSParser.parseMasterOrMedia(text: commentaryFirstMaster, baseURL: baseURL)
        #expect(inspection1.variants.count == 1)
        #expect(inspection1.variants[0].audioGroupID == "aud")
        #expect(inspection1.variants[0].audioURI == nil)
        #expect(inspection1.referencedPlaylistURLs.contains(try #require(URL(string: "https://cdn.video.example/commentary.m3u8"))))

        // 2. Muxed DEFAULT=YES appearing BEFORE commentary URI must also stay nil.
        let defaultFirstMaster = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Main",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Spanish",DEFAULT=NO,AUTOSELECT=YES,URI="es.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,AUDIO="aud"
        1080p.m3u8
        """
        let inspection2 = try CuriumHLSParser.parseMasterOrMedia(text: defaultFirstMaster, baseURL: baseURL)
        #expect(inspection2.variants[0].audioURI == nil)
        #expect(inspection2.referencedPlaylistURLs.contains(try #require(URL(string: "https://cdn.video.example/es.m3u8"))))

        // 3. Packed audio extension detection (fMP4 -> .m4a, packed ADTS/AC-3/EC-3/MP3 -> native ext, TS -> .ts).
        for (segName, expectedExt) in [
            ("seg0.m4s", "m4a"),
            ("seg0.aac", "aac"),
            ("seg0.adts", "aac"),
            ("seg0.ac3", "ac3"),
            ("seg0.ec3", "ec3"),
            ("seg0.mp3", "mp3"),
            ("seg0.ts", "ts"),
        ] {
            let playlistText = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\n\(segName)\n#EXT-X-ENDLIST"
            let media = try CuriumHLSParser.parseMediaPlaylist(text: playlistText, baseURL: baseURL)
            #expect(CuriumHLSMediaDownloadTask.preferredAudioTrackExtension(for: media) == expectedExt)
        }

        // 4. muxFMP4Tracks surfaces audioMuxFailed cleanly on invalid media and rethrows CancellationError when cancelled.
        let dir = try makeTempDir("curium-mr-mux")
        defer { try? FileManager.default.removeItem(at: dir) }
        let badVideo = dir.appending(path: "bad.mp4", directoryHint: .notDirectory)
        let badAudio = dir.appending(path: "bad.m4a", directoryHint: .notDirectory)
        let outMux = dir.appending(path: "out.mp4", directoryHint: .notDirectory)
        try Data("not-an-mp4".utf8).write(to: badVideo)
        try Data("not-an-m4a".utf8).write(to: badAudio)

        do {
            try await CuriumHLSMediaDownloadTask.muxFMP4Tracks(videoURL: badVideo, audioURL: badAudio, outputURL: outMux)
            Issue.record("Expected muxFMP4Tracks to throw audioMuxFailed on unreadable inputs")
        } catch let error as CuriumMediaDownloadError {
            if case .audioMuxFailed = error {
                // Expected clean failure surfaced instead of silently saving mute video.
            } else {
                Issue.record("Expected .audioMuxFailed, got \(error)")
            }
        }

        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await CuriumHLSMediaDownloadTask.muxFMP4Tracks(videoURL: badVideo, audioURL: badAudio, outputURL: outMux)
        }
        do {
            try await cancelledTask.value
            Issue.record("Expected CancellationError when cancelled before muxing")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test("P1-4: CuriumBackgroundKeepAlive preserves WebRTC/PiP audio sessions, skips deactivation while playing, and respects .shouldResume")
    @MainActor
    func backgroundKeepAlivePreservesWebRTCAndPiPAndRespectsShouldResume() {
        // Category preservation: never clobber WebRTC `.playAndRecord` or active PiP non-mixing `.playback`.
        #expect(CuriumBackgroundKeepAlive.shouldPreserveExistingAudioCategory(
            currentCategory: .playAndRecord,
            currentOptions: [],
            isMediaPlaying: false
        ))
        #expect(CuriumBackgroundKeepAlive.shouldPreserveExistingAudioCategory(
            currentCategory: .playback,
            currentOptions: [],
            isMediaPlaying: true
        ))
        #expect(!CuriumBackgroundKeepAlive.shouldPreserveExistingAudioCategory(
            currentCategory: .playback,
            currentOptions: [.mixWithOthers],
            isMediaPlaying: false
        ))
        #expect(!CuriumBackgroundKeepAlive.shouldPreserveExistingAudioCategory(
            currentCategory: .soloAmbient,
            currentOptions: [],
            isMediaPlaying: false
        ))

        // Session deactivation: skip `setActive(false)` while video/PiP is playing or WebRTC mic is active.
        #expect(!CuriumBackgroundKeepAlive.shouldDeactivateAudioSession(
            deactivateRequested: true,
            wasRunning: true,
            currentCategory: .playback,
            isMediaPlaying: true
        ))
        #expect(!CuriumBackgroundKeepAlive.shouldDeactivateAudioSession(
            deactivateRequested: true,
            wasRunning: true,
            currentCategory: .playAndRecord,
            isMediaPlaying: false
        ))
        #expect(CuriumBackgroundKeepAlive.shouldDeactivateAudioSession(
            deactivateRequested: true,
            wasRunning: true,
            currentCategory: .playback,
            isMediaPlaying: false
        ))
        #expect(!CuriumBackgroundKeepAlive.shouldDeactivateAudioSession(
            deactivateRequested: true,
            wasRunning: false,
            currentCategory: .playback,
            isMediaPlaying: false
        ))

        // Interruption end: honor `.shouldResume` instead of unconditionally restarting.
        #expect(!CuriumBackgroundKeepAlive.shouldResumeAfterInterruptionEnd(
            shouldBeActive: true,
            options: []
        ))
        #expect(CuriumBackgroundKeepAlive.shouldResumeAfterInterruptionEnd(
            shouldBeActive: true,
            options: [.shouldResume]
        ))
        #expect(!CuriumBackgroundKeepAlive.shouldResumeAfterInterruptionEnd(
            shouldBeActive: false,
            options: [.shouldResume]
        ))

        let playingState = OSAllocatedUnfairLock(initialState: true)
        let keepAlive = CuriumBackgroundKeepAlive(isMediaPlayingProvider: {
            playingState.withLock { $0 }
        })
        defer { keepAlive.stopImmediately() }
        keepAlive.setExternalMediaPlaybackActive(true)
        #expect(keepAlive.isExternalMediaActive)
        playingState.withLock { $0 = false }
        keepAlive.setExternalMediaPlaybackActive(false)
        #expect(!keepAlive.isExternalMediaActive)
        #expect(!keepAlive.isEngineRunning)
    }

    @Test("P1-5: SPA soft-navigation clears stale media caches on path/query changes while preserving #fragment jumps")
    @MainActor
    func spaSoftNavigationClearsMediaCachesWhileFragmentPreservesThem() throws {
        let host = MockBrowserHost()
        let videoA = try #require(URL(string: "https://spa.example/watch?v=alpha"))
        let tab = MockTabHost(tabID: "t-spa", url: videoA, title: "Alpha")
        host.tabs = [tab]
        host.activeTab = tab
        let store = CuriumBrowserStore(host: host, restoreSession: false)

        let streamA = try #require(URL(string: "https://cdn.spa.example/alpha/master.m3u8"))
        let streamB = try #require(URL(string: "https://cdn.spa.example/beta/master.m3u8"))
        _ = store.mediaRadar.ingest(
            rawEvent: ["url": streamA, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200],
            tabID: "t-spa",
            effectiveUserAgent: nil
        )
        #expect(store.mediaRadar.events(for: "t-spa").count == 1)

        // Fragment-only same-document navigation preserves captured media.
        store.browserHost(
            host,
            tab: tab,
            didCommitNavigationTo: try #require(URL(string: "https://spa.example/watch?v=alpha#t=30")),
            navigationID: 1,
            isSameDocument: true,
            isReload: false
        )
        #expect(store.mediaRadar.events(for: "t-spa").count == 1)

        // Same-document SPA query change (`pushState` to next video) clears stale media caches.
        store.browserHost(
            host,
            tab: tab,
            didCommitNavigationTo: try #require(URL(string: "https://spa.example/watch?v=beta")),
            navigationID: 2,
            isSameDocument: true,
            isReload: false
        )
        #expect(store.mediaRadar.events(for: "t-spa").isEmpty)

        // Same-document SPA path change also clears stale media caches.
        _ = store.mediaRadar.ingest(
            rawEvent: ["url": streamB, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200],
            tabID: "t-spa",
            effectiveUserAgent: nil
        )
        #expect(store.mediaRadar.events(for: "t-spa").count == 1)
        store.browserHost(
            host,
            tab: tab,
            didCommitNavigationTo: try #require(URL(string: "https://spa.example/shorts/gamma")),
            navigationID: 3,
            isSameDocument: true,
            isReload: false
        )
        #expect(store.mediaRadar.events(for: "t-spa").isEmpty)
    }

    @Test("P1-6: CuriumMediaRadar rejects .cmfv/.cmfa chunks and prevents MSE chunk floods from evicting HLS/DASH manifests")
    @MainActor
    func mediaRadarRejectsCMAFAndProtectsManifestsFromChunkEviction() throws {
        let cmfv = try #require(URL(string: "https://cdn.example/seg001.cmfv"))
        let cmfa = try #require(URL(string: "https://cdn.example/seg001.cmfa"))
        #expect(CuriumMediaResourceEvent.classify(url: cmfv, mimeType: "video/mp4", destination: "empty") == nil)
        #expect(CuriumMediaResourceEvent.classify(url: cmfa, mimeType: "audio/mp4", destination: "empty") == nil)

        let radar = CuriumMediaRadar()
        let hlsMaster = try #require(URL(string: "https://cdn.example/master.m3u8"))
        let dashManifest = try #require(URL(string: "https://cdn.example/manifest.mpd"))

        #expect(radar.ingest(
            rawEvent: ["url": hlsMaster, "mimeType": "application/vnd.apple.mpegurl", "httpMethod": "GET", "httpStatusCode": 200, "requestDestination": "empty"],
            tabID: "t-evict",
            effectiveUserAgent: nil
        ) != nil)
        #expect(radar.ingest(
            rawEvent: ["url": dashManifest, "mimeType": "application/dash+xml", "httpMethod": "GET", "httpStatusCode": 200, "requestDestination": "empty"],
            tabID: "t-evict",
            effectiveUserAgent: nil
        ) != nil)

        // Flood 100 unique MSE chunk URLs (exceeding maxEventsPerTab = 64).
        for idx in 0..<100 {
            let chunkURL = try #require(URL(string: "https://cdn.example/video.mp4?range=\(idx * 1024)-\((idx + 1) * 1024 - 1)"))
            let dest = idx.isMultiple(of: 2) ? "empty" : "other"
            _ = radar.ingest(
                rawEvent: ["url": chunkURL, "mimeType": "video/mp4", "httpMethod": "GET", "httpStatusCode": 206, "contentLength": 1024, "requestDestination": dest],
                tabID: "t-evict",
                effectiveUserAgent: nil
            )
        }

        let retained = radar.events(for: "t-evict")
        #expect(retained.count == CuriumMediaRadar.maxEventsPerTab)
        #expect(retained.contains(where: { $0.url == hlsMaster }))
        #expect(retained.contains(where: { $0.url == dashManifest }))
    }

    @Test("P1-7 & P1-8: 64 MiB segment cap, 86400s direct download timeout, and EXT-X-BYTERANGE 206/200 validation")
    func byteRangeValidationSegmentCapAndDirectDownloadTimeout() throws {
        #expect(CuriumHLSMediaDownloadTask.maxSegmentBytes == 64 * 1024 * 1024)
        #expect(CuriumDirectMediaDownloadTask.resourceTimeoutInterval == 86_400)

        let directSession = CuriumMediaNetworking.makeEphemeralSession(
            proxy: .direct,
            timeoutIntervalForResource: CuriumDirectMediaDownloadTask.resourceTimeoutInterval
        )
        defer { directSession.invalidateAndCancel() }
        #expect(directSession.configuration.timeoutIntervalForRequest == 30)
        #expect(directSession.configuration.timeoutIntervalForResource == 86_400)

        let fullPayload = Data(0..<20)

        // Exact 206 Partial Content succeeds.
        let ok206 = try CuriumMediaNetworking.validateByteRangeResponse(
            data: Data(10..<15),
            statusCode: 206,
            contentRangeHeader: "bytes 10-14/20",
            byteRange: (length: 5, offset: 10)
        )
        #expect(ok206 == Data(10..<15))

        // Truncated 206 fails closed.
        #expect(throws: CuriumMediaDownloadError.byteRangeMismatch(expected: 5, actual: 3)) {
            _ = try CuriumMediaNetworking.validateByteRangeResponse(
                data: Data(10..<13),
                statusCode: 206,
                contentRangeHeader: nil,
                byteRange: (length: 5, offset: 10)
            )
        }

        // Mismatched Content-Range start on 206 fails closed.
        #expect(throws: CuriumMediaDownloadError.byteRangeMismatch(expected: 5, actual: 5)) {
            _ = try CuriumMediaNetworking.validateByteRangeResponse(
                data: Data(0..<5),
                statusCode: 206,
                contentRangeHeader: "bytes 0-4/20",
                byteRange: (length: 5, offset: 10)
            )
        }

        // Full 200 OK slices exact [offset ..< offset + length].
        let sliced200 = try CuriumMediaNetworking.validateByteRangeResponse(
            data: fullPayload,
            statusCode: 200,
            byteRange: (length: 5, offset: 10)
        )
        #expect(sliced200 == Data(10..<15))

        // Truncated/out-of-bounds 200 OK fails closed.
        #expect(throws: CuriumMediaDownloadError.byteRangeMismatch(expected: 5, actual: 2)) {
            _ = try CuriumMediaNetworking.validateByteRangeResponse(
                data: Data(0..<12),
                statusCode: 200,
                byteRange: (length: 5, offset: 10)
            )
        }

        // Non-200/206 2xx status fails closed.
        #expect(throws: CuriumMediaDownloadError.byteRangeMismatch(expected: 5, actual: 0)) {
            _ = try CuriumMediaNetworking.validateByteRangeResponse(
                data: Data(),
                statusCode: 204,
                byteRange: (length: 5, offset: 0)
            )
        }
    }

    @Test("P2-9: Public-to-private SSRF guard blocks local/RFC1918/link-local/ULA targets while allowing loopback-to-loopback")
    @MainActor
    func publicToPrivateSSRFGuardBlocksLocalTargetsAndAllowsLoopbackToLoopback() async throws {
        // Private host classifier covers loopback, RFC 1918, link-local, CGNAT, ULA, IPv4-mapped IPv6, and legacy integer IPv4.
        for privateHost in [
            "127.0.0.1", "127.1", "2130706433", "0x7f000001", "localhost", "api.localhost", "box.local",
            "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1", "169.254.169.254",
            "100.64.0.1", "0.0.0.0", "::1", "[::1]", "fc00::1", "fd12:3456::1", "fe80::1%en0",
            "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:10.0.0.1",
        ] {
            #expect(CuriumHLSParser.isPrivateOrLocalHost(privateHost), "Expected private host for \(privateHost)")
        }
        for publicHost in ["cdn.example.com", "1.1.1.1", "8.8.8.8", "172.32.0.1", "2606:4700:4700::1111"] {
            #expect(!CuriumHLSParser.isPrivateOrLocalHost(publicHost), "Expected public host for \(publicHost)")
        }

        // Public HLS playlist referencing private variant/key/map/segment fails closed.
        let publicBase = try #require(URL(string: "https://cdn.example.com/master.m3u8"))
        for ssrfPlaylist in [
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nhttp://127.0.0.1:9222/json",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"http://169.254.169.254/latest/meta-data/\"\n#EXTINF:4.0,\nseg.ts\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXT-X-MAP:URI=\"http://192.168.1.1/init.mp4\"\n#EXTINF:4.0,\nseg.m4s\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXTINF:4.0,\nhttp://[fd00::1]/secret.ts\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXTINF:4.0,\nhttp://[::ffff:127.0.0.1]/secret.ts\n#EXT-X-ENDLIST",
        ] {
            #expect(throws: CuriumHLSParserError.self) {
                _ = try CuriumHLSParser.parseMasterOrMedia(text: ssrfPlaylist, baseURL: publicBase)
            }
        }

        // Loopback -> loopback HLS parsing remains allowed for local test servers.
        let localBase = try #require(URL(string: "http://127.0.0.1:18080/master.m3u8"))
        let localMedia = try CuriumHLSParser.parseMediaPlaylist(
            text: "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nhttp://127.0.0.1:18080/seg0.ts\n#EXT-X-ENDLIST",
            baseURL: localBase
        )
        #expect(localMedia.segments.count == 1)

        // Public -> private HTTP redirect is rejected; loopback -> loopback redirect is allowed.
        let publicPrev = try #require(URL(string: "https://cdn.example.com/video.mp4"))
        let privateRedirect = URLRequest(url: try #require(URL(string: "http://127.0.0.1:8080/internal")))
        let blocked = CuriumMediaNetworking.validateAndSanitizeRedirectRequest(
            privateRedirect,
            from: publicPrev,
            originatingHostIsPublic: true
        )
        #expect(blocked == .rejectedPrivateNetwork("127.0.0.1"))

        let localRedirect = CuriumMediaNetworking.validateAndSanitizeRedirectRequest(
            privateRedirect,
            from: localBase,
            originatingHostIsPublic: false
        )
        if case .allowed(let req, _) = localRedirect {
            #expect(req.url?.host == "127.0.0.1")
        } else {
            Issue.record("Expected loopback-to-loopback redirect to be allowed, got \(localRedirect)")
        }

        // Store download entry point blocks private target launched from a public tab.
        let host = MockBrowserHost()
        let publicTab = MockTabHost(tabID: "t-ssrf", url: URL(string: "https://public.example/watch"))
        host.tabs = [publicTab]
        host.activeTab = publicTab
        let store = CuriumBrowserStore(host: host, restoreSession: false)
        let evilCandidate = CuriumMediaCandidate(
            id: "http://127.0.0.1:9222/video.mp4",
            url: try #require(URL(string: "http://127.0.0.1:9222/video.mp4")),
            kind: .video,
            title: "Evil",
            host: "127.0.0.1",
            mimeType: "video/mp4",
            contentLength: 1024,
            resolutionLabel: nil,
            durationSeconds: nil,
            referrer: URL(string: "https://public.example/watch"),
            frameOrigin: "https://public.example",
            effectiveUserAgent: nil,
            fromDOM: true,
            fromNetwork: false
        )
        let started = await store.startMediaDownload(candidate: evilCandidate, inTabID: "t-ssrf")
        #expect(started == nil)
        #expect(store.errorMessage?.localizedCaseInsensitiveContains("private") == true)
    }

    @Test("P2-10: DOM probeScript backfills <source type> onto currentSrc, omits url:null blob entries, and walks open shadowRoots")
    func domProbeScriptBackfillsSourceTypeOmitsBlobEntriesAndWalksOpenShadowRoots() throws {
        let jsContext = try #require(JSContext())
        var jsException: String?
        jsContext.exceptionHandler = { _, exc in
            jsException = exc?.toString()
        }

        let harness = """
        const location = { href: "https://watch.example/page/index.html" };
        function URL(raw, base) {
          if (/^https?:\\/\\//i.test(raw)) { this.href = raw; return; }
          if (raw.startsWith("/")) { this.href = "https://watch.example" + raw; return; }
          this.href = "https://watch.example/page/" + raw;
        }
        function makeNode(tag, props, children, shadowRoot) {
          return Object.assign({
            tagName: tag.toUpperCase(),
            children: children || [],
            shadowRoot: shadowRoot || null,
            getAttribute(name) { return (this._attrs && this._attrs[name]) || null; },
            querySelectorAll(sel) {
              const wanted = sel.split(",").map(s => s.trim().toLowerCase());
              const out = [];
              const walk = (list) => {
                for (const item of list) {
                  if (wanted.includes("*") || wanted.includes((item.tagName || "").toLowerCase())) {
                    out.push(item);
                  }
                  if (item.children) walk(item.children);
                }
              };
              walk(this.children);
              return out;
            }
          }, props || {});
        }
        const hlsSource = makeNode("source", {
          src: "https://cdn.example/manifest-no-ext",
          type: "application/vnd.apple.mpegurl"
        });
        const hlsVideo = makeNode("video", {
          currentSrc: "https://cdn.example/manifest-no-ext",
          videoWidth: 1920,
          videoHeight: 1080,
          duration: 120
        }, [hlsSource]);
        const blobVideo = makeNode("video", {
          currentSrc: "blob:https://watch.example/1234-5678",
          videoWidth: 1280,
          videoHeight: 720,
          duration: 60
        });
        const innerShadowVideo = makeNode("video", {
          currentSrc: "https://cdn.example/shadow-player.mp4",
          videoWidth: 1920,
          videoHeight: 1080,
          duration: 45
        });
        const nestedShadowRoot = makeNode("div", {}, [innerShadowVideo]);
        const nestedHost = makeNode("mux-video", {}, [], nestedShadowRoot);
        const outerShadowRoot = makeNode("div", {}, [nestedHost]);
        const outerHost = makeNode("mux-player", {}, [], outerShadowRoot);
        const document = makeNode("document", {
          baseURI: "https://watch.example/page/index.html",
          title: "Shadow Player Demo"
        }, [hlsVideo, blobVideo, outerHost]);
        """
        jsContext.evaluateScript(harness)
        #expect(jsException == nil)

        let rawVal = jsContext.evaluateScript(CuriumMediaDOMScanner.probeScript)
        #expect(jsException == nil)
        let dict = try #require(rawVal?.toDictionary() as? [String: Any])
        let frame = CuriumIsolatedFrameEvalResult.parse(from: [
            "isMainFrame": NSNumber(value: true),
            "frameURL": try #require(URL(string: "https://watch.example/page/index.html")),
            "frameOrigin": "https://watch.example",
            "result": dict,
        ])

        let parsed = CuriumMediaDOMScanner.parseProbeResults([frame])
        #expect(parsed.pageTitle == "Shadow Player Demo")
        #expect(parsed.blobVideoCount == 1)
        // Only the 2 real HTTP(S) media URLs are in entries — zero `url: null` blob placeholders.
        #expect(parsed.entries.count == 2)
        #expect(!parsed.entries.contains { $0.isBlob || $0.url == nil })

        let hlsEntry = try #require(parsed.entries.first { $0.url?.absoluteString == "https://cdn.example/manifest-no-ext" })
        #expect(hlsEntry.mimeType == "application/vnd.apple.mpegurl")
        #expect(CuriumMediaResourceEvent.classify(
            url: try #require(hlsEntry.url),
            mimeType: hlsEntry.mimeType,
            destination: "video"
        ) == .hls)

        let shadowEntry = try #require(parsed.entries.first { $0.url?.absoluteString == "https://cdn.example/shadow-player.mp4" })
        #expect(shadowEntry.width == 1920)
        #expect(shadowEntry.height == 1080)
    }

    @Test("P2-11: Direct Origin omission, https->http Referer strip, cross-subdomain redirect cookies, mid-commit cancel, and child HLS collapse")
    @MainActor
    func redirectHeaderSanitizationStagedCommitCancelAndChildHLSCollapse() async throws {
        // 1. Direct media request omits Origin: and strips Referer on https -> http downgrade.
        let httpsVideo = try #require(URL(string: "https://cdn.example/clip.mp4"))
        let httpVideo = try #require(URL(string: "http://cdn.example/clip.mp4"))
        let ctx = CuriumMediaRequestContext(
            cookieHeader: "sid=1",
            userAgent: "Curium/1",
            referrer: URL(string: "https://watch.example/page"),
            origin: "https://watch.example",
            proxy: .direct
        )
        let directReq = CuriumMediaNetworking.makeRequest(url: httpsVideo, context: ctx, includeOrigin: false)
        #expect(directReq.value(forHTTPHeaderField: "Origin") == nil)
        #expect(directReq.value(forHTTPHeaderField: "Referer") == "https://watch.example/page")
        #expect(directReq.value(forHTTPHeaderField: "Cookie") == "sid=1")

        let downgradedInitialReq = CuriumMediaNetworking.makeRequest(url: httpVideo, context: ctx, includeOrigin: false)
        #expect(downgradedInitialReq.value(forHTTPHeaderField: "Referer") == nil)

        // 2. Redirect https -> http strips Referer & old Cookie; cross-subdomain redirect refreshes Cookie via cookieResolver.
        let prevHTTPS = try #require(URL(string: "https://www.example.com/watch/video"))
        var downgradeProposed = URLRequest(url: try #require(URL(string: "http://www.example.com/watch/video")))
        downgradeProposed.setValue("https://www.example.com/watch", forHTTPHeaderField: "Referer")
        downgradeProposed.setValue("secure_sid=secret", forHTTPHeaderField: "Cookie")

        let downgradeResult = await CuriumMediaNetworking.sanitizeRedirectRequest(
            downgradeProposed,
            from: prevHTTPS,
            originatingHostIsPublic: true,
            cookieResolver: { _ in nil }
        )
        if case .allowed(let sanitized, _) = downgradeResult {
            #expect(sanitized.value(forHTTPHeaderField: "Referer") == nil)
            #expect(sanitized.value(forHTTPHeaderField: "Cookie") == nil)
        } else {
            Issue.record("Expected allowed downgrade redirect with scrubbed headers, got \(downgradeResult)")
        }

        var crossSubdomainProposed = URLRequest(url: try #require(URL(string: "https://cdn.example.com/assets/movie.mp4")))
        crossSubdomainProposed.setValue("host_only_www=secret", forHTTPHeaderField: "Cookie")
        crossSubdomainProposed.setValue("https://www.example.com/watch", forHTTPHeaderField: "Referer")

        let subdomainResult = await CuriumMediaNetworking.sanitizeRedirectRequest(
            crossSubdomainProposed,
            from: prevHTTPS,
            originatingHostIsPublic: true,
            cookieResolver: { url in
                url.host == "cdn.example.com" ? "domain_auth=valid_for_cdn" : nil
            }
        )
        if case .allowed(let sanitized, _) = subdomainResult {
            #expect(sanitized.value(forHTTPHeaderField: "Cookie") == "domain_auth=valid_for_cdn")
            #expect(sanitized.value(forHTTPHeaderField: "Referer") == "https://www.example.com/watch")
        } else {
            Issue.record("Expected cross-subdomain redirect with refreshed cookie, got \(subdomainResult)")
        }

        // 3. CuriumDownload.cancel() cancels an in-flight staged-file commit after task.state == .completed.
        let commitDir = try makeTempDir("curium-mr-commit-cancel")
        defer { try? FileManager.default.removeItem(at: commitDir) }
        let committedDest = commitDir.appending(path: "movie.mp4", directoryHint: .notDirectory)

        let mockTask = MockDownloadTask(
            originalURL: httpsVideo,
            suggestedFilename: "movie.mp4",
            mimeType: "video/mp4",
            payloadToWrite: Data("video-bytes".utf8)
        )
        let download = CuriumDownload(task: mockTask)
        let gate = StagedCommitTestGate()
        download.stagedCommitHandlerOverride = { stagedURL, _ in
            await gate.markEnteredAndWaitForRelease()
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: stagedURL, to: committedDest)
            return committedDest
        }

        let startTask = Task { @MainActor in
            await download.start()
        }
        await gate.waitUntilEntered()
        #expect(mockTask.state == .completed)
        #expect(download.isActive)

        download.cancel()
        #expect(download.state == .cancelled)
        await gate.release()

        let savedURL = await startTask.value
        #expect(savedURL == nil)
        #expect(download.state == .cancelled)
        #expect(download.savedURL == nil)
        #expect(download.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: committedDest.path))

        // 4. CuriumMediaRadarSheet.computeSubsumedChildHLSIDs preserves standalone direct child downloads
        // across sheet reopen without un-subsuming a child already displayed inside a master's variant row.
        let masterURL = try #require(URL(string: "https://cdn.example/master.m3u8"))
        let variantURL = try #require(URL(string: "https://cdn.example/v5/prog_index.m3u8"))
        let audioChildURL = try #require(URL(string: "https://cdn.example/a1/prog_index.m3u8"))
        let masterInspection = CuriumHLSMasterInspection(
            sourceURL: masterURL,
            isMasterPlaylist: true,
            variants: [
                CuriumHLSVariant(
                    id: variantURL.absoluteString,
                    url: variantURL,
                    bandwidth: 2_000_000,
                    averageBandwidth: nil,
                    width: 1280,
                    height: 720,
                    codecs: "avc1.640020,mp4a.40.2",
                    frameRate: 30,
                    audioGroupID: "aud1",
                    audioURI: audioChildURL
                ),
            ],
            directSegmentCount: 0,
            estimatedDurationSeconds: nil,
            isLiveStream: false,
            isFMP4: true,
            encryption: .none,
            referencedPlaylistURLs: [variantURL, audioChildURL]
        )
        let loadedMasters = [masterURL.absoluteString: masterInspection]

        // No downloads: both variant and audio child are subsumed.
        let subsumedNone = CuriumMediaRadarSheet.computeSubsumedChildHLSIDs(
            loadedMasters: loadedMasters,
            localDownloadsByTargetKey: [:],
            storeDownloads: []
        )
        #expect(subsumedNone == [variantURL.absoluteString, audioChildURL.absoluteString])

        // Master-variant download (across sheet reopen -> empty localDownloadsByTargetKey): variant STAYS subsumed!
        let masterVariantDownload = CuriumDownload(
            task: CuriumHLSMediaDownloadTask(
                playlistURL: variantURL,
                audioPlaylistURL: audioChildURL,
                masterPlaylistURL: masterURL,
                suggestedFilename: "Clip (720p).mp4",
                context: ctx
            )
        )
        let subsumedMasterVariant = CuriumMediaRadarSheet.computeSubsumedChildHLSIDs(
            loadedMasters: loadedMasters,
            localDownloadsByTargetKey: [:],
            storeDownloads: [masterVariantDownload]
        )
        #expect(subsumedMasterVariant.contains(variantURL.absoluteString))
        #expect(subsumedMasterVariant.contains(audioChildURL.absoluteString))

        // Standalone direct child download (masterPlaylistURL == nil) across sheet reopen: NOT subsumed!
        let standaloneVariantDownload = CuriumDownload(
            task: CuriumHLSMediaDownloadTask(
                playlistURL: variantURL,
                audioPlaylistURL: nil,
                masterPlaylistURL: nil,
                suggestedFilename: "prog_index.ts",
                context: ctx
            )
        )
        let standaloneAudioDownload = CuriumDownload(
            task: CuriumHLSMediaDownloadTask(
                playlistURL: audioChildURL,
                audioPlaylistURL: nil,
                masterPlaylistURL: nil,
                suggestedFilename: "audio.m4a",
                context: ctx
            )
        )
        let subsumedStandalone = CuriumMediaRadarSheet.computeSubsumedChildHLSIDs(
            loadedMasters: loadedMasters,
            localDownloadsByTargetKey: [:],
            storeDownloads: [standaloneVariantDownload, standaloneAudioDownload]
        )
        #expect(!subsumedStandalone.contains(variantURL.absoluteString))
        #expect(!subsumedStandalone.contains(audioChildURL.absoluteString))
    }

    @Test("Oracle P1: Untrusted Content-Range, BYTERANGE, MEDIA-SEQUENCE, and RESOLUTION values fail safely without integer overflow traps")
    func untrustedMediaHeadersAndPlaylistsResistIntegerOverflow() throws {
        // 1. Content-Range: bytes 0-Int.max/* fails closed without trapping in validateByteRangeResponse.
        #expect(throws: CuriumMediaDownloadError.byteRangeMismatch(expected: 16, actual: Int.max)) {
            _ = try CuriumMediaNetworking.validateByteRangeResponse(
                data: Data(repeating: 0xAA, count: 16),
                statusCode: 206,
                contentRangeHeader: "bytes 0-9223372036854775807/*",
                byteRange: (length: 16, offset: 0)
            )
        }

        // 2. Explicit #EXT-X-BYTERANGE overflow throws .invalidPlaylist without trapping.
        let baseURL = try #require(URL(string: "https://cdn.example/video.m3u8"))
        let explicitOverflowPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:16@9223372036854775800
        seg.mp4
        #EXT-X-ENDLIST
        """
        #expect(throws: CuriumHLSParserError.self) {
            _ = try CuriumHLSParser.parseMediaPlaylist(text: explicitOverflowPlaylist, baseURL: baseURL)
        }

        // 3. Chained implicit #EXT-X-BYTERANGE overflow throws .invalidPlaylist without trapping.
        let chainedOverflowPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:100@9223372036854775700
        seg.mp4
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:100
        seg.mp4
        #EXT-X-ENDLIST
        """
        #expect(throws: CuriumHLSParserError.self) {
            _ = try CuriumHLSParser.parseMediaPlaylist(text: chainedOverflowPlaylist, baseURL: baseURL)
        }

        // 4. #EXT-X-MAP BYTERANGE overflow throws .invalidPlaylist without trapping.
        let mapOverflowPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="16@9223372036854775800"
        #EXTINF:4.0,
        seg.m4s
        #EXT-X-ENDLIST
        """
        #expect(throws: CuriumHLSParserError.self) {
            _ = try CuriumHLSParser.parseMediaPlaylist(text: mapOverflowPlaylist, baseURL: baseURL)
        }

        // 5. #EXT-X-MEDIA-SEQUENCE near Int.max with multiple segments throws cleanly.
        let seqOverflowPlaylist = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:9223372036854775807
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        seg0.ts
        #EXTINF:4.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        #expect(throws: CuriumHLSParserError.self) {
            _ = try CuriumHLSParser.parseMediaPlaylist(text: seqOverflowPlaylist, baseURL: baseURL)
        }

        // 6. Extreme RESOLUTION=4000000000x4000000000 is bounded out rather than trapping during variant sort.
        let hugeResMaster = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=4000000000x4000000000
        huge.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
        hd.m3u8
        """
        let masterInspection = try CuriumHLSParser.parseMasterOrMedia(
            text: hugeResMaster,
            baseURL: try #require(URL(string: "https://cdn.example/master.m3u8"))
        )
        #expect(masterInspection.variants.count == 2)
        #expect(masterInspection.variants[0].url.lastPathComponent == "hd.m3u8")
        #expect(masterInspection.variants[0].width == 1920)
        #expect(masterInspection.variants[1].url.lastPathComponent == "huge.m3u8")
        #expect(masterInspection.variants[1].width == nil)
        #expect(masterInspection.variants[1].height == nil)

        // 7. DOM probe results with huge dimensions (including > Int.max floats) drop cleanly and merge sorts without overflow.
        let frame = CuriumIsolatedFrameEvalResult.parse(from: [
            "isMainFrame": NSNumber(value: true),
            "frameURL": try #require(URL(string: "https://watch.example/")),
            "frameOrigin": "https://watch.example",
            "result": [
                "pageTitle": "Overflow Test",
                "blobVideoCount": 0,
                "entries": [
                    [
                        "url": "https://cdn.example/huge.mp4",
                        "tag": "video",
                        "width": 1.0e30,
                        "height": 1.0e30,
                    ],
                    [
                        "url": "https://cdn.example/big.mp4",
                        "tag": "video",
                        "width": 4_000_000_000.0,
                        "height": 4_000_000_000.0,
                    ],
                ],
            ] as [String: Any],
        ])
        let parsedDOM = CuriumMediaDOMScanner.parseProbeResults([frame])
        #expect(parsedDOM.entries.count == 2)
        #expect(parsedDOM.entries.allSatisfy { $0.width == nil && $0.height == nil })

        let syntheticHuge = CuriumDOMMediaEntry(
            url: URL(string: "https://cdn.example/synthetic-a.mp4"),
            isBlob: false,
            tag: "video",
            title: "A",
            width: 4_000_000_000,
            height: 4_000_000_000,
            durationSeconds: 10,
            frameURL: nil,
            frameOrigin: nil,
            mimeType: "video/mp4"
        )
        let syntheticNormal = CuriumDOMMediaEntry(
            url: URL(string: "https://cdn.example/synthetic-b.mp4"),
            isBlob: false,
            tag: "video",
            title: "B",
            width: 1920,
            height: 1080,
            durationSeconds: 10,
            frameURL: nil,
            frameOrigin: nil,
            mimeType: "video/mp4"
        )
        let merged = CuriumMediaDOMScanner.merge(
            tabID: "t-overflow",
            pageTitle: "Overflow",
            networkEvents: [],
            domEntries: [syntheticHuge, syntheticNormal],
            blobVideoCount: 0,
            effectiveUserAgent: nil
        )
        #expect(merged.candidates.count == 2)
    }

    @Test("Oracle P2: Public frameOrigin enforces SSRF guard across about:srcdoc, about:blank, and no-referrer")
    @MainActor
    func publicFrameOriginEnforcesSSRFGuardAcrossAboutBlankAndSrcdoc() async throws {
        let localVideoURL = try #require(URL(string: "http://127.0.0.1:8080/internal.mp4"))
        let localHLSURL = try #require(URL(string: "http://127.0.0.1:8080/internal.m3u8"))
        let srcdocURL = try #require(URL(string: "about:srcdoc"))
        let blankURL = try #require(URL(string: "about:blank"))

        // 1. Direct isOriginatingHostPublic recognizes public origin even when referrer is nil or about:srcdoc.
        #expect(CuriumMediaNetworking.isOriginatingHostPublic(
            url: localVideoURL,
            referrer: nil,
            origin: "https://evil.example"
        ))
        #expect(CuriumMediaNetworking.isOriginatingHostPublic(
            url: localVideoURL,
            referrer: srcdocURL,
            origin: "https://evil.example"
        ))
        // Loopback origin -> loopback target remains allowed.
        #expect(!CuriumMediaNetworking.isOriginatingHostPublic(
            url: localVideoURL,
            referrer: nil,
            origin: "http://127.0.0.1:8080"
        ))

        // 2. Store inspectHLSStream, startMediaDownload (direct + separate audioURI), and makeMediaRequestContext
        //    enforce private-network blocking when tab is about:blank and referrer is about:srcdoc/nil.
        let host = MockBrowserHost()
        let blankTab = MockTabHost(tabID: "t-srcdoc", url: blankURL)
        host.tabs = [blankTab]
        host.activeTab = blankTab
        let store = CuriumBrowserStore(host: host, restoreSession: false)

        let srcdocHLSCandidate = CuriumMediaCandidate(
            id: localHLSURL.absoluteString,
            url: localHLSURL,
            kind: .hls,
            title: "Srcdoc SSRF",
            host: "127.0.0.1",
            mimeType: "application/vnd.apple.mpegurl",
            contentLength: -1,
            resolutionLabel: nil,
            durationSeconds: nil,
            referrer: srcdocURL,
            frameOrigin: "https://evil.example",
            effectiveUserAgent: nil,
            fromDOM: true,
            fromNetwork: false
        )

        do {
            _ = try await store.inspectHLSStream(for: srcdocHLSCandidate, inTabID: "t-srcdoc")
            Issue.record("Expected inspectHLSStream to reject private target from public frameOrigin")
        } catch let error as CuriumMediaDownloadError {
            #expect(error == .blockedPrivateNetworkHost("127.0.0.1"))
        }

        let blockedDirect = await store.startMediaDownload(candidate: srcdocHLSCandidate, inTabID: "t-srcdoc")
        #expect(blockedDirect == nil)
        #expect(store.errorMessage?.localizedCaseInsensitiveContains("private") == true)

        // Private audioURI on an otherwise public-frameOrigin variant is also blocked.
        let publicVariantURL = try #require(URL(string: "https://cdn.evil.example/video.m3u8"))
        let privateAudioURL = try #require(URL(string: "http://127.0.0.1:9222/audio.m3u8"))
        let publicHLSCandidate = CuriumMediaCandidate(
            id: publicVariantURL.absoluteString,
            url: publicVariantURL,
            kind: .hls,
            title: "Audio SSRF",
            host: "cdn.evil.example",
            mimeType: "application/vnd.apple.mpegurl",
            contentLength: -1,
            resolutionLabel: nil,
            durationSeconds: nil,
            referrer: nil,
            frameOrigin: "https://evil.example",
            effectiveUserAgent: nil,
            fromDOM: true,
            fromNetwork: false
        )
        let privateAudioVariant = CuriumHLSVariant(
            id: publicVariantURL.absoluteString,
            url: publicVariantURL,
            bandwidth: 1_000_000,
            averageBandwidth: nil,
            width: 1280,
            height: 720,
            codecs: nil,
            frameRate: nil,
            audioGroupID: "aud",
            audioURI: privateAudioURL
        )
        store.errorMessage = nil
        let blockedAudio = await store.startMediaDownload(
            candidate: publicHLSCandidate,
            hlsVariant: privateAudioVariant,
            inTabID: "t-srcdoc"
        )
        #expect(blockedAudio == nil)
        #expect(store.errorMessage?.localizedCaseInsensitiveContains("private") == true)

        // makeMediaRequestContext preserves public origin while omitting non-HTTP about:srcdoc Referer.
        let ctx = await store.makeMediaRequestContext(
            for: localHLSURL,
            candidate: srcdocHLSCandidate,
            inTabID: "t-srcdoc"
        )
        #expect(ctx.referrer == nil)
        #expect(ctx.origin == "https://evil.example")
        do {
            _ = try await CuriumMediaNetworking.inspectHLS(url: localHLSURL, context: ctx)
            Issue.record("Expected CuriumMediaNetworking.inspectHLS to reject private target via context.origin")
        } catch let error as CuriumMediaDownloadError {
            #expect(error == .blockedPrivateNetworkHost("127.0.0.1"))
        }
    }

    @Test("Oracle P2: Customized Personal booted via selectedProfileID == nil reports pending engine restart instead of silent ACTIVE")
    @MainActor
    func customizedPersonalWithNilSelectionReportsPendingEngineRestart() throws {
        defer { CuriumFingerprintBootstrap.resetStateForTesting() }

        let dir = try makeTempDir("curium-personal-nil-restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let supportRoot = dir.appending(path: "Application Support", directoryHint: .isDirectory)
        let cachesRoot = dir.appending(path: "Caches", directoryHint: .isDirectory)
        let curiumRoot = dir.appending(path: "SharedCurium", directoryHint: .isDirectory)
        let fileURL = curiumRoot.appending(path: CuriumFingerprintStore.fileName, directoryHint: .notDirectory)

        let store = CuriumFingerprintStore(
            fileURL: fileURL,
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot,
            curiumSupportRoot: curiumRoot
        )

        // 1. Unmodified Personal booted on a Build 42 engine with selectedProfileID == nil has no pending restart.
        let v2Caps = CuriumEngineFingerprintCapabilities(dictionary: [
            "contractVersion": 2,
            "supportedSchemaVersions": [1, 2],
            "maxConfigBytes": 65536,
        ])
        let cleanOutcome = CuriumFingerprintBootstrap.prepareEngineLaunch(
            store: store,
            capabilitiesProvider: { v2Caps },
            configureEngine: { _, _ in true }
        )
        #expect(cleanOutcome == .configured(profileID: "default", revision: 1, nativeHardware: false))
        #expect(!store.hasPendingActiveProfileEngineChanges)
        #expect(!store.hasPendingProfileSwitch)

        // 2. Customize Personal with a Fixed Proxy mid-session -> immediately flags pending engine restart.
        var personal = try #require(store.profile(id: "default"))
        let customProxy = CuriumProxyConfig.fixed(rules: "socks5://127.0.0.1:1080", bypassRules: nil)
        personal.proxy = customProxy
        #expect(store.upsert(personal).isValid)
        #expect(store.hasPendingActiveProfileEngineChanges)
        #expect(store.hasPendingProfileSwitch)

        // 3. After relaunching with the updated Personal profile, pending restart clears and activeLaunchProxy updates.
        let relaunchedOutcome = CuriumFingerprintBootstrap.prepareEngineLaunch(
            store: store,
            capabilitiesProvider: { v2Caps },
            configureEngine: { _, _ in true }
        )
        #expect(relaunchedOutcome == .configured(profileID: "default", revision: 2, nativeHardware: false))
        #expect(CuriumFingerprintBootstrap.activeLaunchProxy == customProxy)
        #expect(!store.hasPendingActiveProfileEngineChanges)
        #expect(!store.hasPendingProfileSwitch)
    }

    @Test("Start Page: CuriumSiteIdentity strips noisy prefixes, fixes W monograms, and gates Favorite URLs")
    func startPageSiteIdentityMonogramAndURLValidation() throws {
        // Fixes the legacy "W" monogram bug across www./m./mobile. hosts while keeping meaningful subdomains.
        #expect(CuriumSiteIdentity.cleanHost(from: "www.nytimes.com") == "nytimes.com")
        #expect(CuriumSiteIdentity.cleanHost(from: "M.Wikipedia.org") == "Wikipedia.org")
        #expect(CuriumSiteIdentity.cleanHost(from: "mobile.twitter.com") == "twitter.com")
        #expect(CuriumSiteIdentity.cleanHost(from: "docs.google.com") == "docs.google.com")
        #expect(CuriumSiteIdentity.monogramInitial(forHost: "www.nytimes.com") == "N")
        #expect(CuriumSiteIdentity.monogramInitial(forHost: "www.apple.com") == "A")
        #expect(CuriumSiteIdentity.monogramInitial(forHost: "docs.google.com") == "D")
        #expect(CuriumSiteIdentity.monogramInitial(forHost: "news.ycombinator.com") == "N")

        // Filters transient bot-challenge / redirect boilerplate titles back to cleanHost.
        #expect(CuriumSiteIdentity.displayTitle(rawTitle: "Just a moment...", cleanHost: "vimeo.com") == "vimeo.com")
        #expect(CuriumSiteIdentity.displayTitle(rawTitle: "Attention Required! | Cloudflare", cleanHost: "example.com") == "example.com")
        #expect(CuriumSiteIdentity.displayTitle(rawTitle: "https://vimeo.com/123", cleanHost: "vimeo.com") == "vimeo.com")
        #expect(CuriumSiteIdentity.displayTitle(rawTitle: "Shaka Player Demo", cleanHost: "shaka-project.github.io") == "Shaka Player Demo")

        // Canonical host key preserves non-default ports and ignores default 80/443.
        #expect(CuriumSiteIdentity.canonicalSiteKey(for: try #require(URL(string: "https://www.example.com:443/a"))) == "example.com")
        #expect(CuriumSiteIdentity.canonicalSiteKey(for: try #require(URL(string: "http://m.example.com:80/b"))) == "example.com")
        #expect(CuriumSiteIdentity.canonicalSiteKey(for: try #require(URL(string: "http://localhost:8080/app"))) == "localhost:8080")
        #expect(CuriumSiteIdentity.canonicalSiteKey(for: try #require(URL(string: "file:///etc/hosts"))) == nil)

        // Favorite URL normalization prepends https:// and rejects non-HTTP(S) schemes & junk input.
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "news.ycombinator.com")?.absoluteString == "https://news.ycombinator.com")
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "http://localhost:3000/dev")?.absoluteString == "http://localhost:3000/dev")
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "localhost:8080")?.absoluteString == "https://localhost:8080")
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "127.0.0.1:9000")?.absoluteString == "https://127.0.0.1:9000")
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "javascript:alert(1)") == nil)
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "data:text/html,hi") == nil)
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "file:///tmp/a.html") == nil)
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "not a url") == nil)
        #expect(CuriumSiteIdentity.normalizedFavoriteURL(from: "singleword") == nil)
    }

    @Test("Start Page: conciseStartPostureSummary emits at most 3 editorial tokens")
    func startPageConcisePostureSummary() throws {
        let personal = CuriumFingerprintStore.makeDefaultPersonalProfile(preserveLegacyDefaults: false)
        #expect(personal.conciseStartPostureSummary == "macOS 158 · Custom HW")

        var nativeOverrideOff = personal
        nativeOverrideOff.desktop.webglVendor = nil
        nativeOverrideOff.desktop.webglRenderer = nil
        nativeOverrideOff.mobile.webglVendor = nil
        nativeOverrideOff.mobile.webglRenderer = nil
        nativeOverrideOff.hardware = .native
        #expect(nativeOverrideOff.conciseStartPostureSummary == "macOS 158")

        let macTemplate = try #require(CuriumProfileTemplate.template(for: "macos-desktop"))
        let macProxied = macTemplate.instantiate(
            id: "p-mac01",
            displayName: "Work Mac",
            enableFarbling: true,
            proxy: .fixed(rules: "socks5://127.0.0.1:1080", bypassRules: nil)
        )
        #expect(macProxied.conciseStartPostureSummary == "macOS 158 · Farbled · Proxy")

        let macCustomDirect = macTemplate.instantiate(
            id: "p-mac02",
            displayName: "Mac Clean",
            enableFarbling: false,
            hardwareVariantID: "macos-desktop-m3-8c-16g-1512x982",
            proxy: .direct
        )
        #expect(macCustomDirect.conciseStartPostureSummary == "macOS 158 · Custom HW · Direct")
    }

    @Test("Start Page: CuriumLibrary.frequentSites ranks by frecency, deduplicates Favorites/hosts, and deletes cleanly")
    @MainActor
    func startPageFrequentSitesFrecencyDedupAndDelete() async throws {
        let dir = try makeTempDir("curium-start-frequent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appending(path: "curium.sqlite", directoryHint: .notDirectory)
        let library = CuriumLibrary(profileID: "p-freq", database: CuriumDatabase(databaseURL: dbURL, profileID: "p-freq"))

        let favURL = try #require(URL(string: "https://www.apple.com/"))
        let dupFavMobile = try #require(URL(string: "https://m.apple.com/iphone"))
        let topURL1 = try #require(URL(string: "https://www.nytimes.com/section/tech"))
        let topURL2 = try #require(URL(string: "https://nytimes.com/"))
        let secondURL = try #require(URL(string: "https://news.ycombinator.com/"))

        #expect(await library.saveBookmark(url: favURL, title: "Apple", in: CuriumBookmarkFolder.favoritesID))
        library.recordVisit(url: dupFavMobile, title: "Apple Mobile")
        library.recordVisit(url: topURL1, title: "NYT Tech")
        library.recordVisit(url: topURL1, title: "NYT Tech")
        library.recordVisit(url: topURL1, title: "NYT Tech")
        library.recordVisit(url: topURL2, title: "NYT Home")
        library.recordVisit(url: secondURL, title: "Hacker News")

        // Ensure all enqueued SQLite writes flush before querying.
        await library.checkpointAsync()

        let frequent = await library.frequentSites(limit: 6)
        // Apple (including m.apple.com) is excluded because www.apple.com is in Favorites;
        // www.nytimes.com & nytimes.com collapse to 1 canonical host entry ahead of HN.
        #expect(frequent.count == 2)
        #expect(frequent[0].cleanHost == "nytimes.com")
        #expect(frequent[0].visitCount == 3)
        #expect(frequent[1].cleanHost == "news.ycombinator.com")

        // Removing the top URL removes only that site row (non-destructive to other pages on the host),
        // promoting the remaining nytimes.com URL; removing that second URL clears the host completely.
        await library.deleteSite(frequent[0])
        let afterFirstDelete = await library.frequentSites(limit: 6)
        #expect(afterFirstDelete.count == 2)
        #expect(afterFirstDelete.contains(where: { $0.url == topURL2 }))
        #expect(!afterFirstDelete.contains(where: { $0.url == topURL1 }))

        let remainingNYT = try #require(afterFirstDelete.first(where: { $0.url == topURL2 }))
        await library.deleteSite(remainingNYT)
        let afterSecondDelete = await library.frequentSites(limit: 6)
        #expect(afterSecondDelete.count == 1)
        #expect(afterSecondDelete[0].cleanHost == "news.ycombinator.com")
    }

    @Test("Start Page: CuriumStartPageLayoutMetrics locks 161pt/334pt fold-invariant leaves across Flat and Book Pose")
    func startPageLayoutMetricsFoldInvariance() {
        // 1. Inner Landscape Flat (`867 pt` safe width inside 84 pt vertical bar): 680 pt spread -> 161 pt / 334 pt.
        let flat = CuriumStartPageLayoutMetrics.resolve(
            bounds: CGRect(x: 0, y: 0, width: 867, height: 669),
            fold: nil
        )
        #expect(!flat.isDualLeafBookPose)
        #expect(flat.spreadWidth == 680)
        #expect(flat.favoriteColumns == 4)
        #expect(flat.favoriteCardWidth == 161)
        #expect(flat.recentColumns == 2)
        #expect(flat.recentCardWidth == 334)

        // 2. Inner Landscape Book Pose (`.division` at x=455.5..495.5): exact same 161 pt / 334 pt cards, 72 pt gutter.
        let book = CuriumStartPageLayoutMetrics.resolve(
            bounds: CGRect(x: 0, y: 0, width: 867, height: 669),
            fold: .init(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isVertical: true)
        )
        #expect(book.isDualLeafBookPose)
        #expect(book.leafWidth == 334)
        #expect(book.hingeGutter == 72)
        #expect(book.favoriteColumns == 4)
        #expect(book.favoriteCardWidth == flat.favoriteCardWidth)
        #expect(book.recentColumns == 2)
        #expect(book.recentCardWidth == flat.recentCardWidth)
        #expect(book.leadingInset == 105.5)
        #expect(book.trailingInset == 21.5)

        // 3. Outer Portrait (`382 pt`): 2 Favorite cols, 1 Recent col, stacked header.
        let outer = CuriumStartPageLayoutMetrics.resolve(
            bounds: CGRect(x: 0, y: 0, width: 382, height: 678),
            fold: nil
        )
        #expect(!outer.isWideHeader)
        #expect(outer.favoriteColumns == 2)
        #expect(outer.recentColumns == 1)
        #expect(outer.spreadWidth == 342)

        // 4. Inner Portrait Tabletop Pose (horizontal `.division` y=455.5..495.5): bounded to upper pane.
        let tabletop = CuriumStartPageLayoutMetrics.resolve(
            bounds: CGRect(x: 0, y: 0, width: 669, height: 951),
            fold: .init(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), isVertical: false)
        )
        #expect(tabletop.viewport.height == 443.5)
        #expect(tabletop.favoriteColumns == 4)
        #expect(tabletop.recentColumns == 2)

        // 5. Dynamic Type Accessibility sizes halve column counts cleanly.
        let a11y = CuriumStartPageLayoutMetrics.resolve(
            bounds: CGRect(x: 0, y: 0, width: 867, height: 669),
            fold: nil,
            isAccessibilitySize: true
        )
        #expect(a11y.favoriteColumns == 2)
        #expect(a11y.recentColumns == 1)
    }
}
