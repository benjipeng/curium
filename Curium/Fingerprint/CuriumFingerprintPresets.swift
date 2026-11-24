import Foundation

/// Current full Stable Google Chrome release baseline anchored across all verified templates.
enum CuriumChromeStableBaseline {
    static let majorVersion = "158"
    static let fullVersion = "158.0.8127.89"
    static let productVersion = "Chrome/158.0.0.0"
    static let macOSPlatformVersion = "26.7.3"
    static let androidPlatformVersion = "15.0.0"
}

/// Verified built-in downstream fingerprint profiles. Adding or tuning presets requires
/// only Swift edits — no Chromium rebuild needed.
enum CuriumFingerprintPresets {
    /// Curated, empirically verified built-in presets exposed as creation archetypes.
    /// Curium commits strictly to native Apple Silicon macOS Chrome 158 so hardware,
    /// CoreText, CoreAudio, and Metal foundations stay 100% coherent across displays.
    static let allBuiltIns: [CuriumFingerprintProfile] = [
        macosDesktopFirst,
        privacyHardened,
    ]

    static let builtInIDs: Set<String> = Set(allBuiltIns.map(\.id)).union(["default"])

    /// Legacy v1 built-in preset IDs retired from new-profile templates after empirical
    /// anti-detect feasibility testing (unverified x86_64 or impossible iOS Blink stacks).
    /// Retained strictly as reserved slugs so APFS directories and v1->v2 migrations stay safe.
    static let retiredLegacyBuiltInIDs: Set<String> = [
        "ios-blink",
        "win11-workstation",
        "linux-desktop",
        "pixel-android",
    ]

    /// Complete set of current + retired built-in slugs reserved against direct upsert collisions.
    static let reservedBuiltInIDs: Set<String> = builtInIDs.union(retiredLegacyBuiltInIDs)

    /// Exact unconfigured Build 39 (`patches/0105`) baseline used exclusively when
    /// `selectedProfileID == nil` (`CuriumConfigureLaunchFingerprint(nil, nil)`), keeping
    /// unconfigured `"default"` (`Personal`) and Settings' legacy UA pickers 100% faithful
    /// to what the engine actually runs.
    static let build39NativeBaseline = CuriumFingerprintProfile(
        id: "default",
        displayName: "Authentic Chrome (Default)",
        notes: "Build 39 unconfigured baseline (Android 15 Mobile + macOS Desktop with native Apple hardware).",
        isBuiltIn: true,
        revision: 1,
        defaultSlot: .mobile,
        mobile: CuriumIdentitySlot(
            osCpu: "Linux; Android 10; K",
            appendMobileToken: true,
            primaryBrand: "Google Chrome",
            platform: "Android",
            platformVersion: "15.0.0",
            architecture: "",
            bitness: "",
            model: "",
            mobile: true,
            wow64: false,
            formFactors: ["Mobile"],
            navigatorPlatform: "Linux armv81"
        ),
        desktop: CuriumIdentitySlot(
            osCpu: "Macintosh; Intel Mac OS X 10_15_7",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "macOS",
            architecture: "arm",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "MacIntel"
        ),
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .default,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: .native
    )

