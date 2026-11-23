import Darwin
import Foundation
import OSLog
import SQLite3
import os

/// Lazily opens one connection per profile for all scenes. Each operation runs to completion
/// on this actor, so a transaction never spans an actor suspension.
actor CuriumDatabase {
    static let shared = CuriumDatabase()
    private static let instancesLock = OSAllocatedUnfairLock<[String: CuriumDatabase]>(initialState: [:])

    static func shared(forProfile profileID: String) -> CuriumDatabase {
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized.isEmpty ? "default" : normalized.lowercased()
        if key == "default" {
            return shared
        }
        return instancesLock.withLock { cache in
            if let existing = cache[key] {
                return existing
            }
            let created = CuriumDatabase(profileID: normalized)
            cache[key] = created
            return created
        }
    }

    private let databaseURL: URL?
    private let profileID: String
    private var connection: CuriumSQLite?
    private var openFailure: (any Error)?

    init(databaseURL: URL? = nil, profileID: String = "default") {
        self.databaseURL = databaseURL
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profileID = trimmed.isEmpty ? "default" : trimmed
    }

    private func database() throws -> CuriumSQLite {
        if let connection { return connection }
        if let openFailure { throw openFailure }
        do {
            let db = try CuriumSQLite(url: databaseURL ?? Self.defaultURL(forProfile: profileID))
            connection = db
            return db
        } catch {
            // A failed schema or path must not silently fall back to a fresh database.
            Self.log.error("Could not open library: \(String(describing: error), privacy: .private)")
            openFailure = DatabaseUnavailable()
            throw DatabaseUnavailable()
        }
    }

    private struct DatabaseUnavailable: Error {}
    private struct AdoptionFailed: Error {}

    /// The library could not be opened, so nothing is saved this session.
    static func isUnavailable(_ error: any Error) -> Bool { error is DatabaseUnavailable }
    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "library")

    static func report(_ error: any Error) {
        guard !(error is DatabaseUnavailable) else { return }
        log.error("Library operation failed: \(String(describing: error), privacy: .private)")
    }

    private static func defaultURL(forProfile profileID: String) throws -> URL {
        let resolution = try CuriumLibraryLocation.resolve(profileID: profileID)
        guard CuriumLibraryLocation.adoptLegacyIfNeeded(resolution) else {
            throw AdoptionFailed()
        }
        log.notice("library(\(profileID, privacy: .public)) at \(resolution.database.path, privacy: .public)")
        return resolution.database
    }

    func recordVisit(url: URL, title: String, at date: Date) throws {
        let db = try database()
        let address = CuriumSQLite.Value.text(url.absoluteString)
        let time = CuriumSQLite.Value.real(date.timeIntervalSince1970)
        try db.write {
            try db.run("""
                INSERT INTO sites (url, title, visit_count, last_visit) VALUES (?, ?, 1, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = CASE WHEN excluded.title = '' THEN sites.title ELSE excluded.title END,
                    visit_count = sites.visit_count + 1,
                    last_visit = MAX(COALESCE(sites.last_visit, excluded.last_visit), excluded.last_visit)
                """, [address, .text(title), time])
            try db.run("""
                INSERT INTO visits (site_id, visited_at) SELECT id, ? FROM sites WHERE url = ?
                """, [time, address])
        }
    }

    func updateTitle(_ title: String, for url: URL) throws -> Bool {
        let db = try database()
        return try db.write {
            try db.run("UPDATE sites SET title = ?1 WHERE url = ?2 AND title != ?1", [.text(title), .text(url.absoluteString)])
            return db.changes > 0
        }
    }

    func historyDays(matching query: String, limit: Int, calendar: Calendar) throws -> [CuriumHistoryDay] {
        try Task.checkCancellation()
        guard limit > 0 else { return [] }
        let db = try database()
        // Fold each site once, then use the visit index only for matched sites.
        let matchedSites = query.isEmpty ? "" : """
            WITH matched_sites AS MATERIALIZED (
                SELECT id, url, title FROM sites
                WHERE curium_fold(title) LIKE ?1 ESCAPE '\\' OR curium_fold(url) LIKE ?1 ESCAPE '\\'
            )
            """
        let source = query.isEmpty
            ? "visits v JOIN sites s ON s.id = v.site_id"
            : "matched_sites s CROSS JOIN visits v ON v.site_id = s.id"
        var days: [CuriumHistoryDay] = []
        var day: Date?
        var dayStart = TimeInterval.infinity
        var dayEnd = -TimeInterval.infinity
        var entries: [CuriumHistoryEntry] = []
        var indices: [Int64: Int] = [:]
        var count = 0
        // Stream in visit order. After reaching the limit, finish counting the
        // selected entries on the last day, then stop reading older days.
        try db.cancellableRows("""
            \(matchedSites)
            SELECT s.id, s.url, s.title, v.visited_at
            FROM \(source)
            ORDER BY v.visited_at DESC, v.id DESC
            """, query.isEmpty ? [] : [.text("%" + Self.likeLiteral(query) + "%")]) { row in
            let timestamp = sqlite3_column_double(row, 3)
            let time = Date(timeIntervalSince1970: timestamp)
            if timestamp < dayStart || timestamp >= dayEnd {
                let localDay = calendar.startOfDay(for: time)
                if day != localDay {
                    if let day, !entries.isEmpty {
                        days.append(CuriumHistoryDay(day: day, entries: entries))
                    }
                    if count == limit {
                        entries.removeAll()
                        return false
                    }
                    day = localDay
                    entries.removeAll(keepingCapacity: true)
                    indices.removeAll(keepingCapacity: true)
                }
                dayStart = localDay.timeIntervalSince1970
                dayEnd = calendar.date(byAdding: .day, value: 1, to: localDay)?.timeIntervalSince1970 ?? (dayStart + 86_400)
            }
            let id = sqlite3_column_int64(row, 0)
            if let index = indices[id] {
                let entry = entries[index]
                entries[index] = CuriumHistoryEntry(siteID: id, url: entry.url, title: entry.title,
                                                    lastVisit: entry.lastVisit, visitsThatDay: entry.visitsThatDay + 1)
            } else if count < limit, let url = URL(string: CuriumSQLite.text(row, 1)) {
                indices[id] = entries.count
                entries.append(CuriumHistoryEntry(siteID: id, url: url, title: CuriumSQLite.text(row, 2),
                                                  lastVisit: time, visitsThatDay: 1))
                count += 1
            }
            return true
        }
        if let day, !entries.isEmpty { days.append(CuriumHistoryDay(day: day, entries: entries)) }
        return days
    }

    func delete(siteID: Int64, url: URL, day: DateInterval) throws {
        let db = try database()
        let site = CuriumSQLite.Value.integer(siteID)
        let address = CuriumSQLite.Value.text(url.absoluteString)
        try db.write {
            try db.run("""
                DELETE FROM visits WHERE site_id = (SELECT id FROM sites WHERE id = ? AND url = ?)
                    AND visited_at >= ? AND visited_at < ?
                """, [site, address, .real(day.start.timeIntervalSince1970), .real(day.end.timeIntervalSince1970)])
            try db.run("UPDATE sites SET \(Self.visitSummary()) WHERE id = ? AND url = ?", [site, address])
            try db.run("DELETE FROM sites WHERE id = ? AND url = ? AND visit_count = 0", [site, address])
        }
    }

    /// Removes a site and all of its visit rows across every day (used by Start Page's
    /// Frequently Visited context menu).
    func deleteSite(id siteID: Int64, url: URL) throws {
        let db = try database()
        let site = CuriumSQLite.Value.integer(siteID)
        let address = CuriumSQLite.Value.text(url.absoluteString)
        try db.write {
            try db.run("DELETE FROM visits WHERE site_id = (SELECT id FROM sites WHERE id = ? AND url = ?)", [site, address])
            try db.run("DELETE FROM sites WHERE id = ? AND url = ?", [site, address])
        }
    }

    /// Bounded frecency query over `sites` (7-day half-life) for the Start Page's
    /// Frequently Visited shelf. Deduplication against Favorites and canonical hosts runs in Swift.
    func frequentSiteCandidates(limit: Int, now: Date) throws -> [CuriumFrequentSite] {
        try Task.checkCancellation()
        guard limit > 0 else { return [] }
        let db = try database()
        let fetchLimit = Int64(max(64, limit * 12))
        let time = CuriumSQLite.Value.real(now.timeIntervalSince1970)
        var results: [CuriumFrequentSite] = []
        results.reserveCapacity(min(Int(fetchLimit), 96))
        try db.cancellableRows("""
            SELECT id, url, title, visit_count, last_visit
            FROM sites
            WHERE visit_count > 0
              AND last_visit IS NOT NULL
              AND (url LIKE 'https://%' COLLATE NOCASE OR url LIKE 'http://%' COLLATE NOCASE)
            ORDER BY (CAST(visit_count AS REAL) / (1.0 + MAX(0.0, ?1 - last_visit) / 604800.0)) DESC,
                     last_visit DESC,
                     id DESC
            LIMIT ?2
            """, [time, .integer(fetchLimit)]) { row in
            let id = sqlite3_column_int64(row, 0)
            let rawURL = CuriumSQLite.text(row, 1)
            let title = CuriumSQLite.text(row, 2)
            let visitCount = Int(sqlite3_column_int64(row, 3))
            let lastVisit = Date(timeIntervalSince1970: sqlite3_column_double(row, 4))
            if let url = URL(string: rawURL) {
                results.append(CuriumFrequentSite(
                    siteID: id,
                    url: url,
                    title: title,
                    visitCount: visitCount,
                    lastVisit: lastVisit
                ))
            }
            return true
        }
        return results
    }

    func clearHistory(since start: Date?) throws {
        let db = try database()
        try db.write {
            if let start {
                let time = CuriumSQLite.Value.real(start.timeIntervalSince1970)
                // Identify affected sites from the visits being removed, and
                // compute the summary of the visits that will remain.
                try db.run("""
                    UPDATE sites SET \(Self.visitSummary(before: "?1"))
                    WHERE id IN (SELECT site_id FROM visits WHERE visited_at >= ?1)
                    """, [time])
                try db.run("DELETE FROM visits WHERE visited_at >= ?", [time])
                try db.run("DELETE FROM sites WHERE last_visit IS NULL AND visit_count = 0")
            } else {
                try db.run("DELETE FROM visits")
                try db.run("DELETE FROM sites")
            }
        }
    }

    private static func visitSummary(before parameter: String? = nil) -> String {
        let filter = "site_id = sites.id" + (parameter.map { " AND visited_at < " + $0 } ?? "")
        return """
            visit_count = (SELECT COUNT(*) FROM visits WHERE \(filter)),
            last_visit = (SELECT MAX(visited_at) FROM visits WHERE \(filter))
            """
    }

    func bookmarkTree() throws -> CuriumBookmarkTree {
        try readBookmarks(database())
    }

    private func readBookmarks(_ db: CuriumSQLite) throws -> CuriumBookmarkTree {
        var items: [CuriumBookmarkItem] = []
        try db.rows("SELECT id, parent_id, title, url FROM bookmark_items ORDER BY parent_id, position, id") { row in
            let id = sqlite3_column_int64(row, 0)
            let parentID = sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 1)
            let title = CuriumSQLite.text(row, 2)
            if sqlite3_column_type(row, 3) == SQLITE_NULL {
                items.append(.folder(CuriumBookmarkFolder(id: id, parentID: parentID, title: title)))
            } else if let url = URL(string: CuriumSQLite.text(row, 3)) {
                items.append(.bookmark(CuriumBookmark(id: id, parentID: parentID, url: url, title: title)))
            }
            return true
        }
        return CuriumBookmarkTree(items: items)
    }

    func saveBookmark(url: URL, title: String, in folderID: Int64?, at date: Date) throws -> CuriumBookmarkTree {
        try mutateBookmarks { db in
            try requireFolder(folderID, in: db)
            try upsertBookmark(url: url, title: title, folderID: folderID, at: date, in: db)
        }
    }

    private func upsertBookmark(url: URL, title: String, folderID: Int64?, at date: Date,
                                in db: CuriumSQLite) throws {
        try db.run("""
            INSERT INTO bookmark_items (parent_id, url, title, position, created_at)
            VALUES (?1, ?2, ?3, \(Self.lastBookmarkPosition), ?4)
            ON CONFLICT(url) DO UPDATE SET
                title = excluded.title,
                position = CASE WHEN bookmark_items.parent_id IS excluded.parent_id
                    THEN bookmark_items.position ELSE excluded.position END,
                parent_id = excluded.parent_id
            """, [Self.parent(folderID), .text(url.absoluteString), .text(title), .real(date.timeIntervalSince1970)])
    }

    func saveBookmarkFolder(id: Int64?, title: String, in folderID: Int64?, at date: Date) throws -> CuriumBookmarkTree {
        try mutateBookmarks { db in
            guard id != CuriumBookmarkFolder.favoritesID else { throw InvalidBookmarkFolder() }
            try requireFolder(folderID, excluding: id, in: db)
            if let id {
                try db.run("""
                    UPDATE bookmark_items SET title = ?2,
                        position = CASE WHEN parent_id IS ?1 THEN position ELSE \(Self.lastBookmarkPosition) END,
                        parent_id = ?1
                    WHERE id = ?3 AND url IS NULL
                    """, [Self.parent(folderID), .text(title), .integer(id)])
                guard db.changes == 1 else { throw InvalidBookmarkFolder() }
            } else {
                try db.run("""
                    INSERT INTO bookmark_items (parent_id, title, position, created_at)
                    VALUES (?1, ?2, \(Self.lastBookmarkPosition), ?3)
                    """, [Self.parent(folderID), .text(title), .real(date.timeIntervalSince1970)])
            }
        }
    }

    private struct InvalidBookmarkFolder: Error {}

    private func requireFolder(_ id: Int64?, excluding movedID: Int64? = nil, in db: CuriumSQLite) throws {
        guard let id else { return }
        var valid = false
        try db.rows("""
            WITH RECURSIVE ancestors(id, parent_id) AS (
                SELECT id, parent_id FROM bookmark_items WHERE id = ?1 AND url IS NULL
                UNION
                SELECT item.id, item.parent_id FROM bookmark_items item JOIN ancestors ON item.id = ancestors.parent_id
            )
            SELECT EXISTS (SELECT 1 FROM ancestors)
                AND NOT EXISTS (SELECT 1 FROM ancestors WHERE id = ?2)
            """, [.integer(id), Self.parent(movedID)]) { row in
            valid = sqlite3_column_int(row, 0) != 0
            return true
        }
        guard valid else { throw InvalidBookmarkFolder() }
    }

    func deleteBookmarkItem(_ id: Int64) throws -> CuriumBookmarkTree {
        try mutateBookmarks { db in
            try db.run("DELETE FROM bookmark_items WHERE id = ? AND id != ?",
                       [.integer(id), .integer(CuriumBookmarkFolder.favoritesID)])
        }
    }

    func reorderBookmarks(in folderID: Int64?, ids: [Int64]) throws -> CuriumBookmarkTree {
        try mutateBookmarks { db in
            var current: [Int64] = []
            try db.rows("SELECT id FROM bookmark_items WHERE parent_id IS ? ORDER BY position, id",
                        [Self.parent(folderID)]) { row in
                current.append(sqlite3_column_int64(row, 0))
                return true
            }
            let known = Set(current)
            let visible = Set(ids)
            var desired = ids.lazy.filter { known.contains($0) }.makeIterator()
            // Keep siblings added since the drag in their current slots.
            for (position, currentID) in current.enumerated() {
                let id = visible.contains(currentID) ? (desired.next() ?? currentID) : currentID
                try db.run("UPDATE bookmark_items SET position = ? WHERE id = ?",
                           [.integer(Int64(position)), .integer(id)])
            }
        }
    }

    private static func parent(_ id: Int64?) -> CuriumSQLite.Value {
        id.map(CuriumSQLite.Value.integer) ?? .null
    }

    private static let lastBookmarkPosition =
        "(SELECT COALESCE(MAX(position) + 1, 0) FROM bookmark_items WHERE parent_id IS ?1)"

    private func mutateBookmarks(_ body: (CuriumSQLite) throws -> Void) throws -> CuriumBookmarkTree {
        let db = try database()
        let updated = try db.write {
            try body(db)
            return try readBookmarks(db)
        }
        // A busy checkpoint does not undo a successful commit.
        do { try db.checkpoint() } catch { Self.report(error) }
        return updated
    }

    func addressMatches(for input: String, limit: Int, now: Date) throws -> [CuriumAddressMatch] {
        try Task.checkCancellation()
        var needle = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = needle.range(of: "://"), !needle[..<scheme.lowerBound].contains(where: \.isWhitespace) {
            needle = String(needle[scheme.upperBound...])
        }
        if needle.prefix(4).lowercased() == "www." { needle.removeFirst(4) }
        guard !needle.isEmpty, limit > 0 else { return [] }
        let db = try database()
        let literal = Self.likeLiteral(needle)
        let contains = CuriumSQLite.Value.text("%" + literal + "%")
        var matches = try readMatches(db, kind: .bookmark, sql: """
            SELECT b.url, b.title FROM bookmark_items b WHERE b.url IS NOT NULL AND (\(Self.contains("b")))
            ORDER BY b.parent_id IS \(CuriumBookmarkFolder.favoritesID) DESC, b.position, b.id LIMIT ?2
            """, values: [contains, .integer(Int64(limit))])
        guard matches.count < limit else { return matches }

        let normalized = Self.normalizedURL("s")
        let bookmarkExclusion = """
            NOT EXISTS (SELECT 1 FROM bookmark_items b WHERE b.url = s.url AND (\(Self.contains("b"))))
            """
        let rank = """
            ORDER BY s.visit_count / (1.0 + MAX(0, ?2 - s.last_visit) / 604800.0) DESC,
                     s.last_visit DESC, s.id DESC LIMIT ?3
            """
        let canMatchHost = !needle.contains { "/:?#".contains($0) }
        let prefix = CuriumSQLite.Value.text(literal + "%")
        let time = CuriumSQLite.Value.real(now.timeIntervalSince1970)
        if canMatchHost {
            // The NOCASE expression index supplies this prefix range. Only
            // the matching candidates need to be ranked by frecency.
            matches += try readMatches(db, kind: .history, sql: """
                SELECT s.url, s.title FROM sites s
                WHERE \(normalized) LIKE ?4 ESCAPE '\\' AND \(bookmarkExclusion)
                \(rank)
                """, values: [contains, time, .integer(Int64(limit - matches.count)), prefix])
        }
        if matches.count < limit {
            let tail = canMatchHost ? "AND \(normalized) NOT LIKE ?4 ESCAPE '\\'" : ""
            var bindings: [CuriumSQLite.Value] = [contains, time, .integer(Int64(limit - matches.count))]
            if canMatchHost { bindings.append(prefix) }
            matches += try readMatches(db, kind: .history, sql: """
                SELECT s.url, s.title FROM sites s
                WHERE (\(Self.contains("s"))) AND \(bookmarkExclusion) \(tail)
                \(rank)
                """, values: bindings)
        }
        return matches
    }

    /// History-only address match query used when bookmarks are already matched in memory.
    /// Avoids the correlated `bookmark_items` subquery and lets callers deduplicate in Swift.
    func historyAddressMatches(
        for input: String,
        excludingURLs excludedURLs: Set<String>,
        limit: Int,
        now: Date
    ) throws -> [CuriumAddressMatch] {
        try Task.checkCancellation()
        var needle = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = needle.range(of: "://"), !needle[..<scheme.lowerBound].contains(where: \.isWhitespace) {
            needle = String(needle[scheme.upperBound...])
        }
        if needle.prefix(4).lowercased() == "www." { needle.removeFirst(4) }
        guard !needle.isEmpty, limit > 0 else { return [] }
        let db = try database()
        let literal = Self.likeLiteral(needle)
        let contains = CuriumSQLite.Value.text("%" + literal + "%")
        let normalized = Self.normalizedURL("s")
        let rank = """
            ORDER BY s.visit_count / (1.0 + MAX(0, ?2 - s.last_visit) / 604800.0) DESC,
                     s.last_visit DESC, s.id DESC LIMIT ?3
            """
        let canMatchHost = !needle.contains { "/:?#".contains($0) }
        let prefix = CuriumSQLite.Value.text(literal + "%")
        let time = CuriumSQLite.Value.real(now.timeIntervalSince1970)
        let extraRows = min(excludedURLs.count, 64)

        var matches: [CuriumAddressMatch] = []
        matches.reserveCapacity(limit)
        if canMatchHost {
            let remaining = limit - matches.count
            let fetchLimit = Int64(remaining + extraRows)
            matches += try readHistoryMatches(
                db,
                sql: """
                    SELECT s.url, s.title FROM sites s
                    WHERE \(normalized) LIKE ?1 ESCAPE '\\'
                    \(rank)
                    """,
                values: [prefix, time, .integer(fetchLimit)],
                excludingURLs: excludedURLs,
                maxCount: remaining
            )
        }
        if matches.count < limit {
            let remaining = limit - matches.count
            let fetchLimit = Int64(remaining + extraRows)
            let tail = canMatchHost ? "AND \(normalized) NOT LIKE ?4 ESCAPE '\\'" : ""
            var bindings: [CuriumSQLite.Value] = [contains, time, .integer(fetchLimit)]
            if canMatchHost { bindings.append(prefix) }
            matches += try readHistoryMatches(
                db,
                sql: """
                    SELECT s.url, s.title FROM sites s
                    WHERE (\(Self.contains("s"))) \(tail)
                    \(rank)
                    """,
                values: bindings,
                excludingURLs: excludedURLs,
                maxCount: remaining
            )
        }
        return matches
    }

    private func readHistoryMatches(
        _ db: CuriumSQLite,
        sql: String,
        values: [CuriumSQLite.Value],
        excludingURLs excludedURLs: Set<String>,
        maxCount: Int
    ) throws -> [CuriumAddressMatch] {
        guard maxCount > 0 else { return [] }
        var matches: [CuriumAddressMatch] = []
        matches.reserveCapacity(maxCount)
        try db.cancellableRows(sql, values) { row in
            let rawURL = CuriumSQLite.text(row, 0)
            guard !excludedURLs.contains(rawURL) else { return true }
            if let url = URL(string: rawURL) {
                matches.append(CuriumAddressMatch(kind: .history, url: url, title: CuriumSQLite.text(row, 1)))
            }
            return matches.count < maxCount
        }
        return matches
    }

    private func readMatches(_ db: CuriumSQLite, kind: CuriumAddressMatch.Kind, sql: String,
                             values: [CuriumSQLite.Value]) throws -> [CuriumAddressMatch] {
        var matches: [CuriumAddressMatch] = []
        try db.cancellableRows(sql, values) { row in
            if let url = URL(string: CuriumSQLite.text(row, 0)) {
                matches.append(CuriumAddressMatch(kind: kind, url: url, title: CuriumSQLite.text(row, 1)))
            }
            return true
        }
        return matches
    }

    fileprivate static func normalizedURL(_ table: String? = nil) -> String {
        let url = table.map { "\($0).url" } ?? "url"
        return """
            CASE
                WHEN substr(\(url), 1, 12) = 'https://www.' COLLATE NOCASE THEN substr(\(url), 13)
                WHEN substr(\(url), 1, 11) = 'http://www.' COLLATE NOCASE THEN substr(\(url), 12)
                WHEN substr(\(url), 1, 8) = 'https://' COLLATE NOCASE THEN substr(\(url), 9)
                WHEN substr(\(url), 1, 7) = 'http://' COLLATE NOCASE THEN substr(\(url), 8)
                WHEN substr(\(url), instr(\(url), '://') + 3, 4) = 'www.' COLLATE NOCASE
                    AND instr(\(url), '://') > 0 THEN substr(\(url), instr(\(url), '://') + 7)
                WHEN instr(\(url), '://') > 0 THEN substr(\(url), instr(\(url), '://') + 3)
                WHEN substr(\(url), 1, 4) = 'www.' COLLATE NOCASE THEN substr(\(url), 5)
                ELSE \(url)
            END
            """
    }

    private static func contains(_ table: String) -> String {
        let title = "\(table).title"
        return """
            \(normalizedURL(table)) LIKE ?1 ESCAPE '\\'
            OR \(title) LIKE ?1 ESCAPE '\\'
            OR (length(\(title)) != length(CAST(\(title) AS BLOB)) AND curium_fold(\(title)) LIKE ?1 ESCAPE '\\')
            """
    }

    private static func likeLiteral(_ text: String) -> String {
        fold(text).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    fileprivate static let posixLocale = Locale(identifier: "en_US_POSIX")

    fileprivate static func fold(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: Self.posixLocale)
    }

    func checkpoint() throws {
        guard let connection else { return }
        try connection.checkpoint()
    }
}

