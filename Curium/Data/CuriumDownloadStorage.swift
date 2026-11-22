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
/// (`Caches/CuriumPDFPreview/`) and durable user downloads visible in Files.app
/// (`<HostContainer>/Documents/Curium/Downloads/` under LiveContainer).
enum CuriumDownloadStorage {
    static let previewCacheDirectoryName = "CuriumPDFPreview"
    private static let maxStemUTF8Bytes = 200
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var activePreviewSessionNames: Set<String> = []
    private nonisolated(unsafe) static var reservedDownloadPaths: Set<String> = []

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

    /// Durable Downloads directory visible in Files.app (host container under LiveContainer).
    nonisolated static func downloadsRootDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let hostPath = environment["LC_HOME_PATH"], !hostPath.isEmpty {
            let host = URL(fileURLWithPath: hostPath, isDirectory: true).standardizedFileURL
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

    /// Ephemeral Caches root used exclusively for inline tab PDF viewing (never pollutes Downloads).
    nonisolated static func pdfPreviewCacheRoot() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches.appending(path: previewCacheDirectoryName, directoryHint: .isDirectory)
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

    /// Allocates a collision-free flat file URL directly inside the durable Downloads folder
    /// (e.g. `paper.pdf`, `paper (2).pdf`, `paper (3).pdf`).
    nonisolated static func uniqueDownloadDestination(
        filename: String,
        in downloadsRoot: URL? = nil
    ) throws -> URL {
        let root = try (downloadsRoot ?? downloadsRootDirectory()).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safeName = sanitizedFilename(filename)
        let (stem, ext) = splitFilename(safeName)

        let fm = FileManager.default
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

    /// Copies an ephemeral previewed file into durable Downloads on explicit user Save,
    /// retrying cleanly if a concurrent save claims the same name.
    nonisolated static func savePreviewFileToDownloads(
        sourceURL: URL,
        suggestedFilename: String,
        downloadsRoot: URL? = nil
    ) throws -> URL {
        let fm = FileManager.default
        for _ in 0..<8 {
            let destination = try uniqueDownloadDestination(filename: suggestedFilename, in: downloadsRoot)
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
        let destination = try uniqueDownloadDestination(filename: fallbackName, in: downloadsRoot)
        defer { releaseDownloadReservation(at: destination) }
        try fm.copyItem(at: sourceURL, to: destination)
        return destination
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
    /// without touching any session currently active in this process.
    nonisolated static func cleanupStalePDFPreviews(cacheRoot: URL? = nil) {
        guard let root = try? cacheRoot ?? pdfPreviewCacheRoot() else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        stateLock.lock()
        let activeSnapshot = activePreviewSessionNames
        stateLock.unlock()

        for entry in entries {
            guard !activeSnapshot.contains(entry.lastPathComponent) else { continue }
            try? fm.removeItem(at: entry)
        }
    }

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
    /// and any path escaping the canonical Downloads root.
    nonisolated static func deleteSavedDownload(at fileURL: URL, downloadsRoot: URL? = nil) throws {
        let canonicalRoot = try (downloadsRoot ?? downloadsRootDirectory())
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
        try fm.removeItem(at: canonicalTarget)

        if canonicalParent != canonicalRoot,
           canonicalParent.path.hasPrefix(rootPrefix),
           !isSymbolicLink(atPath: canonicalParent.path),
           let remaining = try? fm.contentsOfDirectory(atPath: canonicalParent.path),
           remaining.isEmpty {
            try? fm.removeItem(at: canonicalParent)
        }
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
