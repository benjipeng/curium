import SwiftUI
import UIKit

/// Live `.insetGrouped` transfer inspector presenting multi-lane byte-range slices,
/// throughput sparkline, 2-column fold-safe telemetry grid, diagnostics, and full lifecycle actions.
struct CuriumTransferInspectorView: View {
    @Environment(\.curiumPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    let store: CuriumBrowserStore
    let download: CuriumDownload
    var isEmbeddedInSplit: Bool = false
    var onOpenSavedFile: ((URL, String, Bool) -> Void)? = nil
    var onDeleted: (() -> Void)? = nil

    @State private var copiedURL = false
    @State private var copiedResetTask: Task<Void, Never>?

    private static let metricsColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var resolvedSavedURL: URL? {
        store.savedURL(for: download)
    }

    private var sourceURL: URL? {
        download.resolvedURL ?? download.originalURL
    }

    private var totalDisplayValue: String {
        if let known = download.knownTotalBytes, known > 0 {
            return CuriumTransferFormatters.bytes(known)
        }
        if let estimated = download.estimatedTotalBytes, estimated > 0 {
            return "~\(CuriumTransferFormatters.bytes(estimated))"
        }
        return "Stream"
    }

    private var lanesDisplayValue: String {
        if download.transportKind == .multiLaneRange {
            return "\(download.activeLanes) / \(download.configuredLanes)"
        }
        return download.isActive ? "1 / 1" : "0 / \(max(1, download.configuredLanes))"
    }

    private var completedSliceCount: Int {
        download.slices.reduce(into: 0) { count, slice in
            if slice.isComplete { count += 1 }
        }
    }

    var body: some View {
        let badge = CuriumTransferFormatters.badge(for: download, tint: palette.tint)

        List {
            // 1. Overview + 10 pt Heatmap + Lifecycle Controls
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: download.symbolName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(palette.tint)
                            .frame(width: 24, alignment: .center)
                            .padding(.top, 1)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(download.filename)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

                            Text(CuriumTransferFormatters.subtitle(for: download))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(badge.title)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(badge.foreground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(badge.background, in: Capsule())
                            .fixedSize()
                    }

                    CuriumByteRangeHeatmapBar(
                        slices: download.slices,
                        totalBytes: download.knownTotalBytes,
                        fallbackFraction: download.fraction,
                        phase: download.phase,
                        height: 10
                    )

                    if download.phase == .remuxing || download.phase == .saving || download.phase == .probing {
                        Text(CuriumTransferFormatters.compactProgressLine(
                            for: download,
                            includeETA: false,
                            includeLanes: false
                        ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    primaryActionBar
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text(download.transportKind.displayTitle)
                    Spacer()
                    if download.transportKind == .multiLaneRange {
                        Text("\(download.configuredLanes)× Lanes")
                            .foregroundStyle(palette.tint)
                    }
                }
                .font(.caption.monospacedDigit())
            }

            // 2. Live Throughput Sparkline + Fold-Safe 2-Column Metrics Grid
            Section("Throughput & Telemetry") {
                VStack(alignment: .leading, spacing: 12) {
                    CuriumThroughputSparklineView(
                        samples: download.throughputSamples,
                        peakBytesPerSec: download.peakSpeedBytesPerSec,
                        isActive: download.phase == .downloading,
                        height: 52
                    )

                    LazyVGrid(columns: Self.metricsColumns, alignment: .leading, spacing: 10) {
                        metricCell(
                            title: "Transferred",
                            value: CuriumTransferFormatters.bytes(download.receivedBytes)
                        )
                        metricCell(
                            title: "Total",
                            value: totalDisplayValue
                        )
                        metricCell(
                            title: "Speed",
                            value: download.phase == .downloading
                                ? CuriumTransferFormatters.speed(download.speedBytesPerSec)
                                : "—",
                            highlightTint: download.phase == .downloading && download.speedBytesPerSec >= 1
                                ? palette.tint
                                : nil
                        )
                        metricCell(
                            title: "Peak",
                            value: download.peakSpeedBytesPerSec >= 1
                                ? CuriumTransferFormatters.speed(download.peakSpeedBytesPerSec)
                                : "—"
                        )
                        metricCell(
                            title: "Active Lanes",
                            value: lanesDisplayValue
                        )
                        metricCell(
                            title: "ETA",
                            value: download.phase == .downloading
                                ? CuriumTransferFormatters.etaDisplay(download.etaSeconds)
                                : "—"
                        )
                    }
                }
                .padding(.vertical, 4)

                if let totalSegments = download.totalSegments, totalSegments > 0 {
                    LabeledContent("HLS Segments", value: "\(download.completedSegments) / \(totalSegments)")
                        .font(.subheadline.monospacedDigit())
                }
            }

            // 3. Per-Slice Breakdown
            if !download.slices.isEmpty {
                Section("Byte-Range Slices (\(completedSliceCount)/\(download.slices.count))") {
                    ForEach(download.slices) { slice in
                        sliceRow(slice)
                    }
                }
            }

            // 4. Source & Diagnostics
            Section("Source & Diagnostics") {
                if let url = sourceURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Button {
                            copySourceURL(url)
                        } label: {
                            Label(
                                copiedURL ? "Copied URL" : "Copy URL",
                                systemImage: copiedURL ? "checkmark" : "doc.on.doc"
                            )
                            .font(.caption.weight(.medium))
                            .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(palette.tint)
                    }
                    .padding(.vertical, 2)
                }

                if let pageURL = download.pageURL {
                    LabeledContent("Referrer Page") {
                        Text(pageURL.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }

                if let mime = download.mimeType, !mime.isEmpty {
                    LabeledContent("MIME Type", value: mime)
                        .font(.subheadline)
                }

                if let eTag = download.eTag, !eTag.isEmpty {
                    LabeledContent("ETag") {
                        Text(eTag)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if let destination = download.saveDestinationLabel, !destination.isEmpty {
                    LabeledContent("Destination", value: destination)
                        .font(.subheadline)
                }

                LabeledContent("Elapsed", value: CuriumTransferFormatters.duration(download.elapsedSeconds))
                    .font(.subheadline.monospacedDigit())

                LabeledContent(
                    "Created",
                    value: download.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.subheadline)

                if let completedAt = download.completedAt {
                    LabeledContent(
                        "Completed",
                        value: completedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    .font(.subheadline)
                }

                if let failure = download.failure, !failure.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Error", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }

            // 5. Manage Transfer
            Section {
                if download.isActive || download.phase == .queued || download.phase == .paused || download.phase == .pendingConfirmation {
                    Button(role: .destructive) {
                        store.cancelDownload(download)
                    } label: {
                        Label("Cancel Transfer", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    store.removeTransfer(download)
                    onDeleted?()
                    if !isEmbeddedInSplit {
                        dismiss()
                    }
                } label: {
                    Label("Remove from Transfers", systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            if !isEmbeddedInSplit, let fileURL = resolvedSavedURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onDisappear {
            copiedResetTask?.cancel()
            copiedResetTask = nil
        }
    }

    @ViewBuilder
    private var primaryActionBar: some View {
        HStack(spacing: 10) {
            if download.phase == .pendingConfirmation {
                Button {
                    Task { await store.startDownload(download) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Save Download")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(palette.tint)
            } else if download.canPause {
                Button {
                    store.pauseDownload(download)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pause.fill")
                        Text("Pause")
                    }
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(palette.tint)
            } else if download.canResume {
                Button {
                    store.resumeDownload(download)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                        Text("Resume")
                    }
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(palette.tint)
            } else if download.canRetry {
                Button {
                    store.retryDownload(download)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(palette.tint)
            }

            if download.phase == .completed, let fileURL = resolvedSavedURL {
                if let onOpenSavedFile {
                    Button {
                        onOpenSavedFile(fileURL, download.filename, download.isPDF)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: download.isPDF ? "doc.richtext" : "eye")
                            Text(download.isPDF ? "Open in Tab" : "Open")
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(palette.tint)
                }

                ShareLink(item: fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(palette.tint)
            }
        }
    }

    private func metricCell(
        title: String,
        value: String,
        highlightTint: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(highlightTint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sliceRow(_ slice: CuriumByteRangeSlice) -> some View {
        let isRunning = slice.isActiveLane && download.phase == .downloading && !slice.isComplete
        let iconName = slice.isComplete
            ? "checkmark.circle.fill"
            : (isRunning ? "bolt.circle.fill" : "circle.dotted")
        let iconColor: Color = slice.isComplete
            ? .green
            : (isRunning ? palette.tint : .secondary)
        let pct = Int((slice.fraction * 100).rounded())

        return HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 16, alignment: .center)
                .accessibilityHidden(true)

            Text(String(format: "#%02d", slice.id))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text("\(CuriumTransferFormatters.bytes(slice.startOffset)) → \(CuriumTransferFormatters.bytes(slice.endOffset))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 6)

            Text("\(pct)%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(slice.isComplete ? Color.green : Color.primary)
        }
    }

    private func copySourceURL(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
        copiedURL = true
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard !Task.isCancelled else { return }
            copiedURL = false
            copiedResetTask = nil
        }
    }
}
