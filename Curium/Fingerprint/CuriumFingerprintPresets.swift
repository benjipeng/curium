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

    /// Build 39 authentic Chrome dual-slot profile with 100% native Apple hardware & GPU.
    static let defaultAuthenticChrome = CuriumFingerprintProfile(
        id: "default",
        displayName: "Authentic Chrome (Default)",
        notes: "Android 15 Chrome on Mobile, macOS arm64 Chrome on Desktop. Preserves native Apple hardware and Metal GPU.",
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

    /// Pixel 9 Android 15 mobile profile with Chrome Reduced UA, Pixel 9 CH model, Android font filtering, and native hardware (auto-capped at 8 GB).
    static let pixelAndroid = CuriumFingerprintProfile(
        id: "pixel-android",
        displayName: "Pixel 9 (Android 15)",
        notes: "Isolated Pixel 9 Android 15 mobile identity (Reduced UA with Pixel 9 Client Hint model, Android font filtering) and macOS Desktop slot, keeping native hardware.",
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
            model: "Pixel 9",
            mobile: true,
            wow64: false,
            formFactors: ["Mobile"],
            navigatorPlatform: "Linux armv81",
            screen: .mobilePixel9,
            webglProfile: .mobileAndroid
        ),
        desktop: defaultAuthenticChrome.desktop,
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .default,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: .native,
        fontProfile: .android,
        hideSpeechVoices: true
    )

    /// Privacy-hardened profile keeping native Apple hardware while enabling deterministic per-site C++ farbling, WebRTC UDP lockdown & GPC.
    /// `fingerprintSeed` is intentionally `nil` here; `CuriumFingerprintStore` materializes and persists a fresh per-install 256-bit random seed.
    static let privacyHardened = CuriumFingerprintProfile(
        id: "privacy-hardened",
        displayName: "Privacy Hardened",
        notes: "Isolated profile with native Apple hardware, deterministic per-site Canvas/Audio/WebGL/TextMetrics farbling, non-proxied WebRTC UDP disabled, and Global Privacy Control enabled.",
        isBuiltIn: true,
        revision: 2,
        defaultSlot: .mobile,
        mobile: defaultAuthenticChrome.mobile,
        desktop: defaultAuthenticChrome.desktop,
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .disableNonProxiedUdp,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: true,
        hardware: .native,
        fingerprintSeed: nil,
        farbling: .allEnabled
    )
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
            subtitle: "Android 15 Mobile + macOS Desktop with native Apple hardware.",
            badge: "Standard",
            defaultSymbolName: "person.crop.circle",
            defaultPalette: .violet,
            baseProfile: CuriumFingerprintPresets.defaultAuthenticChrome
        ),
        CuriumProfileTemplate(
            id: CuriumFingerprintPresets.privacyHardened.id,
            title: "Privacy Hardened",
            subtitle: "Per-site Canvas/Audio/WebGL farbling, GPC, and non-proxied WebRTC UDP off.",
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
            subtitle: "Pixel 9 Android 15 Reduced UA with Android font filtering and native hardware.",
            badge: "Android",
            defaultSymbolName: "globe",
            defaultPalette: .berkelium,
            baseProfile: CuriumFingerprintPresets.pixelAndroid
        ),
    ]

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
        if baseProfile.hasFarblingEnabled {
            profile.fingerprintSeed = CuriumFingerprintSchema.generateRandomSeedHex()
        }
        return profile.normalizedForPersistence()
    }
}
