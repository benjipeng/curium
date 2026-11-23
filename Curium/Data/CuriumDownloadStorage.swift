import Darwin
import Foundation

/// Persisted file discovered on disk inside Curium's durable Downloads directory.
struct CuriumSavedDownload: Identifiable, Equatable, Sendable {
    let url: URL
    let filename: String
    let byteCount: Int64
    let modifiedAt: Date
    let isPDF: Bool

    var id: URL { url }
}

/// Manages strict separation between ephemeral inline PDF preview cache files
/// (`Caches/CuriumPDFPreview/`), transient Blink download staging
/// (`Caches/CuriumDownloadStaging/`), and durable user downloads visible in Files.app
/// (either a user-selected custom folder or `<HostContainer>/Documents/Curium/Downloads/`
/// / `<SharedAppGroup>/Documents/Curium/Downloads/` under LiveContainer).
enum CuriumDownloadStorage {
    static let previewCacheDirectoryName = "CuriumPDFPreview"
    static let downloadStagingDirectoryName = "CuriumDownloadStaging"

    private static let maxStemUTF8Bytes = 200
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var activePreviewSessionNames: Set<String> = []
    private nonisolated(unsafe) static var activeDownloadStagingSessionNames: Set<String> = []
    private nonisolated(unsafe) static var reservedDownloadPaths: Set<String> = []

    private nonisolated(unsafe) static let cachedSharedDefaults: UserDefaults = {
        if isRunningInLiveContainer(),
           let groupID = liveContainerSharedAppGroupID(),
           liveContainerSharedAppGroupURL() != nil,
           let suite = UserDefaults(suiteName: groupID) {
            return suite
        }
        return .standard
    }()

    // MARK: - LiveContainer Host & App Group Helpers

    /// True when executing as a guest inside LiveContainer (`LC_HOME_PATH` injected).
    nonisolated static func isRunningInLiveContainer(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let path = environment["LC_HOME_PATH"] else { return false }
        return !path.isEmpty
    }

    /// Queries LiveContainer's real host App Group identifier (`[LCSharedUtils appGroupID]`),
    /// shared identically across LiveContainer 1, LiveContainer 2, and LiveContainer 3+.
    nonisolated static func liveContainerSharedAppGroupID() -> String? {
        guard let cls = NSClassFromString("LCSharedUtils") as AnyObject? else { return nil }
        let selector = NSSelectorFromString("appGroupID")
        guard cls.responds(to: selector),
              let groupID = cls.perform(selector)?.takeUnretainedValue() as? String,
              !groupID.isEmpty else {
            return nil
        }
        return groupID
    }

