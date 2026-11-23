import SwiftUI
import UIKit

/// Pure, testable iPhone Duo fold-invariant geometry for `CuriumStartPage`.
/// Locks `161 pt` Favorite plinths and `334 pt` Recent ledger rows across both Inner Landscape
/// Flat (`680 pt` centered spread) and Book Pose (`334 + 72 hinge gutter + 334` around `.division`)
/// so bending the hinge parts the two leaves cleanly with zero text reflow or column-count jump.
struct CuriumStartPageLayoutMetrics: Equatable, Sendable {
    struct Fold: Equatable, Sendable {
        let frame: CGRect
        let isVertical: Bool
    }

    let viewport: CGRect
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let spreadWidth: CGFloat
    let leafWidth: CGFloat
    let hingeGutter: CGFloat
    let isDualLeafBookPose: Bool
    let isWideHeader: Bool
    let favoriteColumns: Int
    let favoriteCardWidth: CGFloat
    let recentColumns: Int
    let recentCardWidth: CGFloat
    let gridSpacing: CGFloat

    /// Local-coordinate leaf rects in Book Pose for leaf-scoped skylight gradients.
    let leftLeafLocalRect: CGRect?
    let rightLeafLocalRect: CGRect?

    static func resolve(
        bounds: CGRect,
        fold: Fold?,
        isAccessibilitySize: Bool = false,
        layoutDirection: LayoutDirection = .leftToRight
    ) -> CuriumStartPageLayoutMetrics {
        let gridSpacing: CGFloat = 12
        let safeWidth = max(240, bounds.width)

        // 1. Vertical `.division` (Book Pose or Split View edge crease).
        if let fold, fold.isVertical, fold.frame.intersects(bounds) {
            let leftSpan = max(0, fold.frame.minX - bounds.minX)
            let rightSpan = max(0, bounds.maxX - fold.frame.maxX)

            if min(leftSpan, rightSpan) >= 320 {
                // Dual-Leaf Book Pose (`867 pt` Inner Landscape w/ `40 pt` center crease).
                let foldPadding: CGFloat = 16
                let hingeGutter = fold.frame.width + 2 * foldPadding
                let leafWidth = floor(min(334, min(leftSpan, rightSpan) - foldPadding - 20))
                let physicalLeft = max(0, fold.frame.minX - bounds.minX - foldPadding - leafWidth)
                let physicalRight = max(0, bounds.maxX - (fold.frame.maxX + foldPadding + leafWidth))
                let spreadWidth = leafWidth * 2 + hingeGutter

                let favCols = isAccessibilitySize ? 2 : 4
                let favCardWidth = favCols == 4 ? (leafWidth - gridSpacing) / 2 : leafWidth
                let recCols = isAccessibilitySize ? 1 : 2
                let recCardWidth = leafWidth

                let leftRect = CGRect(
                    x: fold.frame.minX - bounds.minX - foldPadding - leafWidth,
                    y: 0,
                    width: leafWidth,
                    height: bounds.height
                )
                let rightRect = CGRect(
                    x: fold.frame.maxX - bounds.minX + foldPadding,
                    y: 0,
                    width: leafWidth,
                    height: bounds.height
                )

                return CuriumStartPageLayoutMetrics(
                    viewport: bounds,
                    leadingInset: layoutDirection == .leftToRight ? physicalLeft : physicalRight,
                    trailingInset: layoutDirection == .leftToRight ? physicalRight : physicalLeft,
                    spreadWidth: spreadWidth,
                    leafWidth: leafWidth,
                    hingeGutter: hingeGutter,
                    isDualLeafBookPose: true,
                    isWideHeader: true,
                    favoriteColumns: favCols,
                    favoriteCardWidth: max(0, favCardWidth),
                    recentColumns: recCols,
                    recentCardWidth: max(0, recCardWidth),
                    gridSpacing: gridSpacing,
                    leftLeafLocalRect: leftRect,
                    rightLeafLocalRect: rightRect
                )
            }

            // Split View (`13.5 pt` edge division where one side is near zero).
            let physicalLeft: CGFloat
            let physicalRight: CGFloat
            if rightSpan >= leftSpan {
                physicalLeft = (fold.frame.maxX - bounds.minX) + 12
                physicalRight = 22
            } else {
                physicalLeft = 24
                physicalRight = (bounds.maxX - fold.frame.minX) + 12
            }
            let spreadWidth = max(220, safeWidth - physicalLeft - physicalRight)
            let favCols = isAccessibilitySize ? 1 : 2
            let favCardWidth = favCols == 2 ? (spreadWidth - gridSpacing) / 2 : spreadWidth
            return CuriumStartPageLayoutMetrics(
                viewport: bounds,
                leadingInset: layoutDirection == .leftToRight ? physicalLeft : physicalRight,
                trailingInset: layoutDirection == .leftToRight ? physicalRight : physicalLeft,
                spreadWidth: spreadWidth,
                leafWidth: spreadWidth,
                hingeGutter: gridSpacing,
                isDualLeafBookPose: false,
                isWideHeader: spreadWidth >= 560,
                favoriteColumns: favCols,
                favoriteCardWidth: max(0, favCardWidth),
                recentColumns: 1,
                recentCardWidth: max(0, spreadWidth),
                gridSpacing: gridSpacing,
                leftLeafLocalRect: nil,
                rightLeafLocalRect: nil
            )
        }

        // 2. Horizontal `.division` (Tabletop Pose on Inner Portrait) or Flat posture.
        let viewport: CGRect
        if let fold, !fold.isVertical, fold.frame.intersects(bounds) {
            let above = max(0, fold.frame.minY - bounds.minY - 12)
            let below = max(0, bounds.maxY - fold.frame.maxY - 12)
            if above >= 180 || above >= below {
                viewport = CGRect(x: 0, y: 0, width: bounds.width, height: above)
            } else {
                viewport = CGRect(x: 0, y: bounds.maxY - below, width: bounds.width, height: below)
            }
        } else {
            viewport = bounds
        }

        let spreadWidth: CGFloat
        if safeWidth >= 760 {
            // Inner Landscape Flat (`867 pt` -> `680 pt` centered spread, exact 161/334 pt lock).
            spreadWidth = min(680, safeWidth - 72)
        } else if safeWidth >= 600 {
            // Inner Portrait Flat (`669 pt` -> `600 pt` centered spread).
            spreadWidth = min(600, safeWidth - 64)
        } else if safeWidth >= 500 {
            // Outer Landscape (`594 pt` -> `522 pt` corner-safe spread).
            spreadWidth = min(522, safeWidth - 72)
        } else {
            // Outer Portrait (`382 pt` -> `342 pt` spread with 20 pt side margins).
            spreadWidth = max(240, safeWidth - 40)
        }

        let sideMargin = max(0, (safeWidth - spreadWidth) / 2)
        let baseFavCols = safeWidth >= 600 ? 4 : 2
        let favCols = isAccessibilitySize ? max(1, baseFavCols / 2) : baseFavCols
        let favCardWidth = (spreadWidth - CGFloat(favCols - 1) * gridSpacing) / CGFloat(favCols)

        let baseRecCols = safeWidth >= 600 ? 2 : 1
        let recCols = isAccessibilitySize ? 1 : baseRecCols
        let recCardWidth = (spreadWidth - CGFloat(recCols - 1) * gridSpacing) / CGFloat(recCols)
        let leafWidth = baseRecCols == 2 ? (spreadWidth - gridSpacing) / 2 : spreadWidth

        return CuriumStartPageLayoutMetrics(
            viewport: viewport,
            leadingInset: sideMargin,
            trailingInset: sideMargin,
            spreadWidth: spreadWidth,
            leafWidth: max(0, leafWidth),
            hingeGutter: gridSpacing,
            isDualLeafBookPose: false,
            isWideHeader: spreadWidth >= 560,
            favoriteColumns: favCols,
            favoriteCardWidth: max(0, favCardWidth),
            recentColumns: recCols,
            recentCardWidth: max(0, recCardWidth),
            gridSpacing: gridSpacing,
            leftLeafLocalRect: nil,
            rightLeafLocalRect: nil
        )
    }
}

