import Foundation

/// Built-in downstream fingerprint profiles. Adding or tuning presets requires
/// only Swift edits — no Chromium rebuild needed.
enum CuriumFingerprintPresets {
    static let allBuiltIns: [CuriumFingerprintProfile] = [
        defaultAuthenticChrome,
        iosBlinkAuthentic,
        macosDesktopFirst,
        windowsWorkstation,
        linuxDesktop,
        pixelAndroid,
        privacyHardened,
    ]

    static let builtInIDs: Set<String> = Set(allBuiltIns.map(\.id))

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

    /// Standard dual-slot Authentic Chrome profile: Android 15 Mobile masked with coherent
    /// non-Apple GPU, screen, 8-core/8 GB hardware, Android font filtering, and hidden Apple
    /// speech voices, paired with a native macOS arm64 Desktop slot.
    static let defaultAuthenticChrome = CuriumFingerprintProfile(
        id: "default",
        displayName: "Authentic Chrome (Default)",
        notes: "Android 15 Chrome on Mobile with coherent non-Apple Adreno WebGL, 412×915 screen, Android font filtering, and 8-core/8 GB hardware, paired with a macOS arm64 Desktop slot.",
        isBuiltIn: true,
        revision: 2,
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
            navigatorPlatform: "Linux armv81",
            webglVendor: "Google Inc. (Qualcomm)",
            webglRenderer: "ANGLE (Qualcomm, Adreno (TM) 750, OpenGL ES 3.2)",
            screen: .mobilePixel9,
            webglProfile: .mobileAndroid
        ),
        desktop: build39NativeBaseline.desktop,
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

    /// iOS 18_7 mobile UA with macOS desktop slot and 100% native Apple hardware & GPU.
    static let iosBlinkAuthentic = CuriumFingerprintProfile(
        id: "ios-blink",
        displayName: "iOS Blink + macOS Desktop",
        notes: "Isolated profile using iOS 18_7 mobile UA and macOS Desktop slot with native Apple hardware.",
        isBuiltIn: true,
        revision: 1,
        defaultSlot: .mobile,
        mobile: CuriumIdentitySlot(
            osCpu: "iPhone; CPU iPhone OS 18_7 like Mac OS X",
            appendMobileToken: true,
            primaryBrand: "Google Chrome",
            platform: "iOS",
            platformVersion: "18.7.0",
            architecture: "arm",
            bitness: "64",
            model: "",
            mobile: true,
            wow64: false,
            formFactors: ["Mobile"],
            navigatorPlatform: "iPhone"
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

    /// Desktop-first macOS Chrome profile (including ServiceWorkers & SharedWorkers) with native Apple Silicon.
    static let macosDesktopFirst = CuriumFingerprintProfile(
        id: "macos-desktop",
        displayName: "macOS Desktop-First",
        notes: "Isolated profile presenting macOS arm64 Chrome across all tabs and ServiceWorkers with native Apple hardware.",
        isBuiltIn: true,
        revision: 1,
        defaultSlot: .desktop,
        mobile: CuriumIdentitySlot(
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

    /// Example profile with opt-in non-Apple hardware, GPU, font, and web screen overrides (Windows 11 x64 workstation).
    static let windowsWorkstation = CuriumFingerprintProfile(
        id: "win11-workstation",
        displayName: "Windows 11 Workstation",
        notes: "Isolated Windows 11 x64 Desktop profile with opt-in CPU, memory, desktop pointer, Windows font filtering, 1080p web screen, and Intel ANGLE WebGL overrides.",
        isBuiltIn: true,
        revision: 2,
        defaultSlot: .desktop,
        mobile: CuriumIdentitySlot(
            osCpu: "Windows NT 10.0; Win64; x64",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "Windows",
            platformVersion: "19.0.0",
            architecture: "x86",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "Win32",
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)",
            screen: .desktop1080pWindows,
            webglProfile: .desktopWindows,
            pdfViewerEnabled: true
        ),
        desktop: CuriumIdentitySlot(
            osCpu: "Windows NT 10.0; Win64; x64",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "Windows",
            platformVersion: "19.0.0",
            architecture: "x86",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "Win32",
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)",
            screen: .desktop1080pWindows,
            webglProfile: .desktopWindows,
            pdfViewerEnabled: true
        ),
        languages: ["en-US", "en"],
        proxy: .system,
        webrtcIpHandlingPolicy: .defaultPublicInterfaceOnly,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: CuriumHardwareOverrides(
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            timezone: nil
        ),
        fontProfile: .windows,
        hideSpeechVoices: true
    )

    /// Desktop-first Linux x86_64 profile with coherent Mesa/Intel WebGL, Linux font filtering & desktop input capabilities.
    static let linuxDesktop = CuriumFingerprintProfile(
        id: "linux-desktop",
        displayName: "Linux Desktop (x86_64)",
        notes: "Isolated Linux x86_64 Chrome workstation with empty Sec-CH-UA-Platform-Version (matching upstream Linux Chrome), Linux font filtering, 1080p web screen, and Mesa Intel WebGL.",
        isBuiltIn: true,
        revision: 2,
        defaultSlot: .desktop,
        mobile: CuriumIdentitySlot(
            osCpu: "X11; Linux x86_64",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "Linux",
            platformVersion: "",
            architecture: "x86",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "Linux x86_64",
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Mesa Intel(R) Graphics (ADL GT2), OpenGL 4.6)",
            screen: .desktop1080pLinux,
            webglProfile: .desktopLinux,
            pdfViewerEnabled: true
        ),
        desktop: CuriumIdentitySlot(
            osCpu: "X11; Linux x86_64",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "Linux",
            platformVersion: "",
            architecture: "x86",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "Linux x86_64",
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Mesa Intel(R) Graphics (ADL GT2), OpenGL 4.6)",
            screen: .desktop1080pLinux,
            webglProfile: .desktopLinux,
            pdfViewerEnabled: true
        ),
        languages: ["en-US", "en"],
        proxy: .system,
        webrtcIpHandlingPolicy: .defaultPublicInterfaceOnly,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: CuriumHardwareOverrides(
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            timezone: nil
        ),
        fontProfile: .linux,
        hideSpeechVoices: true
    )

