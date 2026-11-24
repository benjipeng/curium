import CryptoKit
import Foundation
import Security

/// Continuous real-world Apple Silicon macOS population sampler.
///
/// Combines four orthogonal, empirically verified authentic axes:
/// 1. 18 weighted genuine Apple Silicon SKUs (`M1` through `M4 Pro`, 8–14 CPU cores,
///    W3C/Chromium spec-capped `navigator.deviceMemory = 8`)
/// 2. 14 authentic public Apple macOS point releases strictly aligned to each chip's
///    minimum shipping OS (`14.x` Sonoma for M1–M3, `15.x` Sequoia for M1–M4, `26.x` Tahoe for all)
/// 3. 8 authentic Chrome Stable desktop builds (`156.0.8078.*` / `157.0.8103.*` / `158.0.8127.*`
///    with User-Agent Reduction `Chrome/<major>.0.0.0` preserved)
/// 4. 15 authentic `@2x` 30-bit Apple Retina & HiDPI displays whose `availHeight >= 960`
///    (immune to `0110` viewport height-stretching on both `slab` and `duo` Portrait) paired
///    with continuous pixel-granular visible Dock geometry (80% bottom `38–84 pt`, 20% right
///    `44–78 pt` so `window.screenX === 0 >= availLeft`) and accurate notched (`38 pt`) vs
///    non-notched (`25 pt`) menu bar heights.
///
/// Paired with `CuriumProfileFontManager`'s 45 clean 5–6 font macOS suites and seeded
/// `s52` TTS voices, every fresh `Personal` install and every new profile draws from a
/// vast authentic Apple Silicon Mac population without storing any burn/replay history.
enum CuriumMacOSManifold {
    struct AppleSiliconSKU: Equatable, Sendable {
        let id: String
        let chipName: String
        let cores: Int
        /// Always `8` per the W3C Device Memory spec and Chromium's `ApproximatedDeviceMemory` ceiling.
        let memoryGB: Double
        /// Minimum major macOS version that could ship on this silicon generation (`14`, `15`, or `26`).
        let minMacOSMajor: Int
        /// Whether this chip generation shipped in notched MacBooks (affecting typical built-in menu bar height).
        let prefersNotchedBuiltIn: Bool

        var webglRenderer: String {
            "ANGLE (Apple, ANGLE Metal Renderer: \(chipName), Unspecified Version)"
        }
    }

    struct MacOSRelease: Equatable, Sendable {
        let major: Int
        let version: String
        let weight: Int
    }

    struct ChromeRelease: Equatable, Sendable {
        let major: String
        let fullVersion: String
        let weight: Int

        var productVersion: String {
            "Chrome/\(major).0.0.0"
        }
    }

    struct DisplayGeometrySpec: Equatable, Sendable {
        let width: Int
        let height: Int
        /// `38` for notched MacBook Air/Pro panels (M2+ Air, M1+ 14"/16" Pro); `25` for iMac and external HiDPI displays.
        let menuBarHeight: Int
        /// `true` for M1–M4 built-in panels that require a notched-capable chip (`false` for iMac / external HiDPI monitors compatible with every chip).
        let isNotchedBuiltIn: Bool
        /// Relative real-world market prevalence weight (avoids rare-device penalties).
        let weight: Int
    }

    enum DockPlacement: Equatable, Sendable {
        /// Bottom Dock inset (`availHeight < height - menuBarHeight`, `availWidth == width`, `availLeft == 0`).
        case bottom
        /// Right-edge Dock inset (`availWidth < width`, `availHeight == height - menuBarHeight`, `availLeft == 0`,
        /// coherent with Chromium's `window.screenX == 0`).
        case right
    }

    struct SampledIdentity: Equatable, Sendable {
        let sku: AppleSiliconSKU
        let macOS: MacOSRelease
        let chrome: ChromeRelease
        let display: DisplayGeometrySpec
        let screen: CuriumScreenOverride
        let dockPlacement: DockPlacement
    }