/// Editorial Quiet start page for blank tabs: static palette-matched paper atmosphere,
/// monograph masthead + active profile posture bar, fold-invariant Favorites plinths,
/// and frecency-ranked local Frequently Visited ledger.
struct CuriumStartPage: View {
    let store: CuriumBrowserStore
    let topInset: CGFloat
    var bottomClearance: CGFloat = 32
    var onOpenProfiles: (() -> Void)? = nil
    var onOpenHistory: (() -> Void)? = nil

    @Environment(\.curiumPalette) private var palette
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var frequentSites: [CuriumFrequentSite] = []
    @State private var hasLoadedFrequentSites = false
    @State private var showingAddFavorite = false
    @State private var editingFavorite: CuriumBookmark?

    private var fingerprintStore: CuriumFingerprintStore { CuriumFingerprintStore.shared }

    private struct FrequentQueryKey: Equatable {
        let profileID: String
        let bookmarkRevision: Int
        let historyRevision: Int
        let favoritesEmpty: Bool
    }

    var body: some View {
        let favorites = store.library.favoriteBookmarks
        let effectiveFrequentSites = hasLoadedFrequentSites ? frequentSites : store.library.cachedFrequentSites
        let effectiveHasLoaded = hasLoadedFrequentSites || store.library.hasLoadedFrequentSites
        let queryKey = FrequentQueryKey(
            profileID: store.library.profileID,
            bookmarkRevision: store.library.bookmarkRevision,
            historyRevision: store.library.historyRevision,
            favoritesEmpty: favorites.isEmpty
        )

        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let fold = activeFold(in: proxy)
            let metrics = CuriumStartPageLayoutMetrics.resolve(
                bounds: bounds,
                fold: fold,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                layoutDirection: layoutDirection
            )

            ZStack(alignment: .top) {
                CuriumStartAtmosphere(palette: palette, metrics: metrics)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                ScrollView {
                    startPageContent(
                        favorites: favorites,
                        frequentSites: effectiveFrequentSites,
                        hasLoadedFrequentSites: effectiveHasLoaded,
                        metrics: metrics
                    )
                    .padding(.leading, metrics.leadingInset)
                    .padding(.trailing, metrics.trailingInset)
                    .frame(width: metrics.viewport.width, alignment: .topLeading)
                }
                .safeAreaPadding(.top, topInset + 18)
                .safeAreaPadding(.bottom, bottomClearance)
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: metrics.viewport.width, height: metrics.viewport.height)
                .position(x: metrics.viewport.midX, y: metrics.viewport.midY)

                CuriumStartPageTopVeil(palette: palette, height: topInset + 18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: queryKey) {
            let targetLimit = queryKey.favoritesEmpty ? 8 : 6
            let loaded = await store.library.frequentSites(
                excludingFavorites: nil,
                limit: targetLimit
            )
            guard !Task.isCancelled else { return }
            frequentSites = loaded
            hasLoadedFrequentSites = true
        }
        .sheet(isPresented: $showingAddFavorite) {
            CuriumAddFavoriteSheet(library: store.library)
        }
        .sheet(item: $editingFavorite) { bookmark in
            CuriumBookmarkEditor(
                library: store.library,
                subject: .bookmark(url: bookmark.url, title: bookmark.title)
            )
        }
    }

