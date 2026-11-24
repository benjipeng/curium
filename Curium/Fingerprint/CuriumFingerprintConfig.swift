import CryptoKit
import Foundation
import Security

/// Schema versions shared with `third_party/blink/public/common/curium/curium_fingerprint_config.h`.
enum CuriumFingerprintSchema {
    static let minSupportedVersion = 1
    static let version = 3
    static let maxPayloadBytes = 65_536
    static let runtimePolicyVersion = 1
    static let maxRuntimePolicyBytes = 16_384
    static let validDeviceMemoryBuckets: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]
    static let validColorDepths: Set<Int> = [24, 30, 32]
    static let validFormFactors: Set<String> = [
        "Desktop", "Automotive", "Mobile", "Tablet", "XR", "EInk", "Watch",
    ]
    /// Retired public static seeds shipped in earlier preset drafts; never reused across
    /// installs, duplicates, or imports.
    static let retiredStaticSeeds: Set<String> = [
        "96c0a17d4f2b8e5319046c72a8f5e31d6b04927a5e8c3f104d9b6a27e0c51384",
        "96c0a17d8c334a28922f6c79c5be7e8e441c4a0d54c86182c4f6794d3b0b89e1",
    ]

    /// Generates a cryptographically random 32-byte (64 lowercase hex character)
    /// deterministic farbling seed for Build 41+ profiles.
    static func generateRandomSeedHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isValidSeedHex(_ hex: String) -> Bool {
        guard hex.utf8.count == 64 else { return false }
        return hex.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 48 && v <= 57) || (v >= 65 && v <= 70) || (v >= 97 && v <= 102)
        }
    }

    static func isRetiredStaticSeed(_ hex: String?) -> Bool {
        guard let hex else { return false }
        return retiredStaticSeeds.contains(hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

enum CuriumDefaultSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case mobile
    case desktop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mobile: return "Mobile Default (Dual-Slot)"
        case .desktop: return "Desktop First (Including Workers)"
        }
    }
}

enum CuriumPointerType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case coarse
    case fine

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .coarse: return "Coarse (Touch)"
        case .fine: return "Fine (Mouse)"
        }
    }
}

enum CuriumHoverType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case hover

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .hover: return "Hover Capable"
        }
    }
}

enum CuriumFontProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case native
    case apple
    case windows
    case linux
    case android

    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "Native (Unfiltered)"
        case .apple: return "Apple (macOS / iOS)"
        case .windows: return "Windows (Filter Apple Fonts)"
        case .linux: return "Linux (Filter Apple Fonts)"
        case .android: return "Android (Filter Apple Fonts)"
        }
    }
}

enum CuriumWebGLProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case native
    case desktopWindows = "desktop_windows"
    case desktopMacOS = "desktop_macos"
    case desktopLinux = "desktop_linux"
    case mobileAndroid = "mobile_android"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "Native Apple Metal"
        case .desktopWindows: return "Desktop Windows (D3D11)"
        case .desktopMacOS: return "Desktop macOS"
        case .desktopLinux: return "Desktop Linux (Mesa)"
        case .mobileAndroid: return "Mobile Android"
        }
    }
}

struct CuriumScreenOverride: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var availWidth: Int?
    var availHeight: Int?
    var colorDepth: Int?
    // Build 43 (schemaVersion >= 3) optional geometry & web-only DPR overrides.
    var availTop: Int?
    var availLeft: Int?
    var devicePixelRatio: Double?

    init(
        width: Int,
        height: Int,
        availWidth: Int? = nil,
        availHeight: Int? = nil,
        colorDepth: Int? = nil,
        availTop: Int? = nil,
        availLeft: Int? = nil,
        devicePixelRatio: Double? = nil
    ) {
        self.width = width
        self.height = height
        self.availWidth = availWidth
        self.availHeight = availHeight
        self.colorDepth = colorDepth
        self.availTop = availTop
        self.availLeft = availLeft
        self.devicePixelRatio = devicePixelRatio
    }

    static let desktop1080pWindows = CuriumScreenOverride(
        width: 1920, height: 1080, availWidth: 1920, availHeight: 1040, colorDepth: 24
    )
    static let desktop1080pLinux = CuriumScreenOverride(
        width: 1920, height: 1080, availWidth: 1920, availHeight: 1050, colorDepth: 24
    )
    static let desktop1440x900 = CuriumScreenOverride(
        width: 1440, height: 900, availWidth: 1440, availHeight: 875, colorDepth: 24
    )
    static let mobilePixel9 = CuriumScreenOverride(
        width: 412, height: 915, availWidth: 412, availHeight: 915, colorDepth: 24
    )

    var summary: String {
        let aw = availWidth ?? width
        let ah = availHeight ?? height
        let depth = colorDepth ?? 24
        return "\(width)×\(height) (avail \(aw)×\(ah), \(depth)-bit)"
    }
}

