import SwiftUI

struct CuriumLibrarySheet: View {
    let store: CuriumBrowserStore
    let section: Section
    var currentPage: CuriumBookmarkPage?

    @Environment(\.dismiss) private var dismiss

    enum Section {
        case bookmarks, history
    }

    var body: some View {
        NavigationStack {
            switch section {
            case .bookmarks:
                CuriumBookmarkList(
                    library: store.library,
                    folderID: nil,
                    currentPage: currentPage,
                    open: open,
                    onDismissSheet: { dismiss() }
                )
                .navigationDestination(for: Int64.self) { folderID in
                    CuriumBookmarkList(
                        library: store.library,
                        folderID: folderID,
                        currentPage: currentPage,
                        open: open,
                        onDismissSheet: { dismiss() }
                    )
                }
            case .history:
                CuriumHistoryList(
                    library: store.library,
                    open: open,
                    onDone: { dismiss() }
                ) {
                    await store.clearWebsiteData(since: $0)
                }
            }
        }
        .curiumSheetErrorAlert(store: store, presentationDelay: .milliseconds(350))
    }

    private func open(_ url: URL, _ inNewTab: Bool) {
        if !inNewTab, let tab = store.activeTab {
            tab.load(url)
        } else {
            guard store.newTab(url: url) else { return }
        }
        dismiss()
    }
}

private struct CuriumHistoryList: View {
    let library: CuriumLibrary
    let open: (URL, Bool) -> Void
    let onDone: () -> Void
    let clearWebsiteData: (Date?) async -> Void

    @State private var search = ""
    @State private var result: Result?
    @State private var confirmingClear = false
    @State private var editingBookmark: CuriumHistoryEntry?

    private struct Request: Equatable {
        let query: String
        let revision: Int
    }

    private struct Result {
        let query: String
        let days: [CuriumHistoryDay]
    }

    var body: some View {
        let request = Request(query: search.trimmingCharacters(in: .whitespacesAndNewlines),
                              revision: library.historyRevision)
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today)

        VStack(spacing: 0) {
            if library.storageUnavailable {
                CuriumStorageUnavailableBanner()
            }
            List {
                ForEach(result?.days ?? []) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            CuriumHistoryRow(entry: entry, library: library, open: open) {
                                editingBookmark = entry
                            }
                        }
                    } header: {
                        dayLabel(day.day, calendar: calendar, today: today, weekAgo: weekAgo)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if let result {
                    if result.days.isEmpty && result.query == request.query {
                        if result.query.isEmpty {
                            ContentUnavailableView {
                                Label("No History", systemImage: "clock")
                            } description: {
                                Text("Pages you visit will appear here.")
                            }
                        } else {
                            ContentUnavailableView.search(text: result.query)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search History")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: onDone) {
                    Label("Done", systemImage: "checkmark")
                }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    confirmingClear = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .accessibilityLabel("Clear History and Website Data")
                .accessibilityIdentifier("curium.history.clear")
                .disabled(result == nil)
                .confirmationDialog("Clear History and Website Data?", isPresented: $confirmingClear,
                                    titleVisibility: .visible) {
                    ForEach(CuriumHistoryClearRange.allCases) { range in
                        Button(range.title, role: .destructive) {
                            Task {
                                await library.clearHistory(range)
                                await clearWebsiteData(range.start())
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Clears history, cookies, cache, and site storage from the chosen period. It may sign you out of websites.")
                }
            }
        }
        .sheet(item: $editingBookmark) { entry in
            CuriumBookmarkEditor(library: library, subject: .bookmark(url: entry.url, title: entry.title))
        }
        .task(id: request) {
            if request.query != (result?.query ?? "") {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let days = await library.historyDays(matching: request.query)
            guard !Task.isCancelled else { return }
            result = Result(query: request.query, days: days)
        }
    }

    private func dayLabel(_ day: Date, calendar: Calendar, today: Date, weekAgo: Date?) -> Text {
        if calendar.isDateInToday(day) { return Text("Today") }
        if calendar.isDateInYesterday(day) { return Text("Yesterday") }

        if let weekAgo, (weekAgo..<today).contains(day) {
            return Text(day, format: .dateTime.weekday(.wide))
        }
        return Text(day, format: .dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct CuriumHistoryRow: View {
    let entry: CuriumHistoryEntry
    let library: CuriumLibrary
    let open: (URL, Bool) -> Void
    let editBookmark: () -> Void

    var body: some View {
        let title = entry.title.isEmpty ? entry.host : entry.title
        let time = entry.lastVisit.formatted(date: .omitted, time: .shortened)

        Button {
            open(entry.url, false)
        } label: {
            CuriumLibraryRow(title: title, host: entry.host, detail: "\(entry.host) · \(time)",
                             visitCount: entry.visitsThatDay)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(entry.visitsThatDay > 1
            ? Text("\(entry.host), \(time), visits: \(entry.visitsThatDay)")
            : Text("\(entry.host), \(time)"))
        .accessibilityHint("Opens in the current tab")
        .accessibilityIdentifier("curium.history.row")
        .swipeActions {
            Button(role: .destructive) {
                Task { await library.delete(entry) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { open(entry.url, false) } label: {
                Label("Open", systemImage: "arrow.up.right")
            }
            Button { open(entry.url, true) } label: {
                Label("Open in New Tab", systemImage: "plus.square")
            }
            Button { UIPasteboard.general.url = entry.url } label: {
                Label("Copy Link", systemImage: "link")
            }
            CuriumHistoryBookmarkMenuButton(url: entry.url, library: library, action: editBookmark)
            Divider()
            Button(role: .destructive) { Task { await library.delete(entry) } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Evaluates `library.isBookmarked` lazily inside the context menu so scrolling history
/// rows do not register an observation dependency on `library.bookmarks`.
private struct CuriumHistoryBookmarkMenuButton: View {
    let url: URL
    let library: CuriumLibrary
    let action: () -> Void

    var body: some View {
        let isBookmarked = library.isBookmarked(url)
        Button(action: action) {
            Label(isBookmarked ? "Edit Bookmark" : "Add Bookmark",
                  systemImage: isBookmarked ? "bookmark.fill" : "bookmark")
        }
    }
}

private struct CuriumLibraryRow: View {
    let title: String
    let host: String
    let detail: String
    var visitCount = 1

    var body: some View {
        HStack(spacing: 12) {
            CuriumSiteMonogram(host: host)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if visitCount > 1 {
                Text("×\(visitCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(minHeight: CuriumSpace.tapTarget)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct CuriumSiteMonogram: View {
    enum Size {
        case row, shortcut
    }

    let host: String
    var size: Size = .row
    @Environment(\.curiumPalette) private var palette

    var body: some View {
        let side: CGFloat = size == .row ? 36 : 64
        Text(host.first.map { String($0).localizedUppercase } ?? "·")
            .font(.system(size == .row ? .title3 : .largeTitle, design: .serif).weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(4)
            .frame(width: side, height: side)
            .foregroundStyle(.tint)
            .background(palette.tile, in: .rect(cornerRadius: size == .row ? 9 : 16))
            .accessibilityHidden(true)
    }
}