    /// Shared macOS arm64 Chrome 158 Stable desktop slot aligned with real macOS Chrome 158
    /// (`platformVersion: "27.2.1"`, Apple M3 14" 1512×982 30-bit display, `webglProfile: .native`,
    /// desktop input & PDF viewer enabled).
    static let stableMacOSDesktopSlot = CuriumIdentitySlot(
        osCpu: "Macintosh; Intel Mac OS X 10_15_7",
        productVersion: CuriumChromeStableBaseline.productVersion,
        appendMobileToken: false,
        primaryBrand: "Google Chrome",
        majorVersion: CuriumChromeStableBaseline.majorVersion,
        fullVersion: CuriumChromeStableBaseline.fullVersion,
        platform: "macOS",
        platformVersion: CuriumChromeStableBaseline.macOSPlatformVersion,
        architecture: "arm",
        bitness: "64",
        model: "",
        mobile: false,
        wow64: false,
        formFactors: ["Desktop"],
        navigatorPlatform: "MacIntel",
        maxTouchPoints: 0,
        pointerType: .fine,
        hoverType: .hover,
        webglVendor: "Google Inc. (Apple)",
        webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M3, Unspecified Version)",
        screen: CuriumScreenOverride(
            width: 1512,
            height: 982,
            availWidth: 1512,
            availHeight: 914,
            colorDepth: 30
        ),
        webglProfile: .native,
        pdfViewerEnabled: true
    )

    /// Recommended desktop-first macOS ARM64 Chrome 158 Stable profile anchored on a
    /// coherent Apple M3 14" (8c / 16 GB / 1512×982 30-bit) baseline with selectable M1–M5 chips.
    static let macosDesktopFirst = CuriumFingerprintProfile(
        id: "macos-desktop",
        displayName: "macOS Desktop (Apple Silicon)",
        notes: "Verified macOS arm64 Chrome 158 Stable profile across all tabs and workers with native Apple Silicon architecture, selectable M1–M5 chips, and 8–32 GB RAM tiers.",
        isBuiltIn: true,
        revision: 2,
        defaultSlot: .desktop,
        mobile: stableMacOSDesktopSlot,
        desktop: stableMacOSDesktopSlot,
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .default,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: CuriumHardwareOverrides(
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            timezone: nil
        ),
        fontProfile: .apple,
        hideSpeechVoices: false
    )

    /// Verified dual-slot Mobile Chrome 158 Stable profile: Android 15 Reduced-UA Mobile
    /// masked with coherent non-Apple Adreno WebGL strings, explicit `webglProfile: .native`
    /// (avoiding extension-stripping VM penalties), 412×915 screen, Android font filtering,
    /// and 8-core/8 GB hardware, paired with a macOS arm64 Chrome 158 Desktop slot.
    static let defaultAuthenticChrome = CuriumFingerprintProfile(
        id: "default",
        displayName: "Mobile Chrome (Android 15)",
        notes: "Android 15 Chrome 158 Stable on Mobile with coherent Adreno/Mali WebGL strings, native WebGL extension profile (no VM stripping penalty), 412×915 screen, Android font filtering, and 8-core/8 GB hardware, paired with a macOS arm64 Desktop slot.",
        isBuiltIn: true,
        revision: 3,
        defaultSlot: .mobile,
        mobile: CuriumIdentitySlot(
            osCpu: "Linux; Android 10; K",
            productVersion: CuriumChromeStableBaseline.productVersion,
            appendMobileToken: true,
            primaryBrand: "Google Chrome",
            majorVersion: CuriumChromeStableBaseline.majorVersion,
            fullVersion: CuriumChromeStableBaseline.fullVersion,
            platform: "Android",
            platformVersion: CuriumChromeStableBaseline.androidPlatformVersion,
            architecture: "",
            bitness: "",
            model: "",
            mobile: true,
            wow64: false,
            formFactors: ["Mobile"],
            navigatorPlatform: "Linux armv81",
            webglVendor: "Google Inc. (Qualcomm)",
            webglRenderer: "ANGLE (Qualcomm, Adreno (TM) 750, OpenGL ES 3.2)",
            screen: .mobilePixel9,
            webglProfile: .native
        ),
        desktop: stableMacOSDesktopSlot,
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .default,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: CuriumHardwareOverrides(
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            timezone: nil
        ),
        fontProfile: .android,
        hideSpeechVoices: true
    )

    /// Privacy-hardened macOS ARM64 Chrome 158 Stable profile built on the verified
    /// Apple Silicon desktop stack with deterministic per-site C++ farbling, non-proxied
    /// WebRTC UDP lockdown, and Global Privacy Control (`Sec-GPC: 1`).
    /// `fingerprintSeed` is intentionally `nil` here; `CuriumFingerprintStore` materializes
    /// and persists a fresh per-install 256-bit random seed.
    static let privacyHardened = CuriumFingerprintProfile(
        id: "privacy-hardened",
        displayName: "Privacy Hardened (macOS)",
        notes: "Verified macOS arm64 Chrome 158 Stable profile with deterministic per-site Canvas/Audio/WebGL/TextMetrics farbling, non-proxied WebRTC UDP disabled, and Global Privacy Control enabled.",
        isBuiltIn: true,
        revision: 4,
        defaultSlot: .desktop,
        mobile: stableMacOSDesktopSlot,
        desktop: stableMacOSDesktopSlot,
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .disableNonProxiedUdp,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: true,
        hardware: CuriumHardwareOverrides(
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            timezone: nil
        ),
        fingerprintSeed: nil,
        farbling: .allEnabled,
        fontProfile: .apple,
        hideSpeechVoices: false
    )

    /// Rolls a coherent hardware/GPU/screen/OS/Chrome variant for `profile` from the
    /// continuous real-Mac Apple Silicon manifold (`CuriumMacOSManifold`), avoiding
    /// `profile`'s current hardware/display and active `existingProfiles`.
    /// Returns `nil` for legacy/custom archetypes without a verified macOS pool.
    /// Never mutates `id`, `displayName`, `proxy`, `timezone`, `languages`, or `fingerprintSeed`.
    static func rollCoherentHardwareVariant(
        for profile: CuriumFingerprintProfile,
        avoiding existingProfiles: [CuriumFingerprintProfile] = []
    ) -> CuriumFingerprintProfile? {
        guard CuriumFingerprintDevicePools.poolID(for: profile) != nil else {
            return nil
        }
        let sampled = CuriumMacOSManifold.sampleIdentity(
            avoiding: existingProfiles,
            excluding: profile
        )
        return CuriumMacOSManifold.apply(sampled, to: profile)
    }
}

