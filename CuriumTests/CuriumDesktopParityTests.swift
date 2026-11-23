import CuriumEngineContract
import Foundation
import JavaScriptCore
import Testing

private final class MockHiddenDesktopParityManager: NSObject, CrIOSExtensionManagingV1 {
    var entries: [[String: Any]] = []
    var actionSnapshots: [String: [String: Any]] = [:]
    var blockedCounts: [String: NSNumber] = [:]
    var actionCalls: [(String, Int32)] = []
    var blockedCountCalls: [(String, Int32)] = []
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
        blockedCountCalls.append((extensionID, tabID))
        return blockedCounts[extensionID] ?? 0
    }

    func popupForExtension(withID extensionID: String, tabID: Int32) throws -> any CrIOSExtensionPopupHostingV1 {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }

    func commandsForExtension(withID extensionID: String) throws -> [[String: String]] { [] }
    func dispatchCommandNamed(_ commandName: String, toExtensionWithID extensionID: String) throws {}
}

private final class MockTrustedDesktopParityManager: NSObject, CrIOSExtensionManagingV1, @unchecked Sendable {
    let trustedRootPath: String
    var entries: [[String: Any]] = []
    var installAttempts = 0
    var failFirstInstallWithRestoring = false
    var returnInitiallyEnabled = true
    var lastInstalledDirectoryPath: String?
    var setEnabledCalls: [(String, Bool)] = []

    init(trustedRootPath: String) {
        self.trustedRootPath = trustedRootPath
        super.init()
    }

    func extensions() throws -> [[String: Any]] { entries }

    func setExtensionWithID(_ extensionId: String?, enabled: Bool) throws {
        guard let extensionId else { return }
        setEnabledCalls.append((extensionId, enabled))
        if let idx = entries.firstIndex(where: { ($0["id"] as? String) == extensionId }) {
            entries[idx]["enabled"] = enabled
        }
    }

    @objc(trustedUnpackedExtensionsDirectoryWithError:)
    func trustedUnpackedExtensionsDirectory() throws -> String {
        trustedRootPath
    }

    @objc(installExtensionFromTrustedDirectory:completion:)
    func installExtension(
        fromTrustedDirectory directoryPath: String,
        completion: @escaping ([String: Any]?, NSError?) -> Void
    ) {
        installAttempts += 1
        lastInstalledDirectoryPath = directoryPath
        if failFirstInstallWithRestoring && installAttempts == 1 {
            let err = NSError(
                domain: "CrIOSExtensionManagerErrorDomain",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Chromium is restoring installed extensions."]
            )
            completion(nil, err)
            return
        }
        let entry: [String: Any] = [
            "id": CuriumDesktopParityExtension.extensionID,
            "name": "Curium Desktop Parity",
            "version": CuriumDesktopParityExtension.manifestVersion,
            "enabled": returnInitiallyEnabled,
        ]
        if let idx = entries.firstIndex(where: { ($0["id"] as? String) == CuriumDesktopParityExtension.extensionID }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        completion(entry, nil)
    }

    func actionPresentationForExtension(withID extensionID: String, tabID: Int32) throws -> [String: Any] { [:] }
    func observeActionPresentationChanges(handler: @escaping @MainActor (String?) -> Void) -> (any NSObjectProtocol)? { NSObject() }
    func blockedRequestCountForExtension(withID extensionID: String, tabID: Int32) throws -> NSNumber { 0 }
    func popupForExtension(withID extensionID: String, tabID: Int32) throws -> any CrIOSExtensionPopupHostingV1 {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }
    func commandsForExtension(withID extensionID: String) throws -> [[String: String]] { [] }
    func dispatchCommandNamed(_ commandName: String, toExtensionWithID extensionID: String) throws {}
}

@Suite("Built-in Desktop Parity Extension")
struct CuriumDesktopParityTests {
    @Test("Deterministic RSA-2048 public key derives exact igckbhkefpgcfcijbdhbkalaofkagpom extension ID")
    func deterministicExtensionID() throws {
        let derived = try #require(
            CuriumDesktopParityExtension.deriveExtensionID(
                publicKeyBase64: CuriumDesktopParityExtension.publicKeyBase64
            )
        )
        #expect(derived == "igckbhkefpgcfcijbdhbkalaofkagpom")
        #expect(derived == CuriumDesktopParityExtension.extensionID)
        #expect(derived != CuriumVideoPiPExtension.extensionID)
        #expect(derived.wholeMatch(of: /[a-p]{32}/) != nil)
        #expect(CuriumDesktopParityExtension.hiddenExtensionIDs == [derived])

