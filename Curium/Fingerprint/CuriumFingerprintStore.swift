import Darwin
import Foundation
import Observation
import OSLog
import Security
import os

/// Durable Swift store (v2) for user-retained multi-profile identities & fingerprints.
/// Lives beside `"default"`'s `curium.sqlite` in the LiveContainer-durable support root
/// (App Group -> Host Container -> Standalone Application Support).
@Observable
final class CuriumFingerprintStore {
    struct PersistedState: Codable, Equatable {
        static let currentVersion = 2

        var version: Int = Self.currentVersion
        /// `nil` or `"default"` selects the primary default profile (`Personal`).
        var selectedProfileID: String?
        var profiles: [CuriumFingerprintProfile]
        var retiredProfileIDs: Set<String> = []

        private enum CodingKeys: String, CodingKey {
            case version
            case selectedProfileID
            case profiles
            case retiredProfileIDs
        }

        init(
            version: Int = Self.currentVersion,
            selectedProfileID: String?,
            profiles: [CuriumFingerprintProfile],
            retiredProfileIDs: Set<String> = []
        ) {
            self.version = version
            self.selectedProfileID = selectedProfileID
            self.profiles = profiles
            self.retiredProfileIDs = retiredProfileIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            selectedProfileID = try container.decodeIfPresent(String.self, forKey: .selectedProfileID)
            profiles = try container.decode([CuriumFingerprintProfile].self, forKey: .profiles)
            retiredProfileIDs = try container.decodeIfPresent(Set<String>.self, forKey: .retiredProfileIDs) ?? []
        }
    }

    struct ParsedImport: Equatable, Sendable {
        let profile: CuriumFingerprintProfile
        let schemaError: String?
        let warnings: [String]
    }

    static let fileName = "fingerprint-profiles.json"

    /// Process-wide main-actor singleton shared across launch bootstrap, recovery UI,
    /// Settings, and Profile Studio.
    @MainActor
    static let shared = CuriumFingerprintStore.loadShared()

    private let fileURL: URL
    private let applicationSupportRoot: URL?
    private let cachesRoot: URL?
    private let curiumSupportRoot: URL?
    private var migratedSeedIDs: Set<String> = []

    private(set) var selectedProfileID: String?
    private(set) var profiles: [CuriumFingerprintProfile]
    private(set) var retiredProfileIDs: Set<String>
    private(set) var loadError: String?
    private(set) var lastPersistError: String?

    var templates: [CuriumProfileTemplate] {
        CuriumProfileTemplate.allTemplates
    }

    /// Profile ID scheduled for next cold launch (`nil` resolves to `"default"`).
    var nextLaunchProfileID: String {
        selectedProfileID ?? "default"
    }

    /// Profile ID actively running in this process.
    var activeLaunchProfileID: String {
        CuriumFingerprintBootstrap.activeProfileID
    }

    /// The profile currently running in this process.
    var activeProfile: CuriumFingerprintProfile {
        profile(id: activeLaunchProfileID)
            ?? profiles.first(where: \.isPrimaryDefault)
            ?? Self.makeDefaultPersonalProfile()
    }

    /// The profile scheduled for next cold launch.
    var nextLaunchProfile: CuriumFingerprintProfile {
        profile(id: nextLaunchProfileID)
            ?? profiles.first(where: \.isPrimaryDefault)
            ?? Self.makeDefaultPersonalProfile()
    }

    var hasPendingProfileSwitch: Bool {
        nextLaunchProfileID.lowercased() != activeLaunchProfileID.lowercased()
    }

    /// The profile explicitly selected for next launch, or `nil` when using unconfigured defaults.
    var selectedProfile: CuriumFingerprintProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    /// Compatibility accessor for Wave 1 Studio UI (empty in v2 retained-profile stores).
    var builtInProfiles: [CuriumFingerprintProfile] {
        profiles.filter(\.isBuiltIn)
    }

    /// Compatibility accessor returning all non-default retained profiles.
    var customProfiles: [CuriumFingerprintProfile] {
        profiles.filter { !$0.isPrimaryDefault }
    }

    func profile(id: String) -> CuriumFingerprintProfile? {
        let lowered = id.lowercased()
        return profiles.first { $0.id.lowercased() == lowered }
    }

    convenience init(fileURL: URL) {
        self.init(fileURL: fileURL, applicationSupportRoot: nil, cachesRoot: nil, curiumSupportRoot: nil)
    }

