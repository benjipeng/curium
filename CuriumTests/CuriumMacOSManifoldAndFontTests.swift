import CoreGraphics
import CuriumEngineContract
import Foundation
import Testing

private final class MockRetiredParityUpgradeManager: NSObject, CrIOSExtensionManagingV1, @unchecked Sendable {
    let trustedRootPath: String
    var entries: [[String: Any]] = []
    var installAttempts = 0
    var setEnabledCalls: [(String, Bool)] = []
    var actionSnapshots: [String: [String: Any]] = [:]
    var blockedCounts: [String: NSNumber] = [:]

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
        }
        let targetID = isPiP ? CuriumVideoPiPExtension.extensionID : "unexpected-extension"
        let entry: [String: Any] = [
            "id": targetID,
            "name": isPiP ? "Curium Video PiP" : "Unexpected",
            "version": CuriumVideoPiPExtension.manifestVersion,
            "enabled": true,
        ]
        if let idx = entries.firstIndex(where: { ($0["id"] as? String) == targetID }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        completion(entry, nil)
    }

    func actionPresentationForExtension(withID extensionID: String, tabID: Int32) throws -> [String: Any] {
        actionSnapshots[extensionID] ?? [:]
    }

    func observeActionPresentationChanges(handler: @escaping @MainActor (String?) -> Void) -> (any NSObjectProtocol)? {
        NSObject()
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

@Suite("macOS Manifold, Profile Fonts & Retired Parity Tombstone")
struct CuriumMacOSManifoldAndFontTests {
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

        // Two fresh zero-noise installs must never collapse onto a single hardcoded Personal identity.
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

    @Test("CuriumExtensionStore hides, disables, and cleans disk files for the retired Desktop Parity extension")
    @MainActor
    func extensionStoreHidesAndDisablesRetiredDesktopParityExtension() async throws {
        let retiredID = "igckbhkefpgcfcijbdhbkalaofkagpom"
        #expect(CuriumExtensionStore.hiddenBuiltInExtensionIDs.contains(retiredID))

        let root = FileManager.default.temporaryDirectory
            .appending(path: "curium-parity-tombstone-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Fresh container: never installs Desktop Parity; only Video PiP installs.
        let freshRoot = root.appending(path: "FreshTrusted", directoryHint: .isDirectory)
        let freshManager = MockRetiredParityUpgradeManager(trustedRootPath: freshRoot.path)
        _ = CuriumExtensionStore(manager: freshManager)
        for _ in 0..<40 {
            if freshManager.entries.contains(where: { ($0["id"] as? String) == CuriumVideoPiPExtension.extensionID }) {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(freshManager.installAttempts == 0)
        #expect(!freshManager.entries.contains(where: { ($0["id"] as? String) == retiredID }))

        // 2. Upgraded container: disables pre-existing Desktop Parity, hides it from UI/badges, and removes disk dir.
        let upgradeRoot = root.appending(path: "UpgradeTrusted", directoryHint: .isDirectory)
        let legacyDir = upgradeRoot.appending(path: "curium_desktop_parity", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDir.appending(path: "manifest.json"))

        let upgradeManager = MockRetiredParityUpgradeManager(trustedRootPath: upgradeRoot.path)
        upgradeManager.entries = [[
            "id": retiredID,
            "name": "Curium Desktop Parity",
            "version": "1.2.0",
            "enabled": true,
        ]]
        upgradeManager.actionSnapshots[retiredID] = ["isEnabled": true, "badgeText": "99"]
        upgradeManager.blockedCounts[retiredID] = 42

        let store = CuriumExtensionStore(manager: upgradeManager)
        for _ in 0..<40 {
            if let entry = upgradeManager.entries.first(where: { ($0["id"] as? String) == retiredID }),
               (entry["enabled"] as? Bool) == false {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let parityEntry = try #require(
            upgradeManager.entries.first(where: { ($0["id"] as? String) == retiredID })
        )
        #expect(upgradeManager.installAttempts == 0)
        #expect((parityEntry["enabled"] as? Bool) == false)
        #expect(!FileManager.default.fileExists(atPath: legacyDir.path))

        store.refresh(tabID: 1, includeBlockedCounts: true)
        #expect(store.installed.isEmpty)
        #expect(store.badge == nil)
        #expect(store.blockedCount == nil)
    }
}