        let pemWrapped = """
        -----BEGIN PUBLIC KEY-----
        \(CuriumDesktopParityExtension.publicKeyBase64)
        -----END PUBLIC KEY-----
        """
        #expect(CuriumDesktopParityExtension.deriveExtensionID(publicKeyBase64: pemWrapped) == derived)
        #expect(CuriumDesktopParityExtension.deriveExtensionID(publicKeyBase64: "") == nil)
        #expect(CuriumDesktopParityExtension.deriveExtensionID(publicKeyBase64: "not valid base64!!!") == nil)
    }

    @Test("Generated manifest.json is valid MV3 with document_start MAIN-world desktop_parity.js and zero extra permissions")
    func manifestStructure() throws {
        let data = Data(CuriumDesktopParityExtension.manifestJSON.utf8)
        let raw = try JSONSerialization.jsonObject(with: data)
        let obj = try #require(raw as? [String: Any])

        #expect((obj["manifest_version"] as? Int) == 3)
        #expect((obj["name"] as? String) == "Curium Desktop Parity")
        #expect((obj["version"] as? String) == CuriumDesktopParityExtension.manifestVersion)
        #expect((obj["key"] as? String) == CuriumDesktopParityExtension.publicKeyBase64)
        #expect(obj["background"] == nil)
        #expect(obj["permissions"] == nil)
        #expect(obj["action"] == nil)

        let scripts = try #require(obj["content_scripts"] as? [[String: Any]])
        #expect(scripts.count == 1)

        let entry = scripts[0]
        #expect((entry["js"] as? [String]) == ["desktop_parity.js"])
        #expect((entry["matches"] as? [String]) == ["http://*/*", "https://*/*"])
        #expect((entry["run_at"] as? String) == "document_start")
        #expect((entry["world"] as? String) == "MAIN")
        #expect((entry["all_frames"] as? Bool) == true)
        #expect((entry["match_about_blank"] as? Bool) == true)
    }