/// Coherent hardware, GPU, screen, Chrome version, and Client Hint variant for multi-variant
/// fingerprint templates. Every variant obeys Build 42 C++ schema v2 limits and passes
/// `CuriumFingerprintValidator.validate(_:)` with zero errors and zero warnings.
struct CuriumHardwareProfileVariant: Identifiable, Equatable, Sendable {
    let id: String
    let poolID: String
    let label: String
    /// Desktop-first archetypes apply slot overrides to `desktop` (and `mobile` when
    /// `mobile.mobile != true`); mobile-first dual-slot archetypes (e.g. Android) apply
    /// slot overrides exclusively to `mobile`.
    let appliesToBothSlots: Bool

    let majorVersion: String?
    let fullVersion: String?
    let productVersion: String?
    let platformVersion: String?
    let model: String?
    let architecture: String?
    let bitness: String?
    let navigatorPlatform: String?

    let webglVendor: String
    let webglRenderer: String
    let webglProfile: CuriumWebGLProfile
    let screen: CuriumScreenOverride

    let maxTouchPoints: Int?
    let pointerType: CuriumPointerType?
    let hoverType: CuriumHoverType?
    let pdfViewerEnabled: Bool?

    let hardwareConcurrency: Int
    let deviceMemoryGB: Double
    let fontProfile: CuriumFontProfile
    let hideSpeechVoices: Bool?

    init(
        id: String,
        poolID: String,
        label: String,
        appliesToBothSlots: Bool,
        majorVersion: String? = CuriumChromeStableBaseline.majorVersion,
        fullVersion: String? = CuriumChromeStableBaseline.fullVersion,
        productVersion: String? = CuriumChromeStableBaseline.productVersion,
        platformVersion: String?,
        model: String?,
        architecture: String?,
        bitness: String?,
        navigatorPlatform: String?,
        webglVendor: String,
        webglRenderer: String,
        webglProfile: CuriumWebGLProfile,
        screen: CuriumScreenOverride,
        maxTouchPoints: Int?,
        pointerType: CuriumPointerType?,
        hoverType: CuriumHoverType?,
        pdfViewerEnabled: Bool?,
        hardwareConcurrency: Int,
        deviceMemoryGB: Double,
        fontProfile: CuriumFontProfile,
        hideSpeechVoices: Bool?
    ) {
        self.id = id
        self.poolID = poolID
        self.label = label
        self.appliesToBothSlots = appliesToBothSlots
        self.majorVersion = majorVersion
        self.fullVersion = fullVersion
        self.productVersion = productVersion
        self.platformVersion = platformVersion
        self.model = model
        self.architecture = architecture
        self.bitness = bitness
        self.navigatorPlatform = navigatorPlatform
        self.webglVendor = webglVendor
        self.webglRenderer = webglRenderer
        self.webglProfile = webglProfile
        self.screen = screen
        self.maxTouchPoints = maxTouchPoints
        self.pointerType = pointerType
        self.hoverType = hoverType
        self.pdfViewerEnabled = pdfViewerEnabled
        self.hardwareConcurrency = hardwareConcurrency
        self.deviceMemoryGB = deviceMemoryGB
        self.fontProfile = fontProfile
        self.hideSpeechVoices = hideSpeechVoices
    }