    /// Pixel 9 Android 15 mobile profile with Chrome Reduced UA, Pixel 9 CH model, Mali-G715 WebGL, Android font filtering, and 8-core/8 GB hardware.
    static let pixelAndroid = CuriumFingerprintProfile(
        id: "pixel-android",
        displayName: "Pixel 9 (Android 15)",
        notes: "Isolated Pixel 9 Android 15 mobile identity (Reduced UA with Pixel 9 Client Hint model, Mali-G715 WebGL, Android font filtering, and 8-core/8 GB hardware) paired with a macOS Desktop slot.",
        isBuiltIn: true,
        revision: 3,
        defaultSlot: .mobile,
        mobile: CuriumIdentitySlot(
            osCpu: "Linux; Android 10; K",
            appendMobileToken: true,
            primaryBrand: "Google Chrome",
            platform: "Android",
            platformVersion: "15.0.0",
            architecture: "",
            bitness: "",
            model: "Pixel 9",
            mobile: true,
            wow64: false,
            formFactors: ["Mobile"],
            navigatorPlatform: "Linux armv81",
            webglVendor: "Google Inc. (ARM)",
            webglRenderer: "ANGLE (ARM, Mali-G715, OpenGL ES 3.2)",
            screen: .mobilePixel9,
            webglProfile: .mobileAndroid
        ),
        desktop: defaultAuthenticChrome.desktop,
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

    /// Privacy-hardened Android 15 profile masking non-Apple mobile hardware while enabling deterministic per-site C++ farbling, WebRTC UDP lockdown & GPC.
    /// `fingerprintSeed` is intentionally `nil` here; `CuriumFingerprintStore` materializes and persists a fresh per-install 256-bit random seed.
    static let privacyHardened = CuriumFingerprintProfile(
        id: "privacy-hardened",
        displayName: "Privacy Hardened",
        notes: "Isolated Android 15 Mobile profile with coherent non-Apple GPU/screen/fonts, deterministic per-site Canvas/Audio/WebGL/TextMetrics farbling, non-proxied WebRTC UDP disabled, and Global Privacy Control enabled.",
        isBuiltIn: true,
        revision: 3,
        defaultSlot: .mobile,
        mobile: defaultAuthenticChrome.mobile,
        desktop: defaultAuthenticChrome.desktop,
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .disableNonProxiedUdp,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: true,
        hardware: defaultAuthenticChrome.hardware,
        fingerprintSeed: nil,
        farbling: .allEnabled,
        fontProfile: .android,
        hideSpeechVoices: true
    )

    /// Rolls a coherent hardware/GPU/screen variant for `profile` from its matching
    /// device pool, selecting a variant distinct from `profile`'s current hardware/GPU
    /// signature and preferring variants unused by `existingProfiles`.
    /// Returns `nil` for native-only archetypes without a hardware variant pool.
    /// Never mutates `id`, `displayName`, `proxy`, `timezone`, `languages`, or `fingerprintSeed`.
    static func rollCoherentHardwareVariant(
        for profile: CuriumFingerprintProfile,
        avoiding existingProfiles: [CuriumFingerprintProfile] = []
    ) -> CuriumFingerprintProfile? {
        guard let poolID = CuriumFingerprintDevicePools.poolID(for: profile),
              let variant = CuriumFingerprintDevicePools.selectVariant(
                  forPoolID: poolID,
                  avoiding: existingProfiles,
                  excluding: profile
              )
        else {
            return nil
        }
        return variant.apply(to: profile)
    }
}

/// Coherent hardware, GPU, screen, and Client Hint variant for multi-variant fingerprint
/// templates. Every variant obeys Build 42 C++ schema v2 limits and passes
/// `CuriumFingerprintValidator.validate(_:)` with zero errors and zero warnings.
struct CuriumHardwareProfileVariant: Identifiable, Equatable, Sendable {
    let id: String
    let poolID: String
    let label: String
    /// Desktop-first archetypes apply slot overrides to `desktop` (and `mobile` when
    /// `mobile.mobile != true`); mobile-first dual-slot archetypes (e.g. Android) apply
    /// slot overrides exclusively to `mobile`.
    let appliesToBothSlots: Bool

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

/// Curated coherent hardware/GPU/screen pools for multi-variant fingerprint templates.
enum CuriumFingerprintDevicePools {
    static let windowsWorkstation: [CuriumHardwareProfileVariant] = [
        CuriumHardwareProfileVariant(
            id: "win11-intel-iris-xe-1080p",
            poolID: CuriumFingerprintPresets.windowsWorkstation.id,
            label: "Intel Iris Xe · 1920×1080",
            appliesToBothSlots: true,
            platformVersion: "19.0.0",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)",
            webglProfile: .desktopWindows,
            screen: CuriumScreenOverride(width: 1920, height: 1080, availWidth: 1920, availHeight: 1040, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .windows,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "win11-nvidia-rtx3060-1440p",
            poolID: CuriumFingerprintPresets.windowsWorkstation.id,
            label: "NVIDIA RTX 3060 · 2560×1440",
            appliesToBothSlots: true,
            platformVersion: "19.0.0",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (NVIDIA)",
            webglRenderer: "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)",
            webglProfile: .desktopWindows,
            screen: CuriumScreenOverride(width: 2560, height: 1440, availWidth: 2560, availHeight: 1400, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 12,
            deviceMemoryGB: 8,
            fontProfile: .windows,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "win11-amd-rx6700xt-1080p",
            poolID: CuriumFingerprintPresets.windowsWorkstation.id,
            label: "AMD Radeon RX 6700 XT · 1920×1080",
            appliesToBothSlots: true,
            platformVersion: "15.0.0",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (AMD)",
            webglRenderer: "ANGLE (AMD, AMD Radeon RX 6700 XT Direct3D11 vs_5_0 ps_5_0, D3D11)",
            webglProfile: .desktopWindows,
            screen: CuriumScreenOverride(width: 1920, height: 1080, availWidth: 1920, availHeight: 1040, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 16,
            deviceMemoryGB: 8,
            fontProfile: .windows,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "win11-intel-uhd770-864p",
            poolID: CuriumFingerprintPresets.windowsWorkstation.id,
            label: "Intel UHD 770 · 1536×864",
            appliesToBothSlots: true,
            platformVersion: "15.0.0",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Intel(R) UHD Graphics 770 Direct3D11 vs_5_0 ps_5_0, D3D11)",
            webglProfile: .desktopWindows,
            screen: CuriumScreenOverride(width: 1536, height: 864, availWidth: 1536, availHeight: 824, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 6,
            deviceMemoryGB: 4,
            fontProfile: .windows,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "win11-nvidia-rtx4060-1050p",
            poolID: CuriumFingerprintPresets.windowsWorkstation.id,
            label: "NVIDIA RTX 4060 · 1680×1050",
            appliesToBothSlots: true,
            platformVersion: "19.0.0",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (NVIDIA)",
            webglRenderer: "ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Direct3D11 vs_5_0 ps_5_0, D3D11)",
            webglProfile: .desktopWindows,
            screen: CuriumScreenOverride(width: 1680, height: 1050, availWidth: 1680, availHeight: 1010, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 16,
            deviceMemoryGB: 8,
            fontProfile: .windows,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "win11-amd-radeon-864p",
            poolID: CuriumFingerprintPresets.windowsWorkstation.id,
            label: "AMD Radeon Graphics · 1536×864",
            appliesToBothSlots: true,
            platformVersion: "15.0.0",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (AMD)",
            webglRenderer: "ANGLE (AMD, AMD Radeon(TM) Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)",
            webglProfile: .desktopWindows,
            screen: CuriumScreenOverride(width: 1536, height: 864, availWidth: 1536, availHeight: 824, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 4,
            deviceMemoryGB: 8,
            fontProfile: .windows,
            hideSpeechVoices: true
        ),
    ]

    static let linuxDesktop: [CuriumHardwareProfileVariant] = [
        CuriumHardwareProfileVariant(
            id: "linux-intel-adl-1080p",
            poolID: CuriumFingerprintPresets.linuxDesktop.id,
            label: "Mesa Intel ADL GT2 · 1920×1080",
            appliesToBothSlots: true,
            platformVersion: "",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: "Linux x86_64",
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Mesa Intel(R) Graphics (ADL GT2), OpenGL 4.6)",
            webglProfile: .desktopLinux,
            screen: CuriumScreenOverride(width: 1920, height: 1080, availWidth: 1920, availHeight: 1050, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .linux,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "linux-amd-rx6700xt-1440p",
            poolID: CuriumFingerprintPresets.linuxDesktop.id,
            label: "Mesa AMD RX 6700 XT · 2560×1440",
            appliesToBothSlots: true,
            platformVersion: "",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: "Linux x86_64",
            webglVendor: "Google Inc. (AMD)",
            webglRenderer: "ANGLE (AMD, AMD Radeon RX 6700 XT (radeonsi, navi22, LLVM 18.1.3, DRM 3.57), OpenGL 4.6)",
            webglProfile: .desktopLinux,
            screen: CuriumScreenOverride(width: 2560, height: 1440, availWidth: 2560, availHeight: 1410, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 16,
            deviceMemoryGB: 8,
            fontProfile: .linux,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "linux-intel-tgl-1050p",
            poolID: CuriumFingerprintPresets.linuxDesktop.id,
            label: "Mesa Intel Xe TGL · 1680×1050",
            appliesToBothSlots: true,
            platformVersion: "",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: "Linux x86_64",
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Mesa Intel(R) Xe Graphics (TGL GT2), OpenGL 4.6)",
            webglProfile: .desktopLinux,
            screen: CuriumScreenOverride(width: 1680, height: 1050, availWidth: 1680, availHeight: 1020, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 4,
            deviceMemoryGB: 8,
            fontProfile: .linux,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "linux-amd-rembrandt-1080p",
            poolID: CuriumFingerprintPresets.linuxDesktop.id,
            label: "Mesa AMD Rembrandt · 1920×1080",
            appliesToBothSlots: true,
            platformVersion: "",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: "Linux x86_64",
            webglVendor: "Google Inc. (AMD)",
            webglRenderer: "ANGLE (AMD, AMD Radeon Graphics (radeonsi, rembrandt, LLVM 18.1.3, DRM 3.57), OpenGL 4.6)",
            webglProfile: .desktopLinux,
            screen: CuriumScreenOverride(width: 1920, height: 1080, availWidth: 1920, availHeight: 1050, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 12,
            deviceMemoryGB: 8,
            fontProfile: .linux,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "linux-intel-uhd770-1440p",
            poolID: CuriumFingerprintPresets.linuxDesktop.id,
            label: "Mesa Intel UHD 770 · 2560×1440",
            appliesToBothSlots: true,
            platformVersion: "",
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: "Linux x86_64",
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Mesa Intel(R) UHD Graphics 770 (ADL-S GT1), OpenGL 4.6)",
            webglProfile: .desktopLinux,
            screen: CuriumScreenOverride(width: 2560, height: 1440, availWidth: 2560, availHeight: 1410, colorDepth: 24),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 12,
            deviceMemoryGB: 8,
            fontProfile: .linux,
            hideSpeechVoices: true
        ),
    ]

    static let macosDesktop: [CuriumHardwareProfileVariant] = [
        CuriumHardwareProfileVariant(
            id: "macos-apple-m1-1440x900",
            poolID: CuriumFingerprintPresets.macosDesktopFirst.id,
            label: "Apple M1 · 1440×900",
            appliesToBothSlots: true,
            platformVersion: nil,
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (Apple)",
            webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)",
            webglProfile: .desktopMacOS,
            screen: CuriumScreenOverride(width: 1440, height: 900, availWidth: 1440, availHeight: 875, colorDepth: 30),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .apple,
            hideSpeechVoices: nil
        ),
        CuriumHardwareProfileVariant(
            id: "macos-apple-m2-1470x956",
            poolID: CuriumFingerprintPresets.macosDesktopFirst.id,
            label: "Apple M2 · 1470×956",
            appliesToBothSlots: true,
            platformVersion: nil,
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (Apple)",
            webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M2, Unspecified Version)",
            webglProfile: .desktopMacOS,
            screen: CuriumScreenOverride(width: 1470, height: 956, availWidth: 1470, availHeight: 919, colorDepth: 30),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .apple,
            hideSpeechVoices: nil
        ),
        CuriumHardwareProfileVariant(
            id: "macos-apple-m3-1512x982",
            poolID: CuriumFingerprintPresets.macosDesktopFirst.id,
            label: "Apple M3 · 1512×982",
            appliesToBothSlots: true,
            platformVersion: nil,
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (Apple)",
            webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M3, Unspecified Version)",
            webglProfile: .desktopMacOS,
            screen: CuriumScreenOverride(width: 1512, height: 982, availWidth: 1512, availHeight: 944, colorDepth: 30),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .apple,
            hideSpeechVoices: nil
        ),
        CuriumHardwareProfileVariant(
            id: "macos-apple-m3pro-1728x1117",
            poolID: CuriumFingerprintPresets.macosDesktopFirst.id,
            label: "Apple M3 Pro · 1728×1117",
            appliesToBothSlots: true,
            platformVersion: nil,
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (Apple)",
            webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M3 Pro, Unspecified Version)",
            webglProfile: .desktopMacOS,
            screen: CuriumScreenOverride(width: 1728, height: 1117, availWidth: 1728, availHeight: 1079, colorDepth: 30),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 12,
            deviceMemoryGB: 8,
            fontProfile: .apple,
            hideSpeechVoices: nil
        ),
        CuriumHardwareProfileVariant(
            id: "macos-apple-m4-1680x1050",
            poolID: CuriumFingerprintPresets.macosDesktopFirst.id,
            label: "Apple M4 · 1680×1050",
            appliesToBothSlots: true,
            platformVersion: nil,
            model: nil,
            architecture: nil,
            bitness: nil,
            navigatorPlatform: nil,
            webglVendor: "Google Inc. (Apple)",
            webglRenderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)",
            webglProfile: .desktopMacOS,
            screen: CuriumScreenOverride(width: 1680, height: 1050, availWidth: 1680, availHeight: 1012, colorDepth: 30),
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            pdfViewerEnabled: true,
            hardwareConcurrency: 10,
            deviceMemoryGB: 8,
            fontProfile: .apple,
            hideSpeechVoices: nil
        ),
    ]

