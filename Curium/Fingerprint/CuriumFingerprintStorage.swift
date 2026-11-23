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
        let curiumProfileDirectory: URL?
        let lockFile: URL?
        let sharedLockFile: URL?
        let isDefault: Bool
    }

    struct UsageSnapshot: Equatable, Sendable {
        let supportBytes: Int64
        let cacheBytes: Int64
        let exists: Bool

        var totalBytes: Int64 { supportBytes + cacheBytes }
    }

    enum SharedLockError: LocalizedError, Equatable {
        case invalidProfileID
        case unavailableSupportRoot
        case unsafeSymlinkDetected
        case profileLockedByAnotherInstance
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfileID:
                return "Invalid profile identifier."
            case .unavailableSupportRoot:
                return "Shared profile support directory is unavailable."
            case .unsafeSymlinkDetected:
                return "Refused to lock profile storage because an unexpected symlink or non-directory was encountered."
            case .profileLockedByAnotherInstance:
                return "This profile is already open in another active Curium session."
            case .ioFailure(let detail):
                return "Unable to lock shared profile storage: \(detail)"
            }
        }
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

    /// Resolves the companion advisory lock path inside `<CuriumSupportRoot>`
    /// (`<CuriumSupportRoot>/.curium_default.lock` for `"default"` or
    /// `<CuriumSupportRoot>/Profiles/<slug>/.curium_profile.lock` for isolated profiles).
    static func sharedLockFileURL(
        for profileID: String,
        curiumSupportRoot: URL? = nil,
        applicationSupportRoot: URL? = nil
    ) -> URL? {
        guard CuriumFingerprintValidator.isValidProfileID(profileID),
              let resolvedCuriumRoot = resolveCuriumSupportRoot(
                  curiumSupportRoot: curiumSupportRoot,
                  applicationSupportRoot: applicationSupportRoot
              )
        else { return nil }
        if profileID == "default" {
            return resolvedCuriumRoot.appending(path: ".curium_default.lock", directoryHint: .notDirectory)
        }
        return resolvedCuriumRoot
            .appending(path: "Profiles", directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)
            .appending(path: ".curium_profile.lock", directoryHint: .notDirectory)
    }

    /// Acquires a non-blocking exclusive advisory `flock` on the companion shared-support
    /// lock file with `com.apple.runningboard.can-suspend-locked` set, mirroring Build 40
    /// `paths.mm` so LiveContainer 1 and LiveContainer 2 cannot concurrently run or wipe
    /// the same shared profile support tree (`curium.sqlite` / `session.json`).
    static func acquireSharedProfileLock(
        for profileID: String,
        curiumSupportRoot: URL? = nil,
        applicationSupportRoot: URL? = nil
    ) throws -> Int32 {
        guard CuriumFingerprintValidator.isValidProfileID(profileID) else {
            throw SharedLockError.invalidProfileID
        }
        guard let resolvedCuriumRoot = resolveCuriumSupportRoot(
            curiumSupportRoot: curiumSupportRoot,
            applicationSupportRoot: applicationSupportRoot
        ) else {
            throw SharedLockError.unavailableSupportRoot
        }

        let lockFile: URL
        if profileID == "default" {
            try ensureSafeDirectory(resolvedCuriumRoot)
            lockFile = resolvedCuriumRoot.appending(path: ".curium_default.lock", directoryHint: .notDirectory)
        } else {
            let profilesDir = resolvedCuriumRoot.appending(path: "Profiles", directoryHint: .isDirectory)
            let profileDir = profilesDir.appending(path: profileID, directoryHint: .isDirectory)
            try ensureSafeDirectory(resolvedCuriumRoot)
            try ensureSafeDirectory(profilesDir)
            try ensureSafeDirectory(profileDir)
            lockFile = profileDir.appending(path: ".curium_profile.lock", directoryHint: .notDirectory)
        }

        let lockKind = inspectPathWithLstat(lockFile.path)
        if lockKind == .symlink || lockKind == .directory || lockKind == .otherNonDirectory {
            throw SharedLockError.unsafeSymlinkDetected
        }

        let fd = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 {
            if errno == ELOOP {
                throw SharedLockError.unsafeSymlinkDetected
            }
            throw SharedLockError.ioFailure(String(cString: strerror(errno)))
        }

        var canSuspend: UInt8 = 1
        _ = fsetxattr(fd, "com.apple.runningboard.can-suspend-locked", &canSuspend, 1, 0, 0)

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            close(fd)
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                throw SharedLockError.profileLockedByAnotherInstance
            }
            throw SharedLockError.ioFailure(String(cString: strerror(lockErrno)))
        }
        return fd
    }

    /// Resolves the exact `<Application Support>`, `<Caches>`, and durable Curium profile
    /// roots used by Build 42 (`paths.mm`) and Curium's per-profile SQLite/session storage
    /// without creating directories.
    static func locations(
        for profileID: String,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil,
        curiumSupportRoot: URL? = nil
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

        let resolvedCuriumRoot = resolveCuriumSupportRoot(
            curiumSupportRoot: curiumSupportRoot,
            applicationSupportRoot: applicationSupportRoot
        )

        if profileID == "default" {
            let sharedLock = resolvedCuriumRoot?.appending(path: ".curium_default.lock", directoryHint: .notDirectory)
            return Locations(
                profileID: profileID,
                supportDirectory: supportBase.appending(path: "Chromium", directoryHint: .isDirectory),
                cacheDirectory: cachesBase.appending(path: "Chromium", directoryHint: .isDirectory),
                curiumProfileDirectory: nil,
                lockFile: nil,
                sharedLockFile: sharedLock,
                isDefault: true
            )
        }

        let curiumProfileDir = resolvedCuriumRoot?
            .appending(path: "Profiles", directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)

        let supportDir = supportBase
            .appending(path: "ChromiumProfiles", directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)
        let cacheDir = cachesBase
            .appending(path: "ChromiumProfiles", directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)
        let lockFile = supportDir.appending(path: ".curium_profile.lock", directoryHint: .notDirectory)
        let sharedLockFile = curiumProfileDir?.appending(path: ".curium_profile.lock", directoryHint: .notDirectory)

        return Locations(
            profileID: profileID,
            supportDirectory: supportDir,
            cacheDirectory: cacheDir,
            curiumProfileDirectory: curiumProfileDir,
            lockFile: lockFile,
            sharedLockFile: sharedLockFile,
            isDefault: false
        )
    }

    /// Scans `<Application Support>/ChromiumProfiles/`, `<Caches>/ChromiumProfiles/`, and
    /// `<CuriumSupportRoot>/Profiles/` with symlink-safe `lstat` checks and returns all
    /// valid non-default directory slugs currently present on disk (case-insensitively
    /// deduplicated, sorted).
    static func existingIsolatedProfileSlugs(
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil,
        curiumSupportRoot: URL? = nil
    ) -> [String] {
        let fm = FileManager.default
        let supportBase = applicationSupportRoot ?? (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
        let cachesBase = cachesRoot ?? (try? fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
        let resolvedCuriumRoot = resolveCuriumSupportRoot(
            curiumSupportRoot: curiumSupportRoot,
            applicationSupportRoot: applicationSupportRoot
        )

        var containers: [URL] = [supportBase, cachesBase]
            .compactMap { $0?.appending(path: "ChromiumProfiles", directoryHint: .isDirectory) }
        if let resolvedCuriumRoot {
            containers.append(resolvedCuriumRoot.appending(path: "Profiles", directoryHint: .isDirectory))
        }

        var discoveredByLowered: [String: String] = [:]
        for profilesDir in containers {
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

    /// Discovers isolated `ChromiumProfiles/<slug>` and `Curium/Profiles/<slug>` directories
    /// on disk that are not present in `knownIDs` (compared case-insensitively for APFS safety),
    /// skipping symlinks via `lstat`.
    static func discoverOrphanedProfiles(
        knownIDs: Set<String>,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil,
        curiumSupportRoot: URL? = nil
    ) -> [String] {
        let knownLowered = Set(knownIDs.map { $0.lowercased() })
        return existingIsolatedProfileSlugs(
            applicationSupportRoot: applicationSupportRoot,
            cachesRoot: cachesRoot,
            curiumSupportRoot: curiumSupportRoot
        ).filter { slug in
            !knownLowered.contains(slug.lowercased())
        }
    }

    /// Returns true if the given profile ID matches the currently open engine session
    /// or the outcome chosen for this process launch.
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
        cachesRoot: URL? = nil,
        curiumSupportRoot: URL? = nil
    ) -> UsageSnapshot {
        guard let loc = locations(
            for: profileID,
            applicationSupportRoot: applicationSupportRoot,
            cachesRoot: cachesRoot,
            curiumSupportRoot: curiumSupportRoot
        ) else {
            return UsageSnapshot(supportBytes: 0, cacheBytes: 0, exists: false)
        }
        let support = measureDirectorySafely(loc.supportDirectory, verifyParentChainDepth: loc.isDefault ? 1 : 2)
        let cache = measureDirectorySafely(loc.cacheDirectory, verifyParentChainDepth: loc.isDefault ? 1 : 2)
        let curiumProfile = loc.curiumProfileDirectory.map {
            measureDirectorySafely($0, verifyParentChainDepth: 2)
        } ?? (bytes: 0, exists: false)

        let pdfPreview: (bytes: Int64, exists: Bool)
        if !loc.isDefault, let pdfPreviewDir = isolatedPDFPreviewDirectory(for: profileID, cachesRoot: cachesRoot) {
            pdfPreview = measureDirectorySafely(pdfPreviewDir, verifyParentChainDepth: 2)
        } else {
            pdfPreview = (0, false)
        }

        return UsageSnapshot(
            supportBytes: support.bytes + curiumProfile.bytes,
            cacheBytes: cache.bytes + pdfPreview.bytes,
            exists: support.exists || curiumProfile.exists || cache.exists || pdfPreview.exists
        )
    }

    /// Safely deletes an inactive, unlocked isolated profile's `Application Support`,
    /// `Caches`, `Curium/Profiles/<slug>/`, and `Caches/CuriumPDFPreview/<slug>/`
    /// directories. Refuses `"default"`, active profiles, symlink escapes, and profiles
    /// locked via `flock(LOCK_EX | LOCK_NB)`.
    static func wipeIsolatedProfile(
        _ profileID: String,
        isActiveInCurrentProcess: Bool,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil,
        curiumSupportRoot: URL? = nil
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
            cachesRoot: cachesRoot,
            curiumSupportRoot: curiumSupportRoot
        ) else {
            throw WipeError.invalidProfileID
        }

        // Verify parent chains (`ChromiumProfiles`, `Profiles`, `CuriumPDFPreview`, and `<slug>`)
        // contain no symlinks or unexpected non-directory entries.
        let supportParent = loc.supportDirectory.deletingLastPathComponent()
        let cacheParent = loc.cacheDirectory.deletingLastPathComponent()
        var pathsToVerify: [URL] = [supportParent, loc.supportDirectory, cacheParent, loc.cacheDirectory]

        var curiumDeleteTarget: URL?
        if let curiumProfileDir = loc.curiumProfileDirectory {
            let profilesParent = curiumProfileDir.deletingLastPathComponent()
            let curiumRoot = profilesParent.deletingLastPathComponent()
            if profilesParent.lastPathComponent == "Profiles",
               curiumProfileDir.lastPathComponent == profileID {
                pathsToVerify.append(contentsOf: [curiumRoot, profilesParent, curiumProfileDir])
                curiumDeleteTarget = curiumProfileDir
            }
        }

        var pdfPreviewDeleteTarget: URL?
        if let pdfPreviewDir = isolatedPDFPreviewDirectory(for: profileID, cachesRoot: cachesRoot) {
            let previewParent = pdfPreviewDir.deletingLastPathComponent()
            if previewParent.lastPathComponent == CuriumDownloadStorage.previewCacheDirectoryName,
               pdfPreviewDir.lastPathComponent == profileID {
                pathsToVerify.append(contentsOf: [previewParent, pdfPreviewDir])
                pdfPreviewDeleteTarget = pdfPreviewDir
            }
        }

        for dir in pathsToVerify {
            let state = inspectPathWithLstat(dir.path)
            if state == .symlink || state == .otherNonDirectory {
                throw WipeError.unsafeSymlinkDetected
            }
        }

        // Acquire exclusive advisory locks on BOTH `<Application Support>/ChromiumProfiles/<slug>/.curium_profile.lock`
        // AND `<CuriumSupportRoot>/Profiles/<slug>/.curium_profile.lock`, keeping every `LOCK_EX` fd held across
        // all `removeItem` operations so no sibling LiveContainer process can race or open mid-wipe.
        var lockCandidates: [URL] = []
        var seenLockPaths: Set<String> = []
        for candidate in [loc.lockFile, loc.sharedLockFile].compactMap({ $0 }) {
            let standardized = candidate.standardizedFileURL.path
            if seenLockPaths.insert(standardized).inserted {
                lockCandidates.append(candidate)
            }
        }

        var heldLockFDs: [Int32] = []
        defer {
            for fd in heldLockFDs {
                close(fd)
            }
        }

        for lockFile in lockCandidates {
            let lockState = inspectPathWithLstat(lockFile.path)
            if lockState == .symlink || lockState == .directory || lockState == .otherNonDirectory {
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
                if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                    let lockErrno = errno
                    close(fd)
                    if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                        throw WipeError.profileLockedByAnotherInstance
                    }
                    throw WipeError.ioFailure(String(cString: strerror(lockErrno)))
                }
                heldLockFDs.append(fd)
            } else if lockState == .missing {
                let parentDir = lockFile.deletingLastPathComponent()
                if inspectPathWithLstat(parentDir.path) == .directory {
                    let fd = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    if fd < 0 {
                        if errno == ELOOP {
                            throw WipeError.unsafeSymlinkDetected
                        }
                        continue
                    }
                    var canSuspend: UInt8 = 1
                    _ = fsetxattr(fd, "com.apple.runningboard.can-suspend-locked", &canSuspend, 1, 0, 0)
                    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                        let lockErrno = errno
                        close(fd)
                        if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                            throw WipeError.profileLockedByAnotherInstance
                        }
                        throw WipeError.ioFailure(String(cString: strerror(lockErrno)))
                    }
                    heldLockFDs.append(fd)
                }
            }
        }

        let fm = FileManager.default
        let deleteTargets = [
            loc.supportDirectory,
            loc.cacheDirectory,
            curiumDeleteTarget,
            pdfPreviewDeleteTarget,
        ].compactMap { $0 }

        for dir in deleteTargets {
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

    private static func ensureSafeDirectory(_ dir: URL) throws {
        let state = inspectPathWithLstat(dir.path)
        switch state {
        case .symlink, .regularFile, .otherNonDirectory:
            throw SharedLockError.unsafeSymlinkDetected
        case .directory:
            break
        case .missing:
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw SharedLockError.ioFailure(error.localizedDescription)
            }
        }
        guard inspectPathWithLstat(dir.path) == .directory else {
            throw SharedLockError.unsafeSymlinkDetected
        }
        guard access(dir.path, R_OK | W_OK | X_OK) == 0 else {
            throw SharedLockError.ioFailure(String(cString: strerror(errno)))
        }
    }

    private static func resolveCuriumSupportRoot(
        curiumSupportRoot: URL?,
        applicationSupportRoot: URL?
    ) -> URL? {
        if let curiumSupportRoot {
            return curiumSupportRoot
        }
        if let applicationSupportRoot {
            return applicationSupportRoot.appending(path: "Curium", directoryHint: .isDirectory)
        }
        return try? CuriumLibraryLocation.supportRootDirectory()
    }

    private static func isolatedPDFPreviewDirectory(for profileID: String, cachesRoot: URL?) -> URL? {
        let cachesBase = cachesRoot ?? (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
        return cachesBase?
            .appending(path: CuriumDownloadStorage.previewCacheDirectoryName, directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)
    }

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
