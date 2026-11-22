import CuriumEngineContract
import Foundation
import Testing

private final class MockHiddenExtensionManager: NSObject, CrIOSExtensionManagingV1 {
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

private final class MockTrustedUnpackedExtensionManager: NSObject, CrIOSExtensionManagingV1, @unchecked Sendable {
    let trustedRootPath: String
    var entries: [[String: Any]] = []
    var installAttempts = 0
    var failFirstInstallWithRestoring = false
    var returnInitiallyDisabled = false
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
        let enabled = !returnInitiallyDisabled
        let entry: [String: Any] = [
            "id": CuriumVideoPiPExtension.extensionID,
            "name": "Curium Video PiP",
            "version": "1.0.0",
            "enabled": enabled,
        ]
        entries.append(entry)
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

@Suite("Built-in Video PiP Extension")
struct CuriumVideoPiPTests {
    @Test("Deterministic RSA-2048 public key derives exact 32-char a-p Chromium extension ID")
    func deterministicExtensionID() throws {
        let derived = try #require(
            CuriumVideoPiPExtension.deriveExtensionID(publicKeyBase64: CuriumVideoPiPExtension.publicKeyBase64)
        )
        #expect(derived == CuriumVideoPiPExtension.extensionID)
        #expect(derived.wholeMatch(of: /[a-p]{32}/) != nil)
        #expect(CuriumVideoPiPExtension.hiddenExtensionIDs.contains(derived))

        // Handles PEM wrappers & whitespace cleanly and rejects invalid keys.
        let pemWrapped = """
        -----BEGIN PUBLIC KEY-----
        \(CuriumVideoPiPExtension.publicKeyBase64)
        -----END PUBLIC KEY-----
        """
        #expect(CuriumVideoPiPExtension.deriveExtensionID(publicKeyBase64: pemWrapped) == derived)
        #expect(CuriumVideoPiPExtension.deriveExtensionID(publicKeyBase64: "") == nil)
        #expect(CuriumVideoPiPExtension.deriveExtensionID(publicKeyBase64: "not valid base64!!!") == nil)
    }

    @Test("Generated manifest.json is valid MV3 with MAIN guard and ISOLATED overlay content scripts")
    func manifestStructure() throws {
        let data = Data(CuriumVideoPiPExtension.manifestJSON.utf8)
        let raw = try JSONSerialization.jsonObject(with: data)
        let obj = try #require(raw as? [String: Any])

        #expect((obj["manifest_version"] as? Int) == 3)
        #expect((obj["name"] as? String) == "Curium Video PiP")
        #expect((obj["version"] as? String) == "1.0.0")
        #expect((obj["key"] as? String) == CuriumVideoPiPExtension.publicKeyBase64)
        #expect(obj["background"] == nil)
        #expect(obj["permissions"] == nil)
        #expect(obj["action"] == nil)

        let scripts = try #require(obj["content_scripts"] as? [[String: Any]])
        #expect(scripts.count == 2)

        let guardEntry = scripts[0]
        #expect((guardEntry["js"] as? [String]) == ["pip_guard.js"])
        #expect((guardEntry["matches"] as? [String]) == ["http://*/*", "https://*/*"])
        #expect((guardEntry["run_at"] as? String) == "document_start")
        #expect((guardEntry["world"] as? String) == "MAIN")
        #expect((guardEntry["all_frames"] as? Bool) == true)
        #expect((guardEntry["match_about_blank"] as? Bool) == true)

        let overlayEntry = scripts[1]
        #expect((overlayEntry["js"] as? [String]) == ["pip_overlay.js"])
        #expect((overlayEntry["matches"] as? [String]) == ["http://*/*", "https://*/*"])
        #expect((overlayEntry["run_at"] as? String) == "document_idle")
        #expect((overlayEntry["world"] as? String) == "ISOLATED")
        #expect((overlayEntry["all_frames"] as? Bool) == true)
        #expect((overlayEntry["match_about_blank"] as? Bool) == true)
    }

    @Test("materialize(into:) writes extension files atomically and is idempotent across repeated calls")
    func materializeIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "curium-pip-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustedRoot = root.appending(path: "TrustedUnpackedExtensions", directoryHint: .isDirectory)
        let firstDir = try CuriumVideoPiPExtension.materialize(into: trustedRoot)
        #expect(firstDir.lastPathComponent == CuriumVideoPiPExtension.directoryName)

        let manifestURL = firstDir.appending(path: "manifest.json", directoryHint: .notDirectory)
        let guardURL = firstDir.appending(path: "pip_guard.js", directoryHint: .notDirectory)
        let overlayURL = firstDir.appending(path: "pip_overlay.js", directoryHint: .notDirectory)

        #expect(try String(contentsOf: manifestURL, encoding: .utf8) == CuriumVideoPiPExtension.manifestJSON)
        #expect(try String(contentsOf: guardURL, encoding: .utf8) == CuriumVideoPiPExtension.guardScript)
        #expect(try String(contentsOf: overlayURL, encoding: .utf8) == CuriumVideoPiPExtension.overlayScript)

        let attrs1 = try FileManager.default.attributesOfItem(atPath: guardURL.path)
        let mtime1 = attrs1[.modificationDate] as? Date

        // Second call with unchanged payload skips rewriting disk files.
        let secondDir = try CuriumVideoPiPExtension.materialize(into: trustedRoot)
        #expect(secondDir.standardizedFileURL == firstDir.standardizedFileURL)
        let attrs2 = try FileManager.default.attributesOfItem(atPath: guardURL.path)
        let mtime2 = attrs2[.modificationDate] as? Date
        #expect(mtime1 == mtime2)