    // MARK: - Top-Level Content Choreography (States A / B / C)

    @ViewBuilder
    private func startPageContent(
        favorites: [CuriumBookmark],
        frequentSites: [CuriumFrequentSite],
        hasLoadedFrequentSites: Bool,
        metrics: CuriumStartPageLayoutMetrics
    ) -> some View {
        if favorites.isEmpty && frequentSites.isEmpty && hasLoadedFrequentSites {
            virginMonographCover(metrics: metrics)
        } else if !favorites.isEmpty {
            // State A: Populated Favorites + optional Frequently Visited shelf.
            VStack(alignment: .leading, spacing: 0) {
                headerBlock(metrics: metrics)
                hairlineDivider(metrics: metrics)
                    .padding(.top, 14)
                    .padding(.bottom, 24)

                favoritesShelf(favorites, metrics: metrics)

                if !frequentSites.isEmpty {
                    frequentSitesShelf(frequentSites, metrics: metrics)
                        .padding(.top, 28)
                }
            }
        } else {
            // State B (0 Favorites + Recent History present, or awaiting initial SQLite read).
            VStack(alignment: .leading, spacing: 0) {
                headerBlock(metrics: metrics)
                hairlineDivider(metrics: metrics)
                    .padding(.top, 14)
                    .padding(.bottom, 20)

                favoritesCompactInviteBar(metrics: metrics)
                    .padding(.bottom, 24)

                if !frequentSites.isEmpty {
                    frequentSitesShelf(frequentSites, metrics: metrics)
                }
            }
        }
    }