private final class CuriumSQLite {
    private static let migrations = [
        """
        CREATE TABLE IF NOT EXISTS sites (
            id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL DEFAULT '',
            visit_count INTEGER NOT NULL DEFAULT 0, last_visit REAL
        );
        CREATE TABLE IF NOT EXISTS visits (
            id INTEGER PRIMARY KEY, site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
            visited_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS visits_by_time ON visits(visited_at);
        CREATE INDEX IF NOT EXISTS visits_by_site ON visits(site_id, visited_at);
        CREATE INDEX IF NOT EXISTS sites_by_time ON sites(last_visit);
        CREATE INDEX IF NOT EXISTS sites_by_address ON sites((\(CuriumDatabase.normalizedURL())) COLLATE NOCASE);
        CREATE TABLE IF NOT EXISTS favorites (
            id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
            position REAL NOT NULL, created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS favorites_by_position ON favorites(position);
        SELECT id, url, title, visit_count, last_visit FROM sites LIMIT 0;
        SELECT id, site_id, visited_at FROM visits LIMIT 0;
        SELECT id, url, title, position, created_at FROM favorites LIMIT 0;
        """,
        """
        CREATE TABLE IF NOT EXISTS bookmark_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_id INTEGER REFERENCES bookmark_items(id) ON DELETE CASCADE,
            url TEXT UNIQUE,
            title TEXT NOT NULL,
            position REAL NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS bookmark_items_by_parent ON bookmark_items(parent_id, position, id);
        INSERT INTO bookmark_items (id, title, position, created_at)
            VALUES (\(CuriumBookmarkFolder.favoritesID), 'Favorites', 0, 0)
            ON CONFLICT(id) DO NOTHING;
        -- Import only when the Favorites folder was inserted, even if this SQL runs again.
        INSERT INTO bookmark_items (parent_id, url, title, position, created_at)
            SELECT \(CuriumBookmarkFolder.favoritesID), url, title, position, created_at FROM favorites
            WHERE changes() = 1
            ORDER BY position, id;
        """
    ]

