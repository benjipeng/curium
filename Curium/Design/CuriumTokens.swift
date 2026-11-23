import SwiftUI
import UIKit

enum CuriumSiteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case adaptive
    case desktop
    case mobile

    var id: Self { self }

    var title: String {
        switch self {
        case .adaptive: "Duo Adaptive (Inner Desktop · Outer Mobile)"
        case .desktop: "Desktop Site"
        case .mobile: "Mobile Site"
        }
    }

    var shortTitle: String {
        switch self {
        case .adaptive: "Duo Adaptive"
        case .desktop: "Desktop"
        case .mobile: "Mobile"
        }
    }

    func prefersDesktop(forViewportWidth width: CGFloat) -> Bool {
        switch self {
        case .adaptive: width >= 600
        case .desktop: true
        case .mobile: false
        }
    }
}

enum CuriumPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case violet, thorium, neptunium, americium, berkelium, californium

    var id: Self { self }

    var title: String {
        switch self {
        case .violet: "Curium Violet"
        case .thorium: "Thorium Teal"
        case .neptunium: "Neptunium Blue"
        case .americium: "Americium Amber"
        case .berkelium: "Berkelium Rose"
        case .californium: "Californium Indigo"
        }
    }

    var notation: String {
        switch self {
        case .violet: "96 Cm"
        case .thorium: "90 Th"
        case .neptunium: "93 Np"
        case .americium: "95 Am"
        case .berkelium: "97 Bk"
        case .californium: "98 Cf"
        }
    }

    var tint: Color { Color(uiColor: ink) }

    // Each pair exceeds 4.5:1 on its corresponding system background.
    var ink: UIColor {
        switch self {
        case .violet: Self.dynamic(light: 0x57349C, dark: 0xC5AEFF)
        case .thorium: Self.dynamic(light: 0x006255, dark: 0x80DDCC)
        case .neptunium: Self.dynamic(light: 0x225494, dark: 0xA6CAFF)
        case .americium: Self.dynamic(light: 0x8C4A00, dark: 0xF5BA62)
        case .berkelium: Self.dynamic(light: 0x992652, dark: 0xFF9BBF)
        case .californium: Self.dynamic(light: 0x3942A3, dark: 0xA9B4FF)
        }
    }

    var tile: Color {
        switch self {
        case .violet: Color(uiColor: Self.dynamic(light: 0xEEE6FA, dark: 0x262035))
        case .thorium: Color(uiColor: Self.dynamic(light: 0xDFF3EE, dark: 0x162F2B))
        case .neptunium: Color(uiColor: Self.dynamic(light: 0xE4EFFD, dark: 0x172B44))
        case .americium: Color(uiColor: Self.dynamic(light: 0xFBEEDB, dark: 0x332514))
        case .berkelium: Color(uiColor: Self.dynamic(light: 0xFCE7EF, dark: 0x361B26))
        case .californium: Color(uiColor: Self.dynamic(light: 0xE8EAFC, dark: 0x1E213D))
        }
    }

    /// Architectural paper canvas for Start Page and Engine Standby, subtly tinted to
    /// the active actinide palette without relying on `@Environment(\.colorScheme)`.
    var canvas: Color {
        switch self {
        case .violet: Color(uiColor: Self.dynamic(light: 0xF8F7FB, dark: 0x0C0B10))
        case .thorium: Color(uiColor: Self.dynamic(light: 0xF6FAF9, dark: 0x090E0D))
        case .neptunium: Color(uiColor: Self.dynamic(light: 0xF6F8FC, dark: 0x090C11))
        case .americium: Color(uiColor: Self.dynamic(light: 0xFBF9F5, dark: 0x0F0C09))
        case .berkelium: Color(uiColor: Self.dynamic(light: 0xFBF7F9, dark: 0x100A0D))
        case .californium: Color(uiColor: Self.dynamic(light: 0xF6F7FB, dark: 0x0A0B11))
        }
    }

    /// Elevated neutral plinth surface for Start Page cards and dossier rows.
    var cardSurface: Color {
        switch self {
        case .violet: Color(uiColor: Self.dynamic(light: 0xFFFFFF, dark: 0x16141E))
        case .thorium: Color(uiColor: Self.dynamic(light: 0xFFFFFF, dark: 0x111918))
        case .neptunium: Color(uiColor: Self.dynamic(light: 0xFFFFFF, dark: 0x111720))
        case .americium: Color(uiColor: Self.dynamic(light: 0xFFFFFF, dark: 0x1A1612))
        case .berkelium: Color(uiColor: Self.dynamic(light: 0xFFFFFF, dark: 0x1B1317))
        case .californium: Color(uiColor: Self.dynamic(light: 0xFFFFFF, dark: 0x131520))
        }
    }

    /// Static skylight atmospheric tint scoped strictly to Start Page / Standby backdrops.
    /// Tuned to avoid 8-bit Mach banding in Dark Mode while preserving serene actinide warmth.
    var atmosphereGlow: Color {
        let lightAlpha: CGFloat = 0.065
        let darkAlpha: CGFloat
        switch self {
        case .americium, .berkelium:
            darkAlpha = 0.065
        case .violet, .thorium, .neptunium, .californium:
            darkAlpha = 0.07
        }
        return Color(uiColor: UIColor { traits in
            let resolved = self.ink.resolvedColor(with: traits)
            return resolved.withAlphaComponent(traits.userInterfaceStyle == .dark ? darkAlpha : lightAlpha)
        })
    }

    fileprivate static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1
            )
        }
    }
}