struct CuriumFarblingSettings: Codable, Equatable, Sendable {
    var canvas: Bool = true
    var audio: Bool = true
    var webgl: Bool = true
    var textMetrics: Bool = true

    static let allEnabled = CuriumFarblingSettings()

    /// Stealth-balanced farbling preset for macOS desktop profiles: diversifies
    /// per-site Audio and WebGL signatures while keeping Canvas and TextMetrics
    /// free of solid-rect pixel noise that triggers anti-detect ML classifiers.
    static let stealthSafe = CuriumFarblingSettings(
        canvas: false,
        audio: true,
        webgl: true,
        textMetrics: false
    )

    var enabledCount: Int {
        [canvas, audio, webgl, textMetrics].filter { $0 }.count
    }
}

enum CuriumWebRTCPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case `default` = "default"
    case defaultPublicAndPrivateInterfaces = "default_public_and_private_interfaces"
    case defaultPublicInterfaceOnly = "default_public_interface_only"
    case disableNonProxiedUdp = "disable_non_proxied_udp"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .default: return "Default"
        case .defaultPublicAndPrivateInterfaces: return "Public & Private Interfaces"
        case .defaultPublicInterfaceOnly: return "Public Interface Only"
        case .disableNonProxiedUdp: return "Disable Non-Proxied UDP"
        }
    }
}

struct CuriumBrandVersion: Codable, Equatable, Sendable {
    var brand: String
    var version: String
}

/// Optional per-slot identity, input capability, WebGL, and web-screen spec.
/// Any `nil` hardware/GPU/input/screen field preserves authentic native device behavior.
struct CuriumIdentitySlot: Codable, Equatable, Sendable {
    var uaString: String?
    var osCpu: String?
    var productVersion: String?
    var appendMobileToken: Bool?
    /// `nil` = omit (default "Google Chrome"); `""` = Chromium-only (2 brands); non-empty = custom primary brand.
    var primaryBrand: String?
    var majorVersion: String?
    var fullVersion: String?
    var brands: [CuriumBrandVersion]?
    var fullVersionBrands: [CuriumBrandVersion]?
    var platform: String?
    var platformVersion: String?
    var architecture: String?
    var bitness: String?
    var model: String?
    var mobile: Bool?
    var wow64: Bool?
    var formFactors: [String]?
    var navigatorPlatform: String?
    var maxTouchPoints: Int?
    var pointerType: CuriumPointerType?
    var hoverType: CuriumHoverType?
    var webglVendor: String?
    var webglRenderer: String?
    // Build 41 (schemaVersion >= 2) per-slot web-exposed surfaces.
    var screen: CuriumScreenOverride?
    var webglProfile: CuriumWebGLProfile?
    var webglMaxTextureSize: Int?
    var webglMaxRenderbufferSize: Int?
    var webglMaxCubeMapTextureSize: Int?
    var pdfViewerEnabled: Bool?

    var hasWebGLOverride: Bool {
        webglVendor != nil || webglRenderer != nil
    }

    var hasInputOverride: Bool {
        maxTouchPoints != nil || pointerType != nil || hoverType != nil
    }

    /// Returns a Build 40 (`schemaVersion: 1`) compatible copy with v2+ keys stripped.
    func strippedForSchemaV1() -> CuriumIdentitySlot {
        var copy = self
        copy.screen = nil
        copy.webglProfile = nil
        copy.webglMaxTextureSize = nil
        copy.webglMaxRenderbufferSize = nil
        copy.webglMaxCubeMapTextureSize = nil
        copy.pdfViewerEnabled = nil
        return copy
    }

    /// Returns a Build 41/42 (`schemaVersion: 2`) compatible copy with v3-only screen
    /// geometry/DPR keys stripped so legacy engines never reject unknown fields.
    func strippedForSchemaV2() -> CuriumIdentitySlot {
        var copy = self
        if var screen = copy.screen {
            screen.availTop = nil
            screen.availLeft = nil
            screen.devicePixelRatio = nil
            copy.screen = screen
        }
        return copy
    }