    @Test("parityScript enforces MacIntel guard, passes JSC execution, preserves reconnect this, and excludes dropped shims")
    func parityScriptInvariantsAndJSRuntimeExecution() throws {
        let script = CuriumDesktopParityExtension.parityScript

        // Required surfaces & runtime guard.
        #expect(script.contains("'MacIntel'"))
        #expect(script.contains("PresentationRequest"))
        #expect(script.contains("No matching route"))
        #expect(script.contains("Route not found"))
        #expect(script.contains("availTop"))
        #expect(script.contains("getLayoutMap"))
        #expect(script.contains("getVoices"))
        #expect(script.contains("getClientCapabilities"))
        #expect(script.contains("LanguageDetector"))
        #expect(script.contains("Summarizer"))
        #expect(script.contains("contentWindow"))
        #expect(script.contains("contentDocument"))

        // Dropped/forbidden shims must never appear in parityScript.
        #expect(!script.contains("requestMediaKeySystemAccess"))
        #expect(!script.contains("com.widevine.alpha"))
        #expect(!script.contains("Widevine"))
        #expect(!script.contains("getComputedStyle"))
        #expect(!script.contains("matchMedia"))
        #expect(!script.contains("performance.memory"))

        // 1. Non-Mac platform guard: leaves non-Mac windows completely untouched.
        let nonMacCtx = try #require(JSContext())
        var nonMacException: String?
        nonMacCtx.exceptionHandler = { _, exc in
            nonMacException = exc?.toString()
        }
        nonMacCtx.evaluateScript("""
        globalThis.window = globalThis;
        globalThis.navigator = { platform: 'Linux armv81' };
        globalThis.devicePixelRatio = 3;
        globalThis.__gCrWeb = { marker: 1 };
        """)
        nonMacCtx.evaluateScript(script)
        #expect(nonMacException == nil)
        #expect(nonMacCtx.evaluateScript("'__gCrWeb' in window")?.toBool() == true)
        #expect(nonMacCtx.evaluateScript("window.devicePixelRatio")?.toInt32() == 3)
        #expect(nonMacCtx.evaluateScript("typeof window.LanguageDetector")?.toString() == "undefined")

        // 2. MacIntel execution: verifies syntax, leak stripping, DPR, dynamic availTop,
        //    199 TTS voices, 48-key layout map, WebAuthn caps, AI surface, and reconnect `this`.
        let macCtx = try #require(JSContext())
        var macException: String?
        macCtx.exceptionHandler = { _, exc in
            macException = exc?.toString()
        }
        macCtx.evaluateScript("""
        globalThis.window = globalThis;
        class DOMException extends Error {
          constructor(message, name) { super(message); this.name = name; }
        }
        globalThis.DOMException = DOMException;
        function PresentationRequest(urls) { this.urls = urls; }
        PresentationRequest.prototype.reconnect = function reconnect(id) {
          if (!(this instanceof PresentationRequest)) {
            return Promise.reject(new TypeError('Illegal invocation'));
          }
          if (id === 'abort-case') {
            return Promise.reject(new DOMException('Aborted', 'AbortError'));
          }
          return Promise.reject(new DOMException('No matching route', 'NotFoundError'));
        };
        globalThis.PresentationRequest = PresentationRequest;

        function SpeechSynthesis() {}
        SpeechSynthesis.prototype.getVoices = function() { return []; };
        function SpeechSynthesisVoice() {}
        globalThis.SpeechSynthesis = SpeechSynthesis;
        globalThis.SpeechSynthesisVoice = SpeechSynthesisVoice;
        globalThis.speechSynthesis = new SpeechSynthesis();

        function Keyboard() {}
        Keyboard.prototype.getLayoutMap = function() { return Promise.resolve(new Map()); };
        function KeyboardLayoutMap() {}
        globalThis.Keyboard = Keyboard;
        globalThis.KeyboardLayoutMap = KeyboardLayoutMap;

        function Screen() {}
        Object.defineProperty(Screen.prototype, 'availTop', { get() { return 0; }, configurable: true, enumerable: true });
        Object.defineProperty(Screen.prototype, 'availLeft', { get() { return 0; }, configurable: true, enumerable: true });
        globalThis.Screen = Screen;
        globalThis.screen = Object.create(Screen.prototype, {
          width: { value: 1512, configurable: true },
          height: { value: 982, configurable: true },
          availWidth: { value: 1512, configurable: true },
          availHeight: { value: 944, configurable: true }
        });

        function PublicKeyCredential() {}
        PublicKeyCredential.getClientCapabilities = function() {
          return Promise.resolve({ conditionalCreate: true });
        };
        globalThis.PublicKeyCredential = PublicKeyCredential;

        globalThis.navigator = {
          platform: 'MacIntel',
          keyboard: new Keyboard()
        };
        globalThis.devicePixelRatio = 3;
        globalThis.__gCrWeb = {};
        globalThis.webkitMessageHandler = {};
        globalThis.NDEFReader = function() {};
        """)
        macCtx.evaluateScript(script)
        #expect(macException == nil)

        macCtx.evaluateScript("""
        globalThis.__audit = {};
        (async () => {
          const voices = window.speechSynthesis.getVoices();
          const kmap = await window.navigator.keyboard.getLayoutMap();
          const caps = await window.PublicKeyCredential.getClientCapabilities();
          const ldAvail = await window.LanguageDetector.availability();
          const sumAvail = await window.Summarizer.availability();

          let routeMsg = '';
          let routeName = '';
          try {
            await new window.PresentationRequest(['https://example.com']).reconnect('r1');
          } catch (e) {
            routeMsg = e.message;
            routeName = e.name;
          }

          let illegalMsg = '';
          try {
            await window.PresentationRequest.prototype.reconnect.call({}, 'r1');
          } catch (e) {
            illegalMsg = e.message;
          }

          let abortMsg = '';
          try {
            await new window.PresentationRequest(['https://example.com']).reconnect('abort-case');
          } catch (e) {
            abortMsg = e.message;
          }

          globalThis.__audit = {
            leaksStripped: !('__gCrWeb' in window) && !('webkitMessageHandler' in window) && !('NDEFReader' in window),
            dpr: window.devicePixelRatio,
            availTop: window.screen.availTop,
            availLeft: window.screen.availLeft,
            voiceCount: voices.length,
            firstVoiceName: voices[0].name,
            keyCount: kmap.size,
            intlBackslash: kmap.get('IntlBackslash'),
            hasPasskey: Boolean(caps.conditionalCreate && caps.passkeyPlatformAuthenticator && caps['extension:prf']),
            ldAvail,
            sumAvail,
            ldNonEnum: !Object.prototype.propertyIsEnumerable.call(window, 'LanguageDetector'),
            routeMsg,
            routeName,
            illegalMsg,
            abortMsg,
            hasChromeCSI: typeof window.chrome?.csi === 'function' && typeof window.chrome?.loadTimes === 'function'
          };
        })();
        """)
        #expect(macException == nil)
        let audit = try #require(macCtx.objectForKeyedSubscript("__audit")?.toDictionary())
        #expect((audit["leaksStripped"] as? Bool) == true)
        #expect((audit["dpr"] as? Int) == 2)
        #expect((audit["availTop"] as? Int) == 38)
        #expect((audit["availLeft"] as? Int) == 0)
        #expect((audit["voiceCount"] as? Int) == 199)
        #expect((audit["firstVoiceName"] as? String) == "Samantha")
        #expect((audit["keyCount"] as? Int) == 48)
        #expect((audit["intlBackslash"] as? String) == "§")
        #expect((audit["hasPasskey"] as? Bool) == true)
        #expect((audit["ldAvail"] as? String) == "available")
        #expect((audit["sumAvail"] as? String) == "unavailable")
        #expect((audit["ldNonEnum"] as? Bool) == true)
        #expect((audit["routeMsg"] as? String) == "Route not found")
        #expect((audit["routeName"] as? String) == "NotFoundError")
        #expect((audit["illegalMsg"] as? String) == "Illegal invocation")
        #expect((audit["abortMsg"] as? String) == "Aborted")
        #expect((audit["hasChromeCSI"] as? Bool) == true)
    }

