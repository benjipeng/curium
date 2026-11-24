import Darwin
import Foundation
import ObjectiveC.runtime
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

/// Multi-instance safe security-scoped external Downloads folder manager for LiveContainer
/// (`LC 1` / `LC 2` / `LC 3+`) and standalone iOS builds.
///
/// Key iOS & LiveContainer invariants enforced:
/// - Keys security-scoped bookmarks by the real host bundle ID (`+[NSUserDefaults lcMainBundle]`),
///   which stays distinct per LiveContainer host and survives 7-day re-signing even after
///   `overwriteMainNSBundle` spoofs `Bundle.main`.
/// - Maintains a single process-scoped security lease (`startAccessingSecurityScopedResource`)
///   to avoid ref-count leaks while keeping `PDFKit`, `QLPreviewController`, and `ShareLink` authorized.
/// - Resolves bookmarks off `@MainActor` so cold `iCloud Drive` / `fileproviderd` mounts never stall launch.
/// - Rejects temporary `-Inbox` / `/tmp/` picks from LiveContainer's legacy *Fix File Picker* toggle
///   and verifies genuine `isWritableFile` + `contentsOfDirectory` access.
@Observable
@MainActor
final class CuriumDownloadsFolderManager {
    static let shared = CuriumDownloadsFolderManager()

    enum Status: Equatable, Sendable {
        case defaultInternal
        case customActive(url: URL, folderName: String, breadcrumb: String)
        case needsHostGrant(folderName: String, breadcrumb: String, canonicalPathHint: String)

        var isCustomActive: Bool {
            if case .customActive = self { return true }
            return false
        }

        var needsHostGrant: Bool {
            if case .needsHostGrant = self { return true }
            return false
        }

        var activeURL: URL? {
            if case .customActive(let url, _, _) = self { return url }
            return nil
        }
    }

    enum PickOutcome: Equatable, Sendable {
        case linkedExistingSharedFolder(folderName: String)
        case activated(folderName: String, offerMoveFrom: URL?, movableFileCount: Int)
        case confirmSwitchFromExpected(pickedURL: URL, pickedName: String, expectedName: String)
        case rejected(message: String)
    }

    struct SharedFolderRecord: Codable, Equatable, Sendable {
        var folderName: String
        var breadcrumb: String
        var canonicalPathHint: String
        var bookmarksByHost: [String: Data]

        init(
            folderName: String,
            breadcrumb: String,
            canonicalPathHint: String,
            bookmarksByHost: [String: Data]
        ) {
            self.folderName = folderName
            self.breadcrumb = breadcrumb
            self.canonicalPathHint = canonicalPathHint
            self.bookmarksByHost = bookmarksByHost
        }
    }

    private struct ActiveFolderState: Sendable {
        var url: URL?
        var breadcrumb: String?
    }

    private struct ScopedLease {
        let url: URL
        let needsStop: Bool