    static let pixelAndroid: [CuriumHardwareProfileVariant] = [
        CuriumHardwareProfileVariant(
            id: "android-pixel-9",
            poolID: CuriumFingerprintPresets.pixelAndroid.id,
            label: "Pixel 9 · 412×915",
            appliesToBothSlots: false,
            platformVersion: "15.0.0",
            model: "Pixel 9",
            architecture: "",
            bitness: "",
            navigatorPlatform: "Linux armv81",
            webglVendor: "Google Inc. (ARM)",
            webglRenderer: "ANGLE (ARM, Mali-G715, OpenGL ES 3.2)",
            webglProfile: .mobileAndroid,
            screen: CuriumScreenOverride(width: 412, height: 915, availWidth: 412, availHeight: 915, colorDepth: 24),
            maxTouchPoints: nil,
            pointerType: nil,
            hoverType: nil,
            pdfViewerEnabled: nil,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .android,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "android-pixel-9-pro",
            poolID: CuriumFingerprintPresets.pixelAndroid.id,
            label: "Pixel 9 Pro · 427×952",
            appliesToBothSlots: false,
            platformVersion: "15.0.0",
            model: "Pixel 9 Pro",
            architecture: "",
            bitness: "",
            navigatorPlatform: "Linux armv81",
            webglVendor: "Google Inc. (ARM)",
            webglRenderer: "ANGLE (ARM, Mali-G715-Immortalis MC7, OpenGL ES 3.2)",
            webglProfile: .mobileAndroid,
            screen: CuriumScreenOverride(width: 427, height: 952, availWidth: 427, availHeight: 952, colorDepth: 24),
            maxTouchPoints: nil,
            pointerType: nil,
            hoverType: nil,
            pdfViewerEnabled: nil,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .android,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "android-pixel-8a",
            poolID: CuriumFingerprintPresets.pixelAndroid.id,
            label: "Pixel 8a · 412×915",
            appliesToBothSlots: false,
            platformVersion: "15.0.0",
            model: "Pixel 8a",
            architecture: "",
            bitness: "",
            navigatorPlatform: "Linux armv81",
            webglVendor: "Google Inc. (ARM)",
            webglRenderer: "ANGLE (ARM, Mali-G715 MC7, OpenGL ES 3.2)",
            webglProfile: .mobileAndroid,
            screen: CuriumScreenOverride(width: 412, height: 915, availWidth: 412, availHeight: 915, colorDepth: 24),
            maxTouchPoints: nil,
            pointerType: nil,
            hoverType: nil,
            pdfViewerEnabled: nil,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .android,
            hideSpeechVoices: true
        ),
        CuriumHardwareProfileVariant(
            id: "android-galaxy-s24",
            poolID: CuriumFingerprintPresets.pixelAndroid.id,
            label: "Galaxy S24 (SM-S921B) · 360×780",
            appliesToBothSlots: false,
            platformVersion: "15.0.0",
            model: "SM-S921B",
            architecture: "",
            bitness: "",
            navigatorPlatform: "Linux armv81",
            webglVendor: "Google Inc. (Qualcomm)",
            webglRenderer: "ANGLE (Qualcomm, Adreno (TM) 750, OpenGL ES 3.2)",
            webglProfile: .mobileAndroid,
            screen: CuriumScreenOverride(width: 360, height: 780, availWidth: 360, availHeight: 780, colorDepth: 24),
            maxTouchPoints: nil,
            pointerType: nil,
            hoverType: nil,
            pdfViewerEnabled: nil,
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            fontProfile: .android,
            hideSpeechVoices: true
        ),
    ]

