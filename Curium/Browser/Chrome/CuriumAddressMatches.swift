import SwiftUI

private enum CuriumAddressInput {
    case address(URL)
    case search(String)

    /// Matches the URL rules in CuriumBrowserStore.submitAddress.
    init?(_ text: String) {
        guard !text.isEmpty else { return nil }
        if let candidate = URL(string: text),
           let scheme = candidate.scheme?.lowercased(), ["https", "http", "chrome"].contains(scheme),
           candidate.host() != nil {
            self = .address(candidate)
        } else if !text.contains(where: \.isWhitespace), !text.contains("://"),
                  let candidate = URL(string: "https://" + text),
                  let host = candidate.host(), host.contains(".") || host == "localhost" {
            self = .address(candidate)
        } else {
            self = .search(text)
        }
    }

    func title(using engine: CuriumSearchEngine) -> Text {
        switch self {
        case .address(let url): Text("Open \(url.host() ?? url.absoluteString)")
        case .search(let query): Text("Search \(engine.title) for “\(query)”")
        }
    }

    var symbol: String {
        switch self {
        case .address: "globe"
        case .search: "magnifyingglass"
        }
    }
}

struct CuriumAddressMatches: View {
    let library: CuriumLibrary
    let text: String
    let currentAddress: String
    let submit: () -> Void
    let open: (URL) -> Void

    @State private var result: (query: String, matches: [CuriumAddressMatch])?
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 24

    init(
        library: CuriumLibrary,
        text: String,
        currentAddress: String = "",
        submit: @escaping () -> Void,
        open: @escaping (URL) -> Void
    ) {
        self.library = library
        self.text = text
        self.currentAddress = currentAddress
        self.submit = submit
        self.open = open
    }

    private struct Request: Equatable {
        let query: String
        let bookmarkRevision: Int
    }

    nonisolated static func shouldSuppressDirectOpenRow(text: String, currentAddress: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCurrent = currentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedText.isEmpty && trimmedText == trimmedCurrent
    }

    var body: some View {
        let suppressesCurrent = Self.shouldSuppressDirectOpenRow(text: text, currentAddress: currentAddress)
        let input = suppressesCurrent ? nil : CuriumAddressInput(text)
        let matches = visibleMatches(suppressingCurrent: suppressesCurrent)

        Group {
            if input != nil || !matches.isEmpty {
                ViewThatFits(in: .vertical) {
                    rows(input: input, matches: matches)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        rows(input: input, matches: matches)
                    }
                    .scrollDismissesKeyboard(.never)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Address Matches")
                .accessibilityIdentifier("curium.address.matches")
            }
        }
        .task(id: Request(query: text, bookmarkRevision: library.bookmarkRevision)) {
            guard !text.isEmpty else {
                result = nil
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(60))
                let matches = await library.addressMatches(for: text)
                try Task.checkCancellation()
                result = (text, matches)
            } catch {
                // An edit or a loss of focus superseded this query.
            }
        }
    }

    private func visibleMatches(suppressingCurrent: Bool) -> [CuriumAddressMatch] {
        if text.isEmpty {
            return library.favoriteBookmarks.prefix(8).map {
                CuriumAddressMatch(kind: .bookmark, url: $0.url, title: $0.title)
            }
        }
        guard let result, result.query == text else { return [] }
        guard suppressingCurrent else { return result.matches }
        let trimmedCurrent = currentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.matches.filter { $0.url.absoluteString != trimmedCurrent }
    }

    private func rows(input: CuriumAddressInput?, matches: [CuriumAddressMatch]) -> some View {
        VStack(spacing: 0) {
            if let input {
                Button(action: submit) {
                    row(symbol: input.symbol) {
                        input.title(using: library.searchEngine)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                    }
                }
                .accessibilityIdentifier("curium.address.match")
            }

            ForEach(matches) { match in
                let host = match.url.host() ?? match.url.absoluteString
                Button { open(match.url) } label: {
                    row(symbol: match.kind == .bookmark ? "bookmark" : "clock") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.title.isEmpty ? host : match.title)
                                .font(.body)
                                .lineLimit(1)
                            if match.title != host && !match.title.isEmpty {
                                Text(host)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .accessibilityValue(match.kind == .bookmark ? Text("Bookmark") : Text("History"))
                .accessibilityIdentifier("curium.address.match")
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
    }

    private func row<Title: View>(symbol: String, @ViewBuilder title: () -> Title) -> some View {
        Label(title: title) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: symbolWidth)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: CuriumSpace.tapTarget, alignment: .leading)
        .contentShape(Rectangle())
    }
}