        func release() {
            if needsStop {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private struct ResolvedBookmark: Sendable {
        let url: URL
        let needsStop: Bool
        let refreshedBookmark: Data?
    }

    private nonisolated static let recordDefaultsKey = "curium.storage.customDownloadsFolderRecord.v1"
    private nonisolated static let activeFolderState = OSAllocatedUnfairLock(initialState: ActiveFolderState())

    private(set) var status: Status = .defaultInternal
    private(set) var isResolving: Bool = false
    private(set) var revision: Int = 0
    var lastErrorMessage: String?

    @ObservationIgnored private var activeScopedLease: ScopedLease?
    @ObservationIgnored private var pendingMoveSourceLease: ScopedLease?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lock-Protected Nonisolated Active Folder State

    nonisolated static func setActiveCustomDownloadsFolder(url: URL?, displayBreadcrumb: String?) {
        activeFolderState.withLock { state in
            state.url = url
            state.breadcrumb = displayBreadcrumb
        }
    }

    nonisolated static var activeCustomDownloadsURL: URL? {
        activeFolderState.withLock { $0.url }
    }

    nonisolated static var isUsingCustomDownloadsFolder: Bool {
        activeFolderState.withLock { $0.url != nil }
    }

    /// True when the active Downloads directory can be browsed directly in iOS Files.app.
    nonisolated static var isDownloadsDirectoryVisibleInFiles: Bool {
        if isUsingCustomDownloadsFolder {
            return true
        }
        if CuriumDownloadStorage.isRunningInLiveContainer() {
            return CuriumDownloadStorage.isPrivateHostDocumentsLayout()
                || CuriumDownloadStorage.liveContainerSharedAppGroupURL() == nil
        }
        return true
    }

    /// User-facing breadcrumb describing where Curium currently saves downloads.
    nonisolated static var displayDownloadsPath: String {
        let snapshot = activeFolderState.withLock { $0 }
        if let breadcrumb = snapshot.breadcrumb, snapshot.url != nil, !breadcrumb.isEmpty {
            return breadcrumb
        }
        if CuriumDownloadStorage.isRunningInLiveContainer() {
            if !CuriumDownloadStorage.isPrivateHostDocumentsLayout(),
               CuriumDownloadStorage.liveContainerSharedAppGroupURL() != nil {
                return "App Storage"
            }
            return "On My iPhone › LiveContainer › Curium › Downloads"
        }
        return "On My iPhone › Curium › Downloads"
    }

    // MARK: - LiveContainer Real Host Identity (`LCBootstrap.m`)

    /// Resolves the genuine host app bundle identifier (`com.kdt.livecontainer...` /
    /// `com.kdt.LiveContainer2...`), bypassing `overwriteMainNSBundle` guest spoofing.
    nonisolated static func currentHostBundleIdentifier() -> String {
        let sel = NSSelectorFromString("lcMainBundle")
        if (UserDefaults.self as AnyObject).responds(to: sel),
           let unmanaged = (UserDefaults.self as AnyObject).perform(sel),
           let hostBundle = unmanaged.takeUnretainedValue() as? Bundle,
           let hostID = hostBundle.bundleIdentifier,
           !hostID.isEmpty {
            return hostID
        }
        return Bundle.main.bundleIdentifier ?? "com.appautomaton.curium.standalone"
    }

    /// Human-readable label for the active host (`LiveContainer`, `LiveContainer 2`, etc.).
    nonisolated static func currentHostDisplayName() -> String {
        let sel = NSSelectorFromString("lcAppUrlScheme")
        if (UserDefaults.self as AnyObject).responds(to: sel),
           let unmanaged = (UserDefaults.self as AnyObject).perform(sel),
           let scheme = unmanaged.takeUnretainedValue() as? String,
           !scheme.isEmpty {
            let lower = scheme.lowercased()
            if lower == "livecontainer" {
                return "LiveContainer"
            }
            if lower.hasPrefix("livecontainer") {
                let suffix = String(lower.dropFirst("livecontainer".count))
                if !suffix.isEmpty {
                    return "LiveContainer \(suffix)"
                }
            }
            return scheme
        }
        return CuriumDownloadStorage.isRunningInLiveContainer() ? "LiveContainer" : "This Device"
    }

    /// Detects LiveContainer's legacy *Fix File Picker* toggle (`guestAppInfo["doSymlinkInbox"] == true`),
    /// which turns folder picks into temporary Inbox copies and stubs security-scope grants.
    nonisolated static func isLegacySymlinkInboxEnabled() -> Bool {
        let sel = NSSelectorFromString("lcGuestAppInfo")
        if (UserDefaults.self as AnyObject).responds(to: sel),
           let unmanaged = (UserDefaults.self as AnyObject).perform(sel),
           let info = unmanaged.takeUnretainedValue() as? [String: Any],
           let flag = info["doSymlinkInbox"] as? Bool {
            return flag
        }
        if let info = UserDefaults.standard.dictionary(forKey: "guestAppInfo"),
           let flag = info["doSymlinkInbox"] as? Bool {
            return flag
        }
        return false
    }

    // MARK: - Startup & Foreground Asynchronous Bookmark Resolution

    func resolveInBackgroundIfNeeded() {
        resolveTask?.cancel()
        resolveTask = nil
        isResolving = false

        guard let record = Self.loadRecord() else {
            releaseScopedAccess()
            Self.setActiveCustomDownloadsFolder(url: nil, displayBreadcrumb: nil)
            if status != .defaultInternal {
                status = .defaultInternal
                revision &+= 1
            }
            return
        }

        let hostID = Self.currentHostBundleIdentifier()
        guard let bookmarkData = record.bookmarksByHost[hostID] else {
            releaseScopedAccess()
            Self.setActiveCustomDownloadsFolder(url: nil, displayBreadcrumb: nil)
            status = .needsHostGrant(
                folderName: record.folderName,
                breadcrumb: record.breadcrumb,
                canonicalPathHint: record.canonicalPathHint
            )
            revision &+= 1
            return
        }

        // Fast-path: retain the active lease if it already points to this exact writable folder.
        if let existing = activeScopedLease?.url,
           existing.standardizedFileURL.path == record.canonicalPathHint,
           Self.verifyRealDirectoryReadWrite(at: existing) {
            Self.setActiveCustomDownloadsFolder(url: existing, displayBreadcrumb: record.breadcrumb)
            status = .customActive(url: existing, folderName: record.folderName, breadcrumb: record.breadcrumb)
            return
        }

        isResolving = true
        resolveTask = Task { @MainActor [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) { () -> ResolvedBookmark? in
                var isStale = false
                guard let url = Self.resolvePersistentBookmark(bookmarkData, isStale: &isStale) else {
                    return nil
                }
                let granted = url.startAccessingSecurityScopedResource()
                // Verify real filesystem read/write rather than trusting a swizzled scope stub.
                guard Self.verifyRealDirectoryReadWrite(at: url) else {
                    if granted { url.stopAccessingSecurityScopedResource() }
                    return nil
                }
                let refreshed: Data? = isStale ? Self.createPersistentBookmark(for: url) : nil
                return ResolvedBookmark(url: url, needsStop: granted, refreshedBookmark: refreshed)
            }.value

            guard let self, !Task.isCancelled else {
                if let resolved, resolved.needsStop {
                    resolved.url.stopAccessingSecurityScopedResource()
                }
                return
            }
            self.isResolving = false
            self.resolveTask = nil

            guard let resolved else {
                self.releaseScopedAccess()
                Self.setActiveCustomDownloadsFolder(url: nil, displayBreadcrumb: nil)
                self.status = .needsHostGrant(
                    folderName: record.folderName,
                    breadcrumb: record.breadcrumb,
                    canonicalPathHint: record.canonicalPathHint
                )
                self.revision &+= 1
                return
            }

            // Atomically swap active security lease.
            self.releaseScopedAccess()
            self.activeScopedLease = ScopedLease(url: resolved.url, needsStop: resolved.needsStop)

            var updatedRecord = record
            let canonicalPath = resolved.url.standardizedFileURL.path
            let folderName = Self.cleanFolderName(for: resolved.url)
            let breadcrumb = Self.displayBreadcrumb(for: resolved.url)
            var didMutate = false
            if let refreshedBookmark = resolved.refreshedBookmark {
                updatedRecord.bookmarksByHost[hostID] = refreshedBookmark
                didMutate = true
            }
            if updatedRecord.canonicalPathHint != canonicalPath
                || updatedRecord.folderName != folderName
                || updatedRecord.breadcrumb != breadcrumb {
                updatedRecord.canonicalPathHint = canonicalPath
                updatedRecord.folderName = folderName
                updatedRecord.breadcrumb = breadcrumb
                didMutate = true
            }
            if didMutate {
                Self.saveRecord(updatedRecord)
            }

            Self.setActiveCustomDownloadsFolder(url: resolved.url, displayBreadcrumb: updatedRecord.breadcrumb)
            self.status = .customActive(
                url: resolved.url,
                folderName: updatedRecord.folderName,
                breadcrumb: updatedRecord.breadcrumb
            )
            self.revision &+= 1
        }
    }

    // MARK: - Adopting & Resetting a Custom Folder

    /// Processes a folder chosen via `UIDocumentPickerViewController`.
    /// When `forceSwitchSharedTarget` is `false` and the current host is in `.needsHostGrant`,
    /// picking a different folder returns `.confirmSwitchFromExpected` to prevent split-brain
    /// between LiveContainer 1 and LiveContainer 2.
    func adoptPickedFolder(
        _ pickedURL: URL,
        forceSwitchSharedTarget: Bool = false
    ) -> PickOutcome {
        lastErrorMessage = nil
        resolveTask?.cancel()
        resolveTask = nil
        isResolving = false

        if Self.isRejectedInboxOrTemporaryURL(pickedURL) {
            let msg = Self.isLegacySymlinkInboxEnabled()
                ? "Turn off “Fix File Picker” in LiveContainer app settings so iOS can grant real folder access."
                : "Please pick a permanent folder in On My iPhone or iCloud Drive (temporary Inbox folders cannot persist)."
            lastErrorMessage = msg
            return .rejected(message: msg)
        }

        let granted = pickedURL.startAccessingSecurityScopedResource()
        guard Self.verifyRealDirectoryReadWrite(at: pickedURL) else {
            if granted { pickedURL.stopAccessingSecurityScopedResource() }
            let msg = Self.isLegacySymlinkInboxEnabled()
                ? "Folder is not writable. Disable “Fix File Picker” in LiveContainer app settings and try again."
                : "Curium could not obtain write access to that folder. Please choose a writable folder in On My iPhone or iCloud Drive."
            lastErrorMessage = msg
            return .rejected(message: msg)
        }

        let canonicalPath = pickedURL.standardizedFileURL.path
        let folderName = Self.cleanFolderName(for: pickedURL)
        let breadcrumb = Self.displayBreadcrumb(for: pickedURL)
        let hostID = Self.currentHostBundleIdentifier()

        // Path-match guard when linking a secondary LiveContainer host (e.g. LC 2 linking LC 1's folder).
        if case .needsHostGrant(let expectedName, _, let expectedPath) = status,
           !forceSwitchSharedTarget,
           canonicalPath != expectedPath {
            if granted { pickedURL.stopAccessingSecurityScopedResource() }
            return .confirmSwitchFromExpected(
                pickedURL: pickedURL,
                pickedName: folderName,
                expectedName: expectedName
            )
        }

        guard let bookmarkData = Self.createPersistentBookmark(for: pickedURL) else {
            if granted { pickedURL.stopAccessingSecurityScopedResource() }
            let msg = "iOS could not create a persistent bookmark for “\(folderName)”."
            lastErrorMessage = msg
            return .rejected(message: msg)
        }

        let previousDir = try? CuriumDownloadStorage.downloadsRootDirectory()
        let previousLease = activeScopedLease
        let wasMatchingNeedsGrant: Bool = {
            if case .needsHostGrant(_, _, let expectedPath) = status {
                return canonicalPath == expectedPath
            }
            return false
        }()

        var nextRecord: SharedFolderRecord
        if wasMatchingNeedsGrant, var existing = Self.loadRecord() {
            existing.bookmarksByHost[hostID] = bookmarkData
            existing.folderName = folderName
            existing.breadcrumb = breadcrumb
            existing.canonicalPathHint = canonicalPath
            nextRecord = existing
        } else {
            // Fresh folder or intentional switch across all hosts: drop stale sibling bookmarks so
            // other LiveContainer instances prompt to link the new shared folder.
            nextRecord = SharedFolderRecord(
                folderName: folderName,
                breadcrumb: breadcrumb,
                canonicalPathHint: canonicalPath,
                bookmarksByHost: [hostID: bookmarkData]
            )
        }

        Self.saveRecord(nextRecord)
        releasePendingMoveSourceLease()

        let movableCount: Int
        if let previousDir,
           !wasMatchingNeedsGrant,
           previousDir.standardizedFileURL.path != canonicalPath {
            movableCount = Self.countVisibleRegularFiles(in: previousDir)
        } else {
            movableCount = 0
        }

        if movableCount > 0,
           let previousDir,
           let previousLease,
           previousLease.url.standardizedFileURL.path == previousDir.standardizedFileURL.path {
            // Retain read/move scope on the departing custom folder until the move prompt settles.
            pendingMoveSourceLease = previousLease
            activeScopedLease = nil
        } else {
            releaseScopedAccess()
        }

        activeScopedLease = ScopedLease(url: pickedURL, needsStop: granted)
        Self.setActiveCustomDownloadsFolder(url: pickedURL, displayBreadcrumb: breadcrumb)
        status = .customActive(url: pickedURL, folderName: folderName, breadcrumb: breadcrumb)
        revision &+= 1

        if wasMatchingNeedsGrant {
            return .linkedExistingSharedFolder(folderName: folderName)
        }
        if movableCount > 0, let previousDir {
            return .activated(folderName: folderName, offerMoveFrom: previousDir, movableFileCount: movableCount)
        }
        return .activated(folderName: folderName, offerMoveFrom: nil, movableFileCount: 0)
    }

    /// Resets storage back to Curium's built-in default container across all LiveContainer hosts.
    func resetToDefaultFolder() -> (offerMoveFrom: URL?, movableFileCount: Int) {
        lastErrorMessage = nil
        resolveTask?.cancel()
        resolveTask = nil
        isResolving = false
        releasePendingMoveSourceLease()

        let previousLease = activeScopedLease
        let previousCustom = previousLease?.url
        let previousCount = previousCustom.map { Self.countVisibleRegularFiles(in: $0) } ?? 0

        Self.clearRecord()
        if previousCount > 0, let previousLease {
            pendingMoveSourceLease = previousLease
            activeScopedLease = nil
        } else {
            releaseScopedAccess()
        }

        Self.setActiveCustomDownloadsFolder(url: nil, displayBreadcrumb: nil)
        status = .defaultInternal
        revision &+= 1

        return (previousCount > 0 ? previousCustom : nil, previousCount)
    }

    /// Releases any temporarily retained read/move lease when the user declines moving previous files.
    func dismissPendingMoveOffer() {
        releasePendingMoveSourceLease()
    }

    /// One-shot non-blocking move of existing regular files from `sourceDir` into the active Downloads folder.
    func moveExistingFiles(from sourceDir: URL) async -> (moved: Int, failed: Int) {
        defer { releasePendingMoveSourceLease() }
        guard let destinationDir = try? CuriumDownloadStorage.downloadsRootDirectory() else {
            return (0, 0)
        }
        guard sourceDir.standardizedFileURL.path != destinationDir.standardizedFileURL.path else {
            return (0, 0)
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (Int, Int) in
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return (0, 0)
            }

            var moved = 0
            var failed = 0
            for item in items {
                let name = item.lastPathComponent
                guard !name.isEmpty, name != ".DS_Store", !name.hasPrefix(".") else { continue }
                guard !Self.isSymbolicLink(atPath: item.path) else { continue }
                let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if vals?.isDirectory == true || vals?.isSymbolicLink == true { continue }

                do {
                    _ = try CuriumDownloadStorage.commitStagedFile(
                        from: item,
                        toDirectory: destinationDir,
                        preferredFilename: name,
                        removeSource: true
                    )
                    moved += 1
                } catch {
                    failed += 1
                }
            }
            return (moved, failed)
        }.value
        revision &+= 1
        return result
    }

    /// Best-effort parent directory URL to pre-seed `UIDocumentPickerViewController.directoryURL`
    /// when re-linking an existing folder chosen on another LiveContainer host.
    var suggestedPickerDirectoryURL: URL? {
        switch status {
        case .customActive(let url, _, _):
            return url.deletingLastPathComponent()
        case .needsHostGrant(_, _, let hint):
            let parent = URL(fileURLWithPath: hint, isDirectory: true).deletingLastPathComponent()
            return FileManager.default.fileExists(atPath: parent.path) ? parent : nil
        case .defaultInternal:
            return nil
        }
    }

    // MARK: - Pure Validators, Display Naming & Persistence

    private func releaseScopedAccess() {
        activeScopedLease?.release()
        activeScopedLease = nil
    }

    private func releasePendingMoveSourceLease() {
        pendingMoveSourceLease?.release()
        pendingMoveSourceLease = nil
    }

    nonisolated static func isRejectedInboxOrTemporaryURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let tmpPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if path == tmpPath || path.hasPrefix(tmpPath + "/") {
            return true
        }
        if path.contains("-Inbox/") || path.hasSuffix("-Inbox") || path.contains("/tmp/") {
            return true
        }
        return false
    }

