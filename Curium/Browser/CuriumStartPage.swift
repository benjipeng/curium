import SwiftUI

/// Favorites in display order on a blank tab.
struct CuriumStartPage: View {
    let store: CuriumBrowserStore
    let topInset: CGFloat
    var onOpenProfiles: (() -> Void)? = nil

    @Environment(\.curiumPalette) private var palette
    @Environment(\.layoutDirection) private var layoutDirection

    private var fingerprintStore: CuriumFingerprintStore { CuriumFingerprintStore.shared }

    private let columnSpacing: CGFloat = 16
    private let edgeMargin: CGFloat = 24
    private let foldMargin: CGFloat = 8

    private struct Fold {
        let frame: CGRect
        let isVertical: Bool
    }

    var body: some View {
        let favorites = store.library.favoriteBookmarks

        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let fold = activeFold(in: proxy)
            let viewport = contentFrame(in: bounds, fold: fold, isEmpty: favorites.isEmpty)

            ScrollView {
                if favorites.isEmpty {
                    emptyPage
                } else {
                    favoriteGrid(favorites, in: viewport, fold: fold)
                }
            }
            .defaultScrollAnchor(favorites.isEmpty ? .center : .top, for: .alignment)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: viewport.width, height: viewport.height)
            .position(x: viewport.midX, y: viewport.midY)
        }
        .padding(.top, topInset)
    }

    private var profilePersonaChip: some View {
        let activeProfile = fingerprintStore.activeProfile
        let hasPendingSwitch = fingerprintStore.hasPendingProfileSwitch
        let nextProfile = hasPendingSwitch ? fingerprintStore.nextLaunchProfile : nil

        return Button {
            onOpenProfiles?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeProfile.resolvedSymbolName)
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)

                Text(activeProfile.displayName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)

                if let nextProfile {
                    Circle()
                        .fill(nextProfile.resolvedPalette.tint)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text("→ \(nextProfile.displayName)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if onOpenProfiles != nil {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.75)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(palette.tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(palette.tile, in: Capsule())
            .frame(minHeight: CuriumSpace.tapTarget)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(onOpenProfiles == nil)
        .accessibilityLabel(
            nextProfile.map {
                "Profile \(activeProfile.displayName), next launch \($0.displayName)"
            } ?? "Profile \(activeProfile.displayName)"
        )
        .accessibilityHint(onOpenProfiles == nil ? "" : "Opens Profile Switcher")
        .accessibilityIdentifier("curium.start.profileChip")
    }

    private var emptyPage: some View {
        VStack(spacing: 16) {
            profilePersonaChip
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 7) {
                Text("96")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Text("Cm")
                    .font(.system(size: 40, weight: .medium, design: .serif))
                    .tracking(-2.5)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(palette.tint)
            .frame(width: 96, height: 96)
            .background(palette.tile, in: .rect(cornerRadius: 22))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Curium, element 96")

            Text("Pages saved to Favorites in Bookmarks appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(edgeMargin)
        .frame(maxWidth: .infinity)
    }

    private func favoriteGrid(_ favorites: [CuriumBookmark], in viewport: CGRect, fold: Fold?) -> some View {
        let count = columnCount(for: viewport.width)
        let innerFold = fold.flatMap { fold in
            fold.isVertical && fold.frame.intersects(viewport) ? fold.frame : nil
        }
        let cellWidth: CGFloat
        if let innerFold {
            let perSide = count / 2
            let paneWidth = min(innerFold.minX - viewport.minX, viewport.maxX - innerFold.maxX)
            cellWidth = (paneWidth - edgeMargin - foldMargin - CGFloat(perSide - 1) * columnSpacing) / CGFloat(perSide)
        } else {
            cellWidth = (viewport.width - 2 * edgeMargin - CGFloat(count - 1) * columnSpacing) / CGFloat(count)
        }

        let width = max(0, min(128, cellWidth))
        let columns = (0..<count).map { index in
            let hingeGap = innerFold.map { $0.width + 2 * foldMargin }
            let spacing = index == count / 2 - 1 ? hingeGap ?? columnSpacing : columnSpacing
            return GridItem(.fixed(width), spacing: spacing, alignment: .top)
        }

        return VStack(spacing: 16) {
            if let innerFold {
                let leftSpan = max(0, innerFold.minX - viewport.minX - foldMargin)
                let rightSpan = max(0, viewport.maxX - innerFold.maxX - foldMargin)
                let usePhysicalLeft = leftSpan > rightSpan
                    || (leftSpan == rightSpan && layoutDirection == .leftToRight)
                let physicalLeftPad: CGFloat = usePhysicalLeft
                    ? edgeMargin
                    : (innerFold.maxX - viewport.minX + foldMargin)
                let physicalRightPad: CGFloat = usePhysicalLeft
                    ? (viewport.maxX - innerFold.minX + foldMargin)
                    : edgeMargin

                profilePersonaChip
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, layoutDirection == .leftToRight ? physicalLeftPad : physicalRightPad)
                    .padding(.trailing, layoutDirection == .leftToRight ? physicalRightPad : physicalLeftPad)
            } else {
                profilePersonaChip
                    .padding(.horizontal, edgeMargin)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(favorites) { favorite in
                    shortcut(favorite)
                }
            }
            .frame(maxWidth: .infinity)
            .offset(x: innerFold.map { $0.midX - viewport.midX } ?? 0)
        }
        .padding(.top, 16)
        .padding(.bottom, edgeMargin)
    }

    private func shortcut(_ favorite: CuriumBookmark) -> some View {
        let host = favorite.host
        let title = favorite.displayTitle

        return Button {
            if let tab = store.activeTab {
                tab.load(favorite.url)
            } else {
                store.newTab(url: favorite.url)
            }
        } label: {
            VStack(spacing: 8) {
                CuriumSiteMonogram(host: host, size: .shortcut)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(title == host ? "" : host)
        .accessibilityHint("Opens in the current tab")
        .accessibilityIdentifier("curium.start.favorite")
        .contextMenu {
            Button { store.newTab(url: favorite.url) } label: {
                Label("Open in New Tab", systemImage: "plus.square")
            }
            Button(role: .destructive) { store.library.deleteBookmarkItem(.bookmark(favorite)) } label: {
                Label("Delete Bookmark", systemImage: "trash")
            }
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        width >= 600 ? 4 : 2
    }

    private func activeFold(in proxy: GeometryProxy) -> Fold? {
        guard #available(iOS 27.1, *) else { return nil }
        let bounds = CGRect(origin: .zero, size: proxy.size)
        guard let region = proxy.reservedRegions(kind: .division)
            .first(where: { $0.isActive && $0.frame.intersects(bounds) }) else { return nil }
        return Fold(frame: region.frame.intersection(bounds), isVertical: region.frame.height > region.frame.width)
    }

    private func contentFrame(in bounds: CGRect, fold: Fold?, isEmpty: Bool) -> CGRect {
        guard let fold else { return bounds }

        if fold.isVertical {
            let left = max(0, fold.frame.minX - foldMargin)
            let right = max(0, bounds.maxX - fold.frame.maxX - foldMargin)
            let perSide = columnCount(for: bounds.width) / 2
            let minimumPane = edgeMargin + CGFloat(perSide) * 80 + CGFloat(perSide - 1) * columnSpacing
            if !isEmpty && min(left, right) >= minimumPane { return bounds }

            // Keep one-pane content clear of both central and edge divisions.
            if left > right || (left == right && layoutDirection == .leftToRight) {
                return CGRect(x: 0, y: 0, width: left, height: bounds.height)
            }
            return CGRect(x: bounds.maxX - right, y: 0, width: right, height: bounds.height)
        }

        // A bounded scroll view prevents a row from crossing a horizontal fold while scrolling.
        let above = max(0, fold.frame.minY - foldMargin)
        let below = max(0, bounds.maxY - fold.frame.maxY - foldMargin)
        if above >= 180 || above >= below {
            return CGRect(x: 0, y: 0, width: bounds.width, height: above)
        }
        return CGRect(x: 0, y: bounds.maxY - below, width: bounds.width, height: below)
    }
}
