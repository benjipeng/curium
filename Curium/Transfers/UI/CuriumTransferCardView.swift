import SwiftUI

/// Native `.insetGrouped` transfer row displaying live multi-lane heatmap, speed, ETA,
/// lane telemetry, and quick Pause / Resume / Retry / Save controls.
/// Strictly zero `.glassEffect()` inside scrolling `List` rows (iPhone Duo Liquid Glass Invariant #4).
struct CuriumTransferCardView: View {
    @Environment(\.curiumPalette) private var palette

    let download: CuriumDownload
    var isSelected: Bool = false
    let onPrimaryAction: () -> Void

    private var showsHeatmap: Bool {
        switch download.phase {
        case .probing, .downloading, .remuxing, .saving, .paused:
            return true
        case .failed:
            return download.receivedBytes > 0
        case .pendingConfirmation, .queued, .completed, .cancelled:
            return false
        }
    }

    private var iconStyle: AnyShapeStyle {
        if download.phase == .completed {
            return AnyShapeStyle(.green)
        }
        if download.phase == .failed {
            return AnyShapeStyle(.red)
        }
        if download.isActive || download.isPDF || download.isVideo || download.isAudio {
            return AnyShapeStyle(palette.tint)
        }
        return AnyShapeStyle(.secondary)
    }

    var body: some View {
        let badge = CuriumTransferFormatters.badge(for: download, tint: palette.tint)

        VStack(alignment: .leading, spacing: 7) {
            // Top row: file SF Symbol + filename (middle truncation) + semantic pill badge
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: download.symbolName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(iconStyle)
                    .frame(width: 18, alignment: .center)
                    .accessibilityHidden(true)

                Text(download.filename)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(badge.title)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(badge.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badge.background, in: Capsule())
                    .fixedSize()
            }

            // Subtitle: domain · transport
            Text(CuriumTransferFormatters.subtitle(for: download))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Middle: multi-lane byte-range heatmap bar
            if showsHeatmap {
                CuriumByteRangeHeatmapBar(
                    slices: download.slices,
                    totalBytes: download.knownTotalBytes,
                    fallbackFraction: download.fraction,
                    phase: download.phase,
                    height: 7
                )
            }

            if download.phase == .failed, let failure = download.failure, !failure.isEmpty {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // Footer: compact monospaced progress + live speed + quick action button
            HStack(spacing: 6) {
                Text(CuriumTransferFormatters.compactProgressLine(
                    for: download,
                    includeETA: true,
                    includeLanes: true
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

                Spacer(minLength: 4)

                if download.phase == .downloading, download.speedBytesPerSec >= 1 {
                    Text(CuriumTransferFormatters.speed(download.speedBytesPerSec))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize()
                }

                trailingActionButton
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trailingActionButton: some View {
        if download.phase == .pendingConfirmation {
            Button(action: onPrimaryAction) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Save")
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(palette.tint)
            .accessibilityIdentifier("curium.transfer.card.save.\(download.id)")
        } else if download.canPause {
            Button(action: onPrimaryAction) {
                Label("Pause", systemImage: "pause.fill")
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(palette.tint)
            .accessibilityLabel("Pause \(download.filename)")
            .accessibilityIdentifier("curium.transfer.card.pause.\(download.id)")
        } else if download.canResume {
            Button(action: onPrimaryAction) {
                Label("Resume", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(palette.tint)
            .accessibilityLabel("Resume \(download.filename)")
            .accessibilityIdentifier("curium.transfer.card.resume.\(download.id)")
        } else if download.canRetry {
            Button(action: onPrimaryAction) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(palette.tint)
            .accessibilityLabel("Retry \(download.filename)")
            .accessibilityIdentifier("curium.transfer.card.retry.\(download.id)")
        }
    }
}