    nonisolated static func verifyRealDirectoryReadWrite(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard fm.isWritableFile(atPath: url.path) else {
            return false
        }
        return (try? fm.contentsOfDirectory(atPath: url.path)) != nil
    }

    nonisolated static func cleanFolderName(for url: URL) -> String {
        let raw = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "File Provider Storage" {
            return "On My iPhone"
        }
        if raw == "com~apple~CloudDocs" {
            return "iCloud Drive"
        }
        return raw.isEmpty ? "Custom Folder" : raw
    }

    nonisolated static func displayBreadcrumb(for url: URL) -> String {
        let name = cleanFolderName(for: url)
        let path = url.standardizedFileURL.path
        if name == "On My iPhone" || name == "iCloud Drive" {
            return name
        }
        if FileManager.default.isUbiquitousItem(at: url)
            || path.contains("Mobile Documents")
            || path.contains("com~apple~CloudDocs") {
            return "iCloud Drive › \(name)"
        }
        return "Files › \(name)"
    }

    private nonisolated static func countVisibleRegularFiles(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        return items.filter { item in
            let name = item.lastPathComponent
            guard !name.isEmpty, name != ".DS_Store", !name.hasPrefix(".") else { return false }
            guard !isSymbolicLink(atPath: item.path) else { return false }
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return vals?.isDirectory != true && vals?.isSymbolicLink != true
        }.count
    }

