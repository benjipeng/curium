import Foundation
import Observation
import OSLog

/// Durable Swift store for user-defined and built-in fingerprint profiles.
/// Lives beside `curium.sqlite` in the LiveContainer-durable support directory
/// (App Group -> Host Container -> Standalone Application Support).
@Observable
final class CuriumFingerprintStore {
    struct PersistedState: Codable, Equatable {
        var version: Int = 1
        /// `nil` means unconfigured Build 39 (`0105`) default mode.
        var selectedProfileID: String?
        var profiles: [CuriumFingerprintProfile]
    }

    static let fileName = "fingerprint-profiles.json"

    private let fileURL: URL
    private(set) var selectedProfileID: String?
    private(set) var profiles: [CuriumFingerprintProfile]
    private(set) var lastPersistError: String?

    /// The profile currently selected for next launch, or `nil` when using Build 39 defaults.
    var selectedProfile: CuriumFingerprintProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    var builtInProfiles: [CuriumFingerprintProfile] {
        profiles.filter(\.isBuiltIn)
    }

    var customProfiles: [CuriumFingerprintProfile] {
        profiles.filter { !$0.isBuiltIn }
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        {
            self.selectedProfileID = decoded.selectedProfileID
            self.profiles = Self.mergedWithBuiltIns(decoded.profiles)
        } else {
            self.selectedProfileID = nil
            self.profiles = CuriumFingerprintPresets.allBuiltIns
        }
    }

    static func defaultStorageURL() -> URL {
        if let resolution = try? CuriumLibraryLocation.resolve() {
            return resolution.database
                .deletingLastPathComponent()
                .appending(path: fileName, directoryHint: .notDirectory)
        }
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Curium/\(fileName)", directoryHint: .notDirectory)
    }

    static func loadShared() -> CuriumFingerprintStore {
        CuriumFingerprintStore(fileURL: defaultStorageURL())
    }

    @discardableResult
    func selectProfile(id: String?) -> Bool {
        if let id, !profiles.contains(where: { $0.id == id }) {
            return false
        }
        let previous = selectedProfileID
        selectedProfileID = id
        if !persist() {
            selectedProfileID = previous
            return false
        }
        return true
    }

    @discardableResult
    func resetToBuild39Default() -> Bool {
        let previous = selectedProfileID
        selectedProfileID = nil
        if !persist() {
            selectedProfileID = previous
            return false
        }
        return true
    }