    @Test("materialize(into:) writes manifest.json, desktop_parity.js, and .curium_version atomically, skips unchanged rewrites, and repairs corruption")
    func materializeIdempotentAndSelfHealing() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "curium-parity-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustedRoot = root.appending(path: "TrustedUnpackedExtensions", directoryHint: .isDirectory)
        let firstDir = try CuriumDesktopParityExtension.materialize(into: trustedRoot)
        #expect(firstDir.lastPathComponent == CuriumDesktopParityExtension.directoryName)

        let manifestURL = firstDir.appending(path: "manifest.json", directoryHint: .notDirectory)
        let scriptURL = firstDir.appending(path: "desktop_parity.js", directoryHint: .notDirectory)
        let stampURL = firstDir.appending(path: CuriumDesktopParityExtension.versionStampFileName, directoryHint: .notDirectory)

        #expect(try String(contentsOf: manifestURL, encoding: .utf8) == CuriumDesktopParityExtension.manifestJSON)
        #expect(try String(contentsOf: scriptURL, encoding: .utf8) == CuriumDesktopParityExtension.parityScript)
        let stamp = try String(contentsOf: stampURL, encoding: .utf8)
        #expect(stamp.wholeMatch(of: /[0-9a-f]{64}/) != nil)

        let attrs1 = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let mtime1 = attrs1[.modificationDate] as? Date