    /// Resolves the genuine kernel App Group container URL shared across LiveContainer instances.
    nonisolated static func liveContainerSharedAppGroupURL() -> URL? {
        guard let groupID = liveContainerSharedAppGroupID() else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// Shared `UserDefaults` backed by LiveContainer's kernel App Group when available so
    /// LiveContainer 1, 2, and 3+ share folder records seamlessly; falls back to `.standard`.
    nonisolated static var sharedDefaults: UserDefaults {
        cachedSharedDefaults
    }

    /// Walks three parent levels above a LiveContainer guest home path (`Application` -> `Data`
    /// -> `Documents` or `LiveContainer`), returning the parent host or shared container root.
    nonisolated static func resolveLiveContainerHostRoot(
        fromCandidatePaths candidatePaths: [String] = defaultLiveContainerCandidatePaths()
    ) -> URL? {
        for rawPath in candidatePaths where !rawPath.isEmpty {
            let guestHome = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            let appDir = guestHome.deletingLastPathComponent()
            let dataDir = appDir.deletingLastPathComponent()
            let parentDir = dataDir.deletingLastPathComponent()
            if appDir.lastPathComponent == "Application",
               dataDir.lastPathComponent == "Data",
               parentDir.lastPathComponent == "Documents" || parentDir.lastPathComponent == "LiveContainer" {
                return parentDir.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// True when the guest home resides under a Private LiveContainer host's `Documents` tree
    /// (`<HostContainer>/Documents/Data/Application/<GuestUUID>`), where `<HostContainer>/Documents/`
    /// is surfaced directly in iOS Files.app.
    nonisolated static func isPrivateHostDocumentsLayout(
        fromCandidatePaths candidatePaths: [String] = defaultLiveContainerCandidatePaths()
    ) -> Bool {
        for rawPath in candidatePaths where !rawPath.isEmpty {
            let guestHome = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            let appDir = guestHome.deletingLastPathComponent()
            let dataDir = appDir.deletingLastPathComponent()
            let parentDir = dataDir.deletingLastPathComponent()
            if appDir.lastPathComponent == "Application",
               dataDir.lastPathComponent == "Data",
               parentDir.lastPathComponent == "Documents" {
                return true
            }
        }
        return false
    }

    // MARK: - Filename Sanitization & Type Detection

    nonisolated static func sanitizedFilename(_ raw: String?, fallback: String = "Download") -> String {
        // Strip NUL and control characters before extracting the path component.
        let filteredScalars = (raw ?? "").unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let cleaned = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = (cleaned as NSString).lastPathComponent
        // Strip leading dots and whitespace together so `". .pdf"` can never remain hidden.
        while true {
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix(".") {
                candidate.removeFirst()
            } else {
                break
            }
        }
        if candidate.isEmpty || candidate == "/" {
            return fallback
        }
        return clampFilenameLength(candidate, fallback: fallback)
    }

    nonisolated static func isPDF(mimeType: String?, filename: String, url: URL? = nil) -> Bool {
        let normalizedMIME = mimeType?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedMIME, !normalizedMIME.isEmpty {
            if normalizedMIME == "application/pdf" || normalizedMIME == "application/x-pdf" {
                return true
            }
            let isGenericBinary = normalizedMIME == "application/octet-stream"
                || normalizedMIME == "binary/octet-stream"
                || normalizedMIME == "application/binary"
            if !isGenericBinary {
                return (filename as NSString).pathExtension.lowercased() == "pdf"
            }
        }
        let filenameExt = (filename as NSString).pathExtension.lowercased()
        if filenameExt == "pdf" {
            return true
        }
        // Only fall back to URL extension when the filename does not advertise a different type.
        if filenameExt.isEmpty, let url, url.pathExtension.lowercased() == "pdf" {
            return true
        }
        return false
    }

    // MARK: - Durable Downloads Root Resolution

    /// Pure, testable resolver for Curium's built-in default Downloads root:
    /// 1. Private LiveContainer layout (`.../Documents/Data/Application/<GuestUUID>`):
    ///    `<HostContainer>/Documents/Curium/Downloads` (Files.app visible).
    /// 2. LiveContainer with Shared App Group container (e.g. Shared App across LC 1/2/3+):
    ///    `<SharedAppGroup>/Documents/Curium/Downloads`.
    /// 3. Explicit `LC_HOME_PATH` without App Group (Shared layout fallback or non-virtualized custom path):
    ///    `<HostRoot or LC_HOME_PATH>/Documents/Curium/Downloads`.
    /// 4. Standalone / Simulator: `<Documents>/Downloads`.
    nonisolated static func defaultDownloadsRootDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        sharedAppGroupURL: URL? = liveContainerSharedAppGroupURL()
    ) throws -> URL {
        let lcHome = environment["LC_HOME_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        let candidatePaths = lcHome.map { [$0] } ?? [homeDirectory]

        if isPrivateHostDocumentsLayout(fromCandidatePaths: candidatePaths),
           let hostRoot = resolveLiveContainerHostRoot(fromCandidatePaths: candidatePaths) {
            return hostRoot.standardizedFileURL
                .appending(path: "Documents/Curium/Downloads", directoryHint: .isDirectory)
        }

        if isRunningInLiveContainer(environment: environment),
           let sharedAppGroupURL {
            return sharedAppGroupURL.standardizedFileURL
                .appending(path: "Documents/Curium/Downloads", directoryHint: .isDirectory)
        }

        if let lcHome {
            if let hostRoot = resolveLiveContainerHostRoot(fromCandidatePaths: [lcHome]) {
                return hostRoot.standardizedFileURL
                    .appending(path: "Documents/Curium/Downloads", directoryHint: .isDirectory)
            }
            let host = URL(fileURLWithPath: lcHome, isDirectory: true).standardizedFileURL
            return host.appending(path: "Documents/Curium/Downloads", directoryHint: .isDirectory)
        }

        let root = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    /// Active durable Downloads directory: returns the user-selected external folder when active
    /// (unless disabled or using a synthetic test environment), otherwise falls back to the built-in default.
    nonisolated static func downloadsRootDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeCustomFolder: Bool = true
    ) throws -> URL {
        let isLiveProcessEnvironment =
            environment["LC_HOME_PATH"] == ProcessInfo.processInfo.environment["LC_HOME_PATH"]
        if includeCustomFolder,
           isLiveProcessEnvironment,
           let customURL = CuriumDownloadsFolderManager.activeCustomDownloadsURL {
            return customURL
        }
        return try defaultDownloadsRootDirectory(
            environment: environment,
            sharedAppGroupURL: isLiveProcessEnvironment ? liveContainerSharedAppGroupURL() : nil
        )
    }

    /// One-shot symlink-safe adoption of pre-Wave-2 LiveContainer downloads saved under
    /// `<LC_HOME_PATH>/Documents/Curium/Downloads` (`.../Data/Application/<GuestUUID>/Documents/Curium/Downloads`)
    /// into the canonical Tier A default downloads directory (`<HostContainer>/Documents/Curium/Downloads`
    /// or `<SharedAppGroup>/Documents/Curium/Downloads`). Returns the count of adopted files.
    @discardableResult
    nonisolated static func adoptLegacyGuestDownloadsIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        sharedAppGroupURL: URL? = liveContainerSharedAppGroupURL()
    ) -> Int {
        guard let lcHome = environment["LC_HOME_PATH"], !lcHome.isEmpty else { return 0 }
        let legacyRoot = URL(fileURLWithPath: lcHome, isDirectory: true)
            .standardizedFileURL
            .appending(path: "Documents/Curium/Downloads", directoryHint: .isDirectory)
        guard let targetRoot = try? defaultDownloadsRootDirectory(
            environment: environment,
            homeDirectory: homeDirectory,
            sharedAppGroupURL: sharedAppGroupURL
        ).standardizedFileURL else {
            return 0
        }
        guard legacyRoot.path != targetRoot.path else { return 0 }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard !isSymbolicLink(atPath: legacyRoot.path),
              fm.fileExists(atPath: legacyRoot.path, isDirectory: &isDir),
              isDir.boolValue else {
            return 0
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let topLevel = try? fm.contentsOfDirectory(
            at: legacyRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var movedCount = 0
        func adoptRegularFile(_ fileURL: URL) {
            guard isRegularNonSymlinkFile(atPath: fileURL.path) else { return }
            let name = fileURL.lastPathComponent
            guard !name.isEmpty, name != ".DS_Store", !name.hasPrefix(".") else { return }
            if (try? commitStagedFile(
                from: fileURL,
                toDirectory: targetRoot,
                preferredFilename: name,
                removeSource: true
            )) != nil {
                movedCount += 1
            }
        }

        for entry in topLevel {
            guard !isSymbolicLink(atPath: entry.path),
                  let values = try? entry.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else {
                continue
            }
            if values.isRegularFile == true {
                adoptRegularFile(entry)
            } else if values.isDirectory == true,
                      let nested = try? fm.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles]
                      ) {
                for child in nested {
                    adoptRegularFile(child)
                }
                if let remaining = try? fm.contentsOfDirectory(atPath: entry.path), remaining.isEmpty {
                    try? fm.removeItem(at: entry)
                }
            }
        }
        return movedCount
    }

    // MARK: - Ephemeral PDF Preview Cache (Per-Profile)

    /// Ephemeral Caches root used exclusively for inline tab PDF viewing (never pollutes Downloads).
    /// `"default"` (or empty) maps to `<Caches>/CuriumPDFPreview`; isolated profiles map to
    /// `<Caches>/CuriumPDFPreview/<sanitizedProfileSlug>`.
    nonisolated static func pdfPreviewCacheRoot(profileID: String = "default") throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = caches.appending(path: previewCacheDirectoryName, directoryHint: .isDirectory)
        guard let slug = sanitizedProfileSlug(profileID) else {
            return base
        }
        return base.appending(path: slug, directoryHint: .isDirectory)
    }

    /// Creates a unique per-session temporary file URL inside the PDF preview cache,
    /// registering its UUID folder so concurrent stale-cache cleanup never removes it.
    nonisolated static func makePreviewDestination(
        filename: String,
        cacheRoot: URL? = nil
    ) throws -> (sessionDirectory: URL, fileURL: URL) {
        let root = try cacheRoot ?? pdfPreviewCacheRoot()
        let safeName = ensurePDFExtension(sanitizedFilename(filename, fallback: "Document.pdf"))
        let sessionName = UUID().uuidString
        let sessionDir = root.appending(path: sessionName, directoryHint: .isDirectory)

        stateLock.lock()
        activePreviewSessionNames.insert(sessionName)
        stateLock.unlock()

        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            return (sessionDir, sessionDir.appending(path: safeName, directoryHint: .notDirectory))
        } catch {
            stateLock.lock()
            activePreviewSessionNames.remove(sessionName)
            stateLock.unlock()
            throw error
        }
    }

    /// Deletes a temporary preview session directory safely (no-op if outside the preview cache root).
    nonisolated static func removePreviewSessionDirectory(_ directory: URL, cacheRoot: URL? = nil) {
        let sessionName = directory.lastPathComponent
        defer {
            stateLock.lock()
            activePreviewSessionNames.remove(sessionName)
            stateLock.unlock()
        }
        guard let root = try? (cacheRoot ?? pdfPreviewCacheRoot())
            .resolvingSymlinksInPath()
            .standardizedFileURL else {
            return
        }
        let targetParent = directory.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard targetParent == root,
              !sessionName.isEmpty,
              sessionName != ".",
              sessionName != "..",
              !isSymbolicLink(atPath: directory.path) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes orphaned temporary PDF preview folders left over from previous launches
    /// without touching any session currently active in this process or sibling profile caches.
    nonisolated static func cleanupStalePDFPreviews(cacheRoot: URL? = nil) {
        guard let root = try? cacheRoot ?? pdfPreviewCacheRoot() else { return }
        let fm = FileManager.default
        guard !isSymbolicLink(atPath: root.path),
              let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }

        stateLock.lock()
        let activeSnapshot = activePreviewSessionNames
        stateLock.unlock()

        for entry in entries {
            let name = entry.lastPathComponent
            // Only remove UUID session folders so default-profile cleanup never touches
            // isolated `<Caches>/CuriumPDFPreview/<profileSlug>/` sibling directories.
            guard UUID(uuidString: name) != nil,
                  !activeSnapshot.contains(name),
                  !isSymbolicLink(atPath: entry.path) else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Transient Blink Download Staging & Coordinated Commit

    /// Ephemeral local staging root (`<Caches>/CuriumDownloadStaging/`) used when streaming
    /// Blink downloads destined for an external custom folder or FileProvider/iCloud Drive.
    nonisolated static func downloadStagingRoot() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches.appending(path: downloadStagingDirectoryName, directoryHint: .isDirectory)
    }

    /// Allocates an isolated per-download staging session folder inside `CuriumDownloadStaging/`.
    nonisolated static func makeDownloadStagingDestination(
        filename: String,
        stagingRoot: URL? = nil
    ) throws -> (sessionDirectory: URL, fileURL: URL) {
        let root = try stagingRoot ?? downloadStagingRoot()
        let safeName = sanitizedFilename(filename)
        let sessionName = UUID().uuidString
        let sessionDir = root.appending(path: sessionName, directoryHint: .isDirectory)

        stateLock.lock()
        activeDownloadStagingSessionNames.insert(sessionName)
        stateLock.unlock()

        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            return (sessionDir, sessionDir.appending(path: safeName, directoryHint: .notDirectory))
        } catch {
            stateLock.lock()
            activeDownloadStagingSessionNames.remove(sessionName)
            stateLock.unlock()
            throw error
        }
    }

    /// Removes a download staging session directory safely (symlink-safe, strictly confined to `stagingRoot`).
    nonisolated static func removeDownloadStagingDirectory(_ directory: URL, stagingRoot: URL? = nil) {
        let sessionName = directory.lastPathComponent
        defer {
            stateLock.lock()
            activeDownloadStagingSessionNames.remove(sessionName)
            stateLock.unlock()
        }
        guard let root = try? (stagingRoot ?? downloadStagingRoot())
            .resolvingSymlinksInPath()
            .standardizedFileURL else {
            return
        }
        let targetParent = directory.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard targetParent == root,
              !sessionName.isEmpty,
              sessionName != ".",
              sessionName != "..",
              !isSymbolicLink(atPath: directory.path) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Cleans orphaned download staging folders left over from terminated launches
    /// without disturbing active in-process download sessions.
    nonisolated static func cleanupStaleDownloadStaging(stagingRoot: URL? = nil) {
        guard let root = try? stagingRoot ?? downloadStagingRoot() else { return }
        let fm = FileManager.default
        guard !isSymbolicLink(atPath: root.path),
              let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }

        stateLock.lock()
        let activeSnapshot = activeDownloadStagingSessionNames
        stateLock.unlock()

        for entry in entries {
            guard !activeSnapshot.contains(entry.lastPathComponent),
                  !isSymbolicLink(atPath: entry.path) else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// Allocates a collision-free flat file URL directly inside the durable Downloads folder
    /// (e.g. `paper.pdf`, `paper (2).pdf`, `paper (3).pdf`).
    nonisolated static func uniqueDownloadDestination(
        filename: String,
        in downloadsRoot: URL? = nil
    ) throws -> URL {
        let root = try (downloadsRoot ?? downloadsRootDirectory()).standardizedFileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let safeName = sanitizedFilename(filename)
        let (stem, ext) = splitFilename(safeName)

        stateLock.lock()
        defer { stateLock.unlock() }

        var candidate = root.appending(path: safeName, directoryHint: .notDirectory)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) || reservedDownloadPaths.contains(candidate.path) {
            let nextName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = root.appending(path: nextName, directoryHint: .notDirectory)
            counter += 1
        }
        reservedDownloadPaths.insert(candidate.path)
        return candidate
    }

    /// Releases an in-flight download path reservation once the write completes or cancels.
    nonisolated static func releaseDownloadReservation(at url: URL) {
        stateLock.lock()
        reservedDownloadPaths.remove(url.standardizedFileURL.path)
        stateLock.unlock()
    }

    /// Commits a staged or previewed file into `destinationDirectory` with collision-free naming
    /// and FileProvider / iCloud Drive `NSFileCoordinator` safety.
    ///
    /// - Fast-path `moveItem` for local non-ubiquitous default directories when `removeSource == true`.
    /// - Coordinated `NSFileCoordinator(writingItemAt:options:.forReplacing)` copy (+ optional source cleanup)
    ///   for custom external folders, iCloud Drive / ubiquitous items, or cross-volume fallbacks.
    /// - Never writes `isExcludedFromBackup = true` on custom or ubiquitous destinations.
    @discardableResult
    nonisolated static func commitStagedFile(
        from stagedURL: URL,
        toDirectory destinationDirectory: URL,
        preferredFilename: String,
        removeSource: Bool
    ) throws -> URL {
        let fm = FileManager.default
        let isUbiquitousDest = isUbiquitousLocation(destinationDirectory)
        let isCustomDest = isWithinCustomDownloadsFolder(destinationDirectory)
        let isUbiquitousSource = isUbiquitousLocation(stagedURL)
        let needsCoordination = isUbiquitousDest || isCustomDest || isUbiquitousSource

        for attempt in 0...8 {
            let candidateName: String
            if attempt < 8 {
                candidateName = preferredFilename
            } else {
                candidateName = clampFilenameLength(
                    "\(UUID().uuidString)-\(sanitizedFilename(preferredFilename))",
                    fallback: "Download"
                )
            }
            let finalURL = try uniqueDownloadDestination(filename: candidateName, in: destinationDirectory)
            defer { releaseDownloadReservation(at: finalURL) }

            if removeSource && !needsCoordination {
                do {
                    try fm.moveItem(at: stagedURL, to: finalURL)
                    return finalURL
                } catch let error as CocoaError where error.code == .fileWriteFileExists && attempt < 8 {
                    continue
                } catch {
                    // Fall through to coordinated copy below (e.g., cross-volume EXDEV).
                }
            }

            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var fileOpError: Error?
            var collided = false

            coordinator.coordinate(
                writingItemAt: finalURL,
                options: .forReplacing,
                error: &coordinationError
            ) { targetURL in
                do {
                    if fm.fileExists(atPath: targetURL.path) {
                        collided = true
                        return
                    }
                    if removeSource && !needsCoordination {
                        do {
                            try fm.moveItem(at: stagedURL, to: targetURL)
                            return
                        } catch {
                            // Cross-volume or FileProvider boundary -> copy + cleanup below.
                        }
                    }
                    try fm.copyItem(at: stagedURL, to: targetURL)
                } catch {
                    fileOpError = error
                }
            }

            if collided {
                if attempt < 8 { continue }
                throw CocoaError(.fileWriteFileExists)
            }
            if let coordinationError {
                throw coordinationError
            }
            if let fileOpError {
                if let cocoa = fileOpError as? CocoaError,
                   cocoa.code == .fileWriteFileExists,
                   attempt < 8 {
                    continue
                }
                throw fileOpError
            }

            if removeSource {
                removeCommittedSource(at: stagedURL)
            }
            return finalURL
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Copies an ephemeral previewed file into durable Downloads on explicit user Save,
    /// routing through `commitStagedFile` for custom external or ubiquitous destinations and
    /// preserving flat collision dedup + retry behavior for local default folders.
    nonisolated static func savePreviewFileToDownloads(
        sourceURL: URL,
        suggestedFilename: String,
        downloadsRoot: URL? = nil
    ) throws -> URL {
        let resolvedRoot = try (downloadsRoot ?? downloadsRootDirectory()).standardizedFileURL
        if requiresFileCoordination(for: resolvedRoot) {
            return try commitStagedFile(
                from: sourceURL,
                toDirectory: resolvedRoot,
                preferredFilename: suggestedFilename,
                removeSource: false
            )
        }

        let fm = FileManager.default
        for _ in 0..<8 {
            let destination = try uniqueDownloadDestination(filename: suggestedFilename, in: resolvedRoot)
            defer { releaseDownloadReservation(at: destination) }
            do {
                try fm.copyItem(at: sourceURL, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        let fallbackName = clampFilenameLength(
            "\(UUID().uuidString)-\(sanitizedFilename(suggestedFilename, fallback: "Document.pdf"))",
            fallback: "Document.pdf"
        )
        let destination = try uniqueDownloadDestination(filename: fallbackName, in: resolvedRoot)
        defer { releaseDownloadReservation(at: destination) }
        try fm.copyItem(at: sourceURL, to: destination)
        return destination
    }

    // MARK: - Listing & Safe Deletion

    /// Lists persisted regular files in the durable Downloads folder, newest first.
    /// Skips symbolic links and supports both flat files and legacy `<UUID>/<file>` folders.
    nonisolated static func listSavedDownloads(in downloadsRoot: URL? = nil) -> [CuriumSavedDownload] {
        guard let root = try? downloadsRoot ?? downloadsRootDirectory() else { return [] }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        guard let topLevel = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [CuriumSavedDownload] = []
        func appendIfRegularFile(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  isRegularNonSymlinkFile(atPath: url.path) else { return }
            let name = url.lastPathComponent
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
            results.append(
                CuriumSavedDownload(
                    url: url,
                    filename: name,
                    byteCount: size,
                    modifiedAt: modified,
                    isPDF: isPDF(mimeType: nil, filename: name, url: url)
                )
            )
        }

        for entry in topLevel {
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true {
                appendIfRegularFile(entry)
            } else if values.isDirectory == true,
                      !isSymbolicLink(atPath: entry.path),
                      let nested = try? fm.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles]
                      ) {
                for child in nested {
                    appendIfRegularFile(child)
                }
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }

    /// Removes a regular file from durable Downloads, refusing symlinks, directories,
    /// and any path escaping the canonical Downloads root. Uses `NSFileCoordinator(.forDeleting)`
    /// when deleting inside a custom external or ubiquitous folder.
    nonisolated static func deleteSavedDownload(at fileURL: URL, downloadsRoot: URL? = nil) throws {
        let resolvedRoot = try (downloadsRoot ?? downloadsRootDirectory())
        let canonicalRoot = resolvedRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let parentDir = fileURL.deletingLastPathComponent()
        let canonicalParent = parentDir
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalParent == canonicalRoot || canonicalParent.path.hasPrefix(rootPrefix) else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Reject deleting symlinks or directories; only regular files inside Downloads may be removed.
        let targetName = fileURL.lastPathComponent
        guard !targetName.isEmpty, targetName != ".", targetName != ".." else {
            throw CocoaError(.fileNoSuchFile)
        }
        let canonicalTarget = canonicalParent.appending(path: targetName, directoryHint: .notDirectory)
        guard canonicalTarget.path.hasPrefix(rootPrefix),
              !isSymbolicLink(atPath: parentDir.path),
              isRegularNonSymlinkFile(atPath: canonicalTarget.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let fm = FileManager.default
        let useCoordination = requiresFileCoordination(for: resolvedRoot)
            || requiresFileCoordination(for: canonicalTarget)

        if useCoordination {
            try coordinatedRemoveItem(at: canonicalTarget)
        } else {
            try fm.removeItem(at: canonicalTarget)
        }

        if canonicalParent != canonicalRoot,
           canonicalParent.path.hasPrefix(rootPrefix),
           !isSymbolicLink(atPath: canonicalParent.path),
           let remaining = try? fm.contentsOfDirectory(atPath: canonicalParent.path),
           remaining.isEmpty {
            if useCoordination {
                try? coordinatedRemoveItem(at: canonicalParent)
            } else {
                try? fm.removeItem(at: canonicalParent)
            }
        }
    }

    // MARK: - Private Helpers

    private nonisolated static func defaultLiveContainerCandidatePaths() -> [String] {
        [
            ProcessInfo.processInfo.environment["LC_HOME_PATH"],
            NSHomeDirectory(),
        ].compactMap { $0 }
    }

    private nonisolated static func isUbiquitousLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return FileManager.default.isUbiquitousItem(at: url)
            || path.contains("Mobile Documents")
            || path.contains("com~apple~CloudDocs")
    }

    private nonisolated static func isWithinCustomDownloadsFolder(_ url: URL) -> Bool {
        guard let customRoot = CuriumDownloadsFolderManager.activeCustomDownloadsURL else {
            return false
        }
        let canonicalCustom = customRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalTarget = url.resolvingSymlinksInPath().standardizedFileURL.path
        if canonicalTarget == canonicalCustom {
            return true
        }
        let prefix = canonicalCustom.hasSuffix("/") ? canonicalCustom : canonicalCustom + "/"
        return canonicalTarget.hasPrefix(prefix)
    }

    private nonisolated static func requiresFileCoordination(for url: URL) -> Bool {
        isUbiquitousLocation(url) || isWithinCustomDownloadsFolder(url)
    }

    private nonisolated static func coordinatedRemoveItem(at url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var removeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                removeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
    }

    private nonisolated static func removeCommittedSource(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if requiresFileCoordination(for: url) {
            try? coordinatedRemoveItem(at: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func sanitizedProfileSlug(_ profileID: String) -> String? {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "default" {
            return nil
        }
        if CuriumFingerprintValidator.isValidProfileID(trimmed) {
            return trimmed
        }
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(min(trimmed.unicodeScalars.count, 32))
        for scalar in trimmed.unicodeScalars {
            let isAlnum = (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
            let isDashOrUnderscore = scalar == "-" || scalar == "_"
            if isAlnum {
                scalars.append(scalar)
            } else if isDashOrUnderscore, !scalars.isEmpty {
                scalars.append(scalar)
            } else if !scalars.isEmpty, scalars.last != "-" {
                scalars.append("-")
            }
            if scalars.count == 32 { break }
        }
        while scalars.last == "-" || scalars.last == "_" {
            scalars.removeLast()
        }
        let slug = String(String.UnicodeScalarView(scalars))
        if slug.isEmpty || slug.lowercased() == "default" {
            return nil
        }
        return slug
    }

    private nonisolated static func ensurePDFExtension(_ filename: String) -> String {
        let (stem, ext) = splitFilename(filename)
        if ext.lowercased() == "pdf" {
            return "\(stem).\(ext)"
        }
        return clampFilenameLength("\(filename).pdf", fallback: "Document.pdf")
    }

    private nonisolated static func splitFilename(_ name: String) -> (stem: String, ext: String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty {
            return (name, "")
        }
        let stem = ns.deletingPathExtension
        if stem.isEmpty {
            return (name, "")
        }
        return (stem, ext)
    }

    private nonisolated static func clampFilenameLength(_ filename: String, fallback: String) -> String {
        let (rawStem, rawExt) = splitFilename(filename)
        let clampedExt = truncateUTF8(rawExt, maxBytes: 24)
        let clampedStem = truncateUTF8(rawStem, maxBytes: maxStemUTF8Bytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clampedStem.isEmpty else { return fallback }
        return clampedExt.isEmpty ? clampedStem : "\(clampedStem).\(clampedExt)"
    }

    private nonisolated static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for idx in text.indices {
            let charBytes = text[idx].utf8.count
            if bytes + charBytes > maxBytes { break }
            bytes += charBytes
            end = text.index(after: idx)
        }
        return String(text[..<end])
    }

    private nonisolated static func isSymbolicLink(atPath path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private nonisolated static func isRegularNonSymlinkFile(atPath path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }
}