    enum Value {
        case null
        case text(String)
        case integer(Int64)
        case real(Double)
    }

    private struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    private let handle: OpaquePointer
    private let url: URL
    private var needsPostWriteProtection = true
    private var hasUncheckpointedWrites = false
    private var statementCache: [String: OpaquePointer] = [:]
    var changes: Int32 { sqlite3_changes(handle) }

    init(url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wasNonempty = files.fileExists(atPath: url.path)
            ? try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { $0 > 0 } ?? true
            : false
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard code == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "No connection"
            if let pointer { sqlite3_close(pointer) }
            throw Failure(code: code, message: message)
        }
        self.handle = pointer
        self.url = url

        applySuspendProtection()
        try check(sqlite3_busy_timeout(handle, 1_000))
        var mode = ""
        try rows("PRAGMA journal_mode = WAL", cache: false) { row in
            mode = Self.text(row, 0)
            return true
        }
        guard mode.lowercased() == "wal" else { throw Failure(code: SQLITE_ERROR, message: "Could not enable WAL") }
        try execute("PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
        try check(sqlite3_create_function_v2(handle, "curium_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let value = values?[0], let bytes = sqlite3_value_text(value) else {
                sqlite3_result_null(context)
                return
            }
            let utf8 = UnsafeBufferPointer(start: bytes, count: Int(sqlite3_value_bytes(value)))
            if utf8.allSatisfy({ $0 < 128 }) {
                sqlite3_result_value(context, value) // SQLite LIKE already folds ASCII.
            } else {
                let folded = CuriumDatabase.fold(String(decoding: utf8, as: UTF8.self))
                folded.withCString { sqlite3_result_text(context, $0, -1, CuriumSQLite.transient) }
            }
        }, nil, nil, nil))
        applySuspendProtection()
        try migrate(backup: wasNonempty)
    }

    deinit {
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close_v2(handle)
    }

    private func migrate(backup: Bool) throws {
        var version = 0
        try rows("PRAGMA user_version", cache: false) { row in
            version = Int(sqlite3_column_int(row, 0))
            return true
        }
        guard version >= 0 else { throw Failure(code: SQLITE_ERROR, message: "Invalid schema version") }
        // A newer build may have added tables. Leave its schema version intact.
        guard version < Self.migrations.count else { return }
        if backup { try backupDatabase(version: version) }
        for index in version..<Self.migrations.count {
            try write {
                try execute(Self.migrations[index])
                try execute("PRAGMA user_version = \(index + 1)")
            }
        }
        do { try checkpoint() } catch { CuriumDatabase.report(error) }
    }

    private func backupDatabase(version: Int) throws {
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".v"
        let backup = directory.appending(path: prefix + "\(version).bak")
        let scratch = directory.appending(path: ".\(prefix)\(UUID().uuidString).tmp")
        defer {
            if files.fileExists(atPath: scratch.path) { try? files.removeItem(at: scratch) }
        }
        try rows("VACUUM INTO ?", [.text(scratch.path)], cache: false) { _ in true }
        // Install the complete snapshot before pruning any older backup.
        guard rename(scratch.path, backup.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            let name = file.lastPathComponent
            guard name != backup.lastPathComponent, name.hasPrefix(prefix), name.hasSuffix(".bak"),
                  Int(name.dropFirst(prefix.count).dropLast(4)) != nil,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            do { try files.removeItem(at: file) } catch { CuriumDatabase.report(error) }
        }
    }

    func write<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            hasUncheckpointedWrites = true
            if needsPostWriteProtection {
                applySuspendProtection()
                needsPostWriteProtection = false
            }
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func checkpoint() throws {
        guard hasUncheckpointedWrites else {
            if needsPostWriteProtection {
                applySuspendProtection()
                needsPostWriteProtection = false
            }
            return
        }
        applySuspendProtection()
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let code = sqlite3_wal_checkpoint_v2(
            handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointedFrames
        )
        if code == SQLITE_BUSY || code == SQLITE_LOCKED {
            let passive = sqlite3_wal_checkpoint_v2(
                handle, nil, SQLITE_CHECKPOINT_PASSIVE, &logFrames, &checkpointedFrames
            )
            if passive != SQLITE_OK && passive != SQLITE_BUSY && passive != SQLITE_LOCKED {
                try check(passive)
            }
            if passive == SQLITE_OK && logFrames == 0 {
                hasUncheckpointedWrites = false
            }
        } else {
            try check(code)
            if logFrames == 0 {
                hasUncheckpointedWrites = false
            }
        }
        applySuspendProtection()
        needsPostWriteProtection = false
    }

    private func applySuspendProtection() {
        var flag: UInt8 = 1
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            let result = setxattr(path, "com.apple.runningboard.can-suspend-locked", &flag, 1, 0, 0)
            if result != 0, errno != ENOENT {
                CuriumDatabase.report(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        try rows(sql, values) { _ in true }
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    func cancellableRows(_ sql: String, _ values: [Value], _ consume: (OpaquePointer) -> Bool) throws {
        try Task.checkCancellation()
        // SQLite calls back on the calling task. Keep the handler scoped to this read.
        sqlite3_progress_handler(handle, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        do {
            try rows(sql, values) { row in
                !Task.isCancelled && consume(row)
            }
        } catch let failure as Failure where failure.code == SQLITE_INTERRUPT && Task.isCancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    func rows(_ sql: String, _ values: [Value] = [], cache: Bool = true, _ consume: (OpaquePointer) -> Bool) throws {
        let statement: OpaquePointer
        if cache, let cached = statementCache.removeValue(forKey: sql) {
            statement = cached
        } else {
            var pointer: OpaquePointer?
            try check(sqlite3_prepare_v2(handle, sql, -1, &pointer, nil))
            guard let prepared = pointer else { throw Failure(code: SQLITE_ERROR, message: "Empty statement") }
            statement = prepared
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            if cache, statementCache[sql] == nil, statementCache.count < 64 {
                statementCache[sql] = statement
            } else {
                sqlite3_finalize(statement)
            }
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: try check(sqlite3_bind_null(statement, index))
            case .text(let text):
                try text.withCString {
                    try check(sqlite3_bind_text64(statement, index, $0, UInt64(text.utf8.count), Self.transient, UInt8(SQLITE_UTF8)))
                }
            case .integer(let number): try check(sqlite3_bind_int64(statement, index, number))
            case .real(let number): try check(sqlite3_bind_double(statement, index, number))
            }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { try check(code); return }
            if !consume(statement) { return }
        }
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw Failure(code: code, message: String(cString: sqlite3_errmsg(handle))) }
    }
}
