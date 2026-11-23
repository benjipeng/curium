import Darwin
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

    struct ParsedImport: Equatable, Sendable {
        let profile: CuriumFingerprintProfile
        let schemaError: String?
        let warnings: [String]
    }

    static let fileName = "fingerprint-profiles.json"

    /// Process-wide main-actor singleton shared across launch bootstrap, recovery UI,
    /// Settings, and Fingerprint Studio.
    @MainActor
    static let shared = CuriumFingerprintStore.loadShared()

    private let fileURL: URL
    private let applicationSupportRoot: URL?
    private let cachesRoot: URL?
    private var migratedBuiltInSeedIDs: Set<String> = []

    private(set) var selectedProfileID: String?
    private(set) var profiles: [CuriumFingerprintProfile]
    private(set) var loadError: String?
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

    convenience init(fileURL: URL) {
        self.init(fileURL: fileURL, applicationSupportRoot: nil, cachesRoot: nil)
    }

    init(
        fileURL: URL,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) {
        self.fileURL = fileURL
        self.applicationSupportRoot = applicationSupportRoot
        self.cachesRoot = cachesRoot

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let merged = Self.mergedWithBuiltIns([])
            self.selectedProfileID = nil
            self.profiles = merged.profiles
            self.migratedBuiltInSeedIDs = merged.migratedBuiltInSeedIDs
            if Self.isFileMissingError(error) {
                self.loadError = nil
            } else {
                self.loadError = "Unable to read \(Self.fileName): \(error.localizedDescription)"
                Self.log.error("fingerprint store read failed (fail-closed): \(String(describing: error), privacy: .public)")
            }
            return
        }

        do {
            let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
            let merged = Self.mergedWithBuiltIns(decoded.profiles)
            self.selectedProfileID = decoded.selectedProfileID
            self.profiles = merged.profiles
            self.migratedBuiltInSeedIDs = merged.migratedBuiltInSeedIDs
            self.loadError = nil
        } catch {
            let merged = Self.mergedWithBuiltIns([])
            self.selectedProfileID = nil
            self.profiles = merged.profiles
            self.migratedBuiltInSeedIDs = merged.migratedBuiltInSeedIDs
            self.loadError = "Corrupt \(Self.fileName): \(Self.describeDecodingError(error))"
            Self.log.error("fingerprint store decode failed (fail-closed): \(String(describing: error), privacy: .public)")
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

    /// Moves an unreadable/corrupt `fingerprint-profiles.json` aside to
    /// `fingerprint-profiles.corrupt-<timestamp>.bak`, clears `loadError`,
    /// resets to Build 39 defaults + built-in presets, and persists a clean store.
    @discardableResult
    func backupCorruptStoreAndReset() -> Bool {
        let fm = FileManager.default
        var st = stat()
        if lstat(fileURL.path, &st) == 0 {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
            let baseName = "fingerprint-profiles.corrupt-\(stamp)"
            let dir = fileURL.deletingLastPathComponent()
            var backupURL = dir.appending(path: "\(baseName).bak", directoryHint: .notDirectory)
            var suffix = 2
            while lstat(backupURL.path, &st) == 0 {
                backupURL = dir.appending(path: "\(baseName)-\(suffix).bak", directoryHint: .notDirectory)
                suffix += 1
            }
            do {
                try fm.moveItem(at: fileURL, to: backupURL)
            } catch {
                lastPersistError = "Failed to back up corrupt store: \(error.localizedDescription)"
                Self.log.error("corrupt store backup failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }

        let previousLoadError = loadError
        let previousSelection = selectedProfileID
        let previousProfiles = profiles
        let previousMigrated = migratedBuiltInSeedIDs

        let merged = Self.mergedWithBuiltIns([])
        loadError = nil
        selectedProfileID = nil
        profiles = merged.profiles
        migratedBuiltInSeedIDs = merged.migratedBuiltInSeedIDs

        if !persist() {
            loadError = previousLoadError
            selectedProfileID = previousSelection
            profiles = previousProfiles
            migratedBuiltInSeedIDs = previousMigrated
            return false
        }
        return true
    }

    @discardableResult
    func selectProfile(id: String?) -> Bool {
        guard loadError == nil else {
            lastPersistError = "Cannot modify profile selection while \(Self.fileName) is unreadable. Back up and reset the corrupt store first."
            return false
        }
        if let id, !profiles.contains(where: { $0.id == id }) {
            return false
        }
        let previousSelection = selectedProfileID
        let previousProfiles = profiles
        let previousMigrated = migratedBuiltInSeedIDs

        if let id, let idx = profiles.firstIndex(where: { $0.id == id }) {
            materializeFarblingSeedIfNeeded(at: idx)
        }
        selectedProfileID = id
        if !persist() {
            selectedProfileID = previousSelection
            profiles = previousProfiles
            migratedBuiltInSeedIDs = previousMigrated
            return false
        }
        return true
    }

    @discardableResult
    func resetToBuild39Default() -> Bool {
        guard loadError == nil else {
            lastPersistError = "Cannot reset selection while \(Self.fileName) is unreadable. Back up and reset the corrupt store first."
            return false
        }
        let previous = selectedProfileID
        selectedProfileID = nil
        if !persist() {
            selectedProfileID = previous
            return false
        }
        return true
    }

    /// Ensures a farbling-enabled profile (such as `privacy-hardened`) has a fresh
    /// non-retired 256-bit seed materialized and persisted to disk before engine launch.
    @discardableResult
    func ensureMaterializedSeedPersisted(for id: String) -> Bool {
        guard loadError == nil,
              let idx = profiles.firstIndex(where: { $0.id == id })
        else { return false }
        let needsPersist = materializeFarblingSeedIfNeeded(at: idx)
            || migratedBuiltInSeedIDs.contains(id.lowercased())
        guard needsPersist else { return true }
        return persist()
    }

    /// Validates a candidate profile against both structural rules and store constraints
    /// (built-in protection, case-insensitive APFS collisions, and orphaned directory collisions)
    /// without mutating the store.
    func validateForUpsert(_ profile: CuriumFingerprintProfile) -> CuriumFingerprintValidationReport {
        let normalized = profile.normalizedForPersistence()
        var report = CuriumFingerprintValidator.validate(normalized)
        let loweredID = normalized.id.lowercased()
        let builtInLowered = Set(CuriumFingerprintPresets.builtInIDs.map { $0.lowercased() })
        if builtInLowered.contains(loweredID) {
            report.errors.append("Built-in profile \"\(normalized.id)\" cannot be overwritten directly. Duplicate it to a new ID first.")
        }
        if let collision = profiles.first(where: { $0.id.lowercased() == loweredID && $0.id != normalized.id }) {
            report.errors.append("Profile ID \"\(normalized.id)\" conflicts with existing profile \"\(collision.id)\" on case-insensitive APFS.")
        }
        let isNewEntry = !profiles.contains(where: { $0.id == normalized.id })
        if isNewEntry,
           CuriumFingerprintValidator.isValidProfileID(normalized.id),
           normalized.id != "default",
           diskProfileSlugsLowered().contains(loweredID)
        {
            report.errors.append("An orphaned storage directory for \"\(normalized.id)\" already exists on disk. Wipe it under Orphaned Storage first or choose a different ID.")
        }
        return report
    }

    /// Creates or updates a user-owned custom profile. Built-in presets are
    /// immutable templates and must be duplicated to a new ID before editing.
    /// Comparisons use case-insensitive matching to prevent APFS directory collisions.
    @discardableResult
    func upsert(_ profile: CuriumFingerprintProfile) -> CuriumFingerprintValidationReport {
        let normalized = profile.normalizedForPersistence()
        var report = validateForUpsert(normalized)
        guard report.isValid else { return report }

        var updated = normalized
        updated.isBuiltIn = false
        let previousProfiles = profiles
        if let idx = profiles.firstIndex(where: { $0.id == normalized.id }) {
            updated.revision = max(normalized.revision, profiles[idx].revision + 1)
            profiles[idx] = updated
        } else {
            updated.revision = max(normalized.revision, 1)
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

    func nextAvailableID(
        base: String,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) -> String {
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
        let diskSlugs = CuriumFingerprintProfileStorage.existingIsolatedProfileSlugs(
            applicationSupportRoot: applicationSupportRoot ?? self.applicationSupportRoot,
            cachesRoot: cachesRoot ?? self.cachesRoot
        ).map { $0.lowercased() }
        let occupiedLowered = Set(profiles.map { $0.id.lowercased() }).union(diskSlugs)

        for suffix in 2...999 {
            let suffixStr = "-\(suffix)"
            let maxStemLen = max(1, 32 - suffixStr.count)
            let candidate = String(stem.prefix(maxStemLen)) + suffixStr
            if CuriumFingerprintValidator.isValidProfileID(candidate),
               !occupiedLowered.contains(candidate.lowercased())
            {
                return candidate
            }
        }
        for _ in 0..<32 {
            let candidate = "custom-\(UUID().uuidString.prefix(8).lowercased())"
            if !occupiedLowered.contains(candidate) {
                return candidate
            }
        }
        return "custom-\(UUID().uuidString.prefix(8).lowercased())"
    }

    func duplicateProfile(from sourceID: String, newID: String, displayName: String) -> CuriumFingerprintProfile? {
        let trimmedNewID = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredNew = trimmedNewID.lowercased()
        let builtInLowered = Set(CuriumFingerprintPresets.builtInIDs.map { $0.lowercased() })
        guard CuriumFingerprintValidator.isValidProfileID(trimmedNewID),
              loweredNew != "default",
              !builtInLowered.contains(loweredNew),
              !profiles.contains(where: { $0.id.lowercased() == loweredNew }),
              !diskProfileSlugsLowered().contains(loweredNew),
              var copy = profiles.first(where: { $0.id == sourceID })
        else { return nil }
        copy.id = trimmedNewID
        copy.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.isBuiltIn = false
        copy.revision = 1
        // Always mint an independent 256-bit farbling seed on clone so duplicated profiles
        // never share Canvas/Audio/WebGL/TextMetrics farbling hashes across sites.
        if copy.fingerprintSeed != nil || copy.hasFarblingEnabled {
            copy.fingerprintSeed = Self.mintFreshSeed(differentFrom: copy.fingerprintSeed)
        }
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

    /// Parses and normalizes either a full `CuriumFingerprintProfile` JSON document or
    /// an engine wire payload (`schemaVersion` + `profileId`) without mutating the store.
    /// Preserves the real `DecodingError` from the matching schema format.
    func parseImportJSON(_ data: Data) throws -> ParsedImport {
        let rawObject = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = rawObject as? [String: Any]
        let isWirePayload = (dict?["profileId"] != nil) && (dict?["id"] == nil)

        let decoder = JSONDecoder()
        var warnings: [String] = []
        var imported: CuriumFingerprintProfile

        if isWirePayload {
            let wire = try decoder.decode(EngineWireImportPayload.self, from: data)
            guard (CuriumFingerprintSchema.minSupportedVersion...CuriumFingerprintSchema.version)
                .contains(wire.schemaVersion)
            else {
                let placeholder = CuriumFingerprintProfile(
                    id: wire.profileId,
                    displayName: wire.profileId,
                    notes: "",
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
                    hardware: wire.hardware ?? .native
                )
                return ParsedImport(
                    profile: placeholder.normalizedForPersistence(),
                    schemaError: "Unsupported fingerprint schemaVersion: \(wire.schemaVersion) (expected \(CuriumFingerprintSchema.minSupportedVersion)–\(CuriumFingerprintSchema.version)).",
                    warnings: []
                )
            }
            imported = CuriumFingerprintProfile(
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
        } else {
            imported = try decoder.decode(CuriumFingerprintProfile.self, from: data)
        }

        imported = imported.normalizedForPersistence()
        imported.isBuiltIn = false
        if imported.displayName.isEmpty {
            imported.displayName = imported.id
        }
        if CuriumFingerprintSchema.isRetiredStaticSeed(imported.fingerprintSeed) {
            imported.fingerprintSeed = Self.mintFreshSeed(differentFrom: imported.fingerprintSeed)
            warnings.append("Replaced retired public farbling seed with a fresh random 256-bit seed.")
        }
        return ParsedImport(profile: imported, schemaError: nil, warnings: warnings)
    }

    /// Imports either a full `CuriumFingerprintProfile` JSON document or a
    /// Build 40/41 engine wire payload (`schemaVersion` + `profileId`).
    /// Rejects built-in profile IDs so users duplicate rather than overwrite templates.
    func importProfileJSON(_ data: Data) throws -> CuriumFingerprintValidationReport {
        let parsed = try parseImportJSON(data)
        if let schemaError = parsed.schemaError {
            return CuriumFingerprintValidationReport(errors: [schemaError])
        }
        var report = upsert(parsed.profile)
        report.warnings.append(contentsOf: parsed.warnings)
        return report
    }

    @discardableResult
    private func persist() -> Bool {
        if let loadError {
            lastPersistError = "Blocked saving \(Self.fileName) while existing store is unreadable (\(loadError)). Back up and reset the corrupt store first."
            Self.log.error("fingerprint store persist blocked (fail-closed): \(loadError, privacy: .public)")
            return false
        }
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
            migratedBuiltInSeedIDs.removeAll()
            return true
        } catch {
            lastPersistError = error.localizedDescription
            Self.log.error("fingerprint store persist failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func materializeFarblingSeedIfNeeded(at index: Int) -> Bool {
        guard profiles.indices.contains(index) else { return false }
        guard profiles[index].hasFarblingEnabled else { return false }
        let current = profiles[index].fingerprintSeed
        if let current,
           CuriumFingerprintSchema.isValidSeedHex(current),
           !CuriumFingerprintSchema.isRetiredStaticSeed(current)
        {
            return false
        }
        profiles[index].fingerprintSeed = Self.mintFreshSeed(differentFrom: current)
        return true
    }

    private func diskProfileSlugsLowered() -> Set<String> {
        Set(
            CuriumFingerprintProfileStorage.existingIsolatedProfileSlugs(
                applicationSupportRoot: applicationSupportRoot,
                cachesRoot: cachesRoot
            ).map { $0.lowercased() }
        )
    }

    static func mintFreshSeed(differentFrom existing: String?) -> String {
        var candidate = CuriumFingerprintSchema.generateRandomSeedHex()
        if let existing, candidate.lowercased() == existing.lowercased() {
            candidate = CuriumFingerprintSchema.generateRandomSeedHex()
        }
        return candidate
    }

    static func describeDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        func formatPath(_ codingPath: [CodingKey]) -> String {
            let joined = codingPath.map(\.stringValue).joined(separator: ".")
            return joined.isEmpty ? "root" : joined
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            let path = formatPath(context.codingPath + [key])
            return "Missing required key \"\(path)\"."
        case .typeMismatch(let type, let context):
            return "Type mismatch at \"\(formatPath(context.codingPath))\" (expected \(type))."
        case .valueNotFound(let type, let context):
            return "Null value at \"\(formatPath(context.codingPath))\" (expected \(type))."
        case .dataCorrupted(let context):
            return "Corrupted data at \"\(formatPath(context.codingPath))\": \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func isFileMissingError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)
        {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isFileMissingError(underlying)
        }
        return false
    }

    /// Emits built-in presets first in canonical order (keeping definitions up to date
    /// across app updates while preserving per-install materialized random farbling seeds),
    /// followed by user-owned custom profiles (case-insensitively deduplicated).
    private static func mergedWithBuiltIns(
        _ stored: [CuriumFingerprintProfile]
    ) -> (profiles: [CuriumFingerprintProfile], migratedBuiltInSeedIDs: Set<String>) {
        let storedByLoweredID = Dictionary(
            stored.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var migratedSeedIDs: Set<String> = []
        var result: [CuriumFingerprintProfile] = CuriumFingerprintPresets.allBuiltIns.map { preset in
            var resolved = preset
            if resolved.hasFarblingEnabled {
                let storedSeed = storedByLoweredID[preset.id.lowercased()]?.fingerprintSeed
                if let storedSeed,
                   CuriumFingerprintSchema.isValidSeedHex(storedSeed),
                   !CuriumFingerprintSchema.isRetiredStaticSeed(storedSeed)
                {
                    resolved.fingerprintSeed = storedSeed
                } else {
                    resolved.fingerprintSeed = CuriumFingerprintSchema.generateRandomSeedHex()
                    migratedSeedIDs.insert(preset.id.lowercased())
                }
            }
            return resolved
        }

        var seenLowered = Set(CuriumFingerprintPresets.builtInIDs.map { $0.lowercased() })
        for item in stored {
            let key = item.id.lowercased()
            guard !seenLowered.contains(key) else { continue }
            seenLowered.insert(key)
            var custom = item
            custom.isBuiltIn = false
            result.append(custom)
        }
        return (result, migratedSeedIDs)
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
/// on any corrupt store, rejected, or unavailable explicit profile.
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
    /// Returns `.rejected` (fail closed) whenever the profile store is unreadable/corrupt
    /// or an explicit profile is selected but missing, invalid, unsupported by the linked
    /// engine, or locked/unavailable.
    @MainActor
    static func prepareEngineLaunch(store: CuriumFingerprintStore = .shared) -> LaunchOutcome {
        if let loadError = store.loadError {
            let outcome = LaunchOutcome.rejected(
                profileID: "store",
                reason: "Profile store failed to load safely: \(loadError)"
            )
            lastOutcome = outcome
            return outcome
        }

        guard let selectedID = store.selectedProfileID else {
            _ = CuriumConfigureLaunchFingerprint(nil, nil)
            lastOutcome = .defaultBuild39
            return .defaultBuild39
        }

        _ = store.ensureMaterializedSeedPersisted(for: selectedID)

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
