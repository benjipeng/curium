import SwiftUI

struct CuriumTabsSheet: View {
    let store: CuriumBrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection

    private struct RowGeometry {
        let count: Int
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let leftInset: CGFloat
        let rightInset: CGFloat
    }

    private struct TabRow: Identifiable {
        let id: String
        let tabs: [CuriumTabModel]
    }

    var body: some View {
        VStack(spacing: 0) {
            CuriumSheetHeader(title: "Tabs")
            GeometryReader { proxy in
                let width = proxy.size.width
                let count = width < 680 ? 2 : 4
                let division = activeDivision(in: proxy)
                let vertical = division.flatMap { $0.height > $0.width ? $0 : nil }
                let horizontal = division.flatMap { $0.width > $0.height ? $0 : nil }
                let above = horizontal.map { max(0, min(proxy.size.height, $0.minY - 8)) }
                let below = horizontal.map { max(0, proxy.size.height - $0.maxY - 8) }
                let contentHeight = max(above ?? proxy.size.height, below ?? 0)
                let top = (below ?? 0) > (above ?? proxy.size.height) ? proxy.size.height - contentHeight : 0
                let rowGeo = computeRowGeometry(width: width, count: count, fold: vertical)
                let rows = makeRows(from: store.tabs, columns: count)

                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(rows) { row in
                            tabRow(row.tabs, geo: rowGeo)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(height: contentHeight)
                .offset(y: top)
                .scrollBounceBehavior(.basedOnSize)
            }
            HStack {
                Text("\(store.tabs.count) \(store.tabs.count == 1 ? "tab" : "tabs")")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if store.newTab() { dismiss() }
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: CuriumSpace.tapTarget)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .presentationDetents([.large])
        .curiumSheetErrorAlert(store: store)
    }

    private func activeDivision(in proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        let canvas = CGRect(origin: .zero, size: proxy.size)
        return proxy.reservedRegions(kind: .division)
            .first { $0.isActive && $0.frame.intersects(canvas) }?.frame.intersection(canvas)
    }

    private func computeRowGeometry(width: CGFloat, count: Int, fold: CGRect?) -> RowGeometry {
        let half = count / 2
        var leftInset: CGFloat = 16
        var rightInset: CGFloat = 16
        if let fold {
            let left = max(0, fold.minX - leftInset - 8)
            let right = max(0, width - rightInset - fold.maxX - 8)
            let minimumGroup = CGFloat(half) * 96 + CGFloat(half - 1) * 14
            if min(left, right) >= minimumGroup {
                return RowGeometry(count: count, leftWidth: left, rightWidth: right, leftInset: leftInset, rightInset: rightInset)
            }
            if left >= right {
                rightInset = max(rightInset, width - fold.minX + 8)
            } else {
                leftInset = max(leftInset, fold.maxX + 8)
            }
        }
        let group = max(0, (width - leftInset - rightInset - 14) / 2)
        return RowGeometry(count: count, leftWidth: group, rightWidth: group, leftInset: leftInset, rightInset: rightInset)
    }

    private func makeRows(from allTabs: [CuriumTabModel], columns count: Int) -> [TabRow] {
        guard count > 0, !allTabs.isEmpty else { return [] }
        var rows: [TabRow] = []
        rows.reserveCapacity((allTabs.count + count - 1) / count)
        var start = 0
        while start < allTabs.count {
            let end = min(allTabs.count, start + count)
            let slice = Array(allTabs[start..<end])
            rows.append(TabRow(id: slice[0].id, tabs: slice))
            start = end
        }
        return rows
    }

    private func tabRow(_ rowTabs: [CuriumTabModel], geo: RowGeometry) -> some View {
        let half = geo.count / 2
        let mid = min(rowTabs.count, half)
        let leftToRight = layoutDirection == .leftToRight

        return HStack(spacing: 0) {
            cards(tabs: rowTabs[0..<mid], columns: half)
                .frame(width: leftToRight ? geo.leftWidth : geo.rightWidth)
            Spacer(minLength: 0)
            cards(tabs: rowTabs[mid..<rowTabs.count], columns: half)
                .frame(width: leftToRight ? geo.rightWidth : geo.leftWidth)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, leftToRight ? geo.leftInset : geo.rightInset)
        .padding(.trailing, leftToRight ? geo.rightInset : geo.leftInset)
    }

    private func cards(tabs rowTabs: ArraySlice<CuriumTabModel>, columns: Int) -> some View {
        HStack(spacing: 14) {
            ForEach(rowTabs) { tab in
                CuriumTabCard(tab: tab, selected: store.activeTab?.id == tab.id) {
                    store.select(tab)
                    dismiss()
                } onClose: {
                    store.close(tab)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(0..<max(0, columns - rowTabs.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct CuriumTabCard: View {
    let tab: CuriumTabModel
    let selected: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    @Environment(\.curiumPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 122)
                    .overlay(alignment: .top) {
                        if let snapshot = tab.thumbnail {
                            Image(uiImage: snapshot)
                                .resizable()
                                .scaledToFill()
                        } else {
                            ZStack {
                                palette.tile
                                if tab.isShowingPDF {
                                    Image(systemName: "doc.richtext")
                                        .font(.title2.weight(.light))
                                } else if tab.url == nil {
                                    Text("Cm").font(.system(.title, design: .serif).weight(.medium))
                                } else {
                                    Image(systemName: "globe")
                                        .font(.title2.weight(.light))
                                }
                            }
                            .foregroundStyle(palette.tint)
                        }
                    }
                    .clipped()
                HStack(spacing: 5) {
                    if selected {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(palette.tint)
                    }
                    Text(tab.displayTitle)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? palette.tint : Color(uiColor: .separator), lineWidth: selected ? 2 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Label("Close Tab", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.displayTitle)")
        }
    }
}
