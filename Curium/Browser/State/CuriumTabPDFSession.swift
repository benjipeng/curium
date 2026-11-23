import CuriumEngineContract
import Foundation
import Observation
import PDFKit
import UIKit
import os

/// Single flattened entry from a PDF's embedded Table of Contents (`PDFOutline`).
struct CuriumPDFOutlineItem: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let pageIndex: Int
    let depth: Int
}

/// Uniquely transfers a newly created or copied non-Sendable PDFKit value onto `@MainActor`.
private final class CuriumPDFTransferBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Nonisolated `PDFDocumentDelegate` bridge so PDFKit's background find callbacks never
/// trigger Swift 6 dynamic `@MainActor` isolation traps, tagged with a generation token
/// to drop callbacks from cancelled queries and coalescing matches into ~50 ms batches.
private final class CuriumPDFSearchDelegate: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    private struct BufferState: Sendable {
        var pending: [CuriumPDFTransferBox<PDFSelection>] = []
        var totalDelivered = 0
        var flushScheduled = false
        var ended = false
    }

    private weak var session: CuriumTabPDFSession?
    private let generation: UInt64
    private let maxMatches: Int
    private let batchInterval: Duration
    private let state = OSAllocatedUnfairLock(initialState: BufferState())

    init(
        session: CuriumTabPDFSession,
        generation: UInt64,
        maxMatches: Int,
        batchInterval: Duration = .milliseconds(50)
    ) {
        self.session = session
        self.generation = generation
        self.maxMatches = maxMatches
        self.batchInterval = batchInterval
    }

    func didMatchString(_ instance: PDFSelection) {
        guard let copy = instance.copy() as? PDFSelection else { return }
        let boxedCopy = CuriumPDFTransferBox(copy)
        enum Action { case none, scheduleFlush, flushNowAndCap }
        let action: Action = state.withLock { s in
            guard !s.ended, s.totalDelivered < maxMatches else { return .none }
            s.pending.append(boxedCopy)
            s.totalDelivered += 1
            if s.totalDelivered >= maxMatches {
                s.ended = true
                return .flushNowAndCap
            }
            if !s.flushScheduled {
                s.flushScheduled = true
                return .scheduleFlush
            }
            return .none
        }
        switch action {
        case .none:
            break
        case .scheduleFlush:
            let interval = batchInterval
            Task.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(for: interval)
                self?.flushPendingToMain(finished: false, hitCap: false)
            }
        case .flushNowAndCap:
            flushPendingToMain(finished: true, hitCap: true)
        }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        let shouldFlush = state.withLock { s -> Bool in
            if s.ended && s.pending.isEmpty { return false }
            s.ended = true
            return true
        }
        guard shouldFlush else { return }
        flushPendingToMain(finished: true, hitCap: false)
    }

    private func flushPendingToMain(finished: Bool, hitCap: Bool) {
        let drained: [CuriumPDFTransferBox<PDFSelection>] = state.withLock { s in
            s.flushScheduled = false
            let batch = s.pending
            s.pending.removeAll(keepingCapacity: !finished)
            return batch
        }
        guard !drained.isEmpty || finished else { return }
        let gen = generation
        DispatchQueue.main.async { [weak session] in
            MainActor.assumeIsolated {
                guard let session else { return }
                if !drained.isEmpty {
                    session.recordSearchMatches(drained.map(\.value), generation: gen)
                }
                if hitCap {
                    session.cancelFindAtCap(generation: gen)
                } else if finished {
                    session.finishSearch(generation: gen)
                }
            }
        }
    }
}

/// Lifecycle controller for an inline PDF open inside a single browser tab.
///
/// Remote PDFs stream into an isolated temporary preview cache (`Caches/CuriumPDFPreview/`)
/// so browsing a PDF never pollutes `Documents/Curium/Downloads/`. Explicit user Save
/// promotes the file into durable Downloads. Closing the session or tab removes the
/// temporary preview directory automatically.
@MainActor
@Observable
final class CuriumTabPDFSession: Identifiable {
    enum Phase: Equatable {
        case loading(progress: Double?)
        case ready
        case failed(String)
    }