    // MARK: - Editorial Profile Header (No Decorative Logo)

    @ViewBuilder
    private func headerBlock(metrics: CuriumStartPageLayoutMetrics) -> some View {
        if metrics.isDualLeafBookPose {
            HStack(alignment: .center, spacing: metrics.hingeGutter) {
                profileHeaderControl
                    .frame(width: metrics.leafWidth, alignment: .leading)
                Color.clear
                    .frame(width: metrics.leafWidth, height: 1)
                    .accessibilityHidden(true)
            }
        } else {
            profileHeaderControl
                .frame(width: metrics.spreadWidth, alignment: .leading)
        }
    }

    private var profileHeaderControl: some View {
        let activeProfile = fingerprintStore.activeProfile
        let hasPendingRestart = fingerprintStore.hasPendingActiveProfileEngineChanges
        let hasPendingSwitch = fingerprintStore.hasPendingProfileIDChange
        let nextProfile = hasPendingSwitch ? fingerprintStore.nextLaunchProfile : nil
        let postureLine = activeProfile.conciseStartPostureSummary

        return Button {
            onOpenProfiles?()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: activeProfile.resolvedSymbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hasPendingRestart ? Color.orange : palette.tint)
                    .frame(width: 34, height: 34)
                    .background(
                        hasPendingRestart ? Color.orange.opacity(0.14) : palette.tile,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                (hasPendingRestart ? Color.orange : palette.tint).opacity(0.16),
                                lineWidth: 0.5
                            )
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 7) {
                        Text(activeProfile.displayName)
                            .font(.system(size: 23, weight: .medium, design: .serif))
                            .tracking(-0.4)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if hasPendingRestart {
                            postureStatusPill("RESTART", foreground: .orange, fill: .orange.opacity(0.14))
                        } else if let nextProfile {
                            postureStatusPill(
                                "→ \(nextProfile.displayName)",
                                foreground: nextProfile.resolvedPalette.tint,
                                fill: nextProfile.resolvedPalette.tile
                            )
                        }

                        if onOpenProfiles != nil {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(CuriumSpace.secondaryInk)
                                .accessibilityHidden(true)
                        }
                    }