    /// Extracts the marketing Apple Silicon chip name (e.g. `"Apple M2 Pro"`) from an ANGLE
    /// Metal renderer string (`"ANGLE (Apple, ANGLE Metal Renderer: Apple M2 Pro, Unspecified Version)"`).
    static func chipDisplayName(fromWebGLRenderer renderer: String?) -> String? {
        guard let renderer,
              let prefixRange = renderer.range(of: "ANGLE Metal Renderer: ")
        else {
            return nil
        }
        let remainder = renderer[prefixRange.upperBound...]
        let rawChip = remainder.split(separator: ",", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawChip.isEmpty ? nil : rawChip
    }

    /// 18 genuine Apple Silicon SKUs spanning M1 through M4 Pro (8–14 CPU cores).
    /// All report Chromium's W3C-capped `navigator.deviceMemory = 8` (real Chrome on macOS
    /// never exposes `16` or `32` regardless of physical unified memory).
    static let appleSiliconSKUs: [AppleSiliconSKU] = [
        AppleSiliconSKU(id: "m1-8c-base", chipName: "Apple M1", cores: 8, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: false),
        AppleSiliconSKU(id: "m1-8c-16m", chipName: "Apple M1", cores: 8, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: false),
        AppleSiliconSKU(id: "m1pro-8c", chipName: "Apple M1 Pro", cores: 8, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m1pro-10c-a", chipName: "Apple M1 Pro", cores: 10, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m1pro-10c-b", chipName: "Apple M1 Pro", cores: 10, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m1max-10c", chipName: "Apple M1 Max", cores: 10, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m2-8c-base", chipName: "Apple M2", cores: 8, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m2-8c-16m", chipName: "Apple M2", cores: 8, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m2pro-10c", chipName: "Apple M2 Pro", cores: 10, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m2pro-12c-a", chipName: "Apple M2 Pro", cores: 12, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m2pro-12c-b", chipName: "Apple M2 Pro", cores: 12, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m2max-12c", chipName: "Apple M2 Max", cores: 12, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m3-8c-base", chipName: "Apple M3", cores: 8, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m3-8c-16m", chipName: "Apple M3", cores: 8, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m3pro-11c", chipName: "Apple M3 Pro", cores: 11, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m3pro-12c", chipName: "Apple M3 Pro", cores: 12, memoryGB: 8, minMacOSMajor: 14, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m4-10c", chipName: "Apple M4", cores: 10, memoryGB: 8, minMacOSMajor: 15, prefersNotchedBuiltIn: true),
        AppleSiliconSKU(id: "m4pro-14c", chipName: "Apple M4 Pro", cores: 14, memoryGB: 8, minMacOSMajor: 15, prefersNotchedBuiltIn: true),
    ]

    /// Authentic public Apple macOS point releases (Sonoma 14.x, Sequoia 15.x, Tahoe 26.x)
    /// verified against Apple Support releases through November 2026.
    static let macOSReleases: [MacOSRelease] = [
        // macOS 14 Sonoma (eligible on M1–M3, low EOL weight)
        MacOSRelease(major: 14, version: "14.7.5", weight: 1),
        MacOSRelease(major: 14, version: "14.8.9", weight: 2),
        // macOS 15 Sequoia (eligible on M1–M4)
        MacOSRelease(major: 15, version: "15.6.1", weight: 2),
        MacOSRelease(major: 15, version: "15.7.2", weight: 2),
        MacOSRelease(major: 15, version: "15.7.9", weight: 3),
        MacOSRelease(major: 15, version: "15.8.1", weight: 3),
        MacOSRelease(major: 15, version: "15.8.2", weight: 4),
        MacOSRelease(major: 15, version: "15.8.3", weight: 7),
        // macOS 26 Tahoe (eligible on M1–M4)
        MacOSRelease(major: 26, version: "26.2.0", weight: 3),
        MacOSRelease(major: 26, version: "26.3.1", weight: 4),
        MacOSRelease(major: 26, version: "26.6.1", weight: 4),
        MacOSRelease(major: 26, version: "26.6.2", weight: 5),
        MacOSRelease(major: 26, version: "26.7.2", weight: 6),
        MacOSRelease(major: 26, version: "26.7.3", weight: 9),
    ]

    /// Authentic Chrome Stable macOS desktop builds verified against Chromium Dash / Chrome Releases Blog.
    static let chromeReleases: [ChromeRelease] = [
        ChromeRelease(major: "156", fullVersion: "156.0.8078.48", weight: 1),
        ChromeRelease(major: "156", fullVersion: "156.0.8078.80", weight: 1),
        ChromeRelease(major: "156", fullVersion: "156.0.8078.114", weight: 2),
        ChromeRelease(major: "157", fullVersion: "157.0.8103.39", weight: 1),
        ChromeRelease(major: "157", fullVersion: "157.0.8103.51", weight: 2),
        ChromeRelease(major: "157", fullVersion: "157.0.8103.80", weight: 3),
        ChromeRelease(major: "158", fullVersion: "158.0.8127.37", weight: 5),
        ChromeRelease(major: "158", fullVersion: "158.0.8127.89", weight: 9),
    ]

    /// 11 mainstream `@2x` 30-bit Apple Retina & HiDPI display scaled resolutions whose
    /// available height stays `>= 960 pt` even with the tallest (`84 pt`) Dock, preventing
    /// `0110`'s viewport height-stretching across both `iphone_17_27_2` (`874 pt`) and
    /// `iphone_duo_27_2` Inner Portrait (`951 pt`) while excluding rare custom-scaled panels.
    static let displayGeometries: [DisplayGeometrySpec] = [
        // MacBook Air 15" M2–M4 (notched 38 pt menu bar)
        DisplayGeometrySpec(width: 1710, height: 1107, menuBarHeight: 38, isNotchedBuiltIn: true, weight: 8),
        DisplayGeometrySpec(width: 1920, height: 1243, menuBarHeight: 38, isNotchedBuiltIn: true, weight: 4),
        // MacBook Air 13" M2–M4 "More Space" (notched 38 pt menu bar)
        DisplayGeometrySpec(width: 1710, height: 1112, menuBarHeight: 38, isNotchedBuiltIn: true, weight: 6),
        // MacBook Pro 14" M1–M4 "More Space" (notched 38 pt menu bar)
        DisplayGeometrySpec(width: 1800, height: 1169, menuBarHeight: 38, isNotchedBuiltIn: true, weight: 7),
        // MacBook Pro 16" M1–M4 default & "More Space" (notched 38 pt menu bar)
        DisplayGeometrySpec(width: 1728, height: 1117, menuBarHeight: 38, isNotchedBuiltIn: true, weight: 10),
        DisplayGeometrySpec(width: 2056, height: 1329, menuBarHeight: 38, isNotchedBuiltIn: true, weight: 5),
        // iMac 24" 4.5K Retina (non-notch 25 pt menu bar)
        DisplayGeometrySpec(width: 2048, height: 1152, menuBarHeight: 25, isNotchedBuiltIn: false, weight: 6),
        DisplayGeometrySpec(width: 2240, height: 1260, menuBarHeight: 25, isNotchedBuiltIn: false, weight: 8),
        // Studio Display 27" 5K / 4K-5K-6K HiDPI external displays (non-notch 25 pt menu bar)
        DisplayGeometrySpec(width: 2560, height: 1440, menuBarHeight: 25, isNotchedBuiltIn: false, weight: 10),
        DisplayGeometrySpec(width: 2880, height: 1620, menuBarHeight: 25, isNotchedBuiltIn: false, weight: 5),
        DisplayGeometrySpec(width: 3008, height: 1692, menuBarHeight: 25, isNotchedBuiltIn: false, weight: 6),
    ]

    /// Known authentic macOS menu bar heights for legacy/explicitly selected displays
    /// (including smaller non-sampled laptop panels like Air 13" M1 `1440×900` or Pro 14" `1512×982`).
    private static let knownMenuBarHeights: [String: Int] = {
        var map: [String: Int] = [
            "1280x800": 25,
            "1440x900": 25,
            "1680x1050": 25,
            "1600x900": 25,
            "1600x1000": 25,
            "1920x1080": 25,
            "1920x1200": 25,
            "2304x1296": 25,
            "2560x1600": 25,
            "2688x1512": 25,
            "3072x1728": 25,
            "3200x1800": 25,
            "3360x1890": 25,
            "1280x832": 38,
            "1470x956": 38,
            "1440x932": 38,
            "1147x745": 38,
            "1352x878": 38,
            "1512x982": 38,
            "1312x848": 38,
            "1496x967": 38,
        ]
        for spec in displayGeometries {
            map["\(spec.width)x\(spec.height)"] = spec.menuBarHeight
        }
        return map
    }()

    /// Returns all authentic public macOS releases compatible with `minMacOSMajor`.
    static func eligibleMacOSReleases(minMajor: Int) -> [MacOSRelease] {
        let filtered = macOSReleases.filter { $0.major >= minMajor }
        return filtered.isEmpty ? macOSReleases.filter { $0.major >= 26 } : filtered
    }

    /// Infers the authentic macOS menu bar height (`38 pt` for notched MacBook resolutions,
    /// `25 pt` for non-notched Air M1 / iMac / external displays) from a profile's screen override.
    static func inferredMenuBarHeight(for screen: CuriumScreenOverride?) -> Int {
        guard let screen else { return 38 }
        return knownMenuBarHeights["\(screen.width)x\(screen.height)"] ?? 38
    }

    /// Side Docks are placed on the right edge (`availLeft == 0`) so `window.screenX === 0`
    /// never falls underneath a left Dock.
    static func prefersLeftDock(forProfileSeed _: String?) -> Bool {
        false
    }

    /// Samples a fresh, hardware-era-coherent Apple Silicon macOS identity using CSPRNG
    /// (`SecRandomCopyBytes`), avoiding duplicating active profiles' `(chip, screen)` tuples
    /// when `avoiding` or `excluding` is provided.
    static func sampleIdentity(
        avoiding existingProfiles: [CuriumFingerprintProfile] = [],
        excluding currentProfile: CuriumFingerprintProfile? = nil
    ) -> SampledIdentity {
        let activePeers = existingProfiles.filter { candidate in
            guard let currentProfile else { return true }
            return candidate.id.lowercased() != currentProfile.id.lowercased()
        }

        // 1. Sample an authentic Apple Silicon SKU preferring chips unused by active peers.
        let excludedRenderer = currentProfile.map { primarySlot(in: $0).webglRenderer } ?? nil
        let usedRenderers = Set(activePeers.compactMap { primarySlot(in: $0).webglRenderer })

        var skuCandidates = appleSiliconSKUs.filter { $0.webglRenderer != excludedRenderer }
        if skuCandidates.isEmpty { skuCandidates = appleSiliconSKUs }
        let freshSKUs = skuCandidates.filter { !usedRenderers.contains($0.webglRenderer) }
        let sku = randomElement(from: freshSKUs.isEmpty ? skuCandidates : freshSKUs)

        // 2. Sample a real Apple macOS point release coherent with the SKU's minimum shipping OS.
        let osPool = eligibleMacOSReleases(minMajor: sku.minMacOSMajor)
        let macOS = weightedRandomElement(from: osPool, weight: \.weight)

        // 3. Sample a verified Chrome Stable build (preserving reduced UA `Chrome/<major>.0.0.0`).
        let chrome = weightedRandomElement(from: chromeReleases, weight: \.weight)

        // 4. Sample an authentic @2x Retina/HiDPI display avoiding resolutions already active.
        let usedResolutions = Set(activePeers.compactMap { peer -> String? in
            guard let s = primarySlot(in: peer).screen else { return nil }
            return "\(s.width)x\(s.height)"
        })
        let excludedRes: String? = currentProfile.flatMap { cur in
            guard let s = primarySlot(in: cur).screen else { return nil }
            return "\(s.width)x\(s.height)"
        }
        var displayPool = displayGeometries.filter { spec in
            if spec.isNotchedBuiltIn && !sku.prefersNotchedBuiltIn {
                return false
            }
            return "\(spec.width)x\(spec.height)" != excludedRes
        }
        if displayPool.isEmpty { displayPool = displayGeometries }
        let freshDisplays = displayPool.filter { !usedResolutions.contains("\($0.width)x\($0.height)") }
        let display = weightedRandomElement(from: freshDisplays.isEmpty ? displayPool : freshDisplays, weight: \.weight)

        // 5. Sample continuous pixel-granular visible Dock geometry (80% bottom, 20% right —
        //    preserving `availLeft == 0` so `window.screenX == 0` never clips under a left Dock).
        let dockPlacement: DockPlacement = randomInt(in: 0..<100) < 80 ? .bottom : .right

        let screen: CuriumScreenOverride
        switch dockPlacement {
        case .bottom:
            // Continuous Dock height 38..84 pt below the 25/38 pt macOS menu bar.
            let dockHeight = randomInt(in: 38...84)
            let availHeight = max(240, display.height - display.menuBarHeight - dockHeight)
            screen = CuriumScreenOverride(
                width: display.width,
                height: display.height,
                availWidth: display.width,
                availHeight: availHeight,
                colorDepth: 30
            )
        case .right:
            // Continuous right-side Dock width 44..78 pt alongside the 25/38 pt top menu bar.
            let dockWidth = randomInt(in: 44...78)
            let availWidth = max(240, display.width - dockWidth)
            let availHeight = max(240, display.height - display.menuBarHeight)
            screen = CuriumScreenOverride(
                width: display.width,
                height: display.height,
                availWidth: availWidth,
                availHeight: availHeight,
                colorDepth: 30
            )
        }

        return SampledIdentity(
            sku: sku,
            macOS: macOS,
            chrome: chrome,
            display: display,
            screen: screen,
            dockPlacement: dockPlacement
        )
    }

    /// Applies `identity` onto both desktop-aligned slots and hardware overrides of `profile`,
    /// preserving `id`, `displayName`, `proxy`, `timezone`, `languages`, `farbling`, and `fingerprintSeed`.
    static func apply(_ identity: SampledIdentity, to profile: CuriumFingerprintProfile) -> CuriumFingerprintProfile {
        var copy = profile
        applySlotFields(identity, to: &copy.desktop)
        if copy.mobile.mobile != true {
            applySlotFields(identity, to: &copy.mobile)
        }
        copy.hardware.hardwareConcurrency = identity.sku.cores
        copy.hardware.deviceMemoryGB = identity.sku.memoryGB
        copy.fontProfile = .apple
        copy.hideSpeechVoices = false
        return copy
    }

    private static func applySlotFields(_ identity: SampledIdentity, to slot: inout CuriumIdentitySlot) {
        slot.osCpu = "Macintosh; Intel Mac OS X 10_15_7"
        slot.appendMobileToken = false
        slot.primaryBrand = "Google Chrome"
        slot.majorVersion = identity.chrome.major
        slot.fullVersion = identity.chrome.fullVersion
        slot.productVersion = identity.chrome.productVersion
        slot.platform = "macOS"
        slot.platformVersion = identity.macOS.version
        slot.architecture = "arm"
        slot.bitness = "64"
        slot.model = ""
        slot.mobile = false
        slot.wow64 = false
        slot.formFactors = ["Desktop"]
        slot.navigatorPlatform = "MacIntel"
        slot.maxTouchPoints = 0
        slot.pointerType = .fine
        slot.hoverType = .hover
        slot.webglVendor = "Google Inc. (Apple)"
        slot.webglRenderer = identity.sku.webglRenderer
        slot.webglProfile = .native
        slot.screen = identity.screen
        slot.pdfViewerEnabled = true
    }

    private static func primarySlot(in profile: CuriumFingerprintProfile) -> CuriumIdentitySlot {
        profile.defaultSlot == .desktop ? profile.desktop : profile.mobile
    }

    private static func randomUInt64() -> UInt64 {
        var value: UInt64 = 0
        let status = withUnsafeMutableBytes(of: &value) { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        if status != errSecSuccess {
            return UInt64.random(in: UInt64.min...UInt64.max)
        }
        return value
    }

    private static func randomInt(in range: Range<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound)
        return range.lowerBound + Int(randomUInt64() % span)
    }

    private static func randomInt(in range: ClosedRange<Int>) -> Int {
        randomInt(in: range.lowerBound..<(range.upperBound + 1))
    }

    private static func randomElement<T>(from array: [T]) -> T {
        array[randomInt(in: 0..<array.count)]
    }

    private static func weightedRandomElement<T>(from array: [T], weight: (T) -> Int) -> T {
        let total = array.reduce(0) { $0 + max(1, weight($1)) }
        var target = randomInt(in: 0..<total)
        for item in array {
            let w = max(1, weight(item))
            if target < w {
                return item
            }
            target -= w
        }
        return array[0]
    }
}