    /// Coherent non-Apple Android 15 Reduced-UA hardware variants (`model == ""`) shared
    /// by `Authentic Chrome` (`"default"`) and `Privacy Hardened` (`"privacy-hardened"`).
    /// Applies strictly to the `mobile` slot so the `desktop` macOS slot stays native Apple.
    private static func makeAndroidStandardVariants(poolID: String) -> [CuriumHardwareProfileVariant] {
        [
            CuriumHardwareProfileVariant(
                id: "\(poolID)-adreno750-412x915",
                poolID: poolID,
                label: "Qualcomm Adreno 750 · 412×915",
                appliesToBothSlots: false,
                platformVersion: "15.0.0",
                model: "",
                architecture: "",
                bitness: "",
                navigatorPlatform: "Linux armv81",
                webglVendor: "Google Inc. (Qualcomm)",
                webglRenderer: "ANGLE (Qualcomm, Adreno (TM) 750, OpenGL ES 3.2)",
                webglProfile: .mobileAndroid,
                screen: CuriumScreenOverride(width: 412, height: 915, availWidth: 412, availHeight: 915, colorDepth: 24),
                maxTouchPoints: nil,
                pointerType: nil,
                hoverType: nil,
                pdfViewerEnabled: nil,
                hardwareConcurrency: 8,
                deviceMemoryGB: 8,
                fontProfile: .android,
                hideSpeechVoices: true
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-mali-g715-412x915",
                poolID: poolID,
                label: "ARM Mali-G715 · 412×915",
                appliesToBothSlots: false,
                platformVersion: "15.0.0",
                model: "",
                architecture: "",
                bitness: "",
                navigatorPlatform: "Linux armv81",
                webglVendor: "Google Inc. (ARM)",
                webglRenderer: "ANGLE (ARM, Mali-G715, OpenGL ES 3.2)",
                webglProfile: .mobileAndroid,
                screen: CuriumScreenOverride(width: 412, height: 915, availWidth: 412, availHeight: 915, colorDepth: 24),
                maxTouchPoints: nil,
                pointerType: nil,
                hoverType: nil,
                pdfViewerEnabled: nil,
                hardwareConcurrency: 8,
                deviceMemoryGB: 8,
                fontProfile: .android,
                hideSpeechVoices: true
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-adreno740-393x873",
                poolID: poolID,
                label: "Qualcomm Adreno 740 · 393×873",
                appliesToBothSlots: false,
                platformVersion: "15.0.0",
                model: "",
                architecture: "",
                bitness: "",
                navigatorPlatform: "Linux armv81",
                webglVendor: "Google Inc. (Qualcomm)",
                webglRenderer: "ANGLE (Qualcomm, Adreno (TM) 740, OpenGL ES 3.2)",
                webglProfile: .mobileAndroid,
                screen: CuriumScreenOverride(width: 393, height: 873, availWidth: 393, availHeight: 873, colorDepth: 24),
                maxTouchPoints: nil,
                pointerType: nil,
                hoverType: nil,
                pdfViewerEnabled: nil,
                hardwareConcurrency: 8,
                deviceMemoryGB: 8,
                fontProfile: .android,
                hideSpeechVoices: true
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-adreno730-360x800",
                poolID: poolID,
                label: "Qualcomm Adreno 730 · 360×800",
                appliesToBothSlots: false,
                platformVersion: "15.0.0",
                model: "",
                architecture: "",
                bitness: "",
                navigatorPlatform: "Linux armv81",
                webglVendor: "Google Inc. (Qualcomm)",
                webglRenderer: "ANGLE (Qualcomm, Adreno (TM) 730, OpenGL ES 3.2)",
                webglProfile: .mobileAndroid,
                screen: CuriumScreenOverride(width: 360, height: 800, availWidth: 360, availHeight: 800, colorDepth: 24),
                maxTouchPoints: nil,
                pointerType: nil,
                hoverType: nil,
                pdfViewerEnabled: nil,
                hardwareConcurrency: 8,
                deviceMemoryGB: 4,
                fontProfile: .android,
                hideSpeechVoices: true
            ),
            CuriumHardwareProfileVariant(
                id: "\(poolID)-mali-g720-412x915",
                poolID: poolID,
                label: "ARM Mali-G720-Immortalis · 412×915",
                appliesToBothSlots: false,
                platformVersion: "15.0.0",
                model: "",
                architecture: "",
                bitness: "",
                navigatorPlatform: "Linux armv81",
                webglVendor: "Google Inc. (ARM)",
                webglRenderer: "ANGLE (ARM, Mali-G720-Immortalis MC12, OpenGL ES 3.2)",
                webglProfile: .mobileAndroid,
                screen: CuriumScreenOverride(width: 412, height: 915, availWidth: 412, availHeight: 915, colorDepth: 24),
                maxTouchPoints: nil,
                pointerType: nil,
                hoverType: nil,
                pdfViewerEnabled: nil,
                hardwareConcurrency: 8,
                deviceMemoryGB: 8,
                fontProfile: .android,
                hideSpeechVoices: true
            ),
        ]
    }