                    Text(postureLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CuriumSpace.secondaryInk)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: CuriumSpace.tapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenProfiles == nil)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel(
            hasPendingRestart
                ? "Profile \(activeProfile.displayName), restart to apply changes, \(postureLine)"
                : nextProfile.map {
                    "Profile \(activeProfile.displayName), switching to \($0.displayName), \(postureLine)"
                } ?? "Profile \(activeProfile.displayName), \(postureLine)"
        )
        .accessibilityHint(onOpenProfiles == nil ? "" : "Opens Profile Switcher")
        .accessibilityIdentifier("curium.start.profileChip")
    }

    private func postureStatusPill(_ text: String, foreground: Color, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
    }

    @ViewBuilder
    private func hairlineDivider(metrics: CuriumStartPageLayoutMetrics) -> some View {
        if metrics.isDualLeafBookPose {
            // Keep the rule strictly beneath the Left Leaf header; never float an orphan rule above empty Right Leaf air.
            HStack(spacing: metrics.hingeGutter) {
                Rectangle()
                    .fill(CuriumSpace.editorialRule)
                    .frame(width: metrics.leafWidth, height: 0.5)
                Color.clear
                    .frame(width: metrics.leafWidth, height: 0.5)
                    .accessibilityHidden(true)
            }
        } else {
            Rectangle()
                .fill(CuriumSpace.editorialRule)
                .frame(width: metrics.spreadWidth, height: 0.5)
        }
    }

    // MARK: - State A: Favorites Shelf

    private func favoritesShelf(
        _ favorites: [CuriumBookmark],
        metrics: CuriumStartPageLayoutMetrics
    ) -> some View {
        let columns = makeGridColumns(
            count: metrics.favoriteColumns,
            cardWidth: metrics.favoriteCardWidth,
            metrics: metrics
        )

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                eyebrow: "FAVORITES",
                metrics: metrics
            ) {
                Button {
                    showingAddFavorite = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                        Text("Add")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(palette.tint)
                    .padding(.leading, 10)
                    .padding(.trailing, 0)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Favorite")
                .accessibilityIdentifier("curium.start.addFavorite")
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.gridSpacing) {
                ForEach(favorites) { favorite in
                    favoriteTile(favorite)
                }
            }
            .frame(width: metrics.spreadWidth, alignment: .leading)
        }
    }

    private func favoriteTile(_ favorite: CuriumBookmark) -> some View {
        let cleanHost = CuriumSiteIdentity.cleanHost(for: favorite.url)
        let hostDisplay = cleanHost.isEmpty ? favorite.host : cleanHost
        let title = favorite.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? hostDisplay
            : favorite.displayTitle

        return Button {
            openURL(favorite.url)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                CuriumSiteMonogram(host: hostDisplay, size: .seal)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .tracking(-0.1)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(hostDisplay)
                        .font(.caption2)
                        .foregroundStyle(CuriumSpace.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CuriumSpace.cardBorder, lineWidth: 0.5)
            }
            .shadow(color: CuriumSpace.cardShadow, radius: 8, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(title == hostDisplay ? "" : hostDisplay)
        .accessibilityHint("Opens in the current tab")
        .accessibilityIdentifier("curium.start.favorite")
        .contextMenu {
            Button { openURL(favorite.url) } label: {
                Label("Open", systemImage: "safari")
            }
            Button { store.newTab(url: favorite.url) } label: {
                Label("Open in New Tab", systemImage: "plus.square")
            }
            Button { editingFavorite = favorite } label: {
                Label("Edit Favorite…", systemImage: "pencil")
            }
            Button { UIPasteboard.general.url = favorite.url } label: {
                Label("Copy Link", systemImage: "link")
            }
            Divider()
            Button(role: .destructive) {
                store.library.deleteBookmarkItem(.bookmark(favorite))
            } label: {
                Label("Delete Bookmark", systemImage: "trash")
            }
        }
    }

    // MARK: - State B: Compact Favorites Invitation Bar

    private func favoritesCompactInviteBar(metrics: CuriumStartPageLayoutMetrics) -> some View {
        let barWidth = metrics.isDualLeafBookPose ? metrics.leafWidth : metrics.spreadWidth
        return HStack(spacing: 10) {
            Image(systemName: "star")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.tint)
                .accessibilityHidden(true)

            Text("Pin any site below or add a Favorite")
                .font(.footnote)
                .foregroundStyle(CuriumSpace.secondaryInk)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                showingAddFavorite = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                    Text("Add")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(palette.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(palette.tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.tint.opacity(0.14), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add Favorite")
            .accessibilityIdentifier("curium.start.addFavorite")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: barWidth, height: CuriumSpace.tapTarget, alignment: .leading)
        .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CuriumSpace.cardBorder, lineWidth: 0.5)
        }
        .shadow(color: CuriumSpace.cardShadow, radius: 8, x: 0, y: 2)
    }

    // MARK: - Frequently Visited Shelf

    private func frequentSitesShelf(
        _ sites: [CuriumFrequentSite],
        metrics: CuriumStartPageLayoutMetrics
    ) -> some View {
        let columns = makeGridColumns(
            count: metrics.recentColumns,
            cardWidth: metrics.recentCardWidth,
            metrics: metrics
        )

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                eyebrow: "FREQUENTLY VISITED",
                metrics: metrics
            ) {
                if let onOpenHistory {
                    Button(action: onOpenHistory) {
                        Text("History")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CuriumSpace.secondaryInk)
                            .padding(.leading, 10)
                            .padding(.trailing, 0)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open History")
                    .accessibilityIdentifier("curium.start.openHistory")
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(sites) { site in
                    frequentSiteRow(site)
                }
            }
            .frame(width: metrics.spreadWidth, alignment: .leading)
        }
    }

    private func frequentSiteRow(_ site: CuriumFrequentSite) -> some View {
        Button {
            openURL(site.url)
        } label: {
            HStack(spacing: 10) {
                CuriumSiteMonogram(host: site.cleanHost, size: .compactSeal)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(site.displayTitle)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(site.cleanHost)
                        .font(.caption2)
                        .foregroundStyle(CuriumSpace.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CuriumSpace.cardBorder, lineWidth: 0.5)
            }
            .shadow(color: CuriumSpace.cardShadow, radius: 8, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(site.displayTitle)
        .accessibilityValue(site.displayTitle == site.cleanHost ? "" : site.cleanHost)
        .accessibilityHint("Opens in the current tab")
        .accessibilityIdentifier("curium.start.frequent")
        .contextMenu {
            Button {
                Task {
                    _ = await store.library.saveBookmark(
                        url: site.url,
                        title: site.displayTitle,
                        in: CuriumBookmarkFolder.favoritesID
                    )
                }
            } label: {
                Label("Pin to Favorites", systemImage: "star")
            }
            Button { store.newTab(url: site.url) } label: {
                Label("Open in New Tab", systemImage: "plus.square")
            }
            Button { UIPasteboard.general.url = site.url } label: {
                Label("Copy Link", systemImage: "link")
            }
            Divider()
            Button(role: .destructive) {
                Task { await store.library.deleteSite(site) }
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
        }
    }

    // MARK: - State C: Virgin Profile Editorial Cover

    @ViewBuilder
    private func virginMonographCover(metrics: CuriumStartPageLayoutMetrics) -> some View {
        let activeProfile = fingerprintStore.activeProfile
        let overline = activeProfile.isPrimaryDefault ? "ACTIVE PROFILE" : "ISOLATED PROFILE"
        let displayTitle = activeProfile.displayName
        let topPad: CGFloat = metrics.viewport.height > 760 ? 56 : 34

        if metrics.isDualLeafBookPose {
            HStack(alignment: .top, spacing: metrics.hingeGutter) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(overline)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(palette.tint)

                    Text(displayTitle)
                        .font(.system(size: 36, weight: .medium, design: .serif))
                        .tracking(-0.9)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Rectangle()
                        .fill(CuriumSpace.editorialRule)
                        .frame(height: 0.5)
                        .padding(.top, 4)

                    Text("Enter an address above, or pin favorite sites to compose this index.")
                        .font(.subheadline)
                        .foregroundStyle(CuriumSpace.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: metrics.leafWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    virginDossierPlinth(activeProfile: activeProfile)
                    virginActionStrip
                }
                .frame(width: metrics.leafWidth, alignment: .leading)
            }
            .padding(.top, topPad)
        } else {
            let coverWidth = min(440, metrics.spreadWidth)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(overline)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(palette.tint)

                    Text(displayTitle)
                        .font(.system(size: 36, weight: .medium, design: .serif))
                        .tracking(-0.9)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                Rectangle()
                    .fill(CuriumSpace.editorialRule)
                    .frame(height: 0.5)

                virginDossierPlinth(activeProfile: activeProfile)

                virginActionStrip
                    .padding(.top, 2)
            }
            .frame(width: coverWidth, alignment: .leading)
            .frame(width: metrics.spreadWidth, alignment: .leading)
            .padding(.top, topPad)
        }
    }

    private func virginDossierPlinth(activeProfile: CuriumFingerprintProfile) -> some View {
        let hasPendingRestart = fingerprintStore.hasPendingActiveProfileEngineChanges
        let hasPendingSwitch = fingerprintStore.hasPendingProfileIDChange
        let nextProfile = hasPendingSwitch ? fingerprintStore.nextLaunchProfile : nil
        let postureLine = activeProfile.conciseStartPostureSummary
        let storageLine = activeProfile.isPrimaryDefault
            ? "Default Profile · Local SQLite"
            : "Isolated Cookies, Tabs & SQLite"

        return Button {
            onOpenProfiles?()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                dossierRow(key: "POSTURE") {
                    HStack(spacing: 6) {
                        Text(postureLine)
                            .font(.footnote.weight(.medium).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if hasPendingRestart {
                            postureStatusPill("RESTART", foreground: .orange, fill: .orange.opacity(0.14))
                        } else if let nextProfile {
                            postureStatusPill(
                                "→ \(nextProfile.displayName)",
                                foreground: nextProfile.resolvedPalette.tint,
                                fill: nextProfile.resolvedPalette.tile
                            )
                        }

                        Spacer(minLength: 4)

                        if onOpenProfiles != nil {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(CuriumSpace.secondaryInk)
                                .accessibilityHidden(true)
                        }
                    }
                }

                Rectangle()
                    .fill(CuriumSpace.editorialRule)
                    .frame(height: 0.5)

                dossierRow(key: "SEARCH") {
                    Text(store.library.searchEngine.title)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Rectangle()
                    .fill(CuriumSpace.editorialRule)
                    .frame(height: 0.5)

                dossierRow(key: "STORAGE") {
                    Text(storageLine)
                        .font(.footnote)
                        .foregroundStyle(CuriumSpace.secondaryInk)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CuriumSpace.cardBorder, lineWidth: 0.5)
            }
            .shadow(color: CuriumSpace.cardShadow, radius: 8, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(onOpenProfiles == nil)
        .accessibilityLabel("Profile \(activeProfile.displayName), \(postureLine)")
        .accessibilityHint(onOpenProfiles == nil ? "" : "Opens Profile Switcher")
        .accessibilityIdentifier("curium.start.profileChip")
    }

    private func dossierRow<Value: View>(
        key: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(CuriumSpace.secondaryInk)
                .frame(width: 78, alignment: .leading)

            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var virginActionStrip: some View {
        Button {
            showingAddFavorite = true
        } label: {
            Label("Add Favorite", systemImage: "plus")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.tint)
                .padding(.horizontal, 16)
                .frame(minHeight: CuriumSpace.tapTarget)
                .background(palette.tile, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(palette.tint.opacity(0.14), lineWidth: 0.5)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("curium.start.addFavorite")
    }

    // MARK: - Section Header & Grid Column Helpers

    @ViewBuilder
    private func sectionHeader<Trailing: View>(
        eyebrow: String,
        metrics: CuriumStartPageLayoutMetrics,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        if metrics.isDualLeafBookPose {
            HStack(alignment: .center, spacing: metrics.hingeGutter) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(CuriumSpace.secondaryInk)
                    .frame(width: metrics.leafWidth, alignment: .leading)

                HStack {
                    Spacer(minLength: 0)
                    trailing()
                }
                .frame(width: metrics.leafWidth, alignment: .trailing)
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(CuriumSpace.secondaryInk)
                Spacer(minLength: 8)
                trailing()
            }
            .frame(width: metrics.spreadWidth, alignment: .leading)
        }
    }

    private func makeGridColumns(
        count: Int,
        cardWidth: CGFloat,
        metrics: CuriumStartPageLayoutMetrics
    ) -> [GridItem] {
        (0..<count).map { index in
            let spacing: CGFloat
            if index == count - 1 {
                spacing = 0
            } else if metrics.isDualLeafBookPose && index == (count / 2) - 1 {
                spacing = metrics.hingeGutter
            } else {
                spacing = metrics.gridSpacing
            }
            return GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top)
        }
    }

    private func openURL(_ url: URL) {
        if let tab = store.activeTab {
            tab.load(url)
        } else {
            store.newTab(url: url)
        }
    }

    private func activeFold(in proxy: GeometryProxy) -> CuriumStartPageLayoutMetrics.Fold? {
        guard #available(iOS 27.1, *) else { return nil }
        let bounds = CGRect(origin: .zero, size: proxy.size)
        guard let region = proxy.reservedRegions(kind: .division, options: [.includeInactive])
            .first(where: { $0.isActive && $0.frame.intersects(bounds) }) else {
            return nil
        }
        return CuriumStartPageLayoutMetrics.Fold(
            frame: region.frame.intersection(bounds),
            isVertical: region.frame.height > region.frame.width
        )
    }
}

// MARK: - Static 1 Hz Atmospheric Backdrop & Seamless Top Veil

/// Static top-skylight wash scoped strictly to Start Page / Standby content surfaces.
/// Every `RadialGradient` tapers to `0.0` alpha *inside* its pane width so neither the
/// `40 pt` physical hinge nor the `84 pt` vertical bar boundary ever exhibits a hard clip seam.
/// Zero `TimelineView` / `.repeatForever` animations so ProMotion drops cleanly to 1 Hz at idle.
struct CuriumStartAtmosphere: View {
    let palette: CuriumPalette
    var metrics: CuriumStartPageLayoutMetrics? = nil

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = max(1, proxy.size.height)

            ZStack {
                palette.canvas

                if let metrics,
                   metrics.isDualLeafBookPose,
                   let leftRect = metrics.leftLeafLocalRect,
                   let rightRect = metrics.rightLeafLocalRect {
                    let leafRadius = min(160, leftRect.width * 0.48)
                    RadialGradient(
                        colors: [palette.atmosphereGlow, .clear],
                        center: UnitPoint(x: leftRect.midX / width, y: 0),
                        startRadius: 0,
                        endRadius: leafRadius
                    )
                    RadialGradient(
                        colors: [palette.atmosphereGlow, .clear],
                        center: UnitPoint(x: rightRect.midX / width, y: 0),
                        startRadius: 0,
                        endRadius: leafRadius
                    )
                } else {
                    let singleRadius = min(360, width * 0.46, height * 0.55)
                    RadialGradient(
                        colors: [palette.atmosphereGlow, .clear],
                        center: UnitPoint(x: 0.5, y: 0),
                        startRadius: 0,
                        endRadius: singleRadius
                    )
                }
            }
        }
    }
}

private struct CuriumStartPageTopVeil: View {
    let palette: CuriumPalette
    let height: CGFloat

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: palette.canvas, location: 0),
                .init(color: palette.canvas.opacity(0.88), location: 0.58),
                .init(color: palette.canvas.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: max(0, height))
    }
}