enum CuriumProfileSymbols {
    static let curated: [String] = [
        "person.crop.circle",
        "briefcase",
        "bag",
        "globe",
        "shield.lefthalf.filled",
        "desktopcomputer",
        "laptopcomputer",
        "iphone",
        "terminal",
        "gamecontroller",
        "graduationcap",
        "airplane",
        "building.2",
        "lock.shield",
        "sparkles",
        "flask",
    ]
}

extension EnvironmentValues {
    @Entry var curiumPalette = CuriumPalette.violet
}

enum CuriumSpace {
    static let omniboxWidth: CGFloat = 520
    static let tapTarget: CGFloat = 44
    /// Vertical center of the system status cluster inside a horizontal-bar status band.
    static let statusCenterline: CGFloat = 48
    /// Width of the status cluster (clock, connectivity) in a horizontal-bar status band.
    /// Trailing room for the status cluster before UIKit reports its occlusion region:
    /// the widest cluster measured on iPhone Duo inner portrait, with a Live Activity
    /// in the island (x 470-645 of 669 pt). Once the region is reported, it rules.
    static let statusClusterReserve: CGFloat = 210
    /// Minimum trailing room for the idle status cluster (144 pt + 8 pt interactive gap)
    /// when a horizontal status band is active but UIKit reports no matching occlusion yet.
    static let statusClusterIdleReserve: CGFloat = 152
    /// Horizontal breathing room between the address bar capsule and a top-band occlusion.
    static let occlusionGap: CGFloat = 8
    /// Space a floating control needs to clear the horizontal bottom toolbar.
    static let bottomToolbarClearance: CGFloat = 58
    /// Compact address pill while reading: Safari's size, centered where the status bar was.
    static let compactPillHeight: CGFloat = 28
    static let compactPillTop: CGFloat = 8
    /// The pill's site name; the UIFont twin measures it so the capsule fits the text.
    static let pillFont = Font.footnote.weight(.medium)
    static let pillMaxDynamicTypeSize: DynamicTypeSize = .xxxLarge
    static let pillMaxContentSizeCategory: UIContentSizeCategory = .extraExtraExtraLarge
    static var pillUIFont: UIFont {
        let live = UIFont.preferredFont(forTextStyle: .footnote).pointSize
        let capped = UIFont.preferredFont(
            forTextStyle: .footnote,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: pillMaxContentSizeCategory)
        ).pointSize
        return UIFont.systemFont(ofSize: min(live, capped), weight: .medium)
    }
    static let secondaryInk = Color(uiColor: CuriumPalette.dynamic(light: 0x565260, dark: 0xB9B5C4))
    static let cardBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.09)
            : UIColor(white: 0, alpha: 0.085)
    })
    static let cardShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .clear
            : UIColor(white: 0, alpha: 0.04)
    })
    static let editorialRule = Color(uiColor: .separator).opacity(0.45)
}

/// Pure host, monogram, deduplication, and Favorite-URL normalization helpers shared by
/// Start Page, Library, and Add Favorite sheets.
enum CuriumSiteIdentity {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let noisyHostPrefixes = ["www.", "m.", "mobile."]
    private static let boilerplateTitles: Set<String> = [
        "just a moment...",
        "just a moment…",
        "attention required! | cloudflare",
        "attention required!",
        "redirecting...",
        "redirecting…",
        "access denied",
    ]

