import CoreGraphics
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
        let isPiP = directoryPath.hasSuffix("/\(CuriumVideoPiPExtension.directoryName)")
        if !isPiP {
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
        }
        let targetID = isPiP ? CuriumVideoPiPExtension.extensionID : CuriumDesktopParityExtension.extensionID
        let entry: [String: Any] = [
            "id": targetID,
            "name": isPiP ? "Curium Video PiP" : "Curium Desktop Parity",
            "version": isPiP ? CuriumVideoPiPExtension.manifestVersion : CuriumDesktopParityExtension.manifestVersion,
            "enabled": isPiP ? true : returnInitiallyEnabled,
        ]
        if let idx = entries.firstIndex(where: { ($0["id"] as? String) == targetID }) {
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

        // 2. Fresh non-desktop / Build 43 launch (`enabled: false`): NEVER materializes or installs desktop_parity.js.
        let freshDisabledRoot = root.appending(path: "TrustedDisabledFresh", directoryHint: .isDirectory)
        let mobileManager = MockTrustedDesktopParityManager(trustedRootPath: freshDisabledRoot.path)
        mobileManager.returnInitiallyEnabled = true
        await CuriumDesktopParityExtension.ensureInstalled(using: mobileManager, enabled: false)
        #expect(mobileManager.installAttempts == 0)
        #expect(mobileManager.setEnabledCalls.isEmpty)
        #expect(mobileManager.entries.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: freshDisabledRoot.appending(path: CuriumDesktopParityExtension.directoryName).path
        ))

        // 3. Build 42 -> Build 43 upgrade (`enabled: false` when already installed & enabled):
        //    disables existing extension in place with zero disk materialization or reinstall.
        let upgradeRoot = root.appending(path: "TrustedDisabledUpgrade", directoryHint: .isDirectory)
        let upgradeManager = MockTrustedDesktopParityManager(trustedRootPath: upgradeRoot.path)
        upgradeManager.entries = [[
            "id": CuriumDesktopParityExtension.extensionID,
            "name": "Curium Desktop Parity",
            "version": CuriumDesktopParityExtension.manifestVersion,
            "enabled": true,
        ]]
        await CuriumDesktopParityExtension.ensureInstalled(using: upgradeManager, enabled: false)
        #expect(upgradeManager.installAttempts == 0)
        #expect(upgradeManager.setEnabledCalls.contains { $0.0 == CuriumDesktopParityExtension.extensionID && $0.1 == false })
        #expect((upgradeManager.entries.first?["enabled"] as? Bool) == false)
        #expect(!FileManager.default.fileExists(
            atPath: upgradeRoot.appending(path: CuriumDesktopParityExtension.directoryName).path
        ))
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
            ["id": parityID, "name": "Curium Desktop Parity", "version": CuriumDesktopParityExtension.manifestVersion, "enabled": true, "removable": false],
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
            ["id": parityID, "name": "Curium Desktop Parity", "version": CuriumDesktopParityExtension.manifestVersion, "enabled": true, "removable": false],
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

    @Test("Seeded parityScript diversifies macOS speech voices per profile while preserving Samantha + all 19 Google voices and clamping Dock availTop to 38 pt")
    func seededSpeechVoicesAndDockAvailTop() throws {
        func runSeed(_ seed: String, height: Int = 1107, availHeight: Int = 1001) throws -> (names: [String], googleCount: Int, availTop: Int) {
            let ctx = try #require(JSContext())
            var jsErr: String?
            ctx.exceptionHandler = { _, exc in jsErr = exc?.toString() }
            ctx.evaluateScript("""
            globalThis.window = globalThis;
            function SpeechSynthesis() {}
            SpeechSynthesis.prototype.getVoices = function() { return []; };
            function SpeechSynthesisVoice() {}
            globalThis.SpeechSynthesis = SpeechSynthesis;
            globalThis.SpeechSynthesisVoice = SpeechSynthesisVoice;
            globalThis.speechSynthesis = new SpeechSynthesis();
            function Screen() {}
            Object.defineProperty(Screen.prototype, 'availTop', { get() { return 0; }, configurable: true, enumerable: true });
            Object.defineProperty(Screen.prototype, 'availLeft', { get() { return 0; }, configurable: true, enumerable: true });
            globalThis.Screen = Screen;
            globalThis.screen = Object.create(Screen.prototype, {
              width: { value: 1710, configurable: true },
              height: { value: \(height), configurable: true },
              availWidth: { value: 1710, configurable: true },
              availHeight: { value: \(availHeight), configurable: true }
            });
            globalThis.navigator = { platform: 'MacIntel' };
            """)
            ctx.evaluateScript(CuriumDesktopParityExtension.parityScript(profileSeed: seed))
            #expect(jsErr == nil)
            let res = try #require(ctx.evaluateScript("""
            (() => {
              const voices = window.speechSynthesis.getVoices();
              return {
                names: voices.map(v => v.name),
                googleCount: voices.filter(v => v.name.startsWith('Google')).length,
                defaultFirst: voices[0]?.name === 'Samantha' && voices[0]?.default === true,
                availTop: window.screen.availTop
              };
            })()
            """)?.toDictionary())
            #expect((res["defaultFirst"] as? Bool) == true)
            let names = try #require(res["names"] as? [String])
            let googleCount = try #require(res["googleCount"] as? Int)
            let availTop = try #require(res["availTop"] as? Int)
            return (names, googleCount, availTop)
        }

        let seedA = try runSeed("p-alpha|aaaa|1700000000000")
        let seedB = try runSeed("p-beta|bbbb|1700000005000")
        let seedARepeat = try runSeed("p-alpha|aaaa|1700000000000")

        #expect(seedA.names == seedARepeat.names)
        #expect(seedA.names != seedB.names)
        #expect(seedA.googleCount == 19)
        #expect(seedB.googleCount == 19)
        #expect(seedA.names.count > 100 && seedA.names.count < 199)
        #expect(seedB.names.count > 100 && seedB.names.count < 199)
        #expect(seedA.availTop == 38)

        // Materializing with a rotated seed reports didChange == true so Chromium reloads desktop_parity.js.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "curium-parity-seed-reload-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let trustedRoot = root.appending(path: "TrustedUnpackedExtensions", directoryHint: .isDirectory)
        let first = try CuriumDesktopParityExtension.materializeWithChangeStatus(into: trustedRoot, profileSeed: "seed-1")
        let same = try CuriumDesktopParityExtension.materializeWithChangeStatus(into: trustedRoot, profileSeed: "seed-1")
        let rotated = try CuriumDesktopParityExtension.materializeWithChangeStatus(into: trustedRoot, profileSeed: "seed-2")
        #expect(first.didChange == true)
        #expect(same.didChange == false)
        #expect(rotated.didChange == true)
    }

    @Test("CuriumProfileFontManager exposes all 45 clean 5-6 font macOS suites and clones valid SFNT binaries")
    func profileFontManagerDisjointSuitesAndSFNTCloning() throws {
        #expect(CuriumProfileFontManager.macOSFontSuites.count == 45)
        let uniqueSuites = Set(CuriumProfileFontManager.macOSFontSuites)
        #expect(uniqueSuites.count == 45)
        for suite in CuriumProfileFontManager.macOSFontSuites {
            #expect(suite.count == 1 || suite.count == 2)
            #expect(!suite.contains("Bitstream Vera Sans Mono"))
        }

        var reachedSuites: Set<[String]> = []
        for idx in 0..<400 {
            let fonts = CuriumProfileFontManager.selectedFonts(
                forProfileSeed: "p-sample-\(idx)|seed-\(idx)|1700000000000",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M\((idx % 4) + 1), Unspecified Version)"
            )
            let names = fonts.map(\.familyName)
            #expect(names.contains("Arial Unicode MS"))
            #expect(names.count >= 2 && names.count <= 3) // +3 built-in iOS fonts => 5..6 total detected
            #expect(!names.contains("Bitstream Vera Sans Mono"))
            reachedSuites.insert(names)
        }
        #expect(reachedSuites.count >= 40)

        // Verify cloned SFNT binary has valid sfnt magic and parses via CGDataProvider/CGFont.
        let sampleSpec = CuriumProfileFontManager.macOSBaselineFont
        let sfnt = try #require(CuriumProfileFontManager.buildClonedSFNT(for: sampleSpec))
        #expect(sfnt.count > 4096)
        let magic = sfnt.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(magic == 0x0001_0000 || magic == 0x4F54_544F)
        let provider = try #require(CGDataProvider(data: sfnt as CFData))
        let cgFont = try #require(CGFont(provider))
        #expect((cgFont.postScriptName as String?) == sampleSpec.postScriptName)
    }

    @Test("parityScript v1.2.0 honors notched (38 pt) vs non-notched (25 pt) menu bar and Left/Right side Dock availLeft")
    func parityScriptMenuBarAndSideDockPlacement() throws {
        func evalScreen(
            width: Int,
            height: Int,
            availWidth: Int,
            availHeight: Int,
            menuBarHeight: Int,
            dockOnLeft: Bool
        ) throws -> (availTop: Int, availLeft: Int) {
            let ctx = try #require(JSContext())
            var jsErr: String?
            ctx.exceptionHandler = { _, exc in jsErr = exc?.toString() }
            ctx.evaluateScript("""
            globalThis.window = globalThis;
            function Screen() {}
            Object.defineProperty(Screen.prototype, 'availTop', { get() { return 0; }, configurable: true, enumerable: true });
            Object.defineProperty(Screen.prototype, 'availLeft', { get() { return 0; }, configurable: true, enumerable: true });
            globalThis.Screen = Screen;
            globalThis.screen = Object.create(Screen.prototype, {
              width: { value: \(width), configurable: true },
              height: { value: \(height), configurable: true },
              availWidth: { value: \(availWidth), configurable: true },
              availHeight: { value: \(availHeight), configurable: true }
            });
            globalThis.navigator = { platform: 'MacIntel' };
            """)
            ctx.evaluateScript(
                CuriumDesktopParityExtension.parityScript(
                    profileSeed: "p-dock|seed|1700000000000",
                    menuBarHeight: menuBarHeight,
                    dockOnLeft: dockOnLeft
                )
            )
            #expect(jsErr == nil)
            let top = try #require(ctx.evaluateScript("window.screen.availTop")?.toInt32())
            let left = try #require(ctx.evaluateScript("window.screen.availLeft")?.toInt32())
            return (Int(top), Int(left))
        }

        // External/non-notch display with bottom Dock -> availTop == 25, availLeft == 0 even if dockOnLeft is true.
        let externalBottom = try evalScreen(
            width: 2560, height: 1440, availWidth: 2560, availHeight: 1355,
            menuBarHeight: 25, dockOnLeft: true
        )
        #expect(externalBottom.availTop == 25)
        #expect(externalBottom.availLeft == 0)

        // Notched MacBook with left Dock (62 pt) -> availTop == 38, availLeft == 62.
        let notchedLeft = try evalScreen(
            width: 1728, height: 1117, availWidth: 1666, availHeight: 1079,
            menuBarHeight: 38, dockOnLeft: true
        )
        #expect(notchedLeft.availTop == 38)
        #expect(notchedLeft.availLeft == 62)

        // Notched MacBook with right Dock (62 pt) -> availTop == 38, availLeft == 0.
        let notchedRight = try evalScreen(
            width: 1728, height: 1117, availWidth: 1666, availHeight: 1079,
            menuBarHeight: 38, dockOnLeft: false
        )
        #expect(notchedRight.availTop == 38)
        #expect(notchedRight.availLeft == 0)

        // Prototype receiver brand check: invoking getter on invalid receiver throws TypeError (`Illegal invocation`).
        let brandCtx = try #require(JSContext())
        var brandErr: String?
        brandCtx.exceptionHandler = { _, exc in brandErr = exc?.toString() }
        brandCtx.evaluateScript("""
        globalThis.window = globalThis;
        function Screen() {}
        Object.defineProperty(Screen.prototype, 'availTop', {
          get() {
            if (!(this instanceof Screen)) throw new TypeError('Illegal invocation');
            return 0;
          },
          configurable: true,
          enumerable: true
        });
        Object.defineProperty(Screen.prototype, 'availLeft', {
          get() {
            if (!(this instanceof Screen)) throw new TypeError('Illegal invocation');
            return 0;
          },
          configurable: true,
          enumerable: true
        });
        globalThis.Screen = Screen;
        globalThis.screen = Object.create(Screen.prototype, {
          width: { value: 1728, configurable: true },
          height: { value: 1117, configurable: true },
          availWidth: { value: 1728, configurable: true },
          availHeight: { value: 1049, configurable: true }
        });
        globalThis.navigator = { platform: 'MacIntel' };
        """)
        brandCtx.evaluateScript(
            CuriumDesktopParityExtension.parityScript(
                profileSeed: "p-brand|seed|1700000000000",
                menuBarHeight: 38,
                dockOnLeft: false
            )
        )
        #expect(brandErr == nil)
        let brandResult = try #require(brandCtx.evaluateScript("""
        (() => {
          const desc = Object.getOwnPropertyDescriptor(Screen.prototype, 'availTop');
          let threwOnBadThis = false;
          try { Reflect.apply(desc.get, {}, []); } catch (e) { threwOnBadThis = e instanceof TypeError; }
          return {
            validTop: window.screen.availTop,
            threwOnBadThis,
            toStringStr: Function.prototype.toString.call(desc.get)
          };
        })()
        """)?.toDictionary())
        #expect((brandResult["validTop"] as? Int) == 38)
        #expect((brandResult["threwOnBadThis"] as? Bool) == true)
        #expect((brandResult["toStringStr"] as? String)?.contains("[native code]") == true)
    }

    @Test("CuriumMacOSManifold enforces 18 Apple Silicon SKUs (8 GB W3C cap), chip-era Nov-2026 macOS/Chrome releases, 11 mainstream @2x HiDPI displays >=960 availH, right/bottom visible Dock, and first-boot fail-closed persistence")
    @MainActor
    func macOSManifoldInvariantsAndFirstBootRandomization() throws {
        #expect(CuriumMacOSManifold.appleSiliconSKUs.count == 18)
        #expect(CuriumMacOSManifold.displayGeometries.count == 11)
        #expect(CuriumMacOSManifold.chipDisplayName(fromWebGLRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M2 Pro, Unspecified Version)") == "Apple M2 Pro")

        let validChromePrefixes = ["156.0.8078.", "157.0.8103.", "158.0.8127."]
        var seenSKUs: Set<String> = []
        var seenDisplays: Set<String> = []
        var seenDockPlacements: Set<CuriumMacOSManifold.DockPlacement> = []
        for _ in 0..<240 {
            let sampled = CuriumMacOSManifold.sampleIdentity()
            seenSKUs.insert(sampled.sku.id)
            seenDisplays.insert("\(sampled.display.width)x\(sampled.display.height)")
            seenDockPlacements.insert(sampled.dockPlacement)

            // W3C / Chromium hard cap: navigator.deviceMemory is always <= 8 GB on real macOS Chrome.
            #expect(sampled.sku.memoryGB == 8)

            // Chip-era macOS constraint: M4 / M4 Pro never pair with macOS 14.x.
            #expect(sampled.macOS.major >= sampled.sku.minMacOSMajor)
            #expect([14, 15, 26].contains(sampled.macOS.major))
            #expect(["156", "157", "158"].contains(sampled.chrome.major))
            #expect(validChromePrefixes.contains { sampled.chrome.fullVersion.hasPrefix($0) })
            #expect(sampled.chrome.productVersion == "Chrome/\(sampled.chrome.major).0.0.0")

            // Physical Apple Silicon SKU × Display coherence:
            // - M1 non-notched SKUs never pair with notched built-in panels.
            // - 16" MacBook Pro panels (1728×1117, 2056×1329) only pair with 10+ core 16" Pro/Max SKUs.
            // - MacBook Air notched panels (1710×1107, 1920×1243, 1710×1112) only pair with base M2/M3/M4 SKUs.
            // - 14" MacBook Pro panel (1800×1169) never pairs with base M1 or M2.
            #expect(sampled.display.isCompatible(with: sampled.sku))
            if !sampled.sku.prefersNotchedBuiltIn {
                #expect(!sampled.display.isNotchedBuiltIn)
                #expect(sampled.display.menuBarHeight == 25)
            }
            if sampled.display.panelClass == .macBookPro16Notched {
                #expect(sampled.sku.chipName.contains("Pro") || sampled.sku.chipName.contains("Max"))
                #expect(sampled.sku.cores >= 10)
                #expect(sampled.sku.id != "m1pro-8c" && sampled.sku.id != "m2pro-10c" && sampled.sku.id != "m3pro-11c")
            }
            if sampled.display.panelClass == .macBookAirNotched {
                #expect(!sampled.sku.chipName.contains("Pro") && !sampled.sku.chipName.contains("Max"))
                #expect(sampled.sku.chipName != "Apple M1")
            }
            if sampled.display.panelClass == .macBookPro14Notched {
                #expect(sampled.sku.chipName != "Apple M1" && sampled.sku.chipName != "Apple M2")
            }
            #expect(CuriumMacOSManifold.inferredMenuBarHeight(for: sampled.screen) == sampled.display.menuBarHeight)
            #expect(CuriumMacOSManifold.prefersLeftDock(forProfileSeed: "any-seed") == false)

            // Visible Dock invariant + availHeight >= 960 (prevents 0110 viewport stretching on slab & duo Portrait).
            let availW = try #require(sampled.screen.availWidth)
            let availH = try #require(sampled.screen.availHeight)
            #expect(availH >= 960)
            switch sampled.dockPlacement {
            case .bottom:
                #expect(availW == sampled.display.width)
                let dockH = sampled.display.height - sampled.display.menuBarHeight - availH
                #expect((38...84).contains(dockH))
            case .right:
                #expect(availH == sampled.display.height - sampled.display.menuBarHeight)
                let dockW = sampled.display.width - availW
                #expect((44...78).contains(dockW))
            }

            let applied = CuriumMacOSManifold.apply(sampled, to: CuriumFingerprintPresets.macosDesktopFirst)
            let report = CuriumFingerprintValidator.validate(applied)
            #expect(report.errors.isEmpty)
            #expect(report.warnings.isEmpty)
            #expect(applied.desktop.osCpu == "Macintosh; Intel Mac OS X 10_15_7")
            #expect(applied.desktop.webglProfile == .native)
            #expect(applied.shortArchetypeSummary.contains(sampled.sku.chipName))
        }
        #expect(seenSKUs.count >= 15)
        #expect(seenDisplays.count >= 9)
        #expect(seenDockPlacements == [.bottom, .right])

        // Two fresh zero-noise installs must never collapse onto a single hardcoded Personal identity
        // and still derive distinct CoreText/voice seed strings without needing a farbling seed.
        let installs = (0..<12).map { _ in CuriumFingerprintStore.makeDefaultPersonalProfile() }
        let distinctCombos = Set(installs.map { "\($0.desktop.webglRenderer ?? "")|\($0.desktop.screen?.width ?? 0)x\($0.desktop.screen?.height ?? 0)|\($0.desktop.platformVersion ?? "")" })
        #expect(distinctCombos.count >= 8)
        let distinctProfileSeeds = Set(installs.map(CuriumProfileFontManager.profileSeedString(for:)))
        #expect(distinctProfileSeeds.count >= 10)

        // First-boot ENOENT store persists randomized Personal fail-closed inside prepareEngineLaunch before ChromeMain.
        defer { CuriumFingerprintBootstrap.resetStateForTesting() }
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-firstboot-persist-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appending(path: CuriumFingerprintStore.fileName)
        let freshStore = CuriumFingerprintStore(fileURL: storeURL)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
        let v2Caps = CuriumEngineFingerprintCapabilities(dictionary: [
            "contractVersion": 2,
            "supportedSchemaVersions": [1, 2],
            "maxConfigBytes": 65536,
        ])
        var persistedBeforeEngineConfigure = false
        let outcome = CuriumFingerprintBootstrap.prepareEngineLaunch(
            store: freshStore,
            capabilitiesProvider: { v2Caps },
            configureEngine: { _, _ in
                persistedBeforeEngineConfigure = FileManager.default.fileExists(atPath: storeURL.path)
                return true
            }
        )
        #expect(outcome == .configured(profileID: "default", revision: 1, nativeHardware: false))
        #expect(persistedBeforeEngineConfigure == true)
        let reloaded = CuriumFingerprintStore(fileURL: storeURL)
        #expect(reloaded.profile(id: "default")?.desktop == freshStore.profile(id: "default")?.desktop)
        #expect(reloaded.profile(id: "default")?.fingerprintSeed == freshStore.profile(id: "default")?.fingerprintSeed)
    }

    @Test("CuriumExtensionStore disables Desktop Parity JS extension automatically when engine advertises Build 43 nativeDesktopParityV1")
    @MainActor
    func extensionStoreDisablesDesktopParityWhenNativeSupported() async throws {
        let desktopProfile = CuriumFingerprintPresets.macosDesktopFirst
        let mobileProfile = CuriumFingerprintPresets.defaultAuthenticChrome

        let build42Caps = CuriumEngineFingerprintCapabilities(dictionary: [
            "contractVersion": 2,
            "supportedSchemaVersions": [1, 2],
            "maxConfigBytes": 65_536,
        ])
        let build43Caps = CuriumEngineFingerprintCapabilities(dictionary: [
            "contractVersion": 3,
            "supportedSchemaVersions": [1, 2, 3],
            "maxConfigBytes": 65_536,
            "features": ["nativeDesktopParityV1": true],
        ])

        #expect(CuriumExtensionStore.shouldEnableDesktopParityExtension(for: desktopProfile, capabilities: build42Caps))
        #expect(!CuriumExtensionStore.shouldEnableDesktopParityExtension(for: mobileProfile, capabilities: build42Caps))
        #expect(!CuriumExtensionStore.shouldEnableDesktopParityExtension(for: desktopProfile, capabilities: build43Caps))
        #expect(!CuriumExtensionStore.shouldEnableDesktopParityExtension(for: mobileProfile, capabilities: build43Caps))

        // 1. Fresh Build 43 manager: never materializes or installs Desktop Parity extension (0 MAIN-world scripts).
        let root = FileManager.default.temporaryDirectory
            .appending(path: "curium-parity-native-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let freshRoot = root.appending(path: "FreshTrusted", directoryHint: .isDirectory)
        let freshManager = MockTrustedDesktopParityManager(trustedRootPath: freshRoot.path)
        _ = CuriumExtensionStore(manager: freshManager, capabilitiesProvider: { build43Caps })
        for _ in 0..<40 {
            if freshManager.entries.contains(where: { ($0["id"] as? String) == CuriumVideoPiPExtension.extensionID }) {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(freshManager.installAttempts == 0)
        #expect(!freshManager.entries.contains(where: { ($0["id"] as? String) == CuriumDesktopParityExtension.extensionID }))
        #expect(!FileManager.default.fileExists(
            atPath: freshRoot.appending(path: CuriumDesktopParityExtension.directoryName).path
        ))

        // 2. Build 42 -> Build 43 upgrade manager: disables pre-existing Desktop Parity extension without reinstalling.
        let upgradeRoot = root.appending(path: "UpgradeTrusted", directoryHint: .isDirectory)
        let upgradeManager = MockTrustedDesktopParityManager(trustedRootPath: upgradeRoot.path)
        upgradeManager.entries = [[
            "id": CuriumDesktopParityExtension.extensionID,
            "name": "Curium Desktop Parity",
            "version": CuriumDesktopParityExtension.manifestVersion,
            "enabled": true,
        ]]
        _ = CuriumExtensionStore(manager: upgradeManager, capabilitiesProvider: { build43Caps })
        for _ in 0..<40 {
            if let entry = upgradeManager.entries.first(where: { ($0["id"] as? String) == CuriumDesktopParityExtension.extensionID }),
               (entry["enabled"] as? Bool) == false {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let parityEntry = try #require(
            upgradeManager.entries.first(where: { ($0["id"] as? String) == CuriumDesktopParityExtension.extensionID })
        )
        #expect(upgradeManager.installAttempts == 0)
        #expect((parityEntry["enabled"] as? Bool) == false)
        #expect(!FileManager.default.fileExists(
            atPath: upgradeRoot.appending(path: CuriumDesktopParityExtension.directoryName).path
        ))
    }
}
