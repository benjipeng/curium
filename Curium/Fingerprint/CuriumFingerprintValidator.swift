import Foundation

struct CuriumFingerprintValidationReport: Equatable, Sendable {
    var errors: [String] = []
    var warnings: [String] = []

    var isValid: Bool { errors.isEmpty }
}

/// Validates structural invariants (mirroring the C++ engine fail-closed rules)
/// and emits cross-field coherence warnings for downstream Swift UI/automation.
enum CuriumFingerprintValidator {
    static func isValidProfileID(_ id: String) -> Bool {
        if id == "default" { return true }
        let scalars = Array(id.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 32 else { return false }
        if id.lowercased() == "default" { return false }
        guard isASCIIAlnum(scalars[0]) else { return false }
        return scalars.allSatisfy { isASCIIAlnum($0) || $0 == "-" || $0 == "_" }
    }

    static func isValidClientHintToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value >= 0x7F { return false }
            if scalar == "\"" || scalar == "\\" || scalar == ";" { return false }
        }
        return true
    }

    static func validate(_ profile: CuriumFingerprintProfile) -> CuriumFingerprintValidationReport {
        var report = CuriumFingerprintValidationReport()

        if !isValidProfileID(profile.id) {
            report.errors.append("Profile ID must be \"default\" or 1–32 ASCII letters, digits, '-' or '_' starting with a letter/digit.")
        }

        validateSlot(profile.mobile, name: "mobile", into: &report)
        validateSlot(profile.desktop, name: "desktop", into: &report)

        if let languages = profile.languages {
            if languages.isEmpty || languages.count > 8 {
                report.errors.append("Languages list must contain 1–8 BCP-47 tags.")
            } else {
                for tag in languages {
                    let normalized = CuriumNormalizedAcceptLanguages([tag])
                    if tag.contains(",") || normalized == "en-US,en" {
                        report.errors.append("Invalid BCP-47 language tag: \(tag)")
                    }
                }
            }
        }

        switch profile.proxy {
        case .system, .direct:
            break
        case .fixed(let rules, let bypass):
            let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.utf8.count > 1024 || hasControlChars(trimmed)
                || !isValidFixedProxyRules(trimmed)
            {
                report.errors.append("Fixed proxy mode requires valid non-direct proxy rules (e.g. \"socks5://127.0.0.1:1080\" or \"http=127.0.0.1:8080;https=127.0.0.1:8080\").")
            }
            if let bypass, bypass.utf8.count > 2048 || hasControlChars(bypass) {
                report.errors.append("Proxy bypass rules contain invalid control characters or exceed 2048 bytes.")
            }
        }

        if let cores = profile.hardware.hardwareConcurrency, !(1...128).contains(cores) {
            report.errors.append("hardwareConcurrency must be between 1 and 128.")
        }

        if let mem = profile.hardware.deviceMemoryGB {
            let valid = CuriumFingerprintSchema.validDeviceMemoryBuckets.contains { abs($0 - mem) < 1e-6 }
            if !valid {
                report.errors.append("deviceMemoryGB must be a valid W3C bucket: 0.25, 0.5, 1, 2, 4, 8, 16, or 32.")
            }
        }

        if let tz = profile.hardware.timezone {
            if tz.isEmpty || tz.utf8.count > 64 || tz.contains("..") || tz.hasPrefix("/") || tz.hasSuffix("/")
                || TimeZone(identifier: tz) == nil
            {
                report.errors.append("Invalid IANA timezone identifier: \(tz)")
            }
        }

        if let seed = profile.fingerprintSeed {
            if !CuriumFingerprintSchema.isValidSeedHex(seed) {
                report.errors.append("fingerprintSeed must be a 64-character hexadecimal string.")
            } else if CuriumFingerprintSchema.isRetiredStaticSeed(seed) {
                report.warnings.append("This profile uses a retired public farbling seed. Rotate the seed for per-profile uniqueness.")
            }
        }

        if let data = try? profile.makeEngineLaunchJSON(), data.count > CuriumFingerprintSchema.maxPayloadBytes {
            report.errors.append("Serialized fingerprint payload exceeds 64 KiB engine limit.")
        }

        // Coherence warnings (non-blocking).
        checkCoherence(profile, into: &report)

        return report
    }

    /// Validates a single identity slot (structural rules + per-slot coherence warnings),
    /// suitable for inline feedback in the slot editor without serializing the full profile.
    static func validateSlot(_ slot: CuriumIdentitySlot, name: String) -> CuriumFingerprintValidationReport {
        var report = CuriumFingerprintValidationReport()
        validateSlot(slot, name: name, into: &report)
        checkSlotCoherence(slot, name: name, into: &report)
        return report
    }

    private static func validateSlot(
        _ slot: CuriumIdentitySlot,
        name: String,
        into report: inout CuriumFingerprintValidationReport
    ) {
        if let ua = slot.uaString {
            if ua.isEmpty || ua.utf8.count > 1024 || hasControlChars(ua) {
                report.errors.append("\(name).uaString must be a non-empty single-line header value (<= 1024 bytes).")
            }
        }
        if let osCpu = slot.osCpu {
            if osCpu.isEmpty || osCpu.utf8.count > 256 || !isPrintableASCII(osCpu) || osCpu.contains("(") || osCpu.contains(")") {
                report.errors.append("\(name).osCpu must be printable ASCII without parentheses.")
            }
        }
        if let pv = slot.productVersion, (pv.isEmpty || pv.utf8.count > 128 || !isPrintableASCII(pv)) {
            report.errors.append("\(name).productVersion must be printable ASCII.")
        }
        if let brand = slot.primaryBrand, !brand.isEmpty, !isValidClientHintToken(brand) {
            report.errors.append("\(name).primaryBrand contains forbidden Client Hint characters.")
        }
        if let major = slot.majorVersion {
            let allDigits = !major.isEmpty && major.count <= 4 && major.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
            if !allDigits || (Int(major) ?? 0) < 1 {
                report.errors.append("\(name).majorVersion must be a positive integer string.")
            }
        }
        if let full = slot.fullVersion, (full.isEmpty || full.utf8.count > 32 || !isValidClientHintToken(full)) {
            report.errors.append("\(name).fullVersion is invalid.")
        }
        for (listName, list) in [("brands", slot.brands), ("fullVersionBrands", slot.fullVersionBrands)] {
            if let list {
                if list.isEmpty || list.count > 8 {
                    report.errors.append("\(name).\(listName) must contain 1–8 entries.")
                } else if list.contains(where: { !isValidClientHintToken($0.brand) || !isValidClientHintToken($0.version) }) {
                    report.errors.append("\(name).\(listName) contains invalid brand or version tokens.")
                }
            }
        }
        if let p = slot.platform, !isValidClientHintToken(p) {
            report.errors.append("\(name).platform is invalid.")
        }
        if let pv = slot.platformVersion, !pv.isEmpty, !isValidClientHintToken(pv) {
            report.errors.append("\(name).platformVersion is invalid.")
        }
        if let arch = slot.architecture, !arch.isEmpty, !isValidClientHintToken(arch) {
            report.errors.append("\(name).architecture is invalid.")
        }
        if let bitness = slot.bitness, !["", "32", "64"].contains(bitness) {
            report.errors.append("\(name).bitness must be \"\", \"32\", or \"64\".")
        }
        if let model = slot.model, !model.isEmpty, !isValidClientHintToken(model) {
            report.errors.append("\(name).model is invalid.")
        }
        if let factors = slot.formFactors {
            if factors.isEmpty || factors.count > 4 || factors.contains(where: { !CuriumFingerprintSchema.validFormFactors.contains($0) }) {
                report.errors.append("\(name).formFactors must contain 1–4 W3C form factor values.")
            }
        }
        if let navPlatform = slot.navigatorPlatform, (navPlatform.isEmpty || navPlatform.utf8.count > 64 || !isPrintableASCII(navPlatform)) {
            report.errors.append("\(name).navigatorPlatform must be printable ASCII.")
        }
        if let mtp = slot.maxTouchPoints, !(0...32).contains(mtp) {
            report.errors.append("\(name).maxTouchPoints must be in 0...32.")
        }
        if let vendor = slot.webglVendor, (vendor.isEmpty || vendor.utf8.count > 256 || !isPrintableASCII(vendor)) {
            report.errors.append("\(name).webglVendor must be printable ASCII.")
        }
        if let renderer = slot.webglRenderer, (renderer.isEmpty || renderer.utf8.count > 256 || !isPrintableASCII(renderer)) {
            report.errors.append("\(name).webglRenderer must be printable ASCII.")
        }
        if (slot.webglVendor == nil) != (slot.webglRenderer == nil) {
            report.warnings.append("\(name): set both webglVendor and webglRenderer together, or leave both empty for native Apple GPU.")
        }
        if let screen = slot.screen {
            if !(240...16384).contains(screen.width) || !(240...16384).contains(screen.height) {
                report.errors.append("\(name).screen width and height must be integers in 240...16384.")
            }
            let availW = screen.availWidth ?? screen.width
            let availH = screen.availHeight ?? screen.height
            if availW < 240 || availW > screen.width || availH < 240 || availH > screen.height {
                report.errors.append("\(name).screen availWidth/availHeight must be in 240...width/height.")
            }
            let depth = screen.colorDepth ?? 24
            if !CuriumFingerprintSchema.validColorDepths.contains(depth) {
                report.errors.append("\(name).screen colorDepth must be 24, 30, or 32.")
            }
        }
        for (limitName, limitVal) in [
            ("webglMaxTextureSize", slot.webglMaxTextureSize),
            ("webglMaxRenderbufferSize", slot.webglMaxRenderbufferSize),
            ("webglMaxCubeMapTextureSize", slot.webglMaxCubeMapTextureSize),
        ] {
            if let limitVal, !(512...65536).contains(limitVal) {
                report.errors.append("\(name).\(limitName) must be in 512...65536.")
            }
        }
    }

    private static func checkSlotCoherence(
        _ slot: CuriumIdentitySlot,
        name: String,
        into report: inout CuriumFingerprintValidationReport
    ) {
        if slot.platform == "Windows" && !slot.hasWebGLOverride {
            report.warnings.append("\(name): Windows identity with native Apple Metal GPU strings may look inconsistent to GPU-aware detectors.")
        }
        if slot.platform == "Linux" && !slot.hasWebGLOverride {
            report.warnings.append("\(name): Linux identity with native Apple Metal GPU strings may look inconsistent to GPU-aware detectors.")
        }
        if slot.platform == "Android" && !slot.hasWebGLOverride {
            report.warnings.append("\(name): Android identity with native Apple Metal GPU strings may look inconsistent to GPU-aware detectors.")
        }
        if slot.mobile == true && (slot.navigatorPlatform == "MacIntel" || slot.navigatorPlatform == "Win32" || slot.navigatorPlatform == "Linux x86_64") {
            report.warnings.append("\(name): mobile=true paired with desktop navigator.platform (\(slot.navigatorPlatform ?? "")).")
        }
        if slot.mobile == false && (slot.navigatorPlatform == "Linux armv81" || slot.navigatorPlatform == "iPhone") {
            report.warnings.append("\(name): mobile=false paired with mobile navigator.platform (\(slot.navigatorPlatform ?? "")).")
        }
    }

    private static func checkCoherence(
        _ profile: CuriumFingerprintProfile,
        into report: inout CuriumFingerprintValidationReport
    ) {
        checkSlotCoherence(profile.mobile, name: "mobile", into: &report)
        checkSlotCoherence(profile.desktop, name: "desktop", into: &report)
        let defaultPlatform = profile.defaultSlot == .desktop
            ? (profile.desktop.platform ?? "macOS")
            : (profile.mobile.platform ?? "Android")
        if defaultPlatform == "Android", let mem = profile.hardware.deviceMemoryGB, mem > 8 {
            report.warnings.append("Android Chrome caps navigator.deviceMemory at 8 GB; overriding to \(Int(mem)) GB is anomalous.")
        }
    }

    private static func isASCIIAlnum(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isPrintableASCII(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
    }

    private static func hasControlChars(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Mirrors Chromium `net::ProxyConfig::ProxyRules::ParseFromString` syntax
    /// while rejecting `direct://`-only rules and malformed schemes/ports so
    /// invalid fixed-proxy strings fail at save/import time rather than launch.
    static func isValidFixedProxyRules(_ rules: String) -> Bool {
        let allowedRulePrefixes: Set<String> = ["http", "https", "ftp", "socks"]
        let allowedProxySchemes: Set<String> = ["http", "https", "socks", "socks4", "socks5"]
        let clauses = rules.split(separator: ";", omittingEmptySubsequences: false)
        guard !clauses.isEmpty else { return false }
        var foundNonDirectProxy = false

        for rawClause in clauses {
            let clause = rawClause.trimmingCharacters(in: .whitespaces)
            guard !clause.isEmpty else { return false }
            let uriList: String
            if let eqIdx = clause.firstIndex(of: "=") {
                let prefix = clause[..<eqIdx].trimmingCharacters(in: .whitespaces).lowercased()
                guard allowedRulePrefixes.contains(prefix) else { return false }
                uriList = String(clause[clause.index(after: eqIdx)...])
            } else {
                uriList = clause
            }
            let entries = uriList.split(separator: ",", omittingEmptySubsequences: false)
            guard !entries.isEmpty else { return false }
            for rawEntry in entries {
                let entry = rawEntry.trimmingCharacters(in: .whitespaces)
                guard !entry.isEmpty,
                      !entry.contains(where: { $0.isWhitespace })
                else { return false }
                if entry.lowercased() == "direct://" {
                    return false
                }
                let hostPort: Substring
                if let sepRange = entry.range(of: "://") {
                    let scheme = entry[..<sepRange.lowerBound].lowercased()
                    guard allowedProxySchemes.contains(scheme) else { return false }
                    hostPort = entry[sepRange.upperBound...]
                } else {
                    hostPort = Substring(entry)
                }
                guard !hostPort.isEmpty, !hostPort.contains("/") else { return false }
                let host: Substring
                let portStr: Substring?
                let isIPv6: Bool
                if hostPort.hasPrefix("[") {
                    guard let closeIdx = hostPort.firstIndex(of: "]") else { return false }
                    host = hostPort[hostPort.index(after: hostPort.startIndex)..<closeIdx]
                    isIPv6 = true
                    let rest = hostPort[hostPort.index(after: closeIdx)...]
                    if rest.isEmpty {
                        portStr = nil
                    } else if rest.hasPrefix(":") {
                        portStr = rest.dropFirst()
                    } else {
                        return false
                    }
                } else if let colonIdx = hostPort.lastIndex(of: ":") {
                    host = hostPort[..<colonIdx]
                    portStr = hostPort[hostPort.index(after: colonIdx)...]
                    isIPv6 = false
                } else {
                    host = hostPort
                    portStr = nil
                    isIPv6 = false
                }
                guard !host.isEmpty, (isIPv6 || !host.contains(":")) else { return false }
                if let portStr {
                    guard !portStr.isEmpty,
                          let port = Int(portStr),
                          (1...65535).contains(port)
                    else { return false }
                }
                foundNonDirectProxy = true
            }
        }
        return foundNonDirectProxy
    }
}