    /// Returns a clean Start Page title, replacing transient bot-challenge / redirect boilerplate
    /// or raw URL strings with `cleanHost`.
    static func displayTitle(rawTitle: String, cleanHost: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cleanHost }
        let lowered = trimmed.folding(options: .caseInsensitive, locale: posixLocale)
        if boilerplateTitles.contains(lowered)
            || lowered.hasPrefix("http://")
            || lowered.hasPrefix("https://") {
            return cleanHost
        }
        return trimmed
    }

    /// Strips a single leading `www.`, `m.`, or `mobile.` prefix for clean display and monograms.
    static func cleanHost(from rawHost: String) -> String {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowered = trimmed.folding(options: .caseInsensitive, locale: posixLocale)
        for prefix in noisyHostPrefixes where lowered.hasPrefix(prefix) && trimmed.count > prefix.count {
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            return String(trimmed[start...])
        }
        return trimmed
    }

    static func cleanHost(for url: URL) -> String {
        let raw = url.host(percentEncoded: false) ?? url.host() ?? ""
        return cleanHost(from: raw)
    }

    /// Extracts a single uppercase monogram initial from the meaningful host label
    /// (`www.nytimes.com` -> `"N"`, `docs.google.com` -> `"D"`).
    static func monogramInitial(forHost rawHost: String) -> String {
        let cleaned = cleanHost(from: rawHost)
        let candidate = cleaned.first(where: { $0.isLetter || $0.isNumber }) ?? cleaned.first
        return candidate.map { String($0).localizedUppercase } ?? "·"
    }

    /// Canonical host key for Start Page deduplication (`http`/`https` only, lowercased POSIX,
    /// one noisy prefix stripped, preserving non-default ports).
    static func canonicalSiteKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host(percentEncoded: false),
              !rawHost.isEmpty else {
            return nil
        }
        let cleaned = cleanHost(from: rawHost).folding(options: .caseInsensitive, locale: posixLocale)
        guard !cleaned.isEmpty else { return nil }
        if let port = url.port, port != 80, port != 443 {
            return "\(cleaned):\(port)"
        }
        return cleaned
    }

    /// Exact normalized URL string key used to avoid duplicating Favorites in Recent History.
    static func normalizedURLKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.folding(options: .caseInsensitive, locale: posixLocale) else {
            return url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        components.scheme = scheme
        components.host = cleanHost(from: host)
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path == "/" {
            components.path = ""
        }
        return components.string ?? url.absoluteString
    }

    /// Normalizes and validates a user-entered website address for saving into Favorites.
    /// Prepends `https://` when no scheme is present; strictly permits only `http` / `https`
    /// with no whitespace and a valid dotted domain, `localhost`, or IP literal.
    static func normalizedFavoriteURL(from rawInput: String) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else if let colon = trimmed.firstIndex(of: ":"),
                  colon > trimmed.startIndex,
                  trimmed[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
                  !trimmed[..<colon].allSatisfy(\.isNumber) {
            // Distinguish `javascript:alert(1)` / `data:...` / `file:...` from `localhost:8080` or `example.com:8443`.
            let afterColon = trimmed[trimmed.index(after: colon)...]
            let portPrefix = afterColon.prefix { $0.isNumber }
            let looksLikeHostPort = !portPrefix.isEmpty
                && (portPrefix.endIndex == afterColon.endIndex
                    || afterColon[portPrefix.endIndex] == "/"
                    || afterColon[portPrefix.endIndex] == "?"
                    || afterColon[portPrefix.endIndex] == "#")
            if looksLikeHostPort {
                withScheme = "https://\(trimmed)"
            } else {
                return nil
            }
        } else {
            withScheme = "https://\(trimmed)"
        }

        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host,
              !rawHost.isEmpty,
              let url = components.url else {
            return nil
        }

        let host = rawHost.folding(options: .caseInsensitive, locale: posixLocale)
        if host == "localhost" {
            return url
        }
        // IPv6 literal (`[::1]`) or IPv4 address.
        if host.contains(":") {
            return url
        }
        if isIPv4Literal(host) {
            return url
        }
        // Standard domain must contain a dot and non-empty labels on both sides (non-empty TLD).
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              let tld = labels.last, tld.count >= 2 else {
            return nil
        }
        return url
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let byte = Int(part), (0...255).contains(byte) else { return false }
            return true
        }
    }
}