    /// Applies this hardware/GPU/screen variant to `profile` without touching `id`,
    /// `displayName`, `proxy`, `hardware.timezone`, `languages`, or `fingerprintSeed`.
    func apply(to profile: CuriumFingerprintProfile) -> CuriumFingerprintProfile {
        var copy = profile
        if appliesToBothSlots {
            applySlotFields(to: &copy.desktop)
            if copy.mobile.mobile != true {
                applySlotFields(to: &copy.mobile)
            }
        } else {
            applySlotFields(to: &copy.mobile)
            // Keep the companion macOS Desktop slot aligned with Stable Chrome 158 when
            // upgrading an unconfigured Build 39 baseline profile onto a verified variant.
            if copy.desktop.platform == "macOS" && copy.desktop.majorVersion == nil {
                copy.desktop.majorVersion = majorVersion
                copy.desktop.fullVersion = fullVersion
                copy.desktop.productVersion = productVersion
                copy.desktop.platformVersion = copy.desktop.platformVersion ?? CuriumChromeStableBaseline.macOSPlatformVersion
                copy.desktop.webglProfile = copy.desktop.webglProfile ?? .native
            }
        }
        copy.hardware.hardwareConcurrency = hardwareConcurrency
        copy.hardware.deviceMemoryGB = deviceMemoryGB
        copy.fontProfile = fontProfile
        if let hideSpeechVoices {
            copy.hideSpeechVoices = hideSpeechVoices
        }
        return copy
    }

    /// True when `profile`'s primary slot and hardware overrides match this variant.
    func matches(_ profile: CuriumFingerprintProfile) -> Bool {
        let slot = primarySlot(in: profile)
        guard slot.webglVendor == webglVendor,
              slot.webglRenderer == webglRenderer,
              slot.screen == screen,
              profile.hardware.hardwareConcurrency == hardwareConcurrency,
              profile.hardware.deviceMemoryGB == deviceMemoryGB
        else {
            return false
        }
        if let model, !model.isEmpty, slot.model != model {
            return false
        }
        if let platformVersion, slot.platformVersion != platformVersion {
            return false
        }
        return true
    }

    /// True when `profile` shares this variant's identifying GPU/screen/model signature
    /// (used to ensure rolling always moves away from the profile's current device).
    func sharesSignature(with profile: CuriumFingerprintProfile) -> Bool {
        if matches(profile) {
            return true
        }
        let slot = primarySlot(in: profile)
        if slot.webglVendor == webglVendor && slot.webglRenderer == webglRenderer {
            return true
        }
        if let model, !model.isEmpty, slot.model == model, slot.screen == screen {
            return true
        }
        return false
    }

    private func primarySlot(in profile: CuriumFingerprintProfile) -> CuriumIdentitySlot {
        if appliesToBothSlots {
            return profile.defaultSlot == .desktop ? profile.desktop : profile.mobile
        }
        return profile.mobile
    }

    private func applySlotFields(to slot: inout CuriumIdentitySlot) {
        if let majorVersion {
            slot.majorVersion = majorVersion
        }
        if let fullVersion {
            slot.fullVersion = fullVersion
        }
        if let productVersion {
            slot.productVersion = productVersion
        }
        if let platformVersion {
            slot.platformVersion = platformVersion
        }
        if let model {
            slot.model = model
        }
        if let architecture {
            slot.architecture = architecture
        }
        if let bitness {
            slot.bitness = bitness
        }
        if let navigatorPlatform {
            slot.navigatorPlatform = navigatorPlatform
        }
        slot.webglVendor = webglVendor
        slot.webglRenderer = webglRenderer
        slot.webglProfile = webglProfile
        slot.screen = screen
        if let maxTouchPoints {
            slot.maxTouchPoints = maxTouchPoints
        }
        if let pointerType {
            slot.pointerType = pointerType
        }
        if let hoverType {
            slot.hoverType = hoverType
        }
        if let pdfViewerEnabled {
            slot.pdfViewerEnabled = pdfViewerEnabled
        }
    }
}

