import Foundation
import Observation

// MARK: - Contract
// CuriumLibrary is the app's durable memory: bookmarks, history, and the
// search engine. Views read and mutate it on the main actor; all disk work
// runs off the main actor in CuriumDatabase. The types and signatures in this
// file are the contract shared by the address bar, the Library sheet, and the
// browser store. Change them only together with every caller.

enum CuriumSearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case google, duckDuckGo, brave, bing

    var id: Self { self }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave Search"
        case .bing: "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .google: components.host = "www.google.com"; components.path = "/search"
        case .duckDuckGo: components.host = "duckduckgo.com"; components.path = "/"
        case .brave: components.host = "search.brave.com"; components.path = "/search"
        case .bing: components.host = "www.bing.com"; components.path = "/search"
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

/// One page in one day of history; repeated visits that day collapse into it.
struct CuriumHistoryEntry: Identifiable, Hashable, Sendable {
    let siteID: Int64
    let url: URL
    let title: String
    let lastVisit: Date
    let visitsThatDay: Int
    let host: String

    init(siteID: Int64, url: URL, title: String, lastVisit: Date, visitsThatDay: Int) {
        self.siteID = siteID
        self.url = url
        self.title = title
        self.lastVisit = lastVisit
        self.visitsThatDay = visitsThatDay
        self.host = url.host() ?? url.absoluteString
    }

    var id: String { "\(siteID)@\(Int(lastVisit.timeIntervalSince1970))" }
}

struct CuriumHistoryDay: Identifiable, Sendable {
    /// Local midnight that starts the day.
    let day: Date
    let entries: [CuriumHistoryEntry]
    var id: Date { day }
}

struct CuriumAddressMatch: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case bookmark, history }
    let kind: Kind
    let url: URL
    let title: String
    var id: URL { url }
}

enum CuriumHistoryClearRange: CaseIterable, Identifiable, Sendable {
    case lastHour, today, todayAndYesterday, all

    var id: Self { self }

    var title: String {
        switch self {
        case .lastHour: "Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .all: "All History"
        }
    }

    /// Start of the range, or nil for all history.
    func start(now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .today: calendar.startOfDay(for: now)
        case .todayAndYesterday: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .all: nil
        }
    }
}

@MainActor
@Observable
final class CuriumLibrary {
    private static let legacySearchEngineKey = "curium.searchEngine"

    let profileID: String
    @ObservationIgnored private let state: State
    @ObservationIgnored private let fingerprintStore: CuriumFingerprintStore

    var bookmarks: CuriumBookmarkTree { state.bookmarks }
    var favoriteBookmarks: [CuriumBookmark] { bookmarks.favorites }
    var favorites: [CuriumBookmark] { favoriteBookmarks }
    var bookmarkRevision: Int { state.bookmarkRevision }
    /// Set once the database cannot be opened; every write after that is lost.
    var storageUnavailable: Bool { state.storageUnavailable }

    /// Increments after every history mutation so views can re-query.
    private(set) var historyRevision: Int {
        get { state.historyRevision }
        set { state.historyRevision = newValue }
    }