// MARK: - Add Favorite Sheet

/// Crisp minimal modal for pinning a website directly into the Favorites folder.
/// Never reads `UIPasteboard.general` automatically on appear (privacy-safe tap-only paste).
struct CuriumAddFavoriteSheet: View {
    let library: CuriumLibrary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.curiumPalette) private var palette
    @FocusState private var urlFocused: Bool

    @State private var rawURL = ""
    @State private var title = ""
    @State private var isSaving = false
    @State private var saveFailed = false

    private var normalizedURL: URL? {
        CuriumSiteIdentity.normalizedFavoriteURL(from: rawURL)
    }

    private var cleanPreviewHost: String {
        normalizedURL.map(CuriumSiteIdentity.cleanHost(for:)) ?? ""
    }

    private var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? cleanPreviewHost : trimmed
    }

    private var showsValidationHint: Bool {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && normalizedURL == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("Website (e.g. news.ycombinator.com)", text: $rawURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($urlFocused)
                            .accessibilityIdentifier("curium.addFavorite.url")

                        if rawURL.isEmpty {
                            Button("Paste Link") {
                                if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !pasted.isEmpty {
                                    rawURL = pasted
                                }
                            }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(palette.tint)
                            .buttonStyle(.plain)
                        }
                    }

                    TextField("Title (Optional)", text: $title)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("curium.addFavorite.title")
                } footer: {
                    if showsValidationHint {
                        Text("Enter a valid http:// or https:// website address.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Saves directly to Favorites on your Start Page.")
                    }
                }

                if normalizedURL != nil {
                    Section("Preview") {
                        HStack(spacing: 12) {
                            CuriumSiteMonogram(host: cleanPreviewHost, size: .seal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(resolvedTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(cleanPreviewHost)
                                    .font(.caption)
                                    .foregroundStyle(CuriumSpace.secondaryInk)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("Add Favorite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) { Label("Save", systemImage: "checkmark") }
                        .disabled(normalizedURL == nil || isSaving)
                        .accessibilityIdentifier("curium.addFavorite.save")
                }
            }
            .alert("Couldn’t Save Favorite", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    library.storageUnavailable
                        ? "Favorites can’t be saved right now because local storage is unavailable."
                        : "Please verify the website address and try again."
                )
            }
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.medium, .large])
        .onAppear { urlFocused = true }
    }

    private func save() {
        guard let url = normalizedURL, !isSaving else { return }
        isSaving = true
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let saved = await library.saveBookmark(
                url: url,
                title: finalTitle,
                in: CuriumBookmarkFolder.favoritesID
            )
            isSaving = false
            if saved { dismiss() } else { saveFailed = true }
        }
    }
}