/// Curated coherent hardware/GPU/screen pools for verified fingerprint templates.
enum CuriumFingerprintDevicePools {
    /// Apple Silicon M1–M5 Max tiers spanning 8–18 CPU cores and spec-capped 8 GB
    /// `navigator.deviceMemory` (matching real macOS Chrome's W3C Device Memory cap),
    /// verified Chrome Stable releases, real macOS point releases, Dock frames, and 30-bit P3 displays.
    private static func makeMacOSAppleSiliconVariants(poolID: String) -> [CuriumHardwareProfileVariant] {
        [
            CuriumHardwareProfileVariant(
                id: "\(poolID)-m1-8c-8g-1440x900",
                poolID: poolID,
                label: "Apple M1 · 8c · 1440×900",
                appliesToBothSlots: true,
                majorVersion: "157",
                fullVersion: "157.0.8103.80",
                productVersion: "Chrome/157.0.0.0",
                platformVersion: "15.8.3",
                model: "",
                architecture: "arm",
                bitness: "64",
                navigatorPlatform: "MacIntel",
                webglVendor: "Google Inc. (Apple)",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)",
                webglProfile: .native,
                screen: CuriumScreenOverride(width: 1440, height: 900, availWidth: 1440, availHeight: 836, colorDepth: 30),
                maxTouchPoints: 0,
                pointerType: .fine,
                hoverType: .hover,
                pdfViewerEnabled: true,
                hardwareConcurrency: 8,
                deviceMemoryGB: 8,
                fontProfile: .apple,
                hideSpeechVoices: false
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-m2-8c-8g-1470x956",
                poolID: poolID,
                label: "Apple M2 · 8c · 1470×956",
                appliesToBothSlots: true,
                majorVersion: CuriumChromeStableBaseline.majorVersion,
                fullVersion: CuriumChromeStableBaseline.fullVersion,
                productVersion: CuriumChromeStableBaseline.productVersion,
                platformVersion: "26.6.2",
                model: "",
                architecture: "arm",
                bitness: "64",
                navigatorPlatform: "MacIntel",
                webglVendor: "Google Inc. (Apple)",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M2, Unspecified Version)",
                webglProfile: .native,
                screen: CuriumScreenOverride(width: 1470, height: 956, availWidth: 1470, availHeight: 890, colorDepth: 30),
                maxTouchPoints: 0,
                pointerType: .fine,
                hoverType: .hover,
                pdfViewerEnabled: true,
                hardwareConcurrency: 8,
                deviceMemoryGB: 8,
                fontProfile: .apple,
                hideSpeechVoices: false
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-m3-8c-16g-1512x982",
                poolID: poolID,
                label: "Apple M3 · 8c · 1512×982",
                appliesToBothSlots: true,
                majorVersion: CuriumChromeStableBaseline.majorVersion,
                fullVersion: CuriumChromeStableBaseline.fullVersion,
                productVersion: CuriumChromeStableBaseline.productVersion,
                platformVersion: CuriumChromeStableBaseline.macOSPlatformVersion,
                model: "",
                architecture: "arm",
                bitness: "64",
                navigatorPlatform: "MacIntel",
                webglVendor: "Google Inc. (Apple)",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M3, Unspecified Version)",
                webglProfile: .native,
                screen: CuriumScreenOverride(width: 1512, height: 982, availWidth: 1512, availHeight: 914, colorDepth: 30),
                maxTouchPoints: 0,
                pointerType: .fine,
                hoverType: .hover,
                pdfViewerEnabled: true,
                hardwareConcurrency: 8,
                deviceMemoryGB: 8,
                fontProfile: .apple,
                hideSpeechVoices: false
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-m3pro-12c-16g-1728x1117",
                poolID: poolID,
                label: "Apple M3 Pro · 12c · 1728×1117",
                appliesToBothSlots: true,
                majorVersion: CuriumChromeStableBaseline.majorVersion,
                fullVersion: "158.0.8127.37",
                productVersion: CuriumChromeStableBaseline.productVersion,
                platformVersion: "26.7.2",
                model: "",
                architecture: "arm",
                bitness: "64",
                navigatorPlatform: "MacIntel",
                webglVendor: "Google Inc. (Apple)",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M3 Pro, Unspecified Version)",
                webglProfile: .native,
                screen: CuriumScreenOverride(width: 1728, height: 1117, availWidth: 1728, availHeight: 1049, colorDepth: 30),
                maxTouchPoints: 0,
                pointerType: .fine,
                hoverType: .hover,
                pdfViewerEnabled: true,
                hardwareConcurrency: 12,
                deviceMemoryGB: 8,
                fontProfile: .apple,
                hideSpeechVoices: false
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-m4-10c-16g-1680x1050",
                poolID: poolID,
                label: "Apple M4 · 10c · 1680×1050",
                appliesToBothSlots: true,
                majorVersion: "156",
                fullVersion: "156.0.8078.114",
                productVersion: "Chrome/156.0.0.0",
                platformVersion: "26.7.3",
                model: "",
                architecture: "arm",
                bitness: "64",
                navigatorPlatform: "MacIntel",
                webglVendor: "Google Inc. (Apple)",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)",
                webglProfile: .native,
                screen: CuriumScreenOverride(width: 1680, height: 1050, availWidth: 1680, availHeight: 982, colorDepth: 30),
                maxTouchPoints: 0,
                pointerType: .fine,
                hoverType: .hover,
                pdfViewerEnabled: true,
                hardwareConcurrency: 10,
                deviceMemoryGB: 8,
                fontProfile: .apple,
                hideSpeechVoices: false
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-m4pro-14c-32g-1728x1117",
                poolID: poolID,
                label: "Apple M4 Pro · 14c · 1728×1117",
                appliesToBothSlots: true,
                majorVersion: CuriumChromeStableBaseline.majorVersion,
                fullVersion: CuriumChromeStableBaseline.fullVersion,
                productVersion: CuriumChromeStableBaseline.productVersion,
                platformVersion: "15.8.3",
                model: "",
                architecture: "arm",
                bitness: "64",
                navigatorPlatform: "MacIntel",
                webglVendor: "Google Inc. (Apple)",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M4 Pro, Unspecified Version)",
                webglProfile: .native,
                screen: CuriumScreenOverride(width: 1728, height: 1117, availWidth: 1668, availHeight: 1079, colorDepth: 30),
                maxTouchPoints: 0,
                pointerType: .fine,
                hoverType: .hover,
                pdfViewerEnabled: true,
                hardwareConcurrency: 14,
                deviceMemoryGB: 8,
                fontProfile: .apple,
                hideSpeechVoices: false
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-m4max-16c-32g-2560x1440",
                poolID: poolID,
                label: "Apple M4 Max · 16c · 2560×1440",
                appliesToBothSlots: true,
                majorVersion: "157",
                fullVersion: "157.0.8103.51",
                productVersion: "Chrome/157.0.0.0",
                platformVersion: "15.8.2",
                model: "",
                architecture: "arm",
                bitness: "64",
                navigatorPlatform: "MacIntel",
                webglVendor: "Google Inc. (Apple)",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M4 Max, Unspecified Version)",
                webglProfile: .native,
                screen: CuriumScreenOverride(width: 2560, height: 1440, availWidth: 2500, availHeight: 1415, colorDepth: 30),
                maxTouchPoints: 0,
                pointerType: .fine,
                hoverType: .hover,
                pdfViewerEnabled: true,
                hardwareConcurrency: 16,
                deviceMemoryGB: 8,
                fontProfile: .apple,
                hideSpeechVoices: false
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-m5max-18c-32g-2560x1440",
                poolID: poolID,
                label: "Apple M5 Max · 18c · 2560×1440",
                appliesToBothSlots: true,
                majorVersion: CuriumChromeStableBaseline.majorVersion,
                fullVersion: CuriumChromeStableBaseline.fullVersion,
                productVersion: CuriumChromeStableBaseline.productVersion,
                platformVersion: CuriumChromeStableBaseline.macOSPlatformVersion,
                model: "",
                architecture: "arm",
                bitness: "64",
                navigatorPlatform: "MacIntel",
                webglVendor: "Google Inc. (Apple)",
                webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M5 Max, Unspecified Version)",
                webglProfile: .native,
                screen: CuriumScreenOverride(width: 2560, height: 1440, availWidth: 2560, availHeight: 1372, colorDepth: 30),
                maxTouchPoints: 0,
                pointerType: .fine,
                hoverType: .hover,
                pdfViewerEnabled: true,
                hardwareConcurrency: 18,
                deviceMemoryGB: 8,
                fontProfile: .apple,
                hideSpeechVoices: false
            ),
        ]
    }

    static let macosDesktop: [CuriumHardwareProfileVariant] =
        makeMacOSAppleSiliconVariants(poolID: CuriumFingerprintPresets.macosDesktopFirst.id)

    static let macosPrivacyHardened: [CuriumHardwareProfileVariant] =
        makeMacOSAppleSiliconVariants(poolID: CuriumFingerprintPresets.privacyHardened.id)

    static let allPools: [String: [CuriumHardwareProfileVariant]] = [
        CuriumFingerprintPresets.macosDesktopFirst.id: macosDesktop,
        CuriumFingerprintPresets.privacyHardened.id: macosPrivacyHardened,
    ]

    static func variants(forTemplateID templateID: String?) -> [CuriumHardwareProfileVariant] {
        guard let key = templateID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty else {
            return []
        }
        return allPools[key] ?? []
    }

    static func variant(forTemplateID templateID: String?, variantID: String?) -> CuriumHardwareProfileVariant? {
        guard let targetID = variantID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !targetID.isEmpty else {
            return nil
        }
        return variants(forTemplateID: templateID).first { $0.id.lowercased() == targetID }
    }

    static func variants(forProfile profile: CuriumFingerprintProfile) -> [CuriumHardwareProfileVariant] {
        guard let poolID = poolID(for: profile) else { return [] }
        return variants(forTemplateID: poolID)
    }

    static func poolID(for profile: CuriumFingerprintProfile) -> String? {
        let templateKey = profile.templateID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let primarySlot = profile.defaultSlot == .desktop ? profile.desktop : profile.mobile
        let platformPool: String?
        switch primarySlot.platform {
        case "macOS":
            if templateKey == CuriumFingerprintPresets.privacyHardened.id {
                platformPool = CuriumFingerprintPresets.privacyHardened.id
            } else {
                platformPool = CuriumFingerprintPresets.macosDesktopFirst.id
            }
        default:
            platformPool = nil
        }

        if let templateKey, allPools[templateKey] != nil {
            if let platformPool, platformPool != templateKey {
                return platformPool
            }
            return templateKey
        }
        return platformPool
    }

    static func selectVariant(
        forPoolID poolID: String,
        avoiding existingProfiles: [CuriumFingerprintProfile],
        excluding currentProfile: CuriumFingerprintProfile?
    ) -> CuriumHardwareProfileVariant? {
        let pool = variants(forTemplateID: poolID)
        guard !pool.isEmpty else { return nil }

        let relevantExisting = existingProfiles.filter { candidate in
            guard let currentProfile else { return true }
            return candidate.id.lowercased() != currentProfile.id.lowercased()
        }

        var usageCounts = [Int](repeating: 0, count: pool.count)
        var lastUsedIndex: Int?
        for existing in relevantExisting {
            if let matchedIdx = matchedVariantIndex(in: pool, for: existing) {
                usageCounts[matchedIdx] += 1
                lastUsedIndex = matchedIdx
            }
        }

        var candidateIndices = Array(pool.indices)
        if let currentProfile {
            let filtered = candidateIndices.filter { !pool[$0].sharesSignature(with: currentProfile) }
            if !filtered.isEmpty {
                candidateIndices = filtered
            }
        }

        let minUsage = candidateIndices.map { usageCounts[$0] }.min() ?? 0
        var leastUsed = candidateIndices.filter { usageCounts[$0] == minUsage }
        if let lastUsedIndex, leastUsed.count > 1 {
            leastUsed.removeAll { $0 == lastUsedIndex }
        }
        guard let pickedIndex = leastUsed.randomElement() ?? candidateIndices.first else {
            return nil
        }
        return pool[pickedIndex]
    }

    private static func matchedVariantIndex(
        in pool: [CuriumHardwareProfileVariant],
        for profile: CuriumFingerprintProfile
    ) -> Int? {
        if let exact = pool.firstIndex(where: { $0.matches(profile) }) {
            return exact
        }
        return pool.firstIndex(where: { $0.sharesSignature(with: profile) })
    }
}

