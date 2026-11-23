import Darwin
import Foundation
import OSLog
import SQLite3

/// Where the library database lives, and the one-time move into that place.
///
/// The store must outlive every way a guest app is replaced: an update, a container
/// reset, a re-import, or a second LiveContainer install. Candidates, most durable first:
///
/// 1. LiveContainer's App Group, shared by every LiveContainer install on the device.
/// 2. LiveContainer's host container, when the App Group is not available.
/// 3. The app's own Application Support, when Curium runs standalone.
///
/// The chosen file is never replaced. When it does not exist yet, the newest library
/// found at an older location is copied in; the original stays where it was.
enum CuriumLibraryLocation {
    static let fileName = "curium.sqlite"

    struct Resolution {
        let database: URL
        /// Older locations to adopt from, newest layout first.
        let legacy: [URL]
    }

    /// Durable Curium support root directory (`<AppGroup>/Library/Application Support/Curium`,
    /// `<HostContainer>/Library/Application Support/Curium`, or `<Standalone AppSupport>/Curium`).
    static func supportRootDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedAppGroupURL: URL? = sharedGroupContainer()
    ) throws -> URL {
        let files = FileManager.default
        let standalone = try files.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        guard let hostPath = environment["LC_HOME_PATH"], !hostPath.isEmpty else {
            return standalone.appending(path: "Curium", directoryHint: .isDirectory)
        }
        if let group = sharedAppGroupURL {
            return group.standardizedFileURL
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: "Curium", directoryHint: .isDirectory)
        }
        let hostRoot = resolveLiveContainerHostRoot(from: hostPath)
        return hostRoot
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: "Curium", directoryHint: .isDirectory)
    }

    /// Profile-scoped Curium support directory (`<CuriumSupportRoot>/` for `"default"`,
    /// `<CuriumSupportRoot>/Profiles/<slug>/` for isolated profiles).
    static func profileSupportDirectory(
        for profileID: String,
        baseSupportRoot: URL? = nil
    ) throws -> URL {
        guard CuriumFingerprintValidator.isValidProfileID(profileID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = try baseSupportRoot ?? supportRootDirectory()
        if profileID == "default" {
            return root
        }
        return root
            .appending(path: "Profiles", directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)
    }

    static func resolve(
        profileID: String = "default",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedAppGroupURL: URL? = sharedGroupContainer()
    ) throws -> Resolution {
        guard CuriumFingerprintValidator.isValidProfileID(profileID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if profileID != "default" {
            let root = try supportRootDirectory(
                environment: environment,
                sharedAppGroupURL: sharedAppGroupURL
            )
            let profileDir = try profileSupportDirectory(for: profileID, baseSupportRoot: root)
            let dbURL = profileDir.appending(path: fileName, directoryHint: .notDirectory)
            return Resolution(database: dbURL, legacy: [])
        }

        let files = FileManager.default
        let standalone = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let ownLibrary = Self.library(in: standalone)

        guard let hostPath = environment["LC_HOME_PATH"], !hostPath.isEmpty else {
            return Resolution(database: ownLibrary, legacy: [])
        }
        let guestHome = URL(fileURLWithPath: hostPath, isDirectory: true).standardizedFileURL
        let hostRoot = resolveLiveContainerHostRoot(from: hostPath)
        let hostLibrary = Self.library(in: hostRoot.appending(path: "Library/Application Support", directoryHint: .isDirectory))
        let guestLibrary = Self.library(in: guestHome.appending(path: "Library/Application Support", directoryHint: .isDirectory))

        if let group = sharedAppGroupURL {
            let groupLibrary = Self.library(
                in: group.standardizedFileURL.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            )
            let legacy = deduplicatedLegacy([hostLibrary, guestLibrary, ownLibrary], excluding: groupLibrary)
            return Resolution(database: groupLibrary, legacy: legacy)
        }
        log.notice("library: LiveContainer App Group unavailable; using the host container")
        let legacy = deduplicatedLegacy([guestLibrary, ownLibrary], excluding: hostLibrary)
        return Resolution(database: hostLibrary, legacy: legacy)
    }

    /// Copies the newest legacy library into `resolution.database` if it does not exist.
    /// Safe when two LiveContainer instances launch at once: the copy is staged
    /// privately and installed with an exclusive rename, so the first one wins.
    /// Returns `false` if a non-empty legacy library exists and adoption failed; the
    /// caller must fail closed instead of creating an empty target DB that would block retries.
    @discardableResult
    static func adoptLegacyIfNeeded(_ resolution: Resolution) -> Bool {
        let files = FileManager.default
        let target = resolution.database
        guard !files.fileExists(atPath: target.path) else { return true }

        let source = resolution.legacy
            .filter { $0 != target && nonEmpty($0) }
            .max { modified($0) < modified($1) }
        guard let source else { return true }

        do {
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let scratch = target.deletingLastPathComponent()
                .appending(path: ".\(fileName).\(UUID().uuidString).adopt")
            defer { try? files.removeItem(at: scratch) }
            try snapshot(source, into: scratch)
            if renamex_np(scratch.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { return true } // Another instance adopted first.
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            log.notice("library: adopted \(source.path, privacy: .public) into \(target.path, privacy: .public)")
            return true
        } catch {
            // Keep `target` absent so the next launch retries adoption cleanly.
            log.error("library: could not adopt \(source.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Private

    private static func resolveLiveContainerHostRoot(from hostPath: String) -> URL {
        if let hostRoot = CuriumDownloadStorage.resolveLiveContainerHostRoot(fromCandidatePaths: [hostPath]) {
            return hostRoot.standardizedFileURL
        }
        return URL(fileURLWithPath: hostPath, isDirectory: true).standardizedFileURL
    }

    private static func deduplicatedLegacy(_ candidates: [URL], excluding target: URL) -> [URL] {
        let excludedPath = target.standardizedFileURL.path
        var seen: Set<String> = [excludedPath]
        var result: [URL] = []
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if seen.insert(path).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private static func library(in support: URL) -> URL {
        support.appending(path: "Curium/\(fileName)", directoryHint: .notDirectory)
    }

    /// The real App Group container. LiveContainer redirects every other group ID into
    /// the guest's own container, so only its own `appGroupID` reaches shared storage.
    static func sharedGroupContainer() -> URL? {
        guard let cls = NSClassFromString("LCSharedUtils") as AnyObject?,
              cls.responds(to: NSSelectorFromString("appGroupID")),
              let id = cls.perform(NSSelectorFromString("appGroupID"))?.takeUnretainedValue() as? String,
              !id.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    private static func nonEmpty(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    private static func modified(_ url: URL) -> Date {
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let dates = [url, wal].compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return dates.max() ?? .distantPast
    }

    /// A consistent copy that includes committed WAL frames.
    private static func snapshot(_ source: URL, into destination: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close_v2(handle) }
        var suspendFlag: UInt8 = 1
        for suffix in ["", "-wal", "-shm"] {
            _ = setxattr(source.path + suffix, "com.apple.runningboard.can-suspend-locked", &suspendFlag, 1, 0, 0)
        }
        sqlite3_busy_timeout(handle, 2_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "VACUUM INTO ?", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, destination.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "library")
}
