import CuriumEngineContract
import Foundation
import Observation

@MainActor
@Observable
final class CuriumDownload: Identifiable {
    let id: String
    let sourceTabID: String?
    let originalURL: URL?
    private(set) var filename: String
    let mimeType: String?
    let isExplicitDownload: Bool
    let isMainFrame: Bool
    let httpMethod: String
    private let task: any CrIOSDownloadTaskV1
    private(set) var state: CrIOSDownloadState
    private(set) var savedURL: URL?
    private(set) var failure: String?
    private(set) var fraction: Double?
    private(set) var totalBytes: Int64 = -1
    private(set) var receivedBytes: Int64 = 0
    private(set) var isStarting = false
    @ObservationIgnored var onActivityChange: (@MainActor () -> Void)?

    var isActive: Bool { isStarting || state == .inProgress }

    init(task: any CrIOSDownloadTaskV1) {
        self.task = task
        id = task.downloadID
        sourceTabID = task.sourceTabID
        originalURL = task.originalURL
        filename = CuriumDownloadStorage.sanitizedFilename(task.suggestedFilename)
        mimeType = task.mimeType
        isExplicitDownload = task.isExplicitDownload ?? false
        isMainFrame = task.isMainFrame ?? true
        let method = (task.httpMethod ?? "GET").trimmingCharacters(in: .whitespacesAndNewlines)
        httpMethod = method.isEmpty ? "GET" : method.uppercased()
        state = task.state
        refresh()
    }

    var isPDF: Bool {
        CuriumDownloadStorage.isPDF(mimeType: mimeType, filename: filename, url: originalURL)
    }

    var isVideo: Bool {
        CuriumDownloadStorage.isVideo(mimeType: mimeType, filename: filename, url: originalURL)
    }

    var isAudio: Bool {
        CuriumDownloadStorage.isAudio(mimeType: mimeType, filename: filename, url: originalURL)
    }

    var symbolName: String {
        CuriumDownloadStorage.symbolName(mimeType: mimeType, filename: filename, url: originalURL)
    }

    var formattedByteSize: String? {
        guard totalBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    func refresh() {
        let newState = task.state
        if state != newState { state = newState }
        let total = task.totalBytes
        if totalBytes != total { totalBytes = total }
        let received = task.receivedBytes
        if receivedBytes != received { receivedBytes = received }
        let newFraction: Double? = total > 0
            ? min(1, max(0, Double(received) / Double(total)))
            : nil
        if fraction != newFraction { fraction = newFraction }
    }

    @discardableResult
    func start(downloadsRoot: URL? = nil) async -> URL? {
        guard state == .pending, !isStarting else { return savedURL }
        isStarting = true
        failure = nil
        onActivityChange?()
        defer {
            isStarting = false
            refresh()
            onActivityChange?()
        }
        let name = filename

        if downloadsRoot == nil && CuriumDownloadsFolderManager.isUsingCustomDownloadsFolder {
            var stagingDirectory: URL?
            defer {
                if let stagingDirectory {
                    CuriumDownloadStorage.removeDownloadStagingDirectory(stagingDirectory)
                }
            }
            do {
                let staged = try await Task.detached(priority: .utility) {
                    try CuriumDownloadStorage.makeDownloadStagingDestination(filename: name)
                }.value
                stagingDirectory = staged.sessionDirectory
                let downloadedURL = try await task.start(withDestinationURL: staged.fileURL)
                let commitName = downloadedURL.lastPathComponent.isEmpty ? name : downloadedURL.lastPathComponent
                let sessionToClean = staged.sessionDirectory
                let committedURL = try await Task.detached(priority: .utility) {
                    defer {
                        CuriumDownloadStorage.removeDownloadStagingDirectory(sessionToClean)
                    }
                    let destinationDirectory = try CuriumDownloadStorage.downloadsRootDirectory()
                    return try CuriumDownloadStorage.commitStagedFile(
                        from: downloadedURL,
                        toDirectory: destinationDirectory,
                        preferredFilename: commitName,
                        removeSource: true
                    )
                }.value
                stagingDirectory = nil
                savedURL = committedURL
                let finalName = committedURL.lastPathComponent
                if !finalName.isEmpty && finalName != filename {
                    filename = finalName
                }
                return savedURL
            } catch {
                if task.state != .cancelled { failure = error.localizedDescription }
                return nil
            }
        }

        var reservedURL: URL?
        defer {
            if let reservedURL {
                CuriumDownloadStorage.releaseDownloadReservation(at: reservedURL)
            }
        }
        do {
            let destination = try await Task.detached(priority: .utility) {
                try CuriumDownloadStorage.uniqueDownloadDestination(filename: name, in: downloadsRoot)
            }.value
            reservedURL = destination
            let resolved = try await task.start(withDestinationURL: destination)
            savedURL = resolved
            let finalName = resolved.lastPathComponent
            if !finalName.isEmpty && finalName != filename {
                filename = finalName
            }
            return savedURL
        } catch {
            if task.state != .cancelled { failure = error.localizedDescription }
            return nil
        }
    }

    func cancel() {
        task.cancel()
        refresh()
        onActivityChange?()
    }
}