/// Curated creation template wrapping one of the verified fingerprint archetypes.
/// Templates are never persisted as live profiles until instantiated by the user.
struct CuriumProfileTemplate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String
    let defaultSymbolName: String
    let defaultPalette: CuriumPalette
    let baseProfile: CuriumFingerprintProfile

    static let allTemplates: [CuriumProfileTemplate] = [
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.macosDesktopFirst.id,
            title: "macOS Desktop (Apple Silicon)",
            subtitle: "Chrome 158 on Apple Silicon (M1–M5 Max, 8–32 GB RAM). Native Metal, CoreText, and CoreAudio.",
            badge: "Recommended",
            defaultSymbolName: "laptopcomputer",
            defaultPalette: .neptunium,
            baseProfile: CuriumFingerprintPresets.macosDesktopFirst
        ),
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.privacyHardened.id,
            title: "Privacy Hardened (macOS)",
            subtitle: "Apple Silicon macOS Chrome 158 with per-site farbling, Global Privacy Control, and non-proxied WebRTC UDP off.",
            badge: "Private",
            defaultSymbolName: "shield.lefthalf.filled",
            defaultPalette: .thorium,
            baseProfile: CuriumFingerprintPresets.privacyHardened
        ),
    ]

    var hasHardwareVariantPool: Bool {
        hardwareVariantCount > 0
    }

    var hardwareVariantCount: Int {
        CuriumFingerprintDevicePools.variants(forTemplateID: id).count
    }

    var supportsNativeHardwareBaseline: Bool {
        baseProfile.usesNativeHardwareAndGPU
    }

    /// Privacy Hardened enables C++ farbling by default; standard macOS Desktop stays
    /// zero-noise native (relying on `CuriumMacOSManifold` + CoreText fonts + TTS voices)
    /// while leaving farbling opt-in.
    var enablesFarblingByDefault: Bool {
        id == CuriumFingerprintPresets.privacyHardened.id
    }

    static func template(for id: String?) -> CuriumProfileTemplate? {
        guard let lowered = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !lowered.isEmpty else {
            return nil
        }
        return allTemplates.first { $0.id.lowercased() == lowered }
    }

    func instantiate(
        id: String,
        displayName: String,
        symbolName: String? = nil,
        palette: CuriumPalette? = nil,
        siteMode: CuriumSiteMode? = nil,
        searchEngine: CuriumSearchEngine? = nil,
        enableFarbling: Bool? = nil,
        randomizeHardwareVariant: Bool = true,
        hardwareVariantID: String? = nil,
        avoidingExisting existingProfiles: [CuriumFingerprintProfile] = [],
        proxy: CuriumProxyConfig? = nil,
        webrtcIpHandlingPolicy: CuriumWebRTCPolicy? = nil,
        timezone: String? = nil,
        languages: [String]? = nil,
        now: Date = .now
    ) -> CuriumFingerprintProfile {
        var profile = baseProfile
        profile.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.displayName = trimmedName.isEmpty ? title : trimmedName
        profile.isBuiltIn = false
        profile.revision = 1
        profile.templateID = self.id
        let trimmedSymbol = symbolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.symbolName = (trimmedSymbol?.isEmpty == false) ? trimmedSymbol : defaultSymbolName
        profile.palette = palette ?? defaultPalette
        profile.siteMode = siteMode ?? .adaptive
        profile.searchEngine = searchEngine ?? .google
        profile.createdAt = now
        profile.lastUsedAt = nil

        if let explicitVariant = CuriumFingerprintDevicePools.variant(
            forTemplateID: self.id,
            variantID: hardwareVariantID
        ) {
            profile = explicitVariant.apply(to: profile)
        } else if randomizeHardwareVariant, hasHardwareVariantPool {
            let sampled = CuriumMacOSManifold.sampleIdentity(
                avoiding: existingProfiles,
                excluding: nil
            )
            profile = CuriumMacOSManifold.apply(sampled, to: profile)
        }

        let resolvedEnableFarbling = enableFarbling ?? enablesFarblingByDefault
        if resolvedEnableFarbling {
            profile.farbling = profile.farbling ?? .stealthSafe
            profile.fingerprintSeed = CuriumFingerprintSchema.generateRandomSeedHex()
        } else {
            profile.farbling = nil
            profile.fingerprintSeed = nil
        }

        if let proxy {
            profile.proxy = proxy
        }
        if let webrtcIpHandlingPolicy {
            profile.webrtcIpHandlingPolicy = webrtcIpHandlingPolicy
        } else if case .fixed = profile.proxy {
            profile.webrtcIpHandlingPolicy = .disableNonProxiedUdp
        }
        if let timezone {
            let trimmedTZ = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.hardware.timezone = trimmedTZ.isEmpty ? nil : trimmedTZ
        }
        if let languages, !languages.isEmpty {
            profile.languages = languages
        }

        return profile.normalizedForPersistence()
    }
}
