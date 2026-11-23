import Foundation

/// Persisted snapshot of a profile's open web tabs (`http`/`https` only) stored in
/// `<CuriumSupportRoot>/session.json` (for `"default"`) or
/// `<CuriumSupportRoot>/Profiles/<slug>/session.json` (for isolated profiles).
struct CuriumSavedSession: Codable, Equatable, Sendable {
    var version: Int = 1
    var openTabURLs: [String]
    var activeTabIndex: Int
    var savedAt: Date
}

enum CuriumSessionStorage {
    static let fileName = "session.json"
    static let maxSavedTabs = 24

    static func sessionFileURL(forProfile profileID: String, directory: URL? = nil) throws -> URL {
        let baseDir: URL
        if let directory {
            baseDir = directory
        } else {
            baseDir = try CuriumLibraryLocation.profileSupportDirectory(for: profileID)
        }
        return baseDir.appending(path: fileName, directoryHint: .notDirectory)
    }

    static func load(forProfile profileID: String, directory: URL? = nil) -> CuriumSavedSession? {
        guard let fileURL = try? sessionFileURL(forProfile: profileID, directory: directory),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(CuriumSavedSession.self, from: data) else {
            return nil
        }

        var filtered: [String] = []
        filtered.reserveCapacity(min(decoded.openTabURLs.count, maxSavedTabs))
        var mappedActiveIndex: Int?

        for (index, raw) in decoded.openTabURLs.enumerated() {
            guard filtered.count < maxSavedTabs else { break }
            guard let url = URL(string: raw), isPersistableWebURL(url) else { continue }
            if index == decoded.activeTabIndex {
                mappedActiveIndex = filtered.count
            }
            filtered.append(url.absoluteString)
        }

        guard !filtered.isEmpty else { return nil }
        let clampedActive = min(max(0, mappedActiveIndex ?? decoded.activeTabIndex), filtered.count - 1)
        return CuriumSavedSession(
            version: decoded.version,
            openTabURLs: filtered,
            activeTabIndex: clampedActive,
            savedAt: decoded.savedAt
        )
    }

    static func save(
        urls: [URL],
        activeIndex: Int,
        forProfile profileID: String,
        directory: URL? = nil
    ) {
        guard let fileURL = try? sessionFileURL(forProfile: profileID, directory: directory) else {
            return
        }

        var filtered: [String] = []
        filtered.reserveCapacity(min(urls.count, maxSavedTabs))
        var mappedActiveIndex: Int?

        for (index, url) in urls.enumerated() {
            guard filtered.count < maxSavedTabs else { break }
            guard isPersistableWebURL(url) else { continue }
            if index == activeIndex {
                mappedActiveIndex = filtered.count
            }
            filtered.append(url.absoluteString)
        }

        if filtered.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let clampedActive = min(max(0, mappedActiveIndex ?? activeIndex), filtered.count - 1)
        let session = CuriumSavedSession(
            version: 1,
            openTabURLs: filtered,
            activeTabIndex: clampedActive,
            savedAt: .now
        )

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(session)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence: session storage failures must never disrupt browsing.
        }
    }

    static func clear(forProfile profileID: String, directory: URL? = nil) {
        guard let fileURL = try? sessionFileURL(forProfile: profileID, directory: directory) else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func isPersistableWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host()?.isEmpty == false
    }
}