        // Second call with unchanged files skips disk rewrites.
        let secondDir = try CuriumDesktopParityExtension.materialize(into: trustedRoot)
        #expect(secondDir.standardizedFileURL == firstDir.standardizedFileURL)
        let attrs2 = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let mtime2 = attrs2[.modificationDate] as? Date
        #expect(mtime1 == mtime2)

        // Corrupting desktop_parity.js while leaving .curium_version intact still triggers atomic repair.
        try Data("corrupted();".utf8).write(to: scriptURL, options: .atomic)
        _ = try CuriumDesktopParityExtension.materialize(into: trustedRoot)
        #expect(try String(contentsOf: scriptURL, encoding: .utf8) == CuriumDesktopParityExtension.parityScript)

        // Removing manifest.json triggers clean atomic repair.
        try FileManager.default.removeItem(at: manifestURL)
        _ = try CuriumDesktopParityExtension.materialize(into: trustedRoot)
        #expect(try String(contentsOf: manifestURL, encoding: .utf8) == CuriumDesktopParityExtension.manifestJSON)
        #expect(try String(contentsOf: stampURL, encoding: .utf8) == stamp)
    }

    @Test("ensureInstalled retries transient startup errors, deduplicates concurrent calls, and reconciles enabled true/false")
    @MainActor
    func ensureInstalledLifecycleAndEnabledReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "curium-parity-bootstrap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustedRoot = root.appending(path: "TrustedUnpackedExtensions", directoryHint: .isDirectory)

        // 1. Desktop launch (`enabled: true`): retries restoring error, enables if returned disabled, deduplicates.
        let desktopManager = MockTrustedDesktopParityManager(trustedRootPath: trustedRoot.path)
        desktopManager.failFirstInstallWithRestoring = true
        desktopManager.returnInitiallyEnabled = false

        let first = Task { @MainActor in
            await CuriumDesktopParityExtension.ensureInstalled(using: desktopManager, enabled: true)
        }
        let second = Task { @MainActor in
            await CuriumDesktopParityExtension.ensureInstalled(using: desktopManager, enabled: true)
        }
        await first.value
        await second.value

        #expect(desktopManager.installAttempts == 2)
        let installedPath = try #require(desktopManager.lastInstalledDirectoryPath)
        #expect(installedPath.hasSuffix("/TrustedUnpackedExtensions/\(CuriumDesktopParityExtension.directoryName)"))
        #expect(FileManager.default.fileExists(atPath: "\(installedPath)/manifest.json"))
        #expect(FileManager.default.fileExists(atPath: "\(installedPath)/desktop_parity.js"))
        #expect(desktopManager.setEnabledCalls.contains { $0.0 == CuriumDesktopParityExtension.extensionID && $0.1 == true })
        #expect((desktopManager.entries.first?["enabled"] as? Bool) == true)

        // Repeat with same enabled state skips reinstall; toggling enabled: false disables in place without reinstalling.
        await CuriumDesktopParityExtension.ensureInstalled(using: desktopManager, enabled: true)
        #expect(desktopManager.installAttempts == 2)
        await CuriumDesktopParityExtension.ensureInstalled(using: desktopManager, enabled: false)
        #expect(desktopManager.installAttempts == 2)
        #expect((desktopManager.entries.first?["enabled"] as? Bool) == false)

        // 2. Non-desktop launch (`enabled: false`): installs trusted package and immediately sets enabled = false.
        let mobileManager = MockTrustedDesktopParityManager(trustedRootPath: trustedRoot.path)
        mobileManager.returnInitiallyEnabled = true
        await CuriumDesktopParityExtension.ensureInstalled(using: mobileManager, enabled: false)
        #expect(mobileManager.installAttempts == 1)
        #expect(mobileManager.setEnabledCalls.contains { $0.0 == CuriumDesktopParityExtension.extensionID && $0.1 == false })
        #expect((mobileManager.entries.first?["enabled"] as? Bool) == false)
    }

    @Test("CuriumExtensionStore hides both built-in extensions (Video PiP and Desktop Parity) across refresh, isInstalled, badges, blocked counts, and action notifications")
    @MainActor
    func extensionStoreHidesBothBuiltInExtensions() async throws {
        let pipID = CuriumVideoPiPExtension.extensionID
        let parityID = CuriumDesktopParityExtension.extensionID
        let userID = String(repeating: "c", count: 32)

        #expect(CuriumExtensionStore.hiddenBuiltInExtensionIDs == Set([pipID, parityID]))

        // 1. Both internal extensions installed -> store reports zero user-visible extensions.
        let builtInOnlyManager = MockHiddenDesktopParityManager()
        builtInOnlyManager.entries = [
            ["id": pipID, "name": "Curium Video PiP", "version": "1.1.0", "enabled": true, "removable": false],
            ["id": parityID, "name": "Curium Desktop Parity", "version": "1.0.0", "enabled": true, "removable": false],
        ]
        builtInOnlyManager.actionSnapshots[pipID] = ["badgeText": "2", "isEnabled": true, "hasPopup": true]
        builtInOnlyManager.actionSnapshots[parityID] = ["badgeText": "8", "isEnabled": true, "hasPopup": true]
        builtInOnlyManager.blockedCounts[pipID] = 10
        builtInOnlyManager.blockedCounts[parityID] = 20

        let builtInOnlyStore = CuriumExtensionStore(manager: builtInOnlyManager)
        builtInOnlyStore.refresh(tabID: 1, includeBlockedCounts: true)

        #expect(builtInOnlyStore.installed.isEmpty)
        #expect(!builtInOnlyStore.hasEnabledExtensions)
        #expect(builtInOnlyStore.badge == nil)
        #expect(builtInOnlyStore.blockedCount == nil)
        #expect(!builtInOnlyStore.isInstalled(pipID))
        #expect(!builtInOnlyStore.isInstalled(parityID))
        #expect(builtInOnlyManager.actionCalls.isEmpty)
        #expect(builtInOnlyManager.blockedCountCalls.isEmpty)

        // Action notifications for either hidden extension ID do not schedule refreshes.
        let callsBeforeNotify = builtInOnlyManager.extensionsCalls
        builtInOnlyManager.actionObserver?(parityID)
        builtInOnlyManager.actionObserver?(pipID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(builtInOnlyManager.extensionsCalls == callsBeforeNotify)

        // 2. Alongside a real user extension -> only the user extension is exposed.
        let mixedManager = MockHiddenDesktopParityManager()
        mixedManager.entries = [
            ["id": pipID, "name": "Curium Video PiP", "version": "1.1.0", "enabled": true, "removable": false],
            ["id": parityID, "name": "Curium Desktop Parity", "version": "1.0.0", "enabled": true, "removable": false],
            ["id": userID, "name": "uBlock Origin Lite", "version": "2026.11", "enabled": true, "removable": true],
        ]
        mixedManager.actionSnapshots[parityID] = ["badgeText": "9", "isEnabled": true, "hasPopup": true]
        mixedManager.actionSnapshots[userID] = ["badgeText": "5", "isEnabled": true, "hasPopup": true]
        mixedManager.blockedCounts[parityID] = 77
        mixedManager.blockedCounts[userID] = 12

        let mixedStore = CuriumExtensionStore(manager: mixedManager)
        mixedStore.refresh(tabID: 3, includeBlockedCounts: true)

        #expect(mixedStore.installed.map(\.id) == [userID])
        #expect(mixedStore.hasEnabledExtensions)
        #expect(mixedStore.badge == "5")
        #expect(mixedStore.blockedCount == 12)
        #expect(mixedStore.isInstalled(userID))
        #expect(!mixedStore.isInstalled(pipID))
        #expect(!mixedStore.isInstalled(parityID))
        #expect(mixedManager.actionCalls.map(\.0) == [userID])
        #expect(mixedManager.blockedCountCalls.map(\.0) == [userID])
    }
}
