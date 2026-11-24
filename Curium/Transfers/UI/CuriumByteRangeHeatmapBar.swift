import SwiftUI

/// Single-pass GPU `Canvas` visualizing concurrent HTTP 206 byte-range slices and active lane cursors.
/// Falls back cleanly to a deterministic progress bar for HLS / single-stream known-length downloads,
/// or a Reduce-Motion-aware indeterminate sweep when total length is unknown.
/// Never runs a `TimelineView` when deterministic, paused, or terminal (protects 1 Hz ProMotion idle).
struct CuriumByteRangeHeatmapBar: View {
    @Environment(\.curiumPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let slices: [CuriumByteRangeSlice]
    let totalBytes: Int64?
    let fallbackFraction: Double?
    let phase: CuriumTransferPhase
    var height: CGFloat = 7

    private var fillTint: Color {
        switch phase {
        case .completed, .remuxing:
            return .green
        case .paused:
            return .orange
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        case .pendingConfirmation, .queued, .probing, .downloading, .saving:
            return palette.tint
        }
    }

    private var hasByteRangeSlices: Bool {
        guard let totalBytes, totalBytes > 0 else { return false }
        return !slices.isEmpty
    }

    private var isIndeterminateActive: Bool {
        if hasByteRangeSlices || fallbackFraction != nil {
            return false
        }
        switch phase {
        case .probing, .downloading, .remuxing, .saving:
            return true
        case .pendingConfirmation, .queued, .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    var body: some View {
        Group {
            if isIndeterminateActive && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    let phaseProgress = Self.sweepPosition(at: timeline.date)
                    heatmapCanvas(sweepProgress: phaseProgress)
                }
            } else {
                heatmapCanvas(sweepProgress: nil)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download progress")
        .accessibilityValue(accessibilitySummary)
    }

    private func heatmapCanvas(sweepProgress: CGFloat?) -> some View {
        let tint = fillTint
        let total = totalBytes
        let currentSlices = slices
        let fraction = fallbackFraction
        let activePhase = phase
        let indeterminateStatic = isIndeterminateActive && reduceMotion

        return Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let trackRect = CGRect(origin: .zero, size: size)
            let trackPath = Path(roundedRect: trackRect, cornerRadius: size.height / 2)

            context.fill(trackPath, with: .color(.secondary.opacity(0.16)))
            context.clip(to: trackPath)

            if let total, total > 0, !currentSlices.isEmpty {
                let width = size.width
                let invTotal = 1.0 / Double(total)

                for slice in currentSlices {
                    guard slice.downloadedBytes > 0 else { continue }
                    let xStart = CGFloat(Double(slice.startOffset) * invTotal) * width
                    let xEnd = CGFloat(Double(slice.currentOffset) * invTotal) * width
                    let barWidth = max(1.5, xEnd - xStart)
                    let rect = CGRect(x: xStart, y: 0, width: barWidth, height: size.height)
                    context.fill(Path(rect), with: .color(tint))

                    if slice.isActiveLane, !slice.isComplete, activePhase == .downloading {
                        let glowRect = CGRect(
                            x: max(0, xEnd - 4.5),
                            y: 0,
                            width: 6,
                            height: size.height
                        )
                        context.fill(Path(glowRect), with: .color(tint.opacity(0.45)))

                        let cursorRect = CGRect(
                            x: max(0, min(width - 2.5, xEnd - 2)),
                            y: 0,
                            width: 2.5,
                            height: size.height
                        )
                        context.fill(Path(cursorRect), with: .color(.primary.opacity(0.88)))
                    }
                }

                // Subtle 1 pt slice-split dividers so concurrent lanes read distinctly.
                for slice in currentSlices.dropFirst() {
                    let tickX = CGFloat(Double(slice.startOffset) * invTotal) * width
                    let tick = CGRect(x: tickX, y: 0, width: 1, height: size.height)
                    context.fill(
                        Path(tick),
                        with: .color(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.65))
                    )
                }
            } else if let fraction {
                let clamped = CGFloat(min(1.0, max(0.0, fraction)))
                let fillWidth = size.width * clamped
                if fillWidth > 0 {
                    let rect = CGRect(x: 0, y: 0, width: fillWidth, height: size.height)
                    context.fill(Path(rect), with: .color(tint))

                    if activePhase == .downloading, clamped < 1.0 {
                        let cursorRect = CGRect(
                            x: max(0, min(size.width - 2.5, fillWidth - 2)),
                            y: 0,
                            width: 2.5,
                            height: size.height
                        )
                        context.fill(Path(cursorRect), with: .color(.primary.opacity(0.85)))
                    }
                }
            } else if let sweepProgress {
                let segmentWidth = max(28, size.width * 0.34)
                let startX = -segmentWidth + sweepProgress * (size.width + segmentWidth)
                let sweepRect = CGRect(x: startX, y: 0, width: segmentWidth, height: size.height)
                let sweepPath = Path(roundedRect: sweepRect, cornerRadius: size.height / 2)
                context.fill(
                    sweepPath,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.15), tint, tint.opacity(0.15)]),
                        startPoint: CGPoint(x: sweepRect.minX, y: size.height / 2),
                        endPoint: CGPoint(x: sweepRect.maxX, y: size.height / 2)
                    )
                )
            } else if indeterminateStatic {
                let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                context.fill(Path(rect), with: .color(tint.opacity(0.45)))
            }
        }
    }

    private static func sweepPosition(at date: Date) -> CGFloat {
        let period: Double = 1.45
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        let normalized = (t < 0 ? t + period : t) / period
        return CGFloat(normalized)
    }

    private var accessibilitySummary: String {
        if let pct = CuriumTransferFormatters.percentage(fallbackFraction) {
            return "\(phase.displayTitle), \(pct)"
        }
        return phase.displayTitle
    }
}