    private nonisolated static let maxOutlineDepth = 32
    private nonisolated static let maxOutlineItems = 400
    private static let maxSearchMatches = 500
    private static let searchDebounceDelay: Duration = .milliseconds(150)
    private static let defaultThumbnailMaxPixels: CGFloat = 768

    private struct ParsedDocumentPayload: @unchecked Sendable {
        let document: PDFDocument
        let outline: [CuriumPDFOutlineItem]
    }

    let id = UUID()
    let filename: String
    let originalURL: URL?

    private(set) var phase: Phase
    private(set) var localFileURL: URL?
    private(set) var document: PDFDocument?
    private(set) var pageCount = 0
    private(set) var currentPageIndex = 0
    private(set) var outlineItems: [CuriumPDFOutlineItem] = []

    /// Search state driven by the floating Find-in-PDF bar.
    var isSearching = false
    var searchQuery = ""
    private(set) var searchMatches: [PDFSelection] = []
    private(set) var activeMatchIndex = 0
    private(set) var isSearchInProgress = false
    private(set) var highlightRevision = 0
    private(set) var navigationRequestID = 0
    private(set) var requestedPageIndex: Int?
    private(set) var requestedSelection: PDFSelection?
    private(set) var requestedZoomScale: CGFloat?
    private(set) var zoomScale: CGFloat = 1.0

    /// Populated once the user explicitly saves this PDF (or when opened from Saved Downloads).
    private(set) var savedDownloadURL: URL?
    private(set) var isSaving = false
    private(set) var saveError: String?

    @ObservationIgnored private var downloadTask: (any CrIOSDownloadTaskV1)?
    @ObservationIgnored private var ephemeralDirectory: URL?
    @ObservationIgnored private let cacheRootOverride: URL?
    @ObservationIgnored private let onReady: (@MainActor () -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var cachedThumbnail: (pageIndex: Int, maxPixels: CGFloat, image: UIImage)?
    @ObservationIgnored private var searchDelegate: CuriumPDFSearchDelegate?
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var isCleanedUp = false

    var displayTitle: String { filename }
    var displayURL: URL? { originalURL ?? savedDownloadURL }
    var isSavedToDownloads: Bool { savedDownloadURL != nil }
    var isOpenedFromSavedFile: Bool { savedDownloadURL != nil && localFileURL == savedDownloadURL }

    var canRetry: Bool {
        if case .failed = phase { return originalURL != nil }
        return false
    }

    /// Starts streaming a remote PDF download into the isolated temporary preview cache.
    init(
        downloadTask: any CrIOSDownloadTaskV1,
        cacheRoot: URL? = nil,
        onReady: (@MainActor () -> Void)? = nil
    ) {
        self.downloadTask = downloadTask
        self.cacheRootOverride = cacheRoot
        self.onReady = onReady
        self.originalURL = downloadTask.originalURL
        self.filename = CuriumDownloadStorage.sanitizedFilename(
            downloadTask.suggestedFilename,
            fallback: downloadTask.originalURL?.lastPathComponent.isEmpty == false
                ? CuriumDownloadStorage.sanitizedFilename(downloadTask.originalURL?.lastPathComponent, fallback: "Document.pdf")
                : "Document.pdf"
        )
        self.phase = .loading(progress: nil)
        beginDownload(cacheRoot: cacheRoot)
    }

    /// Opens an already-saved PDF file from durable Downloads directly inside a tab.
    init(
        savedFileURL: URL,
        filename: String? = nil,
        onReady: (@MainActor () -> Void)? = nil
    ) {
        self.cacheRootOverride = nil
        self.onReady = onReady
        self.originalURL = nil
        self.savedDownloadURL = savedFileURL
        self.localFileURL = savedFileURL
        self.filename = CuriumDownloadStorage.sanitizedFilename(
            filename ?? savedFileURL.lastPathComponent,
            fallback: "Document.pdf"
        )
        self.phase = .loading(progress: nil)
        loadExistingFile(at: savedFileURL)
    }

    isolated deinit {
        cleanup()
    }

    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        loadTask?.cancel()
        loadTask = nil
        progressTask?.cancel()
        progressTask = nil
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        cachedThumbnail = nil
        searchGeneration &+= 1
        document?.cancelFindString()
        document?.delegate = nil
        searchDelegate = nil
        if let task = downloadTask, task.state == .pending || task.state == .inProgress {
            task.cancel()
        }
        downloadTask = nil
        if let ephemeralDirectory {
            let rootOverride = cacheRootOverride
            self.ephemeralDirectory = nil
            Task.detached(priority: .utility) {
                CuriumDownloadStorage.removePreviewSessionDirectory(ephemeralDirectory, cacheRoot: rootOverride)
            }
        }
    }