    static let androidAuthenticChrome: [CuriumHardwareProfileVariant] =
        makeAndroidStandardVariants(poolID: CuriumFingerprintPresets.defaultAuthenticChrome.id)

    static let androidPrivacyHardened: [CuriumHardwareProfileVariant] =
        makeAndroidStandardVariants(poolID: CuriumFingerprintPresets.privacyHardened.id)

    static let allPools: [String: [CuriumHardwareProfileVariant]] = [
        CuriumFingerprintPresets.defaultAuthenticChrome.id: androidAuthenticChrome,
        CuriumFingerprintPresets.privacyHardened.id: androidPrivacyHardened,
        CuriumFingerprintPresets.windowsWorkstation.id: windowsWorkstation,
        CuriumFingerprintPresets.linuxDesktop.id: linuxDesktop,
        CuriumFingerprintPresets.macosDesktopFirst.id: macosDesktop,
        CuriumFingerprintPresets.pixelAndroid.id: pixelAndroid,
    ]

    static func variants(forTemplateID templateID: String?) -> [CuriumHardwareProfileVariant] {
        guard let key = templateID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty else {
            return []
        }
        return allPools[key] ?? []
    }

    static func poolID(for profile: CuriumFingerprintProfile) -> String? {
        let templateKey = profile.templateID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let primarySlot = profile.defaultSlot == .desktop ? profile.desktop : profile.mobile
        let platformPool: String?
        switch primarySlot.platform {
        case "Windows":
            platformPool = CuriumFingerprintPresets.windowsWorkstation.id
        case "Linux":
            platformPool = CuriumFingerprintPresets.linuxDesktop.id
        case "macOS":
            platformPool = CuriumFingerprintPresets.macosDesktopFirst.id
        case "Android":
            let hasModel = primarySlot.model?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            if hasModel {
                platformPool = CuriumFingerprintPresets.pixelAndroid.id
            } else if templateKey == CuriumFingerprintPresets.privacyHardened.id {
                platformPool = CuriumFingerprintPresets.privacyHardened.id
            } else {
                platformPool = CuriumFingerprintPresets.defaultAuthenticChrome.id
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

/// Curated creation template wrapping one of the 7 built-in fingerprint archetypes.
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
            id: CuriumFingerprintPresets.defaultAuthenticChrome.id,
            title: "Authentic Chrome",
            subtitle: "Android 15 Mobile (non-Apple GPU, screen & fonts) + macOS Desktop.",
            badge: "Standard",
            defaultSymbolName: "person.crop.circle",
            defaultPalette: .violet,
            baseProfile: CuriumFingerprintPresets.defaultAuthenticChrome
        ),
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.privacyHardened.id,
            title: "Privacy Hardened",
            subtitle: "Android 15 Mobile with non-Apple GPU/fonts, per-site farbling, GPC, and WebRTC UDP off.",
            badge: "Private",
            defaultSymbolName: "shield.lefthalf.filled",
            defaultPalette: .thorium,
            baseProfile: CuriumFingerprintPresets.privacyHardened
        ),
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.macosDesktopFirst.id,
            title: "macOS Desktop",
            subtitle: "macOS arm64 Chrome across all tabs and workers with native Apple Silicon.",
            badge: "Desktop",
            defaultSymbolName: "laptopcomputer",
            defaultPalette: .neptunium,
            baseProfile: CuriumFingerprintPresets.macosDesktopFirst
        ),
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.iosBlinkAuthentic.id,
            title: "iOS Mobile + macOS",
            subtitle: "iOS 18.7 mobile UA with macOS desktop slot and native Apple hardware.",
            badge: "Mobile",
            defaultSymbolName: "iphone",
            defaultPalette: .californium,
            baseProfile: CuriumFingerprintPresets.iosBlinkAuthentic
        ),
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.windowsWorkstation.id,
            title: "Windows 11 Workstation",
            subtitle: "Windows x64 desktop with 1080p screen, font filtering, and Intel ANGLE GPU.",
            badge: "Work",
            defaultSymbolName: "desktopcomputer",
            defaultPalette: .americium,
            baseProfile: CuriumFingerprintPresets.windowsWorkstation
        ),
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.linuxDesktop.id,
            title: "Linux Desktop",
            subtitle: "Linux x86_64 workstation with Linux font filtering and Mesa Intel WebGL.",
            badge: "Dev",
            defaultSymbolName: "terminal",
            defaultPalette: .thorium,
            baseProfile: CuriumFingerprintPresets.linuxDesktop
        ),
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.pixelAndroid.id,
            title: "Pixel 9 Android",
            subtitle: "Pixel 9 Android 15 Reduced UA with Mali/Adreno GPU, screen, and Android font filtering.",
            badge: "Android",
            defaultSymbolName: "globe",
            defaultPalette: .berkelium,
            baseProfile: CuriumFingerprintPresets.pixelAndroid
        ),
    ]

    var hasHardwareVariantPool: Bool {
        hardwareVariantCount > 0
    }

    var hardwareVariantCount: Int {
        CuriumFingerprintDevicePools.variants(forTemplateID: id).count
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
        enableFarbling: Bool = true,
        randomizeHardwareVariant: Bool = true,
        avoidingExisting existingProfiles: [CuriumFingerprintProfile] = [],
        proxy: CuriumProxyConfig? = nil,
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

        if randomizeHardwareVariant,
           hasHardwareVariantPool,
           let variant = CuriumFingerprintDevicePools.selectVariant(
               forPoolID: self.id,
               avoiding: existingProfiles,
               excluding: nil
           ) {
            profile = variant.apply(to: profile)
        }

        if enableFarbling {
            profile.farbling = profile.farbling ?? .allEnabled
            profile.fingerprintSeed = CuriumFingerprintSchema.generateRandomSeedHex()
        } else {
            profile.farbling = nil
            profile.fingerprintSeed = nil
        }

        if let proxy {
            profile.proxy = proxy
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