    var searchEngine: CuriumSearchEngine {
        get {
            if let profile = fingerprintStore.profile(id: profileID) {
                return profile.resolvedSearchEngine
            }
            if profileID == "default" {
                let raw = UserDefaults.standard.string(forKey: Self.legacySearchEngineKey)
                return raw.flatMap(CuriumSearchEngine.init(rawValue:)) ?? .google
            }
            return .google
        }
        set {
            _ = fingerprintStore.updatePersonaMetadata(for: profileID, searchEngine: newValue)
            if profileID == "default" {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.legacySearchEngineKey)
            }
        }
    }

    // Each window in a profile has a library facade. All windows within the same
    // profile observe the same snapshot and submit writes in order to that profile's DB.
    @MainActor
    @Observable
    fileprivate final class State {
        var bookmarks = CuriumBookmarkTree() {
            didSet { bookmarkRevision += 1 }
        }
        private(set) var bookmarkRevision = 0
        var historyRevision = 0
        var storageUnavailable = false

        let profileID: String
        let database: CuriumDatabase
        @ObservationIgnored var pendingMutation: Task<Bool, Never>?
        @ObservationIgnored var hasLoadedBookmarks = false

        init(profileID: String, database: CuriumDatabase) {
            self.profileID = profileID
            self.database = database
        }
    }

    @MainActor
    private static var statesByProfileID: [String: State] = [:]

    private static func sharedState(for profileID: String) -> State {
        let key = profileID.lowercased()
        if let existing = statesByProfileID[key] {
            return existing
        }
        let created = State(profileID: profileID, database: CuriumDatabase.shared(forProfile: profileID))
        statesByProfileID[key] = created
        return created
    }

    init(
        profileID: String = "default",
        database: CuriumDatabase? = nil,
        fingerprintStore: CuriumFingerprintStore? = nil
    ) {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = trimmed.isEmpty ? "default" : trimmed
        self.profileID = resolvedID
        self.fingerprintStore = fingerprintStore ?? CuriumFingerprintStore.shared
        if let database {
            self.state = State(profileID: resolvedID, database: database)
        } else {
            self.state = Self.sharedState(for: resolvedID)
        }
        guard state.pendingMutation == nil else { return }
        enqueue { library in
            library.bookmarks = try await library.database.bookmarkTree()
            library.hasLoadedBookmarks = true
        }
    }

    /// Preserve submission order, including when a title follows its visit or a
    /// checkpoint follows a write. SQLite itself never runs on the main actor.
    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor (State) async throws -> Void) -> Task<Bool, Never> {
        let state = self.state
        let previous = state.pendingMutation
        let task = Task { @MainActor in
            _ = await previous?.value
            do {
                try await operation(state)
                return true
            } catch {
                if CuriumDatabase.isUnavailable(error), !state.storageUnavailable {
                    state.storageUnavailable = true
                }
                CuriumDatabase.report(error)
                return false
            }
        }
        state.pendingMutation = task
        return task
    }

    private func record(_ error: any Error) {
        if CuriumDatabase.isUnavailable(error), !state.storageUnavailable {
            state.storageUnavailable = true
        }
        CuriumDatabase.report(error)
    }

    private func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host()?.isEmpty == false
    }

    // MARK: History

    /// Records a committed top-level navigation. Ignores non-web schemes.
    func recordVisit(url: URL, title: String) {
        guard isWebURL(url) else { return }
        let date = Date.now
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        enqueue { library in
            try await library.database.recordVisit(url: url, title: title, at: date)
            library.historyRevision += 1
        }
    }

    /// Updates the stored title once the page reports it.
    func updateTitle(_ title: String, for url: URL) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, isWebURL(url) else { return }
        enqueue { library in
            if try await library.database.updateTitle(title, for: url) {
                library.historyRevision += 1
            }
        }
    }

    /// Days newest first; entries newest first within a day. An empty query returns everything up to `limit` entries.
    func historyDays(matching query: String, limit: Int = 600) async -> [CuriumHistoryDay] {
        _ = await state.pendingMutation?.value
        guard !Task.isCancelled else { return [] }
        do {
            return try await state.database.historyDays(matching: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        limit: limit, calendar: .current)
        } catch is CancellationError {
            return []
        } catch {
            record(error)
            return []
        }
    }

    /// Removes the visits behind one entry (that page, that day).
    func delete(_ entry: CuriumHistoryEntry) async {
        guard let day = Calendar.current.dateInterval(of: .day, for: entry.lastVisit) else { return }
        _ = await enqueue { library in
            try await library.database.delete(siteID: entry.siteID, url: entry.url, day: day)
            library.historyRevision += 1
        }.value
    }

    func clearHistory(_ range: CuriumHistoryClearRange) async {
        let start = range.start()
        _ = await enqueue { library in
            try await library.database.clearHistory(since: start)
            library.historyRevision += 1
        }.value
    }

    // MARK: Bookmarks

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.isBookmarked(url)
    }

    func bookmark(for url: URL) async -> CuriumBookmark? {
        _ = await state.pendingMutation?.value
        return bookmarks.bookmark(for: url)
    }

    func saveBookmark(url: URL, title: String, in folderID: Int64?) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = Date.now
        return await mutateBookmarks { try await $0.saveBookmark(url: url, title: title, in: folderID, at: date) }.value
    }

    func saveBookmarkFolder(id: Int64?, title: String, in folderID: Int64?) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let date = Date.now
        return await mutateBookmarks { try await $0.saveBookmarkFolder(id: id, title: title, in: folderID, at: date) }.value
    }

    func deleteBookmarkItem(_ item: CuriumBookmarkItem) {
        mutateBookmarks { try await $0.deleteBookmarkItem(item.id) }
    }

    func moveBookmarkItems(in folderID: Int64?, fromOffsets source: IndexSet, toOffset destination: Int) {
        reorderBookmarks(bookmarks.items(in: folderID).map(\.id), in: folderID, from: source, to: destination)
    }

    private func reorderBookmarks(_ original: [Int64], in folderID: Int64?, from source: IndexSet, to destination: Int) {
        guard let last = source.last, original.indices.contains(last),
              (0...original.count).contains(destination) else { return }
        var ids = original
        let moved = source.map { ids[$0] }
        for offset in source.reversed() { ids.remove(at: offset) }
        ids.insert(contentsOf: moved, at: destination - source.count(in: 0..<destination))
        guard ids != original else { return }
        mutateBookmarks { [ids] in try await $0.reorderBookmarks(in: folderID, ids: ids) }
    }

    @discardableResult
    private func mutateBookmarks(
        _ operation: @escaping @MainActor (CuriumDatabase) async throws -> CuriumBookmarkTree
    ) -> Task<Bool, Never> {
        enqueue { library in
            library.bookmarks = try await operation(library.database)
            library.hasLoadedBookmarks = true
        }
    }


    // MARK: Address bar

    /// Bookmarks first, then history ranked by frequency and recency. No network suggestions.
    func addressMatches(for text: String, limit: Int = 6) async -> [CuriumAddressMatch] {
        guard limit > 0, !Task.isCancelled else { return [] }
        let needle = Self.normalizedNeedle(for: text)
        guard !needle.isEmpty else { return [] }

        if state.hasLoadedBookmarks {
            let bookmarkMatches = Self.matchingBookmarks(in: state.bookmarks, needle: needle, limit: limit)
            if bookmarkMatches.count >= limit { return bookmarkMatches }
            let excluded = Set(bookmarkMatches.map { $0.url.absoluteString })
            do {
                // WAL allows concurrent reads without stalling behind queued write/checkpoint chains.
                let history = try await state.database.historyAddressMatches(
                    for: text,
                    excludingURLs: excluded,
                    limit: limit - bookmarkMatches.count,
                    now: .now
                )
                return bookmarkMatches + history
            } catch is CancellationError {
                return []
            } catch {
                record(error)
                return bookmarkMatches
            }
        }

        _ = await state.pendingMutation?.value
        guard !Task.isCancelled else { return [] }
        do {
            return try await state.database.addressMatches(for: text, limit: limit, now: .now)
        } catch is CancellationError {
            return []
        } catch {
            record(error)
            return []
        }
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func normalizedNeedle(for input: String) -> String {
        var needle = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = needle.range(of: "://"),
           !needle[..<scheme.lowerBound].contains(where: \.isWhitespace) {
            needle = String(needle[scheme.upperBound...])
        }
        if needle.prefix(4).lowercased() == "www." { needle.removeFirst(4) }
        return needle.folding(options: .caseInsensitive, locale: Self.posixLocale)
    }

    private static func normalizedAddress(_ urlString: String) -> String {
        var address = urlString
        if let scheme = address.range(of: "://") {
            address = String(address[scheme.upperBound...])
        }
        if address.prefix(4).lowercased() == "www." { address.removeFirst(4) }
        return address.folding(options: .caseInsensitive, locale: Self.posixLocale)
    }

    private static func matchingBookmarks(
        in tree: CuriumBookmarkTree, needle: String, limit: Int
    ) -> [CuriumAddressMatch] {
        var matches: [CuriumAddressMatch] = []
        matches.reserveCapacity(min(limit, 8))

        func consider(_ bookmark: CuriumBookmark) -> Bool {
            let address = normalizedAddress(bookmark.url.absoluteString)
            let title = bookmark.title.folding(options: .caseInsensitive, locale: Self.posixLocale)
            if address.contains(needle) || title.contains(needle) {
                matches.append(CuriumAddressMatch(kind: .bookmark, url: bookmark.url, title: bookmark.title))
                return matches.count < limit
            }
            return true
        }

        for favorite in tree.favorites {
            if !consider(favorite) { return matches }
        }

        var visitedFolders: Set<Int64> = [CuriumBookmarkFolder.favoritesID]
        func visit(_ folderID: Int64?) -> Bool {
            for item in tree.items(in: folderID) {
                switch item {
                case .bookmark(let bookmark):
                    if bookmark.parentID != CuriumBookmarkFolder.favoritesID, !consider(bookmark) {
                        return false
                    }
                case .folder(let folder):
                    if visitedFolders.insert(folder.id).inserted, !visit(folder.id) {
                        return false
                    }
                }
            }
            return true
        }
        _ = visit(nil)
        return matches
    }

    // MARK: Lifecycle

    /// Flushes the write-ahead log; call when the scene leaves the foreground.
    func checkpoint() {
        enqueue { library in try await library.database.checkpoint() }
    }

    /// Flushes the write-ahead log and awaits completion for background-task handoffs.
    func checkpointAsync() async {
        _ = await enqueue { library in try await library.database.checkpoint() }.value
    }
}
