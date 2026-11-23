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
}