    private nonisolated static func isSymbolicLink(atPath path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    nonisolated static func loadRecord(
        defaults: UserDefaults = CuriumDownloadStorage.sharedDefaults
    ) -> SharedFolderRecord? {
        guard let data = defaults.data(forKey: recordDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(SharedFolderRecord.self, from: data)
    }

    nonisolated static func saveRecord(
        _ record: SharedFolderRecord,
        defaults: UserDefaults = CuriumDownloadStorage.sharedDefaults
    ) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: recordDefaultsKey)
        }
    }

    nonisolated static func clearRecord(
        defaults: UserDefaults = CuriumDownloadStorage.sharedDefaults
    ) {
        defaults.removeObject(forKey: recordDefaultsKey)
    }

    /// Opens the active Downloads folder directly in iOS Files.app via `shareddocuments://`.
    /// Supports both custom external folders and `.defaultInternal` when `isDownloadsDirectoryVisibleInFiles` is `true`.
    static func openActiveDownloadsFolder() {
        CuriumSaveFolderFilesLauncher.openActiveDownloadsFolder()
    }

    // MARK: - Persistent Bookmark Helpers

    nonisolated static func createPersistentBookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), !data.isEmpty {
            return data
        }
        // Fallback matching `NSURLBookmarkCreationWithSecurityScope = 1 << 11`.
        let securityScopedFallback = URL.BookmarkCreationOptions(rawValue: 1 << 11)
        if let data = try? url.bookmarkData(
            options: securityScopedFallback,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), !data.isEmpty {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    nonisolated static func resolvePersistentBookmark(_ bookmarkData: Data, isStale: inout Bool) -> URL? {
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

// MARK: - LiveContainer `DocumentPicker.m` Runtime Bridge

/// Isolated Objective-C runtime bridge keeping `UIDocumentPickerViewController` working cleanly
/// inside LiveContainer without requiring manual per-app LiveContainer toggles.
///
/// Uses `dladdr` image-path verification (`/System/Library/`, `/System/Cryptexes/`, `/usr/lib/`)
/// to distinguish genuinely exchanged Apple IMPs from unswizzled category methods so invoking the
/// original initializer can never self-recurse across LiveContainer versions.
@MainActor
enum CuriumDocumentPickerBridge {
    private static var didInstallHostFix = false

    nonisolated static func imagePath(for imp: IMP) -> String? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(imp), &info) != 0,
              let fname = info.dli_fname else {
            return nil
        }
        return String(cString: fname)
    }

    nonisolated static func isAppleSystemImplementation(_ imp: IMP) -> Bool {
        guard let path = imagePath(for: imp) else { return false }
        return path.contains("/System/Library/")
            || path.contains("/System/Cryptexes/")
            || path.contains("/usr/lib/")
    }

    /// Ensures `DOCConfiguration.setHostIdentifier:` receives LiveContainer's genuine signed host
    /// bundle ID (`lcMainBundle`) even when LiveContainer's `fixFilePickerNew` toggle is off.
    @discardableResult
    static func installHostIdentifierFixIfNeeded() -> Bool {
        guard CuriumDownloadStorage.isRunningInLiveContainer() else { return false }
        guard !didInstallHostFix else { return true }

        _ = UIDocumentPickerViewController.self
        var docClass: AnyClass? = NSClassFromString("DOCConfiguration")
        if docClass == nil {
            _ = dlopen("/System/Library/PrivateFrameworks/DocumentManagerCore.framework/DocumentManagerCore", RTLD_LAZY)
            docClass = NSClassFromString("DOCConfiguration")
        }
        guard let targetClass = docClass,
              let setHostMethod = class_getInstanceMethod(targetClass, NSSelectorFromString("setHostIdentifier:")) else {
            return false
        }
        if !isAppleSystemImplementation(method_getImplementation(setHostMethod)) {
            didInstallHostFix = true
            return true
        }
        let installed = installHostIdentifierFix(
            on: targetClass,
            hostBundleID: CuriumDownloadsFolderManager.currentHostBundleIdentifier()
        )
        if installed {
            didInstallHostFix = true
        }
        return installed
    }

    @discardableResult
    static func installHostIdentifierFix(on targetClass: AnyClass, hostBundleID: String) -> Bool {
        let setHostSel = NSSelectorFromString("setHostIdentifier:")
        guard let method = class_getInstanceMethod(targetClass, setHostSel) else { return false }
        let origIMP = method_getImplementation(method)
        typealias SetHostIDIMP = @convention(c) (AnyObject, Selector, NSString?) -> Void
        let callOrig = unsafeBitCast(origIMP, to: SetHostIDIMP.self)
        let block: @convention(block) (AnyObject, NSString?) -> Void = { obj, _ in
            callOrig(obj, setHostSel, hostBundleID as NSString)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return true
    }

    /// Builds a `UIDocumentPickerViewController` strictly in single-folder open-in-place mode
    /// (`[.folder]`, `asCopy: false`), bypassing LiveContainer `DocumentPicker.m`'s `[.item, .folder]` rewrite.
    static func makeFolderPickerController(
        initialDirectoryURL: URL?,
        pickerClass: UIDocumentPickerViewController.Type = UIDocumentPickerViewController.self,
        isOriginalImplementation: (IMP) -> Bool = isAppleSystemImplementation
    ) -> UIDocumentPickerViewController {
        installHostIdentifierFixIfNeeded()

        let canonicalInitSel = NSSelectorFromString("initForOpeningContentTypes:asCopy:")
        let lcSwappedInitSel = NSSelectorFromString("hook_initForOpeningContentTypes:asCopy:")
        let controller: UIDocumentPickerViewController

        if let canonicalInitMethod = class_getInstanceMethod(pickerClass, canonicalInitSel),
           let origInitMethod = class_getInstanceMethod(pickerClass, lcSwappedInitSel),
           !isOriginalImplementation(method_getImplementation(canonicalInitMethod)),
           isOriginalImplementation(method_getImplementation(origInitMethod)),
           let metaClass = object_getClass(pickerClass),
           let allocMethod = class_getInstanceMethod(metaClass, NSSelectorFromString("alloc")) {
            typealias AllocIMP = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
            typealias InitContentTypesIMP = @convention(c) (
                UnsafeMutableRawPointer,
                Selector,
                NSArray,
                ObjCBool
            ) -> UnsafeMutableRawPointer?

            let callAlloc = unsafeBitCast(method_getImplementation(allocMethod), to: AllocIMP.self)
            let callOrigInit = unsafeBitCast(method_getImplementation(origInitMethod), to: InitContentTypesIMP.self)
            let allocated = callAlloc(pickerClass, NSSelectorFromString("alloc"))
            let soleFolderTypes: NSArray = [UTType.folder] as NSArray
            if let initializedPtr = callOrigInit(allocated.toOpaque(), canonicalInitSel, soleFolderTypes, ObjCBool(false)) {
                controller = Unmanaged<UIDocumentPickerViewController>.fromOpaque(initializedPtr).takeRetainedValue()
            } else {
                controller = pickerClass.init(forOpeningContentTypes: [.folder])
            }
        } else {
            controller = pickerClass.init(forOpeningContentTypes: [.folder])
        }

        let canonicalMultiSel = NSSelectorFromString("setAllowsMultipleSelection:")
        let lcSwappedMultiSel = NSSelectorFromString("hook_setAllowsMultipleSelection:")
        if let canonicalMultiMethod = class_getInstanceMethod(pickerClass, canonicalMultiSel),
           let origMultiMethod = class_getInstanceMethod(pickerClass, lcSwappedMultiSel),
           !isOriginalImplementation(method_getImplementation(canonicalMultiMethod)),
           isOriginalImplementation(method_getImplementation(origMultiMethod)) {
            typealias SetBoolIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
            let callOrigSetMulti = unsafeBitCast(method_getImplementation(origMultiMethod), to: SetBoolIMP.self)
            callOrigSetMulti(controller, canonicalMultiSel, ObjCBool(false))
        } else {
            controller.allowsMultipleSelection = false
        }

        if let initialDirectoryURL {
            controller.directoryURL = initialDirectoryURL
        }
        return controller
    }
}

// MARK: - SwiftUI Picker Sheet, Files Launcher & Reusable Components

private struct CuriumSaveFolderPickerSheet: UIViewControllerRepresentable {
    let initialDirectoryURL: URL?
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = CuriumDocumentPickerBridge.makeFolderPickerController(
            initialDirectoryURL: initialDirectoryURL
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let first = urls.first {
                onPick(first)
            } else {
                onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

/// Opens the active Downloads folder directly in iOS Files.app via `shareddocuments://`.
@MainActor
enum CuriumSaveFolderFilesLauncher {
    static func openActiveDownloadsFolder() {
        guard CuriumDownloadsFolderManager.isDownloadsDirectoryVisibleInFiles else {
            return
        }
        guard let directoryURL = try? CuriumDownloadStorage.downloadsRootDirectory() else {
            return
        }
        if !CuriumDownloadsFolderManager.isUsingCustomDownloadsFolder {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let rawPath = directoryURL.standardizedFileURL.path
        guard !rawPath.isEmpty else {
            return
        }
        let encodedPath = rawPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawPath
        var seen: Set<String> = []
        let candidates: [URL] = [
            "shareddocuments://\(encodedPath)",
            "shareddocuments://\(rawPath)",
            "shareddocuments://",
        ].compactMap { candidate in
            guard seen.insert(candidate).inserted else { return nil }
            return URL(string: candidate)
        }

        openFirstSupported(candidates)
    }

    private static func openFirstSupported(_ candidates: [URL], index: Int = 0) {
        guard index < candidates.count else { return }
        UIApplication.shared.open(candidates[index], options: [:]) { success in
            if !success {
                openFirstSupported(candidates, index: index + 1)
            }
        }
    }
}

/// Per-sheet presentation state for `CuriumSaveLocationRow` and `.curiumSaveFolderPickerFlow(_:)`.
struct CuriumSaveFolderFlowState {
    struct PendingMove: Equatable {
        let sourceDir: URL
        let fileCount: Int
        let destinationName: String
        let isResetToDefault: Bool
    }

    var isShowingPicker: Bool = false
    var pendingMove: PendingMove? = nil
}

/// Native `.insetGrouped` row for selecting, revealing, or resetting Curium's Downloads folder.
struct CuriumSaveLocationRow: View {
    @Environment(\.curiumPalette) private var palette
    @Binding var flow: CuriumSaveFolderFlowState
    let accessibilityID: String
    var onFolderUpdated: (() -> Void)?

    private var folderManager = CuriumDownloadsFolderManager.shared

    init(
        flow: Binding<CuriumSaveFolderFlowState>,
        accessibilityID: String = "curium.downloads.saveLocation",
        onFolderUpdated: (() -> Void)? = nil
    ) {
        self._flow = flow
        self.accessibilityID = accessibilityID
        self.onFolderUpdated = onFolderUpdated
    }

    var body: some View {
        let _ = folderManager.revision
        let isDefaultVisibleInFiles = CuriumDownloadsFolderManager.isDownloadsDirectoryVisibleInFiles

        if case .defaultInternal = folderManager.status, !isDefaultVisibleInFiles {
            Button {
                flow.isShowingPicker = true
            } label: {
                rowContent(chevron: "chevron.right", isDefaultVisibleInFiles: false)
            }
            .foregroundStyle(Color.primary)
            .tint(Color.primary)
            .accessibilityIdentifier(accessibilityID)
        } else {
            Menu {
                switch folderManager.status {
                case .defaultInternal:
                    Button {
                        flow.isShowingPicker = true
                    } label: {
                        Label("Change Save Folder…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        CuriumDownloadsFolderManager.openActiveDownloadsFolder()
                    } label: {
                        Label("Show in Files", systemImage: "folder")
                    }
                case .customActive:
                    Button {
                        flow.isShowingPicker = true
                    } label: {
                        Label("Change Save Folder…", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        CuriumDownloadsFolderManager.openActiveDownloadsFolder()
                    } label: {
                        Label("Show in Files", systemImage: "folder")
                    }
                    Divider()
                    Button(role: .destructive) {
                        let offer = folderManager.resetToDefaultFolder()
                        if let src = offer.offerMoveFrom, offer.movableFileCount > 0 {
                            flow.pendingMove = CuriumSaveFolderFlowState.PendingMove(
                                sourceDir: src,
                                fileCount: offer.movableFileCount,
                                destinationName: CuriumDownloadsFolderManager.isDownloadsDirectoryVisibleInFiles
                                    ? "LiveContainer › Curium"
                                    : "App Storage",
                                isResetToDefault: true
                            )
                        }
                        onFolderUpdated?()
                    } label: {
                        Label("Reset to Default Storage", systemImage: "arrow.uturn.backward")
                    }
                case .needsHostGrant(let folderName, _, _):
                    Button {
                        flow.isShowingPicker = true
                    } label: {
                        Label("Grant Access to “\(folderName)”…", systemImage: "folder.badge.person.crop")
                    }
                    Divider()
                    Button(role: .destructive) {
                        _ = folderManager.resetToDefaultFolder()
                        onFolderUpdated?()
                    } label: {
                        Label("Reset to Default Storage", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                rowContent(chevron: "chevron.up.chevron.down", isDefaultVisibleInFiles: isDefaultVisibleInFiles)
            }
            .foregroundStyle(Color.primary)
            .tint(Color.primary)
            .accessibilityIdentifier(accessibilityID)
        }
    }

    @ViewBuilder
    private func rowContent(chevron: String, isDefaultVisibleInFiles: Bool) -> some View {
        HStack(spacing: 10) {
            Text("Save Location")
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Group {
                switch folderManager.status {
                case .defaultInternal:
                    Text(isDefaultVisibleInFiles ? "LiveContainer › Curium" : "App Storage")
                        .foregroundStyle(Color.secondary)
                case .customActive(_, _, let breadcrumb):
                    Text(breadcrumb)
                        .foregroundStyle(palette.tint)
                case .needsHostGrant(let folderName, _, _):
                    Label("Link “\(folderName)”", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            Image(systemName: chevron)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .contentShape(Rectangle())
    }
}

private struct CuriumSaveFolderPickerFlowModifier: ViewModifier {
    private struct PendingMismatchConfirmation {
        let pickedURL: URL
        let pickedName: String
        let expectedName: String
    }

    @Binding var flow: CuriumSaveFolderFlowState
    var onFolderUpdated: (() -> Void)?

    @State private var folderManager = CuriumDownloadsFolderManager.shared
    @State private var pendingMismatch: PendingMismatchConfirmation?
    @State private var rejectedErrorMessage: String?

    private var moveDialogTitle: String {
        guard let offer = flow.pendingMove else { return "" }
        let fileWord = offer.fileCount == 1 ? "Download" : "Downloads"
        if offer.isResetToDefault {
            return "Move \(offer.fileCount) \(fileWord) Back to Default?"
        }
        return "Move \(offer.fileCount) Existing \(fileWord)?"
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.isShowingPicker) {
                CuriumSaveFolderPickerSheet(
                    initialDirectoryURL: folderManager.suggestedPickerDirectoryURL,
                    onPick: { pickedURL in
                        flow.isShowingPicker = false
                        handlePick(pickedURL, forceSwitchSharedTarget: false)
                    },
                    onCancel: {
                        flow.isShowingPicker = false
                    }
                )
                .ignoresSafeArea()
            }
            .confirmationDialog(
                moveDialogTitle,
                isPresented: Binding(
                    get: { flow.pendingMove != nil },
                    set: { if !$0 { dismissMoveOffer() } }
                ),
                titleVisibility: .visible
            ) {
                if let offer = flow.pendingMove {
                    let fileWord = offer.fileCount == 1 ? "File" : "Files"
                    let moveLabel = offer.isResetToDefault
                        ? "Move \(offer.fileCount) \(fileWord)"
                        : "Move \(offer.fileCount) \(fileWord) to \(offer.destinationName)"
                    Button(moveLabel) {
                        let source = offer.sourceDir
                        flow.pendingMove = nil
                        Task { @MainActor in
                            _ = await folderManager.moveExistingFiles(from: source)
                            onFolderUpdated?()
                        }
                    }
                    Button("Leave in Previous Folder", role: .cancel) {
                        dismissMoveOffer()
                    }
                }
            } message: {
                if let offer = flow.pendingMove {
                    if offer.isResetToDefault {
                        Text("Files left in the previous folder remain safe in Files.")
                    } else {
                        Text("Move existing files once so everything lives in \(offer.destinationName). Left-behind files remain untouched in their previous location.")
                    }
                }
            }
            .confirmationDialog(
                "Different Folder Selected",
                isPresented: Binding(
                    get: { pendingMismatch != nil },
                    set: { if !$0 { pendingMismatch = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let mismatch = pendingMismatch {
                    Button("Switch All Instances to “\(mismatch.pickedName)”") {
                        let url = mismatch.pickedURL
                        pendingMismatch = nil
                        handlePick(url, forceSwitchSharedTarget: true)
                    }
                    Button("Pick “\(mismatch.expectedName)” Instead") {
                        pendingMismatch = nil
                        flow.isShowingPicker = true
                    }
                    Button("Cancel", role: .cancel) {
                        pendingMismatch = nil
                    }
                }
            } message: {
                if let mismatch = pendingMismatch {
                    Text("Another LiveContainer instance uses “\(mismatch.expectedName)”. Pick the same folder to share one library, or switch all instances to “\(mismatch.pickedName)”.")
                }
            }
            .alert(
                "Could Not Link Folder",
                isPresented: Binding(
                    get: { rejectedErrorMessage != nil },
                    set: { if !$0 { rejectedErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    rejectedErrorMessage = nil
                }
            } message: {
                Text(rejectedErrorMessage ?? "")
            }
    }

    private func handlePick(_ url: URL, forceSwitchSharedTarget: Bool) {
        let outcome = folderManager.adoptPickedFolder(url, forceSwitchSharedTarget: forceSwitchSharedTarget)
        switch outcome {
        case .linkedExistingSharedFolder:
            onFolderUpdated?()
        case .activated(let folderName, let offerMoveFrom, let count):
            onFolderUpdated?()
            if let source = offerMoveFrom, count > 0 {
                flow.pendingMove = CuriumSaveFolderFlowState.PendingMove(
                    sourceDir: source,
                    fileCount: count,
                    destinationName: folderName,
                    isResetToDefault: false
                )
            }
        case .confirmSwitchFromExpected(let pickedURL, let pickedName, let expectedName):
            pendingMismatch = PendingMismatchConfirmation(
                pickedURL: pickedURL,
                pickedName: pickedName,
                expectedName: expectedName
            )
        case .rejected(let message):
            rejectedErrorMessage = message
        }
    }

    private func dismissMoveOffer() {
        flow.pendingMove = nil
        folderManager.dismissPendingMoveOffer()
        onFolderUpdated?()
    }
}

extension View {
    func curiumSaveFolderPickerFlow(
        _ flow: Binding<CuriumSaveFolderFlowState>,
        onFolderUpdated: (() -> Void)? = nil
    ) -> some View {
        modifier(CuriumSaveFolderPickerFlowModifier(flow: flow, onFolderUpdated: onFolderUpdated))
    }
}