    init(
        fileURL: URL,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil,
        curiumSupportRoot: URL? = nil
    ) {
        self.fileURL = fileURL
        self.applicationSupportRoot = applicationSupportRoot
        self.cachesRoot = cachesRoot
        self.curiumSupportRoot = curiumSupportRoot

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let isProductionDefaultFile = applicationSupportRoot == nil
                && cachesRoot == nil
                && curiumSupportRoot == nil
                && fileURL.standardizedFileURL == Self.defaultStorageURL().standardizedFileURL
            let preserveLegacy = Self.isFileMissingError(error) && isProductionDefaultFile
            self.selectedProfileID = nil
            self.profiles = [Self.makeDefaultPersonalProfile(preserveLegacyDefaults: preserveLegacy)]
            self.retiredProfileIDs = []
            self.migratedSeedIDs = []
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
            let diskSlugs = Set(
                CuriumFingerprintProfileStorage.existingIsolatedProfileSlugs(
                    applicationSupportRoot: applicationSupportRoot,
                    cachesRoot: cachesRoot,
                    curiumSupportRoot: curiumSupportRoot
                ).map { $0.lowercased() }
            )

            var needsMigrationPersist = false
            if decoded.version < PersistedState.currentVersion {
                let migrated = Self.migrateV1ToV2(decoded, diskSlugsLowered: diskSlugs)
                self.selectedProfileID = migrated.selectedProfileID
                self.profiles = migrated.profiles
                self.retiredProfileIDs = migrated.retiredProfileIDs
                self.migratedSeedIDs = migrated.migratedSeedIDs
                needsMigrationPersist = true
            } else {
                let normalized = Self.normalizeV2State(decoded)
                self.selectedProfileID = normalized.selectedProfileID
                self.profiles = normalized.profiles
                self.retiredProfileIDs = normalized.retiredProfileIDs
                self.migratedSeedIDs = normalized.migratedSeedIDs
                needsMigrationPersist = normalized.needsPersist
            }
            self.loadError = nil
            if needsMigrationPersist {
                _ = persist()
            }
        } catch {
            self.selectedProfileID = nil
            self.profiles = [Self.makeDefaultPersonalProfile()]
            self.retiredProfileIDs = []
            self.migratedSeedIDs = []
            self.loadError = "Corrupt \(Self.fileName): \(Self.describeDecodingError(error))"
            Self.log.error("fingerprint store decode failed (fail-closed): \(String(describing: error), privacy: .public)")
        }
    }

    static func defaultStorageURL() -> URL {
        if let root = try? CuriumLibraryLocation.supportRootDirectory() {
            return root.appending(path: fileName, directoryHint: .notDirectory)
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

    static func makeDefaultPersonalProfile(
        preserveLegacyDefaults: Bool = false,
        now: Date = .now
    ) -> CuriumFingerprintProfile {
        var profile = CuriumFingerprintPresets.build39NativeBaseline
        profile.displayName = "Personal"
        profile.notes = "Primary profile using Chromium's default storage and Build 39 native baseline."
        profile.isBuiltIn = false
        profile.revision = 1
        profile.symbolName = "person.crop.circle"
        profile.templateID = "default"
        profile.createdAt = now
        if preserveLegacyDefaults {
            let defaults = UserDefaults.standard
            let rawPalette = defaults.string(forKey: "curium.palette")
            let rawSiteMode = defaults.string(forKey: "curium.siteMode")
            let rawSearchEngine = defaults.string(forKey: "curium.searchEngine")
            profile.palette = rawPalette.flatMap(CuriumPalette.init(rawValue:)) ?? .violet
            profile.siteMode = rawSiteMode.flatMap(CuriumSiteMode.init(rawValue:)) ?? .adaptive
            profile.searchEngine = rawSearchEngine.flatMap(CuriumSearchEngine.init(rawValue:)) ?? .google
        } else {
            profile.palette = .violet
            profile.siteMode = .adaptive
            profile.searchEngine = .google
        }
        return profile
    }

    /// Moves an unreadable/corrupt `fingerprint-profiles.json` aside to
    /// `fingerprint-profiles.corrupt-<timestamp>.bak`, clears `loadError`,
    /// resets to a clean v2 store with `"default"` (`Personal`), and persists it.
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
        let previousRetired = retiredProfileIDs
        let previousMigrated = migratedSeedIDs

        loadError = nil
        selectedProfileID = nil
        profiles = [Self.makeDefaultPersonalProfile()]
        retiredProfileIDs = []
        migratedSeedIDs = []

        if !persist() {
            loadError = previousLoadError
            selectedProfileID = previousSelection
            profiles = previousProfiles
            retiredProfileIDs = previousRetired
            migratedSeedIDs = previousMigrated
            return false
        }
        return true
    }

    /// Mints a fresh collision-free opaque slug (`p-<8 lowercase hex>`) that never
    /// collides with existing profiles, retired tombstones, built-in template IDs,
    /// or isolated storage directories on disk.
    func mintProfileSlug() -> String {
        let occupied = occupiedSlugsLowered()
        for _ in 0..<128 {
            let candidate = "p-\(Self.randomHex(byteCount: 4))"
            if CuriumFingerprintValidator.isValidProfileID(candidate),
               !occupied.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return "p-\(Self.randomHex(byteCount: 6))"
    }

    @discardableResult
    func createProfile(
        fromTemplate templateID: String,
        displayName: String,
        symbolName: String? = nil,
        palette: CuriumPalette? = nil,
        siteMode: CuriumSiteMode? = nil,
        searchEngine: CuriumSearchEngine? = nil,
        enableFarbling: Bool = true,
        randomizeHardwareVariant: Bool = true,
        hardwareVariantID: String? = nil,
        proxy: CuriumProxyConfig? = nil,
        timezone: String? = nil,
        languages: [String]? = nil
    ) -> CuriumFingerprintProfile? {
        guard loadError == nil else {
            lastPersistError = "Cannot create profile while \(Self.fileName) is unreadable. Back up and reset the corrupt store first."
            return nil
        }
        guard let template = CuriumProfileTemplate.template(for: templateID) else {
            lastPersistError = "Unknown profile template \"\(templateID)\"."
            return nil
        }
        let slug = mintProfileSlug()
        let created = template.instantiate(
            id: slug,
            displayName: displayName,
            symbolName: symbolName,
            palette: palette,
            siteMode: siteMode,
            searchEngine: searchEngine,
            enableFarbling: enableFarbling,
            randomizeHardwareVariant: randomizeHardwareVariant,
            hardwareVariantID: hardwareVariantID,
            avoidingExisting: profiles,
            proxy: proxy,
            timezone: timezone,
            languages: languages
        )
        let validation = validateForUpsert(created)
        guard validation.isValid else {
            lastPersistError = validation.errors.joined(separator: " ")
            return nil
        }
        let previousProfiles = profiles
        profiles.append(created)
        guard persist() else {
            profiles = previousProfiles
            return nil
        }
        return created
    }

    @discardableResult
    func updatePersonaMetadata(
        for id: String,
        displayName: String? = nil,
        symbolName: String? = nil,
        palette: CuriumPalette? = nil,
        siteMode: CuriumSiteMode? = nil,
        searchEngine: CuriumSearchEngine? = nil
    ) -> Bool {
        guard loadError == nil else {
            lastPersistError = "Cannot update profile while \(Self.fileName) is unreadable."
            return false
        }
        let lowered = id.lowercased()
        guard let idx = profiles.firstIndex(where: { $0.id.lowercased() == lowered }) else {
            return false
        }
        let previousProfiles = profiles
        var updated = profiles[idx]
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                updated.displayName = trimmed
            }
        }
        if let symbolName {
            let trimmed = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.symbolName = trimmed.isEmpty ? nil : trimmed
        }
        if let palette {
            updated.palette = palette
        }
        if let siteMode {
            updated.siteMode = siteMode
        }
        if let searchEngine {
            updated.searchEngine = searchEngine
        }
        guard updated != profiles[idx] else { return true }
        profiles[idx] = updated
        if !persist() {
            profiles = previousProfiles
            return false
        }
        return true
    }

    @discardableResult
    func markProfileUsed(_ id: String, at date: Date = .now) -> Bool {
        guard loadError == nil else { return false }
        let lowered = id.lowercased()
        guard let idx = profiles.firstIndex(where: { $0.id.lowercased() == lowered }) else {
            return false
        }
        let previousProfiles = profiles
        profiles[idx].lastUsedAt = date
        if !persist() {
            profiles = previousProfiles
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
        var canonicalID: String?
        if let id {
            guard let existing = profile(id: id) else {
                return false
            }
            canonicalID = existing.id
        }
        let previousSelection = selectedProfileID
        let previousProfiles = profiles
        let previousMigrated = migratedSeedIDs

        if let canonicalID, let idx = profiles.firstIndex(where: { $0.id == canonicalID }) {
            materializeFarblingSeedIfNeeded(at: idx)
        }
        selectedProfileID = canonicalID
        if !persist() {
            selectedProfileID = previousSelection
            profiles = previousProfiles
            migratedSeedIDs = previousMigrated
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

    /// Ensures a farbling-enabled profile has a fresh non-retired 256-bit seed
    /// materialized and persisted to disk before engine launch.
    @discardableResult
    func ensureMaterializedSeedPersisted(for id: String) -> Bool {
        guard loadError == nil,
              let idx = profiles.firstIndex(where: { $0.id.lowercased() == id.lowercased() })
        else { return false }
        let needsPersist = materializeFarblingSeedIfNeeded(at: idx)
            || migratedSeedIDs.contains(id.lowercased())
        guard needsPersist else { return true }
        return persist()
    }

    /// Validates a candidate profile against both structural rules and store constraints
    /// (retired tombstones, reserved template IDs on new profiles, case-insensitive APFS
    /// collisions, and orphaned directory collisions) without mutating the store.
    func validateForUpsert(_ profile: CuriumFingerprintProfile) -> CuriumFingerprintValidationReport {
        let normalized = profile.normalizedForPersistence()
        var report = CuriumFingerprintValidator.validate(normalized)
        let loweredID = normalized.id.lowercased()
        let isNewEntry = !profiles.contains(where: { $0.id == normalized.id })

        if let collision = profiles.first(where: { $0.id.lowercased() == loweredID && $0.id != normalized.id }) {
            report.errors.append("Profile ID \"\(normalized.id)\" conflicts with existing profile \"\(collision.id)\" on case-insensitive APFS.")
        }

        if isNewEntry {
            if retiredProfileIDs.contains(loweredID) {
                report.errors.append("Profile ID \"\(normalized.id)\" was previously deleted and retired. Choose a different ID or create a new profile.")
            }
            let builtInLowered = Set(CuriumFingerprintPresets.reservedBuiltInIDs.map { $0.lowercased() })
            if builtInLowered.contains(loweredID) {
                report.errors.append("Template ID \"\(normalized.id)\" is reserved for new profiles. Create from template or import with a fresh slug.")
            }
            if CuriumFingerprintValidator.isValidProfileID(normalized.id),
               normalized.id != "default",
               diskProfileSlugsLowered().contains(loweredID) {
                report.errors.append("An orphaned storage directory for \"\(normalized.id)\" already exists on disk. Wipe it under Orphaned Storage first or choose a different ID.")
            }
        }
        return report
    }

    /// Creates a new retained profile or updates any existing retained profile (including `"default"`).
    /// Comparisons use case-insensitive matching to prevent APFS directory collisions.
    @discardableResult
    func upsert(_ profile: CuriumFingerprintProfile) -> CuriumFingerprintValidationReport {
        let normalized = profile.normalizedForPersistence()
        var report = validateForUpsert(normalized)
        guard report.isValid else { return report }

        var updated = normalized
        updated.isBuiltIn = false
        let previousProfiles = profiles
        let previousSelection = selectedProfileID

        if let idx = profiles.firstIndex(where: { $0.id == normalized.id }) {
            if updated.createdAt == nil {
                updated.createdAt = profiles[idx].createdAt
            }
            if updated.lastUsedAt == nil {
                updated.lastUsedAt = profiles[idx].lastUsedAt
            }
            updated.revision = max(normalized.revision, profiles[idx].revision + 1)
            profiles[idx] = updated
            // If the user customized Personal's engine fields while on unconfigured `nil`,
            // opt into `"default"` so the engine applies the customized settings on next launch.
            if updated.isPrimaryDefault && !updated.matchesBuild39EngineDefaults && selectedProfileID == nil {
                selectedProfileID = "default"
            }
        } else {
            updated.revision = max(normalized.revision, 1)
            if updated.createdAt == nil {
                updated.createdAt = .now
            }
            profiles.append(updated)
        }
        if !persist() {
            profiles = previousProfiles
            selectedProfileID = previousSelection
            report.errors.append(lastPersistError ?? "Failed to save profile store to disk.")
        }
        return report
    }

    @discardableResult
    func deleteProfile(id: String, allowActiveDeleteForTesting: Bool = false) -> Bool {
        guard loadError == nil else {
            lastPersistError = "Cannot delete profile while \(Self.fileName) is unreadable."
            return false
        }
        let loweredID = id.lowercased()
        guard loweredID != "default" else { return false }
        guard allowActiveDeleteForTesting || !CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(id) else {
            lastPersistError = "Cannot delete the currently active running profile. Switch profiles and relaunch first."
            return false
        }
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return false }

        let previousProfiles = profiles
        let previousSelection = selectedProfileID
        let previousRetired = retiredProfileIDs

        profiles.remove(at: idx)
        retiredProfileIDs.insert(loweredID)
        if selectedProfileID?.lowercased() == loweredID {
            selectedProfileID = nil
        }
        if !persist() {
            profiles = previousProfiles
            selectedProfileID = previousSelection
            retiredProfileIDs = previousRetired
            return false
        }
        return true
    }

    /// Wipes all isolated on-disk storage for a non-default, inactive profile, then removes
    /// it from the store and records its slug in `retiredProfileIDs`.
    @discardableResult
    func deleteProfileAndWipeStorage(
        id: String,
        isActiveInCurrentProcess: Bool? = nil
    ) throws -> Bool {
        guard id.lowercased() != "default" else {
            throw CuriumFingerprintProfileStorage.WipeError.defaultProfileProtected
        }
        let active = isActiveInCurrentProcess ?? CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(id)
        guard !active else {
            throw CuriumFingerprintProfileStorage.WipeError.activeProfileProtected
        }
        try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
            id,
            isActiveInCurrentProcess: active,
            applicationSupportRoot: applicationSupportRoot,
            cachesRoot: cachesRoot,
            curiumSupportRoot: curiumSupportRoot
        )
        return deleteProfile(id: id, allowActiveDeleteForTesting: true)
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
            cachesRoot: cachesRoot ?? self.cachesRoot,
            curiumSupportRoot: self.curiumSupportRoot
        ).map { $0.lowercased() }
        let builtInLowered = Set(CuriumFingerprintPresets.reservedBuiltInIDs.map { $0.lowercased() })
        let occupiedLowered = Set(profiles.map { $0.id.lowercased() })
            .union(retiredProfileIDs)
            .union(builtInLowered)
            .union(diskSlugs)

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
        return mintProfileSlug()
    }

    func duplicateProfile(
        from sourceID: String,
        newID: String? = nil,
        displayName: String
    ) -> CuriumFingerprintProfile? {
        guard loadError == nil else {
            lastPersistError = "Cannot duplicate profile while \(Self.fileName) is unreadable."
            return nil
        }
        guard var copy = profiles.first(where: { $0.id == sourceID }) else { return nil }

        let resolvedNewID: String
        if let newID {
            let trimmedNewID = newID.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredNew = trimmedNewID.lowercased()
            let builtInLowered = Set(CuriumFingerprintPresets.reservedBuiltInIDs.map { $0.lowercased() })
            guard CuriumFingerprintValidator.isValidProfileID(trimmedNewID),
                  loweredNew != "default",
                  !builtInLowered.contains(loweredNew),
                  !retiredProfileIDs.contains(loweredNew),
                  !profiles.contains(where: { $0.id.lowercased() == loweredNew }),
                  !diskProfileSlugsLowered().contains(loweredNew)
            else { return nil }
            resolvedNewID = trimmedNewID
        } else {
            resolvedNewID = mintProfileSlug()
        }

        copy.id = resolvedNewID
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.displayName = trimmedName.isEmpty ? "\(copy.displayName) Copy" : trimmedName
        copy.isBuiltIn = false
        copy.revision = 1
        copy.createdAt = .now
        copy.lastUsedAt = nil
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
    /// Build 40/41 engine wire payload (`schemaVersion` + `profileId`), preserving
    /// its ID when valid and unoccupied.
    func importProfileJSON(_ data: Data) throws -> CuriumFingerprintValidationReport {
        let parsed = try parseImportJSON(data)
        if let schemaError = parsed.schemaError {
            return CuriumFingerprintValidationReport(errors: [schemaError])
        }
        var report = upsert(parsed.profile)
        report.warnings.append(contentsOf: parsed.warnings)
        return report
    }

    /// Imports either a full profile JSON or an engine wire payload under a freshly minted
    /// opaque `p-<8hex>` slug so imports never collide with retired IDs, templates, or
    /// existing profiles.
    func importProfileWithFreshSlug(_ data: Data) throws -> (profile: CuriumFingerprintProfile?, report: CuriumFingerprintValidationReport) {
        let parsed = try parseImportJSON(data)
        if let schemaError = parsed.schemaError {
            return (nil, CuriumFingerprintValidationReport(errors: [schemaError]))
        }
        var candidate = parsed.profile
        candidate.id = mintProfileSlug()
        candidate.isBuiltIn = false
        candidate.revision = 1
        candidate.createdAt = .now
        candidate.lastUsedAt = nil
        if candidate.hasFarblingEnabled {
            let current = candidate.fingerprintSeed
            if current == nil
                || !CuriumFingerprintSchema.isValidSeedHex(current!)
                || CuriumFingerprintSchema.isRetiredStaticSeed(current) {
                candidate.fingerprintSeed = Self.mintFreshSeed(differentFrom: current)
            }
        }
        var report = upsert(candidate)
        report.warnings.append(contentsOf: parsed.warnings)
        let saved = report.isValid ? profiles.first(where: { $0.id == candidate.id }) : nil
        return (saved, report)
    }

    @discardableResult
    private func persist() -> Bool {
        if let loadError {
            lastPersistError = "Blocked saving \(Self.fileName) while existing store is unreadable (\(loadError)). Back up and reset the corrupt store first."
            Self.log.error("fingerprint store persist blocked (fail-closed): \(loadError, privacy: .public)")
            return false
        }
        let state = PersistedState(
            version: PersistedState.currentVersion,
            selectedProfileID: selectedProfileID,
            profiles: profiles,
            retiredProfileIDs: retiredProfileIDs
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
            migratedSeedIDs.removeAll()
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
                cachesRoot: cachesRoot,
                curiumSupportRoot: curiumSupportRoot
            ).map { $0.lowercased() }
        )
    }

    private func occupiedSlugsLowered() -> Set<String> {
        let builtInLowered = Set(CuriumFingerprintPresets.reservedBuiltInIDs.map { $0.lowercased() })
        return Set(profiles.map { $0.id.lowercased() })
            .union(retiredProfileIDs)
            .union(builtInLowered)
            .union(diskProfileSlugsLowered())
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: max(1, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
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

    private static func ensureValidFarblingSeed(_ profile: inout CuriumFingerprintProfile) -> Bool {
        guard profile.hasFarblingEnabled else { return false }
        if let seed = profile.fingerprintSeed,
           CuriumFingerprintSchema.isValidSeedHex(seed),
           !CuriumFingerprintSchema.isRetiredStaticSeed(seed) {
            return false
        }
        profile.fingerprintSeed = CuriumFingerprintSchema.generateRandomSeedHex()
        return true
    }

    /// Migrates a v1 store (7 static built-ins + custom profiles) into v2 retained profiles:
    /// - Retains `"default"` as `"Personal"` (preserving legacy `UserDefaults` palette/siteMode/searchEngine).
    /// - Retains all user-created custom profiles.
    /// - Promotes any of the 6 non-default v1 built-in presets ONLY if currently selected
    ///   or already present on disk (`ChromiumProfiles/<slug>` / `Curium/Profiles/<slug>`).
    /// - Upgrades missing/retired farbling seeds cleanly.
    private static func migrateV1ToV2(
        _ decoded: PersistedState,
        diskSlugsLowered: Set<String>
    ) -> (
        selectedProfileID: String?,
        profiles: [CuriumFingerprintProfile],
        retiredProfileIDs: Set<String>,
        migratedSeedIDs: Set<String>
    ) {
        let now = Date.now
        let defaults = UserDefaults.standard
        let legacyPalette = defaults.string(forKey: "curium.palette").flatMap(CuriumPalette.init(rawValue:)) ?? .violet
        let legacySiteMode = defaults.string(forKey: "curium.siteMode").flatMap(CuriumSiteMode.init(rawValue:)) ?? .adaptive
        let legacySearchEngine = defaults.string(forKey: "curium.searchEngine").flatMap(CuriumSearchEngine.init(rawValue:)) ?? .google

        let selectedLowered = decoded.selectedProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let builtInByLowered = Dictionary(
            uniqueKeysWithValues: CuriumFingerprintPresets.allBuiltIns.map { ($0.id.lowercased(), $0) }
        )
        let reservedBuiltInLowered = Set(CuriumFingerprintPresets.reservedBuiltInIDs.map { $0.lowercased() })

        var migratedSeeds: Set<String> = []
        var result: [CuriumFingerprintProfile] = []
        var seenLowered: Set<String> = ["default"]

        // 1. Primary default ("Personal") profile.
        var defaultProfile: CuriumFingerprintProfile
        if let storedDefault = decoded.profiles.first(where: { $0.id.lowercased() == "default" }) {
            defaultProfile = storedDefault.normalizedForPersistence()
            defaultProfile.id = "default"
            defaultProfile.isBuiltIn = false
            if defaultProfile.displayName.isEmpty
                || defaultProfile.displayName == CuriumFingerprintPresets.defaultAuthenticChrome.displayName
                || defaultProfile.displayName == CuriumFingerprintPresets.build39NativeBaseline.displayName {
                defaultProfile.displayName = "Personal"
            }
            if defaultProfile.symbolName == nil { defaultProfile.symbolName = "person.crop.circle" }
            if defaultProfile.palette == nil { defaultProfile.palette = legacyPalette }
            if defaultProfile.siteMode == nil { defaultProfile.siteMode = legacySiteMode }
            if defaultProfile.searchEngine == nil { defaultProfile.searchEngine = legacySearchEngine }
            if defaultProfile.templateID == nil { defaultProfile.templateID = "default" }
            if defaultProfile.createdAt == nil { defaultProfile.createdAt = now }
        } else {
            defaultProfile = makeDefaultPersonalProfile(preserveLegacyDefaults: true, now: now)
        }
        if ensureValidFarblingSeed(&defaultProfile) {
            migratedSeeds.insert("default")
        }
        result.append(defaultProfile)

        // 2. Stored custom profiles + conditionally promoted v1 built-ins (including retired legacy slugs).
        for raw in decoded.profiles {
            let key = raw.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seenLowered.contains(key) else { continue }

            if reservedBuiltInLowered.contains(key) {
                let shouldPromote = (selectedLowered == key) || diskSlugsLowered.contains(key)
                guard shouldPromote else { continue }
                seenLowered.insert(key)
                var promoted = raw.normalizedForPersistence()
                let canonicalID = builtInByLowered[key]?.id ?? key
                promoted.id = canonicalID
                promoted.isBuiltIn = false
                promoted.templateID = promoted.templateID ?? canonicalID
                let template = CuriumProfileTemplate.template(for: canonicalID)
                if promoted.symbolName == nil {
                    promoted.symbolName = template?.defaultSymbolName ?? "person.crop.circle"
                }
                if promoted.palette == nil {
                    promoted.palette = template?.defaultPalette ?? .violet
                }
                if promoted.siteMode == nil { promoted.siteMode = .adaptive }
                if promoted.searchEngine == nil { promoted.searchEngine = .google }
                if promoted.createdAt == nil { promoted.createdAt = now }
                if ensureValidFarblingSeed(&promoted) {
                    migratedSeeds.insert(key)
                }
                result.append(promoted)
            } else {
                seenLowered.insert(key)
                var custom = raw.normalizedForPersistence()
                custom.isBuiltIn = false
                if custom.symbolName == nil { custom.symbolName = "person.crop.circle" }
                if custom.palette == nil { custom.palette = .violet }
                if custom.siteMode == nil { custom.siteMode = .adaptive }
                if custom.searchEngine == nil { custom.searchEngine = .google }
                if custom.createdAt == nil { custom.createdAt = now }
                if ensureValidFarblingSeed(&custom) {
                    migratedSeeds.insert(key)
                }
                result.append(custom)
            }
        }

        // 3. If v1 selected a built-in preset that wasn't serialized in `decoded.profiles`, promote it.
        if let selectedLowered,
           !seenLowered.contains(selectedLowered),
           let builtInPreset = builtInByLowered[selectedLowered] {
            seenLowered.insert(selectedLowered)
            var promoted = builtInPreset
            promoted.isBuiltIn = false
            promoted.templateID = builtInPreset.id
            let template = CuriumProfileTemplate.template(for: builtInPreset.id)
            promoted.symbolName = template?.defaultSymbolName ?? "person.crop.circle"
            promoted.palette = template?.defaultPalette ?? .violet
            promoted.siteMode = .adaptive
            promoted.searchEngine = .google
            promoted.createdAt = now
            if ensureValidFarblingSeed(&promoted) {
                migratedSeeds.insert(selectedLowered)
            }
            result.append(promoted)
        }

        let retired = Set(decoded.retiredProfileIDs.map { $0.lowercased() })
        return (decoded.selectedProfileID, result, retired, migratedSeeds)
    }

    private static func normalizeV2State(
        _ decoded: PersistedState
    ) -> (
        selectedProfileID: String?,
        profiles: [CuriumFingerprintProfile],
        retiredProfileIDs: Set<String>,
        migratedSeedIDs: Set<String>,
        needsPersist: Bool
    ) {
        var needsPersist = false
        var migratedSeeds: Set<String> = []
        var result: [CuriumFingerprintProfile] = []
        var seenLowered: Set<String> = ["default"]

        if let storedDefault = decoded.profiles.first(where: { $0.id.lowercased() == "default" }) {
            var defaultProfile = storedDefault.normalizedForPersistence()
            if defaultProfile.id != "default" || defaultProfile.isBuiltIn {
                defaultProfile.id = "default"
                defaultProfile.isBuiltIn = false
                needsPersist = true
            }
            if ensureValidFarblingSeed(&defaultProfile) {
                migratedSeeds.insert("default")
                needsPersist = true
            }
            result.append(defaultProfile)
        } else {
            result.append(makeDefaultPersonalProfile())
            needsPersist = true
        }

        for raw in decoded.profiles {
            let key = raw.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seenLowered.contains(key) else { continue }
            seenLowered.insert(key)
            var item = raw.normalizedForPersistence()
            if item.isBuiltIn {
                item.isBuiltIn = false
                needsPersist = true
            }
            if ensureValidFarblingSeed(&item) {
                migratedSeeds.insert(key)
                needsPersist = true
            }
            result.append(item)
        }

        let retired = Set(decoded.retiredProfileIDs.map { $0.lowercased() })
        return (decoded.selectedProfileID, result, retired, migratedSeeds, needsPersist)
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

    private static let outcomeLock = OSAllocatedUnfairLock<LaunchOutcome>(initialState: .defaultBuild39)

    static var lastOutcome: LaunchOutcome {
        outcomeLock.withLock { $0 }
    }

    static var activeProfileID: String {
        switch lastOutcome {
        case .configured(let profileID, _, _):
            return profileID
        case .defaultBuild39, .rejected:
            return "default"
        }
    }

    private static func setLastOutcome(_ outcome: LaunchOutcome) {
        outcomeLock.withLock { $0 = outcome }
    }

    static func engineCapabilities() -> CuriumEngineFingerprintCapabilities {
        CuriumEngineFingerprintCapabilities(dictionary: CuriumEngineFingerprintCapabilitiesDict())
    }

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
            setLastOutcome(outcome)
            return outcome
        }

        guard let selectedID = store.selectedProfileID else {
            _ = CuriumConfigureLaunchFingerprint(nil, nil)
            _ = store.markProfileUsed("default")
            setLastOutcome(.defaultBuild39)
            return .defaultBuild39
        }

        guard let profile = store.profile(id: selectedID) else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "Selected profile \"\(selectedID)\" was not found in the profile store."
            )
            setLastOutcome(outcome)
            return outcome
        }

        if profile.isPrimaryDefault && profile.matchesBuild39EngineDefaults {
            _ = CuriumConfigureLaunchFingerprint(nil, nil)
            _ = store.markProfileUsed("default")
            setLastOutcome(.defaultBuild39)
            return .defaultBuild39
        }

        _ = store.ensureMaterializedSeedPersisted(for: profile.id)
        guard let materialized = store.profile(id: profile.id) else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "Selected profile \"\(selectedID)\" was not found in the profile store."
            )
            setLastOutcome(outcome)
            return outcome
        }

        let validation = CuriumFingerprintValidator.validate(materialized)
        guard validation.isValid else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: validation.errors.joined(separator: " ")
            )
            setLastOutcome(outcome)
            return outcome
        }

        let caps = engineCapabilities()
        guard caps.supportsLaunchFingerprintConfig else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "The embedded Blink engine does not support launch fingerprint profiles (requires Build 40+)."
            )
            setLastOutcome(outcome)
            return outcome
        }

        let negotiatedVersion = min(
            CuriumFingerprintSchema.version,
            max(CuriumFingerprintSchema.minSupportedVersion, caps.contractVersion)
        )
        let jsonData: Data
        do {
            jsonData = try materialized.makeEngineLaunchJSON(schemaVersion: negotiatedVersion)
        } catch {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "Failed to encode profile JSON: \(error.localizedDescription)"
            )
            setLastOutcome(outcome)
            return outcome
        }

        var engineError: NSError?
        guard CuriumConfigureLaunchFingerprint(jsonData, &engineError) else {
            let reason = engineError?.localizedDescription
                ?? "Blink engine rejected launch fingerprint configuration."
            let outcome = LaunchOutcome.rejected(profileID: selectedID, reason: reason)
            setLastOutcome(outcome)
            return outcome
        }

        _ = store.markProfileUsed(materialized.id)
        let outcome = LaunchOutcome.configured(
            profileID: materialized.id,
            revision: materialized.revision,
            nativeHardware: materialized.usesNativeHardwareAndGPU
        )
        setLastOutcome(outcome)
        return outcome
    }
}