    func updateCurrentPage(_ index: Int) {
        guard pageCount > 0 else { return }
        let clamped = min(max(0, index), pageCount - 1)
        if currentPageIndex != clamped {
            currentPageIndex = clamped
        }
    }

    func updateObservedZoomScale(_ scale: CGFloat) {
        let clamped = min(4.0, max(0.5, scale))
        if abs(zoomScale - clamped) > 0.01 {
            zoomScale = clamped
        }
    }

    func jumpToPage(_ index: Int) {
        guard pageCount > 0 else { return }
        let clamped = min(max(0, index), pageCount - 1)
        currentPageIndex = clamped
        requestedSelection = nil
        requestedZoomScale = nil
        requestedPageIndex = clamped
        navigationRequestID &+= 1
    }

    func setZoomScale(_ scale: CGFloat) {
        let clamped = min(2.5, max(0.5, scale))
        zoomScale = clamped
        requestedPageIndex = nil
        requestedSelection = nil
        requestedZoomScale = clamped
        navigationRequestID &+= 1
    }

    func openSearch() {
        guard case .ready = phase else { return }
        isSearching = true
    }

    func closeSearch() {
        isSearching = false
        searchQuery = ""
        cancelSearch()
    }

    func performSearch(query: String) {
        searchQuery = query
        cancelSearch()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, document != nil else { return }

        isSearchInProgress = true
        let generation = searchGeneration
        searchDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.searchDebounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.searchDebounceTask = nil
            self.startSearch(trimmed, generation: generation)
        }
    }

    private func startSearch(_ trimmed: String, generation: UInt64) {
        guard generation == searchGeneration, !isCleanedUp, let document else { return }
        let delegate = CuriumPDFSearchDelegate(
            session: self,
            generation: generation,
            maxMatches: Self.maxSearchMatches
        )
        searchDelegate = delegate
        document.delegate = delegate
        document.beginFindString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    func nextSearchMatch() {
        guard !searchMatches.isEmpty else { return }
        activeMatchIndex = (activeMatchIndex + 1) % searchMatches.count
        focusActiveSearchMatch()
    }

    func previousSearchMatch() {
        guard !searchMatches.isEmpty else { return }
        activeMatchIndex = (activeMatchIndex - 1 + searchMatches.count) % searchMatches.count
        focusActiveSearchMatch()
    }

    /// Explicitly copies the cached PDF into durable `Documents/Curium/Downloads/`.
    @discardableResult
    func saveToDownloads(downloadsRoot: URL? = nil) async -> URL? {
        if let existing = savedDownloadURL {
            return existing
        }
        guard let sourceURL = localFileURL, !isSaving else { return nil }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let name = filename
        do {
            let destination = try await Task.detached(priority: .utility) {
                try CuriumDownloadStorage.savePreviewFileToDownloads(
                    sourceURL: sourceURL,
                    suggestedFilename: name,
                    downloadsRoot: downloadsRoot
                )
            }.value
            savedDownloadURL = destination
            return destination
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }

    func clearSaveError() {
        saveError = nil
    }

    /// Clears `savedDownloadURL` when the saved copy was deleted from Downloads while the
    /// ephemeral preview copy is still open in a tab. Returns `true` if the tab was reading
    /// directly from the deleted saved file itself and should be closed.
    @discardableResult
    func handleSavedFileDeleted(at deletedURL: URL) -> Bool {
        let canonicalDeleted = deletedURL.resolvingSymlinksInPath().standardizedFileURL
        guard let currentSaved = savedDownloadURL else { return false }
        let canonicalSaved = currentSaved.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalSaved == canonicalDeleted else { return false }
        if isOpenedFromSavedFile {
            return true
        }
        savedDownloadURL = nil
        return false
    }

    /// Renders a compact thumbnail of the current PDF page for the Tabs grid, returning
    /// an off-main pre-rendered image when available to keep `@MainActor` free.
    func makeTabThumbnail(maxPixels: CGFloat = 768) -> UIImage? {
        if let cached = cachedThumbnail,
           cached.pageIndex == currentPageIndex,
           abs(cached.maxPixels - maxPixels) < 0.5 {
            return cached.image
        }
        guard let document, let page = document.page(at: currentPageIndex) ?? document.page(at: 0) else {
            return nil
        }
        return Self.renderThumbnail(from: page, maxPixels: maxPixels)
    }

    /// Renders a compact thumbnail off `@MainActor` from the backing PDF file on disk.
    func makeTabThumbnailAsync(maxPixels: CGFloat = 768) async -> UIImage? {
        if let cached = cachedThumbnail,
           cached.pageIndex == currentPageIndex,
           abs(cached.maxPixels - maxPixels) < 0.5 {
            return cached.image
        }
        guard let fileURL = localFileURL else {
            return makeTabThumbnail(maxPixels: maxPixels)
        }
        let targetPage = currentPageIndex
        let rendered = await Task.detached(priority: .utility) {
            Self.renderThumbnail(from: fileURL, pageIndex: targetPage, maxPixels: maxPixels)
        }.value
        guard !Task.isCancelled, !isCleanedUp else { return nil }
        if let rendered {
            cachedThumbnail = (pageIndex: targetPage, maxPixels: maxPixels, image: rendered)
        }
        return rendered
    }

    private func prewarmTabThumbnail(forPage pageIndex: Int, maxPixels: CGFloat) {
        guard let fileURL = localFileURL else { return }
        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .utility) {
                Self.renderThumbnail(from: fileURL, pageIndex: pageIndex, maxPixels: maxPixels)
            }.value
            guard !Task.isCancelled, let self, !self.isCleanedUp else { return }
            if let rendered {
                self.cachedThumbnail = (pageIndex: pageIndex, maxPixels: maxPixels, image: rendered)
            }
            self.thumbnailTask = nil
        }
    }

    private nonisolated static func renderThumbnail(
        from fileURL: URL,
        pageIndex: Int,
        maxPixels: CGFloat
    ) -> UIImage? {
        guard let doc = PDFDocument(url: fileURL),
              let page = doc.page(at: pageIndex) ?? doc.page(at: 0) else {
            return nil
        }
        return renderThumbnail(from: page, maxPixels: maxPixels)
    }

    private nonisolated static func renderThumbnail(from page: PDFPage, maxPixels: CGFloat) -> UIImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let longest = max(bounds.width, bounds.height)
        let factor = min(1.0, maxPixels / longest)
        let target = CGSize(
            width: max(1, (bounds.width * factor).rounded()),
            height: max(1, (bounds.height * factor).rounded())
        )
        return page.thumbnail(of: target, for: .cropBox)
    }

    // MARK: - Private Loading & Search

    private func beginDownload(cacheRoot: URL?) {
        guard let task = downloadTask else {
            phase = .failed("The PDF download task is no longer available.")
            return
        }
        let name = filename
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let destination = try await Task.detached(priority: .utility) {
                    try CuriumDownloadStorage.makePreviewDestination(filename: name, cacheRoot: cacheRoot)
                }.value
                guard !Task.isCancelled, !self.isCleanedUp else {
                    CuriumDownloadStorage.removePreviewSessionDirectory(destination.sessionDirectory, cacheRoot: cacheRoot)
                    return
                }
                self.ephemeralDirectory = destination.sessionDirectory
                self.startProgressPolling(for: task)
                let resolvedURL = try await task.start(withDestinationURL: destination.fileURL)
                self.progressTask?.cancel()
                self.progressTask = nil
                guard !Task.isCancelled, !self.isCleanedUp else { return }
                self.localFileURL = resolvedURL
                await self.openParsedDocument(at: resolvedURL)
            } catch {
                self.progressTask?.cancel()
                self.progressTask = nil
                guard !Task.isCancelled, !self.isCleanedUp else { return }
                if task.state == .cancelled {
                    self.phase = .failed("PDF download was canceled.")
                } else {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func loadExistingFile(at fileURL: URL) {
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.openParsedDocument(at: fileURL)
        }
    }

    private func startProgressPolling(for task: any CrIOSDownloadTaskV1) {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, case .loading = self.phase else { break }
                let total = task.totalBytes
                let nextFraction: Double? = total > 0
                    ? min(1, max(0, Double(task.receivedBytes) / Double(total)))
                    : nil
                let next: Phase = .loading(progress: nextFraction)
                if self.phase != next {
                    self.phase = next
                }
                if task.state != .inProgress && task.state != .pending {
                    break
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
    }

    private func openParsedDocument(at fileURL: URL) async {
        let payload = await Task.detached(priority: .userInitiated) { () -> ParsedDocumentPayload? in
            guard let doc = PDFDocument(url: fileURL), doc.pageCount > 0 else {
                return nil
            }
            let outline = Self.flattenOutline(from: doc)
            return ParsedDocumentPayload(document: doc, outline: outline)
        }.value
        guard !Task.isCancelled, !isCleanedUp else { return }
        guard let payload else {
            phase = .failed("Curium couldn’t read this file as a PDF.")
            return
        }
        document = payload.document
        pageCount = payload.document.pageCount
        currentPageIndex = 0
        outlineItems = payload.outline
        phase = .ready
        prewarmTabThumbnail(forPage: 0, maxPixels: Self.defaultThumbnailMaxPixels)
        onReady?()
    }

    private func cancelSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchGeneration &+= 1
        document?.cancelFindString()
        document?.delegate = nil
        searchDelegate = nil
        isSearchInProgress = false
        if !searchMatches.isEmpty {
            searchMatches = []
            highlightRevision &+= 1
        }
        activeMatchIndex = 0
        requestedSelection = nil
    }

    fileprivate func recordSearchMatches(_ selections: [PDFSelection], generation: UInt64) {
        guard generation == searchGeneration, !isCleanedUp else { return }
        let remaining = Self.maxSearchMatches - searchMatches.count
        guard remaining > 0 else {
            document?.cancelFindString()
            isSearchInProgress = false
            return
        }
        let hadMatches = !searchMatches.isEmpty
        let accepted = selections.prefix(remaining)
        for selection in accepted {
            selection.color = UIColor.systemYellow.withAlphaComponent(0.45)
            searchMatches.append(selection)
        }
        guard !accepted.isEmpty else { return }
        highlightRevision &+= 1
        if !hadMatches {
            activeMatchIndex = 0
            focusActiveSearchMatch()
        }
        if searchMatches.count >= Self.maxSearchMatches {
            document?.cancelFindString()
            isSearchInProgress = false
        }
    }

    fileprivate func cancelFindAtCap(generation: UInt64) {
        guard generation == searchGeneration, !isCleanedUp else { return }
        document?.cancelFindString()
        isSearchInProgress = false
    }

    fileprivate func finishSearch(generation: UInt64) {
        guard generation == searchGeneration, !isCleanedUp else { return }
        isSearchInProgress = false
    }

    private func focusActiveSearchMatch() {
        guard searchMatches.indices.contains(activeMatchIndex) else { return }
        let match = searchMatches[activeMatchIndex]
        if let page = match.pages.first, let document {
            let idx = document.index(for: page)
            if idx != NSNotFound {
                currentPageIndex = idx
            }
        }
        requestedPageIndex = nil
        requestedZoomScale = nil
        requestedSelection = match
        navigationRequestID &+= 1
    }

    private nonisolated static func flattenOutline(from document: PDFDocument) -> [CuriumPDFOutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        var items: [CuriumPDFOutlineItem] = []

        func walk(_ node: PDFOutline, depth: Int) {
            guard depth < maxOutlineDepth, items.count < maxOutlineItems else { return }
            for index in 0..<node.numberOfChildren {
                guard items.count < maxOutlineItems else { return }
                guard let child = node.child(at: index) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if !label.isEmpty,
                   let page = destination?.page,
                   case let pageIdx = document.index(for: page),
                   pageIdx != NSNotFound {
                    items.append(
                        CuriumPDFOutlineItem(
                            id: items.count,
                            title: label,
                            pageIndex: pageIdx,
                            depth: min(depth, 4)
                        )
                    )
                }
                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)
        return items
    }
}