    /// Creates or updates a user-owned custom profile. Built-in presets are
    /// immutable templates and must be duplicated to a new ID before editing.
    /// Comparisons use case-insensitive matching to prevent APFS directory collisions.
    @discardableResult
    func upsert(_ profile: CuriumFingerprintProfile) -> CuriumFingerprintValidationReport {
        var report = CuriumFingerprintValidator.validate(profile)
        let loweredID = profile.id.lowercased()
        let builtInLowered = Set(CuriumFingerprintPresets.builtInIDs.map { $0.lowercased() })
        if builtInLowered.contains(loweredID) {
            report.errors.append("Built-in profile \"\(profile.id)\" cannot be overwritten directly. Duplicate it to a new ID first.")
        }
        if let collision = profiles.first(where: { $0.id.lowercased() == loweredID && $0.id != profile.id }) {
            report.errors.append("Profile ID \"\(profile.id)\" conflicts with existing profile \"\(collision.id)\" on case-insensitive APFS.")
        }
        guard report.isValid else { return report }

        var updated = profile
        updated.isBuiltIn = false
        let previousProfiles = profiles
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            updated.revision = max(profile.revision, profiles[idx].revision + 1)
            profiles[idx] = updated
        } else {
            updated.revision = max(profile.revision, 1)
            profiles.append(updated)
        }
        if !persist() {
            profiles = previousProfiles
            report.errors.append(lastPersistError ?? "Failed to save profile store to disk.")
        }
        return report
    }

    @discardableResult
    func deleteProfile(id: String) -> Bool {
        let loweredID = id.lowercased()
        let builtInLowered = Set(CuriumFingerprintPresets.builtInIDs.map { $0.lowercased() })
        guard loweredID != "default", !builtInLowered.contains(loweredID) else { return false }
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return false }
        guard !profiles[idx].isBuiltIn else { return false }
        let previousProfiles = profiles
        let previousSelection = selectedProfileID
        profiles.remove(at: idx)
        if selectedProfileID == id {
            selectedProfileID = nil
        }
        if !persist() {
            profiles = previousProfiles
            selectedProfileID = previousSelection
            return false
        }
        return true
    }

    func nextAvailableID(base: String) -> String {
        let sanitizedChars = base.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
                || scalar == "-" || scalar == "_"
            {
                return Character(scalar)
            }
            return "-"
        }
        var stem = String(sanitizedChars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if stem.isEmpty || stem.lowercased() == "default" {
            stem = "profile"
        }
        let existingLowered = Set(profiles.map { $0.id.lowercased() })
        for suffix in 2...999 {
            let suffixStr = "-\(suffix)"
            let maxStemLen = max(1, 32 - suffixStr.count)
            let candidate = String(stem.prefix(maxStemLen)) + suffixStr
            if CuriumFingerprintValidator.isValidProfileID(candidate),
               !existingLowered.contains(candidate.lowercased())
            {
                return candidate
            }
        }
        return "custom-\(UUID().uuidString.prefix(8).lowercased())"
    }

    func duplicateProfile(from sourceID: String, newID: String, displayName: String) -> CuriumFingerprintProfile? {
        let loweredNew = newID.lowercased()
        let builtInLowered = Set(CuriumFingerprintPresets.builtInIDs.map { $0.lowercased() })
        guard CuriumFingerprintValidator.isValidProfileID(newID),
              loweredNew != "default",
              !builtInLowered.contains(loweredNew),
              !profiles.contains(where: { $0.id.lowercased() == loweredNew }),
              var copy = profiles.first(where: { $0.id == sourceID })
        else { return nil }
        copy.id = newID
        copy.displayName = displayName
        copy.isBuiltIn = false
        copy.revision = 1
        let previousProfiles = profiles
        profiles.append(copy)
        guard persist() else {
            profiles = previousProfiles
            return nil
        }
        return copy
    }

    func exportProfileJSON(id: String) throws -> Data {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    /// Imports either a full `CuriumFingerprintProfile` JSON document or a
    /// Build 40 engine wire payload (`schemaVersion` + `profileId`).
    /// Rejects built-in profile IDs so users duplicate rather than overwrite templates.
    func importProfileJSON(_ data: Data) throws -> CuriumFingerprintValidationReport {
        let decoder = JSONDecoder()
        if var profile = try? decoder.decode(CuriumFingerprintProfile.self, from: data) {
            profile.isBuiltIn = false
            return upsert(profile)
        }
        let wire = try decoder.decode(EngineWireImportPayload.self, from: data)
        guard (CuriumFingerprintSchema.minSupportedVersion...CuriumFingerprintSchema.version).contains(wire.schemaVersion) else {
            return CuriumFingerprintValidationReport(
                errors: ["Unsupported fingerprint schemaVersion: \(wire.schemaVersion) (expected \(CuriumFingerprintSchema.minSupportedVersion)–\(CuriumFingerprintSchema.version))."]
            )
        }
        let imported = CuriumFingerprintProfile(
            id: wire.profileId,
            displayName: wire.profileId,
            notes: "Imported from engine wire JSON",
            isBuiltIn: false,
            revision: wire.revision ?? 1,
            defaultSlot: wire.defaultSlot ?? .mobile,
            mobile: wire.mobile ?? CuriumIdentitySlot(),
            desktop: wire.desktop ?? CuriumIdentitySlot(),
            languages: wire.languages,
            proxy: wire.proxy ?? .system,
            webrtcIpHandlingPolicy: wire.webrtcIpHandlingPolicy ?? .default,
            enableDoNotTrack: wire.enableDoNotTrack ?? false,
            enableGlobalPrivacyControl: wire.enableGlobalPrivacyControl ?? false,
            hardware: wire.hardware ?? .native,
            fingerprintSeed: wire.fingerprintSeed,
            farbling: wire.farbling,
            fontProfile: wire.fontProfile,
            hideSpeechVoices: wire.hideSpeechVoices
        )
        return upsert(imported)
    }

    @discardableResult
    private func persist() -> Bool {
        let state = PersistedState(
            version: 1,
            selectedProfileID: selectedProfileID,
            profiles: profiles
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
            lastPersistError = nil
            return true
        } catch {
            lastPersistError = error.localizedDescription
            Self.log.error("fingerprint store persist failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Emits built-in presets first in canonical order (keeping definitions up to date
    /// across app updates), followed by user-owned custom profiles (case-insensitively deduplicated).
    private static func mergedWithBuiltIns(_ stored: [CuriumFingerprintProfile]) -> [CuriumFingerprintProfile] {
        var result = CuriumFingerprintPresets.allBuiltIns
        var seenLowered = Set(CuriumFingerprintPresets.builtInIDs.map { $0.lowercased() })
        for item in stored {
            let key = item.id.lowercased()
            guard !seenLowered.contains(key) else { continue }
            seenLowered.insert(key)
            var custom = item
            custom.isBuiltIn = false
            result.append(custom)
        }
        return result
    }

    private struct EngineWireImportPayload: Decodable {
        let schemaVersion: Int
        let revision: UInt64?
        let profileId: String
        let defaultSlot: CuriumDefaultSlot?
        let mobile: CuriumIdentitySlot?
        let desktop: CuriumIdentitySlot?
        let languages: [String]?
        let proxy: CuriumProxyConfig?
        let webrtcIpHandlingPolicy: CuriumWebRTCPolicy?
        let enableDoNotTrack: Bool?
        let enableGlobalPrivacyControl: Bool?
        let hardware: CuriumHardwareOverrides?
        let fingerprintSeed: String?
        let farbling: CuriumFarblingSettings?
        let fontProfile: CuriumFontProfile?
        let hideSpeechVoices: Bool?
    }

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "fingerprint")
}

/// Pre-`ChromeMain` bootstrap coordinator that probes engine capabilities,
/// validates & registers bounded launch configuration bytes, and fails closed
/// on any rejected or unavailable explicit profile.
enum CuriumFingerprintBootstrap {
    enum LaunchOutcome: Equatable, Sendable {
        case defaultBuild39
        case configured(profileID: String, revision: UInt64, nativeHardware: Bool)
        case rejected(profileID: String, reason: String)
    }

    @MainActor
    static private(set) var lastOutcome: LaunchOutcome = .defaultBuild39

    @MainActor
    static func engineCapabilities() -> CuriumEngineFingerprintCapabilities {
        CuriumEngineFingerprintCapabilities(dictionary: CuriumEngineFingerprintCapabilitiesDict())
    }

    @MainActor
    static func activeEngineStatus() -> CuriumEngineFingerprintStatus? {
        guard let dict = CuriumEngineActiveFingerprintStatusDict() else { return nil }
        return CuriumEngineFingerprintStatus(dictionary: dict)
    }

    /// Runs once on the main thread before `ChromeMain`.
    /// Returns `.rejected` (fail closed) whenever an explicit profile is selected
    /// but missing, invalid, unsupported by the linked engine, or locked/unavailable.
    @MainActor
    static func prepareEngineLaunch(store: CuriumFingerprintStore = .loadShared()) -> LaunchOutcome {
        guard let selectedID = store.selectedProfileID else {
            _ = CuriumConfigureLaunchFingerprint(nil, nil)
            lastOutcome = .defaultBuild39
            return .defaultBuild39
        }
        guard let profile = store.profiles.first(where: { $0.id == selectedID }) else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "Selected profile \"\(selectedID)\" was not found in the profile store."
            )
            lastOutcome = outcome
            return outcome
        }

        let validation = CuriumFingerprintValidator.validate(profile)
        guard validation.isValid else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: validation.errors.joined(separator: " ")
            )
            lastOutcome = outcome
            return outcome
        }

        let caps = engineCapabilities()
        guard caps.supportsLaunchFingerprintConfig else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "The embedded Blink engine does not support launch fingerprint profiles (requires Build 40+)."
            )
            lastOutcome = outcome
            return outcome
        }

        let negotiatedVersion = min(
            CuriumFingerprintSchema.version,
            max(CuriumFingerprintSchema.minSupportedVersion, caps.contractVersion)
        )
        let jsonData: Data
        do {
            jsonData = try profile.makeEngineLaunchJSON(schemaVersion: negotiatedVersion)
        } catch {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "Failed to encode profile JSON: \(error.localizedDescription)"
            )
            lastOutcome = outcome
            return outcome
        }

        var engineError: NSError?
        guard CuriumConfigureLaunchFingerprint(jsonData, &engineError) else {
            let reason = engineError?.localizedDescription
                ?? "Blink engine rejected launch fingerprint configuration."
            let outcome = LaunchOutcome.rejected(profileID: selectedID, reason: reason)
            lastOutcome = outcome
            return outcome
        }

        let outcome = LaunchOutcome.configured(
            profileID: profile.id,
            revision: profile.revision,
            nativeHardware: profile.usesNativeHardwareAndGPU
        )
        lastOutcome = outcome
        return outcome
    }
}