    /// Returns a Build 43 (`schemaVersion: 3`) wire-ready copy resolving desktop macOS
    /// `availTop`, `availLeft`, and `devicePixelRatio` defaults when omitted.
    func resolvedForSchemaV3() -> CuriumIdentitySlot {
        var copy = self
        guard var screen = copy.screen else { return copy }
        let isDesktopMacOS = (mobile != true)
            && ((platform ?? "").caseInsensitiveCompare("macOS") == .orderedSame
                || navigatorPlatform == "MacIntel")
        if isDesktopMacOS {
            let availH = screen.availHeight ?? screen.height
            if screen.availTop == nil {
                if screen.height > availH {
                    let inferred = CuriumMacOSManifold.inferredMenuBarHeight(for: screen)
                    screen.availTop = min(inferred, screen.height - availH)
                } else {
                    screen.availTop = 0
                }
            }
            if screen.availLeft == nil {
                screen.availLeft = 0
            }
            if screen.devicePixelRatio == nil {
                screen.devicePixelRatio = 2.0
            }
        } else if screen.availLeft == nil {
            screen.availLeft = 0
        }
        copy.screen = screen
        return copy
    }

    /// Trims surrounding whitespace from string fields while preserving explicit empty strings
    /// (`""`) for fields where empty carries Client Hint semantics (`primaryBrand`,
    /// `platformVersion`, `architecture`, `bitness`, `model`).
    func normalizedForPersistence() -> CuriumIdentitySlot {
        func trimmedNonEmpty(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func trimmedPreservingExplicitEmpty(_ value: String?) -> String? {
            guard let value else { return nil }
            if value.isEmpty { return "" }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var copy = self
        copy.uaString = trimmedNonEmpty(uaString)
        copy.osCpu = trimmedNonEmpty(osCpu)
        copy.productVersion = trimmedNonEmpty(productVersion)
        copy.primaryBrand = trimmedPreservingExplicitEmpty(primaryBrand)
        copy.majorVersion = trimmedNonEmpty(majorVersion)
        copy.fullVersion = trimmedNonEmpty(fullVersion)
        if let brands {
            copy.brands = brands.map {
                CuriumBrandVersion(
                    brand: $0.brand.trimmingCharacters(in: .whitespacesAndNewlines),
                    version: $0.version.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
        if let fullVersionBrands {
            copy.fullVersionBrands = fullVersionBrands.map {
                CuriumBrandVersion(
                    brand: $0.brand.trimmingCharacters(in: .whitespacesAndNewlines),
                    version: $0.version.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
        copy.platform = trimmedNonEmpty(platform)
        copy.platformVersion = trimmedPreservingExplicitEmpty(platformVersion)
        copy.architecture = trimmedPreservingExplicitEmpty(architecture)
        copy.bitness = trimmedPreservingExplicitEmpty(bitness)
        copy.model = trimmedPreservingExplicitEmpty(model)
        if let formFactors {
            copy.formFactors = formFactors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        copy.navigatorPlatform = trimmedNonEmpty(navigatorPlatform)
        copy.webglVendor = trimmedNonEmpty(webglVendor)
        copy.webglRenderer = trimmedNonEmpty(webglRenderer)
        return copy
    }
}

/// Strictly mutually exclusive 3-way proxy policy matching Chromium NetworkContext + Patch 0009.
enum CuriumProxyConfig: Equatable, Sendable {
    case system
    case direct
    case fixed(rules: String, bypassRules: String?)

    var modeName: String {
        switch self {
        case .system: return "system"
        case .direct: return "direct"
        case .fixed: return "fixed"
        }
    }

    var summary: String {
        switch self {
        case .system: return "System Proxy"
        case .direct: return "Direct (Bypass System Proxy)"
        case .fixed(let rules, _): return "Fixed (\(rules))"
        }
    }
}

extension CuriumProxyConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case rules
        case bypassRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(String.self, forKey: .mode)
        switch mode {
        case "system":
            self = .system
        case "direct":
            self = .direct
        case "fixed":
            let rules = try container.decode(String.self, forKey: .rules)
            let bypass = try container.decodeIfPresent(String.self, forKey: .bypassRules)
            self = .fixed(rules: rules, bypassRules: bypass)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: container,
                debugDescription: "Unsupported proxy mode: \(mode)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system:
            try container.encode("system", forKey: .mode)
        case .direct:
            try container.encode("direct", forKey: .mode)
        case .fixed(let rules, let bypassRules):
            try container.encode("fixed", forKey: .mode)
            try container.encode(rules, forKey: .rules)
            if let bypassRules, !bypassRules.isEmpty {
                try container.encode(bypassRules, forKey: .bypassRules)
            }
        }
    }
}

/// Optional launch-scoped hardware & environment overrides.
/// When all fields are `nil`, Curium reports 100% authentic native hardware & timezone.
struct CuriumHardwareOverrides: Codable, Equatable, Sendable {
    var hardwareConcurrency: Int?
    var deviceMemoryGB: Double?
    var timezone: String?

    static let native = CuriumHardwareOverrides()

    var isNative: Bool {
        hardwareConcurrency == nil && deviceMemoryGB == nil && timezone == nil
    }
}

struct CuriumFingerprintProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var notes: String
    var isBuiltIn: Bool
    var revision: UInt64
    var defaultSlot: CuriumDefaultSlot
    var mobile: CuriumIdentitySlot
    var desktop: CuriumIdentitySlot
    /// `nil` resolves iOS preferred languages at launch; non-nil uses this exact ordered BCP-47 list.
    var languages: [String]?
    var proxy: CuriumProxyConfig
    var webrtcIpHandlingPolicy: CuriumWebRTCPolicy
    var enableDoNotTrack: Bool
    var enableGlobalPrivacyControl: Bool
    var hardware: CuriumHardwareOverrides
    // Build 41 (schemaVersion >= 2) anti-fingerprinting configuration.
    var fingerprintSeed: String? = nil
    var farbling: CuriumFarblingSettings? = nil
    var fontProfile: CuriumFontProfile? = nil
    var hideSpeechVoices: Bool? = nil
    // Store v2 UI persona & lifecycle metadata (NEVER serialized into EngineWirePayload).
    var symbolName: String? = nil
    var palette: CuriumPalette? = nil
    var siteMode: CuriumSiteMode? = nil
    var searchEngine: CuriumSearchEngine? = nil
    var templateID: String? = nil
    var createdAt: Date? = nil
    var lastUsedAt: Date? = nil

    var isPrimaryDefault: Bool {
        id == "default"
    }

    var resolvedSymbolName: String {
        if let symbolName {
            let trimmed = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return CuriumProfileTemplate.template(for: templateID ?? id)?.defaultSymbolName ?? "person.crop.circle"
    }

    var resolvedPalette: CuriumPalette {
        palette ?? CuriumProfileTemplate.template(for: templateID ?? id)?.defaultPalette ?? .violet
    }

    var resolvedSiteMode: CuriumSiteMode {
        siteMode ?? .adaptive
    }

    var resolvedSearchEngine: CuriumSearchEngine {
        searchEngine ?? .google
    }

    var usesNativeHardwareAndGPU: Bool {
        hardware.isNative && !mobile.hasWebGLOverride && !desktop.hasWebGLOverride
    }

    var isFarblingActive: Bool {
        guard let seed = fingerprintSeed, !seed.isEmpty else { return false }
        return (farbling ?? .allEnabled).enabledCount > 0
    }

    /// True when the profile requests deterministic farbling (either via non-empty
    /// `farbling` toggles or an explicit `fingerprintSeed`).
    var hasFarblingEnabled: Bool {
        if let farbling {
            return farbling.enabledCount > 0
        }
        return fingerprintSeed != nil
    }

    /// True iff this is the `"default"` profile AND every engine-affecting field matches
    /// Build 39's authentic Chrome baseline with no farbling, font, or speech overrides.
    var matchesBuild39EngineDefaults: Bool {
        guard id == "default" else { return false }
        let baseline = CuriumFingerprintPresets.build39NativeBaseline
        return defaultSlot == baseline.defaultSlot
            && mobile == baseline.mobile
            && desktop == baseline.desktop
            && languages == baseline.languages
            && proxy == baseline.proxy
            && webrtcIpHandlingPolicy == baseline.webrtcIpHandlingPolicy
            && enableDoNotTrack == baseline.enableDoNotTrack
            && enableGlobalPrivacyControl == baseline.enableGlobalPrivacyControl
            && hardware == baseline.hardware
            && fingerprintSeed == nil
            && !hasFarblingEnabled
            && (fontProfile == nil || fontProfile == .native)
            && (hideSpeechVoices == nil || hideSpeechVoices == false)
    }

    /// Whether the consumer one-tap Privacy Hardening bundle (full stealth farbling,
    /// `Sec-GPC: 1` + `navigator.globalPrivacyControl`, and non-proxied WebRTC UDP off)
    /// is active on this profile.
    var isPrivacyHardeningEnabled: Bool {
        fingerprintSeed != nil
            && (farbling ?? .allEnabled) == .allEnabled
            && enableGlobalPrivacyControl
            && webrtcIpHandlingPolicy == .disableNonProxiedUdp
    }

    /// Toggles the Privacy Hardening bundle atomically. Disabling preserves
    /// `.disableNonProxiedUdp` whenever the profile uses an explicit `.fixed` proxy.
    mutating func setPrivacyHardeningEnabled(
        _ enabled: Bool,
        proxyOverride: CuriumProxyConfig? = nil
    ) {
        if enabled {
            farbling = .allEnabled
            fingerprintSeed = CuriumFingerprintStore.mintFreshSeed(
                differentFrom: fingerprintSeed
            )
            enableGlobalPrivacyControl = true
            webrtcIpHandlingPolicy = .disableNonProxiedUdp
        } else {
            farbling = nil
            fingerprintSeed = nil
            enableGlobalPrivacyControl = false
            let effectiveProxy = proxyOverride ?? proxy
            if case .fixed = effectiveProxy {
                webrtcIpHandlingPolicy = .disableNonProxiedUdp
            } else {
                webrtcIpHandlingPolicy = .default
            }
        }
    }

    var shortArchetypeSummary: String {
        let primarySlot = defaultSlot == .desktop ? desktop : mobile
        let platformLabel: String
        if let model = primarySlot.model, !model.isEmpty, let platform = primarySlot.platform, !platform.isEmpty {
            platformLabel = "\(model) (\(platform))"
        } else if let platform = primarySlot.platform, !platform.isEmpty {
            if let major = Self.extractChromeMajorVersion(from: primarySlot) {
                platformLabel = "\(platform) \(major)"
            } else if defaultSlot == .desktop {
                platformLabel = "\(platform) Desktop"
            } else {
                platformLabel = platform
            }
        } else {
            platformLabel = defaultSlot == .desktop ? "macOS Desktop" : "Browser Profile"
        }

        var parts = [platformLabel]
        if let matchedVariant = CuriumFingerprintDevicePools.variants(forProfile: self).first(where: { $0.matches(self) }),
           let chipLabel = matchedVariant.label.split(separator: "·").first?.trimmingCharacters(in: .whitespaces),
           !chipLabel.isEmpty {
            parts.append(chipLabel)
        } else if let manifoldChip = CuriumMacOSManifold.chipDisplayName(fromWebGLRenderer: primarySlot.webglRenderer) {
            parts.append(manifoldChip)
        } else if usesNativeHardwareAndGPU {
            parts.append("Native Apple")
        } else {
            parts.append("Custom HW")
        }
        if isFarblingActive {
            parts.append("Protected")
        }
        switch proxy {
        case .system:
            break
        case .direct:
            parts.append("Direct")
        case .fixed:
            parts.append("Proxy")
        }
        return parts.joined(separator: " · ")
    }

    /// Editorial Start Page posture line (at most 3 concise `" · "`-separated tokens,
    /// e.g. `macOS 158`, `macOS 158 · Protected`, or `macOS 158 · Proxy`).
    var conciseStartPostureSummary: String {
        var parts: [String] = []
        let slot = defaultSlot == .desktop ? desktop : mobile
        let rawPlatform = (slot.platform ?? slot.navigatorPlatform ?? "").lowercased()
        let osLabel: String
        if rawPlatform.contains("mac") {
            osLabel = "macOS"
        } else if rawPlatform.contains("win") {
            osLabel = "Windows"
        } else if rawPlatform.contains("android") {
            osLabel = "Android"
        } else if rawPlatform.contains("linux") {
            osLabel = "Linux"
        } else if rawPlatform.contains("ios") || rawPlatform.contains("iphone") || rawPlatform.contains("ipad") {
            osLabel = "iOS"
        } else {
            osLabel = "macOS"
        }

        if let major = Self.extractChromeMajorVersion(from: slot) {
            parts.append("\(osLabel) \(major)")
        } else {
            parts.append(osLabel)
        }

        if isFarblingActive {
            parts.append("Farbled")
        } else if !usesNativeHardwareAndGPU {
            parts.append("Custom HW")
        }

        switch proxy {
        case .system:
            break
        case .direct:
            parts.append("Direct")
        case .fixed:
            parts.append("Proxy")
        }
        return parts.joined(separator: " · ")
    }

    private static func extractChromeMajorVersion(from slot: CuriumIdentitySlot) -> String? {
        if let major = slot.majorVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !major.isEmpty,
           major.allSatisfy(\.isNumber) {
            return major
        }
        if let full = slot.fullVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           let first = full.split(separator: ".").first,
           !first.isEmpty,
           first.allSatisfy(\.isNumber) {
            return String(first)
        }
        if let ua = slot.uaString {
            for marker in ["Chrome/", "CriOS/"] {
                if let range = ua.range(of: marker) {
                    let digits = ua[range.upperBound...].prefix(while: \.isNumber)
                    if !digits.isEmpty {
                        return String(digits)
                    }
                }
            }
        }
        return nil
    }

    /// Normalizes user-entered or imported string fields (trimming whitespace on IDs,
    /// metadata, slots, languages, proxy rules, timezone, and seed) while preserving
    /// explicit empty Client Hint strings (`""`).
    func normalizedForPersistence() -> CuriumFingerprintProfile {
        var copy = self
        copy.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.mobile = mobile.normalizedForPersistence()
        copy.desktop = desktop.normalizedForPersistence()
        if let languages {
            copy.languages = languages
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        switch proxy {
        case .system, .direct:
            break
        case .fixed(let rules, let bypassRules):
            let trimmedRules = rules.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBypass = bypassRules?.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.proxy = .fixed(
                rules: trimmedRules,
                bypassRules: (trimmedBypass?.isEmpty ?? true) ? nil : trimmedBypass
            )
        }
        if let tz = hardware.timezone {
            let trimmedTZ = tz.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.hardware.timezone = trimmedTZ.isEmpty ? nil : trimmedTZ
        }
        if let seed = fingerprintSeed {
            let trimmedSeed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.fingerprintSeed = trimmedSeed.isEmpty ? nil : trimmedSeed
        }
        if let symbolName {
            let trimmedSymbol = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.symbolName = trimmedSymbol.isEmpty ? nil : trimmedSymbol
        }
        if let templateID {
            let trimmedTemplate = templateID.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.templateID = trimmedTemplate.isEmpty ? nil : trimmedTemplate
        }
        return copy
    }

    /// Serializes strictly the engine wire schema (`schemaVersion: 3` by default, or `2`/`1`
    /// when negotiating down for Build 40–42 engines) without UI metadata.
    func makeEngineLaunchJSON(
        preferredSystemLanguages: [String] = Locale.preferredLanguages,
        schemaVersion: Int = CuriumFingerprintSchema.version
    ) throws -> Data {
        let resolvedLanguages: [String]
        if let explicit = languages, !explicit.isEmpty {
            resolvedLanguages = explicit
        } else {
            let normalized = CuriumNormalizedAcceptLanguages(preferredSystemLanguages)
            resolvedLanguages = normalized.split(separator: ",").map(String.init)
        }

        let targetVersion = min(
            CuriumFingerprintSchema.version,
            max(CuriumFingerprintSchema.minSupportedVersion, schemaVersion)
        )
        let emitV2 = targetVersion >= 2
        let emitV3 = targetVersion >= 3
        let resolvedMobile: CuriumIdentitySlot
        let resolvedDesktop: CuriumIdentitySlot
        if emitV3 {
            resolvedMobile = mobile.resolvedForSchemaV3()
            resolvedDesktop = desktop.resolvedForSchemaV3()
        } else if emitV2 {
            resolvedMobile = mobile.strippedForSchemaV2()
            resolvedDesktop = desktop.strippedForSchemaV2()
        } else {
            resolvedMobile = mobile.strippedForSchemaV1()
            resolvedDesktop = desktop.strippedForSchemaV1()
        }
        let personaSeed: String? = emitV3
            ? CuriumFingerprintSchema.sha256Hex(CuriumProfileFontManager.profileSeedString(for: self))
            : nil

        let payload = EngineWirePayload(
            schemaVersion: targetVersion,
            revision: revision,
            profileId: id,
            defaultSlot: defaultSlot,
            mobile: resolvedMobile,
            desktop: resolvedDesktop,
            languages: resolvedLanguages,
            proxy: proxy,
            webrtcIpHandlingPolicy: webrtcIpHandlingPolicy,
            enableDoNotTrack: enableDoNotTrack,
            enableGlobalPrivacyControl: enableGlobalPrivacyControl,
            hardware: hardware,
            fingerprintSeed: emitV2 ? fingerprintSeed : nil,
            farbling: (emitV2 && fingerprintSeed != nil) ? (farbling ?? .allEnabled) : nil,
            fontProfile: emitV2 ? fontProfile : nil,
            hideSpeechVoices: emitV2 ? hideSpeechVoices : nil,
            personaSeed: personaSeed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    /// Serializes the Build 43 (`policySchemaVersion: 1`, `<= 16384` bytes) hot-mutable
    /// runtime privacy policy payload for `CrIOSEngineBootstrap.applyRuntimePolicyJSON:error:`.
    func makeRuntimePrivacyPolicyJSON(policyRevision: UInt64) throws -> Data {
        let normalized = normalizedForPersistence()
        let clampedRevision = min(CuriumFingerprintValidator.maxSafeJSONRevision, policyRevision)
        let effectiveFarbling: CuriumFarblingSettings? =
            normalized.fingerprintSeed != nil ? (normalized.farbling ?? .allEnabled) : nil
        let payload = RuntimePrivacyPolicyWirePayload(
            policySchemaVersion: CuriumFingerprintSchema.runtimePolicyVersion,
            policyRevision: clampedRevision,
            fingerprintSeed: normalized.fingerprintSeed,
            farbling: effectiveFarbling,
            webrtcIpHandlingPolicy: normalized.webrtcIpHandlingPolicy,
            enableDoNotTrack: normalized.enableDoNotTrack,
            enableGlobalPrivacyControl: normalized.enableGlobalPrivacyControl,
            hideSpeechVoices: normalized.hideSpeechVoices
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private struct EngineWirePayload: Encodable {
        let schemaVersion: Int
        let revision: UInt64
        let profileId: String
        let defaultSlot: CuriumDefaultSlot
        let mobile: CuriumIdentitySlot
        let desktop: CuriumIdentitySlot
        let languages: [String]
        let proxy: CuriumProxyConfig
        let webrtcIpHandlingPolicy: CuriumWebRTCPolicy
        let enableDoNotTrack: Bool
        let enableGlobalPrivacyControl: Bool
        let hardware: CuriumHardwareOverrides
        let fingerprintSeed: String?
        let farbling: CuriumFarblingSettings?
        let fontProfile: CuriumFontProfile?
        let hideSpeechVoices: Bool?
        let personaSeed: String?
    }

    private struct RuntimePrivacyPolicyWirePayload: Encodable {
        let policySchemaVersion: Int
        let policyRevision: UInt64
        let fingerprintSeed: String?
        let farbling: CuriumFarblingSettings?
        let webrtcIpHandlingPolicy: CuriumWebRTCPolicy
        let enableDoNotTrack: Bool
        let enableGlobalPrivacyControl: Bool
        let hideSpeechVoices: Bool?

        private enum CodingKeys: String, CodingKey {
            case policySchemaVersion
            case policyRevision
            case fingerprintSeed
            case farbling
            case webrtcIpHandlingPolicy
            case enableDoNotTrack
            case enableGlobalPrivacyControl
            case hideSpeechVoices
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(policySchemaVersion, forKey: .policySchemaVersion)
            try container.encode(policyRevision, forKey: .policyRevision)
            if let fingerprintSeed {
                try container.encode(fingerprintSeed, forKey: .fingerprintSeed)
            } else {
                try container.encodeNil(forKey: .fingerprintSeed)
            }
            if let farbling {
                try container.encode(farbling, forKey: .farbling)
            } else {
                try container.encodeNil(forKey: .farbling)
            }
            try container.encode(webrtcIpHandlingPolicy, forKey: .webrtcIpHandlingPolicy)
            try container.encode(enableDoNotTrack, forKey: .enableDoNotTrack)
            try container.encode(enableGlobalPrivacyControl, forKey: .enableGlobalPrivacyControl)
            if let hideSpeechVoices {
                try container.encode(hideSpeechVoices, forKey: .hideSpeechVoices)
            } else {
                try container.encodeNil(forKey: .hideSpeechVoices)
            }
        }
    }
}

/// Authoritative status acknowledgement returned by `CrIOSEngineBootstrap.activeFingerprintStatus`.
struct CuriumEngineFingerprintStatus: Equatable, Sendable {
    let contractVersion: Int
    let state: String
    let appliedProfileId: String
    let profileDirectoryOpened: Bool
    let appliedConfigRevision: UInt64
    let defaultSlot: String
    let proxyMode: String
    let hardwareOverridesActive: Bool
    let rejectionCode: Int?
    let rejectionReason: String?

    init(dictionary: [String: Any]) {
        contractVersion = (dictionary["contractVersion"] as? NSNumber)?.intValue ?? 0
        state = (dictionary["state"] as? String) ?? "unsupported"
        appliedProfileId = (dictionary["appliedProfileId"] as? String) ?? "default"
        profileDirectoryOpened = (dictionary["profileDirectoryOpened"] as? NSNumber)?.boolValue ?? false
        appliedConfigRevision = (dictionary["appliedConfigRevision"] as? NSNumber)?.uint64Value ?? 0
        defaultSlot = (dictionary["defaultSlot"] as? String) ?? "mobile"
        proxyMode = (dictionary["proxyMode"] as? String) ?? "system"
        hardwareOverridesActive = (dictionary["hardwareOverridesActive"] as? NSNumber)?.boolValue ?? false
        rejectionCode = (dictionary["rejectionCode"] as? NSNumber)?.intValue
        rejectionReason = dictionary["rejectionReason"] as? String
    }
}

struct CuriumEngineFingerprintCapabilities: Equatable, Sendable {
    let contractVersion: Int
    let supportedSchemaVersions: [Int]
    let maxConfigBytes: Int
    let runtimePolicyVersion: Int
    let maxRuntimePolicyBytes: Int
    let features: [String: Bool]
    let activationScopes: [String: String]

    var supportsLaunchFingerprintConfig: Bool {
        contractVersion >= CuriumFingerprintSchema.minSupportedVersion
    }

    var supportsNativeAntiFingerprinting: Bool {
        contractVersion >= 2 || supportedSchemaVersions.contains(2)
    }

    var supportsHotRuntimePrivacyPolicy: Bool {
        if let explicit = features["hotRuntimePrivacyPolicy"] {
            return explicit
        }
        return runtimePolicyVersion >= CuriumFingerprintSchema.runtimePolicyVersion
    }

    var supportsNativeDesktopParity: Bool {
        features["nativeDesktopParityV1"] == true
    }

    var supportsCoherentWebDPR: Bool {
        features["coherentWebDPR"] == true
    }

    var supportsStealthEdgeFarbling: Bool {
        features["stealthEdgeCanvasFarbling"] == true
    }

    var supportsProfileCachePurgeHook: Bool {
        features["profileCachePurgeHook"] == true
    }

    var supportsProfileHotSwap: Bool {
        if let explicit = features["profileHotSwap"] {
            return explicit
        }
        return contractVersion >= 4
    }

    var supportsNetworkFetchBridge: Bool {
        if let explicit = features["networkFetchBridge"] {
            return explicit
        }
        return contractVersion >= 4
    }

    var supportsTabDiscard: Bool {
        if let explicit = features["tabDiscard"] {
            return explicit
        }
        return contractVersion >= 4
    }

    init(dictionary: [String: Any]?) {
        guard let dictionary else {
            contractVersion = 0
            supportedSchemaVersions = []
            maxConfigBytes = 0
            runtimePolicyVersion = 0
            maxRuntimePolicyBytes = 0
            features = [:]
            activationScopes = [:]
            return
        }
        contractVersion = (dictionary["contractVersion"] as? NSNumber)?.intValue ?? 0
        if let rawVersions = dictionary["supportedSchemaVersions"] as? [NSNumber] {
            supportedSchemaVersions = rawVersions.map(\.intValue)
        } else if contractVersion >= 1 {
            supportedSchemaVersions = [contractVersion]
        } else {
            supportedSchemaVersions = []
        }
        maxConfigBytes = (dictionary["maxConfigBytes"] as? NSNumber)?.intValue ?? 0
        runtimePolicyVersion = (dictionary["runtimePolicyVersion"] as? NSNumber)?.intValue ?? 0
        maxRuntimePolicyBytes = (dictionary["maxRuntimePolicyBytes"] as? NSNumber)?.intValue ?? 0
        if let rawFeatures = dictionary["features"] as? [String: Any] {
            var parsed: [String: Bool] = [:]
            for (k, v) in rawFeatures {
                if let num = v as? NSNumber {
                    parsed[k] = num.boolValue
                }
            }
            features = parsed
        } else {
            features = [:]
        }
        activationScopes = (dictionary["activationScopes"] as? [String: String]) ?? [:]
    }
}
