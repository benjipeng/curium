import Darwin
import Foundation

/// Safe, symlink-hardened storage inspection and cleanup for Chromium profile
/// directories managed by Build 40 (`paths.mm`).
///
/// Mirrors `ios/chrome/browser/shared/model/paths/paths.mm`:
/// - `"default"` (and `nil` / Build 39) -> `<Application Support>/Chromium` and `<Caches>/Chromium`
/// - Isolated `<slug>` -> `<Application Support>/ChromiumProfiles/<slug>` and `<Caches>/ChromiumProfiles/<slug>`
///   with advisory lock file `.curium_profile.lock`.
enum CuriumFingerprintProfileStorage {
    struct Locations: Equatable, Sendable {
        let profileID: String
        let supportDirectory: URL
        let cacheDirectory: URL
        let lockFile: URL?
        let isDefault: Bool
    }

    struct UsageSnapshot: Equatable, Sendable {
        let supportBytes: Int64
        let cacheBytes: Int64
        let exists: Bool

        var totalBytes: Int64 { supportBytes + cacheBytes }
    }

    enum WipeError: LocalizedError, Equatable {
        case invalidProfileID
        case activeProfileProtected
        case defaultProfileProtected
        case profileLockedByAnotherInstance
        case unsafeSymlinkDetected
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfileID:
                return "Invalid profile identifier."
            case .activeProfileProtected:
                return "Cannot wipe the currently active running profile. Switch profiles and relaunch first."
            case .defaultProfileProtected:
                return "The default Chromium profile cannot be wiped from Profile Studio. Use History → Clear instead."
            case .profileLockedByAnotherInstance:
                return "This profile is currently locked by another active Curium session."
            case .unsafeSymlinkDetected:
                return "Refused to access profile storage because an unexpected symlink was encountered."
            case .ioFailure(let detail):
                return "Failed to clear profile storage: \(detail)"
            }
        }
    }

    /// Resolves the exact `<Application Support>` and `<Caches>` roots used by
    /// Chromium's `base::DIR_APP_DATA` and `base::DIR_CACHE` without creating directories.
    static func locations(
        for profileID: String,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) -> Locations? {
        guard CuriumFingerprintValidator.isValidProfileID(profileID) else { return nil }
        let fm = FileManager.default
        let supportBase = applicationSupportRoot ?? (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
        let cachesBase = cachesRoot ?? (try? fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
        guard let supportBase, let cachesBase else { return nil }

        if profileID == "default" {
            return Locations(
                profileID: profileID,
                supportDirectory: supportBase.appending(path: "Chromium", directoryHint: .isDirectory),
                cacheDirectory: cachesBase.appending(path: "Chromium", directoryHint: .isDirectory),
                lockFile: nil,
                isDefault: true
            )
        }

        let supportDir = supportBase
            .appending(path: "ChromiumProfiles", directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)
        let cacheDir = cachesBase
            .appending(path: "ChromiumProfiles", directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)
        let lockFile = supportDir.appending(path: ".curium_profile.lock", directoryHint: .notDirectory)

        return Locations(
            profileID: profileID,
            supportDirectory: supportDir,
            cacheDirectory: cacheDir,
            lockFile: lockFile,
            isDefault: false
        )
    }

    /// Scans `<Application Support>/ChromiumProfiles/` and `<Caches>/ChromiumProfiles/`
    /// with symlink-safe `lstat` checks and returns all valid non-default directory slugs
    /// currently present on disk (case-insensitively deduplicated, sorted).
    static func existingIsolatedProfileSlugs(
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) -> [String] {
        let fm = FileManager.default
        let supportBase = applicationSupportRoot ?? (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
        let cachesBase = cachesRoot ?? (try? fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))

        var discoveredByLowered: [String: String] = [:]
        for base in [supportBase, cachesBase].compactMap({ $0 }) {
            let profilesDir = base.appending(path: "ChromiumProfiles", directoryHint: .isDirectory)
            guard inspectPathWithLstat(profilesDir.path) == .directory else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: profilesDir.path) else { continue }
            for entry in entries {
                guard !entry.hasPrefix("."),
                      entry.lowercased() != "default",
                      CuriumFingerprintValidator.isValidProfileID(entry)
                else { continue }
                let entryURL = profilesDir.appending(path: entry, directoryHint: .isDirectory)
                guard inspectPathWithLstat(entryURL.path) == .directory else { continue }
                let key = entry.lowercased()
                if discoveredByLowered[key] == nil {
                    discoveredByLowered[key] = entry
                }
            }
        }
        return discoveredByLowered.values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Discovers isolated `ChromiumProfiles/<slug>` directories on disk under
    /// Application Support and Caches that are not present in `knownIDs`
    /// (compared case-insensitively for APFS safety), skipping symlinks via `lstat`.
    static func discoverOrphanedProfiles(
        knownIDs: Set<String>,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) -> [String] {
        let knownLowered = Set(knownIDs.map { $0.lowercased() })
        return existingIsolatedProfileSlugs(
            applicationSupportRoot: applicationSupportRoot,
            cachesRoot: cachesRoot
        ).filter { slug in
            !knownLowered.contains(slug.lowercased())
        }
    }

    /// Returns true if the given profile ID matches the currently open engine session
    /// or the outcome chosen for this process launch.
    @MainActor
    static func isProfileActiveInCurrentProcess(_ profileID: String) -> Bool {
        let needle = profileID.lowercased()
        if let status = CuriumFingerprintBootstrap.activeEngineStatus() {
            let liveState = status.state
            let isLive = status.profileDirectoryOpened
                || liveState == "configured"
                || liveState == "default_0105"
            if isLive && status.appliedProfileId.lowercased() == needle {
                return true
            }
        }
        switch CuriumFingerprintBootstrap.lastOutcome {
        case .defaultBuild39:
            return needle == "default"
        case .configured(let activeID, _, _):
            return activeID.lowercased() == needle
        case .rejected:
            return false
        }
    }

    /// Computes total on-disk usage for a profile off the main thread, ignoring symlinks.
    static func measureUsage(
        for profileID: String,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) -> UsageSnapshot {
        guard let loc = locations(
            for: profileID,
            applicationSupportRoot: applicationSupportRoot,
            cachesRoot: cachesRoot
        ) else {
            return UsageSnapshot(supportBytes: 0, cacheBytes: 0, exists: false)
        }
        let support = measureDirectorySafely(loc.supportDirectory, verifyParentChainDepth: loc.isDefault ? 1 : 2)
        let cache = measureDirectorySafely(loc.cacheDirectory, verifyParentChainDepth: loc.isDefault ? 1 : 2)
        return UsageSnapshot(
            supportBytes: support.bytes,
            cacheBytes: cache.bytes,
            exists: support.exists || cache.exists
        )
    }

    /// Safely deletes an inactive, unlocked isolated profile's `Application Support`
    /// and `Caches` directories. Refuses `"default"`, active profiles, symlink escapes,
    /// and profiles locked via `flock(LOCK_EX | LOCK_NB)`.
    static func wipeIsolatedProfile(
        _ profileID: String,
        isActiveInCurrentProcess: Bool,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) throws {
        guard CuriumFingerprintValidator.isValidProfileID(profileID) else {
            throw WipeError.invalidProfileID
        }
        if profileID == "default" {
            throw WipeError.defaultProfileProtected
        }
        if isActiveInCurrentProcess {
            throw WipeError.activeProfileProtected
        }
        guard let loc = locations(
            for: profileID,
            applicationSupportRoot: applicationSupportRoot,
            cachesRoot: cachesRoot
        ) else {
            throw WipeError.invalidProfileID
        }

        // Verify parent chain (`ChromiumProfiles` and `<slug>`) contains no symlinks.
        let supportParent = loc.supportDirectory.deletingLastPathComponent()
        let cacheParent = loc.cacheDirectory.deletingLastPathComponent()
        for dir in [supportParent, loc.supportDirectory, cacheParent, loc.cacheDirectory] {
            let state = inspectPathWithLstat(dir.path)
            if state == .symlink || state == .otherNonDirectory {
                throw WipeError.unsafeSymlinkDetected
            }
        }

        // Probe advisory flock on `.curium_profile.lock` if present so we never
        // delete a profile held open by another running process.
        if let lockFile = loc.lockFile {
            let lockState = inspectPathWithLstat(lockFile.path)
            if lockState == .symlink {
                throw WipeError.unsafeSymlinkDetected
            }
            if lockState == .regularFile {
                let fd = open(lockFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 {
                    if errno == ELOOP {
                        throw WipeError.unsafeSymlinkDetected
                    }
                    throw WipeError.ioFailure(String(cString: strerror(errno)))
                }
                defer { close(fd) }
                if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                    if errno == EWOULDBLOCK || errno == EAGAIN {
                        throw WipeError.profileLockedByAnotherInstance
                    }
                    throw WipeError.ioFailure(String(cString: strerror(errno)))
                }
                _ = flock(fd, LOCK_UN)
            }
        }

        let fm = FileManager.default
        for dir in [loc.supportDirectory, loc.cacheDirectory] {
            let state = inspectPathWithLstat(dir.path)
            guard state == .directory else { continue }
            do {
                try fm.removeItem(at: dir)
            } catch {
                throw WipeError.ioFailure(error.localizedDescription)
            }
        }
    }

    // MARK: - Private

    private enum PathKind {
        case missing
        case directory
        case regularFile
        case symlink
        case otherNonDirectory
    }

    private static func inspectPathWithLstat(_ path: String) -> PathKind {
        var st = stat()
        if lstat(path, &st) != 0 {
            return errno == ENOENT ? .missing : .otherNonDirectory
        }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK { return .symlink }
        if mode == S_IFDIR { return .directory }
        if mode == S_IFREG { return .regularFile }
        return .otherNonDirectory
    }

    private static func measureDirectorySafely(
        _ directory: URL,
        verifyParentChainDepth: Int
    ) -> (bytes: Int64, exists: Bool) {
        var current = directory
        for _ in 0..<verifyParentChainDepth {
            let kind = inspectPathWithLstat(current.path)
            if kind == .missing {
                return (0, false)
            }
            if kind != .directory {
                return (0, false)
            }
            current = current.deletingLastPathComponent()
        }

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        let keySet = Set(keys)
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return (0, true)
        }

        var total: Int64 = 0
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: keySet) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return (total, true)
    }
}