        // Removing one payload file triggers self-healing re-materialization.
        try FileManager.default.removeItem(at: overlayURL)
        #expect(!FileManager.default.fileExists(atPath: overlayURL.path))
        _ = try CuriumVideoPiPExtension.materialize(into: trustedRoot)
        #expect(try String(contentsOf: overlayURL, encoding: .utf8) == CuriumVideoPiPExtension.overlayScript)
    }

    @Test("CuriumExtensionStore hides internal PiP extension across lists, badges, blocked counts, and action notifications")
    @MainActor
    func extensionStoreHidesInternalPiPExtension() async throws {
        let hiddenID = CuriumVideoPiPExtension.extensionID
        let userID = String(repeating: "b", count: 32)

        // 1. Only internal extension installed -> completely invisible to user-facing store properties.
        let hiddenOnlyManager = MockHiddenExtensionManager()
        hiddenOnlyManager.entries = [
            ["id": hiddenID, "name": "Curium Video PiP", "version": "1.0.0", "enabled": true, "removable": false]
        ]
        hiddenOnlyManager.actionSnapshots[hiddenID] = ["badgeText": "9", "isEnabled": true, "hasPopup": true]
        hiddenOnlyManager.blockedCounts[hiddenID] = 42

        let hiddenOnlyStore = CuriumExtensionStore(manager: hiddenOnlyManager)
        hiddenOnlyStore.refresh(tabID: 1, includeBlockedCounts: true)

        #expect(hiddenOnlyStore.installed.isEmpty)
        #expect(!hiddenOnlyStore.hasEnabledExtensions)
        #expect(hiddenOnlyStore.badge == nil)
        #expect(hiddenOnlyStore.blockedCount == nil)
        #expect(!hiddenOnlyStore.isInstalled(hiddenID))
        #expect(hiddenOnlyManager.actionCalls.isEmpty)
        #expect(hiddenOnlyManager.blockedCountCalls.isEmpty)

        // Action presentation changes for the hidden extension must be ignored without scheduling a refresh.
        let callsBeforeNotify = hiddenOnlyManager.extensionsCalls
        hiddenOnlyManager.actionObserver?(hiddenID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(hiddenOnlyManager.extensionsCalls == callsBeforeNotify)
        #expect(hiddenOnlyStore.installed.isEmpty)

        // 2. Alongside a real user extension -> only the user extension is surfaced and queried.
        let mixedManager = MockHiddenExtensionManager()
        mixedManager.entries = [
            ["id": hiddenID, "name": "Curium Video PiP", "version": "1.0.0", "enabled": true, "removable": false],
            ["id": userID, "name": "User Adblocker", "version": "2.1", "enabled": true, "removable": true],
        ]
        mixedManager.actionSnapshots[hiddenID] = ["badgeText": "9", "isEnabled": true, "hasPopup": true]
        mixedManager.actionSnapshots[userID] = ["badgeText": "4", "isEnabled": true, "hasPopup": true]
        mixedManager.blockedCounts[hiddenID] = 99
        mixedManager.blockedCounts[userID] = 5

        let mixedStore = CuriumExtensionStore(manager: mixedManager)
        mixedStore.refresh(tabID: 7, includeBlockedCounts: true)

        #expect(mixedStore.installed.map(\.id) == [userID])
        #expect(mixedStore.hasEnabledExtensions)
        #expect(mixedStore.badge == "4")
        #expect(mixedStore.blockedCount == 5)
        #expect(mixedStore.isInstalled(userID))
        #expect(!mixedStore.isInstalled(hiddenID))
        #expect(mixedManager.actionCalls.map(\.0) == [userID])
        #expect(mixedManager.blockedCountCalls.map(\.0) == [userID])

        // Notifications for hiddenID leave user extension state intact and avoid extra extensions() refreshes.
        let callsBeforeHiddenPing = mixedManager.extensionsCalls
        mixedManager.actionObserver?(hiddenID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(mixedManager.extensionsCalls == callsBeforeHiddenPing)
        #expect(mixedStore.installed.map(\.id) == [userID])
    }

    @Test("ObjC trusted-directory wrapper materializes extension, retries restoring error, enables, and deduplicates")
    @MainActor
    func trustedInstallerBootstrapAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "curium-pip-bootstrap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustedRoot = root.appending(path: "TrustedUnpackedExtensions", directoryHint: .isDirectory)
        let manager = MockTrustedUnpackedExtensionManager(trustedRootPath: trustedRoot.path)
        manager.failFirstInstallWithRestoring = true
        manager.returnInitiallyDisabled = true

        // Launch two concurrent calls across simulated scenes; must deduplicate and retry cleanly.
        let first = Task { @MainActor in
            await CuriumVideoPiPExtension.ensureInstalled(using: manager)
        }
        let second = Task { @MainActor in
            await CuriumVideoPiPExtension.ensureInstalled(using: manager)
        }
        await first.value
        await second.value

        #expect(manager.installAttempts == 2)
        let installedPath = try #require(manager.lastInstalledDirectoryPath)
        #expect(installedPath.hasSuffix("/TrustedUnpackedExtensions/\(CuriumVideoPiPExtension.directoryName)"))
        #expect(FileManager.default.fileExists(atPath: "\(installedPath)/manifest.json"))
        #expect(FileManager.default.fileExists(atPath: "\(installedPath)/pip_guard.js"))
        #expect(FileManager.default.fileExists(atPath: "\(installedPath)/pip_overlay.js"))
        #expect(manager.setEnabledCalls.contains { $0.0 == CuriumVideoPiPExtension.extensionID && $0.1 == true })

        // Subsequent bootstrap calls for the same manager are skipped immediately.
        await CuriumVideoPiPExtension.ensureInstalled(using: manager)
        #expect(manager.installAttempts == 2)
    }
}
