import SwiftUI

/// Single-pass 52 pt throughput sparkline over the latest 36 EWMA speed readings.
/// Purely data-driven with zero internal timers so paused or completed transfers trigger zero redraws.
struct CuriumThroughputSparklineView: View {
    @Environment(\.curiumPalette) private var palette

    let samples: [Double]
    let peakBytesPerSec: Double
    var isActive: Bool = false
    var height: CGFloat = 52

    private var effectivePeak: Double {
        max(peakBytesPerSec, samples.max() ?? 0)
    }

    var body: some View {
        let strokeColor = isActive ? palette.tint : palette.tint.opacity(0.75)
        let displayPeak = effectivePeak

        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                guard size.width > 4, size.height > 4 else { return }

                // Subtle horizontal midline rule for scale reference.
                var midline = Path()
                midline.move(to: CGPoint(x: 0, y: size.height * 0.5))
                midline.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
                context.stroke(
                    midline,
                    with: .color(Color(uiColor: .separator).opacity(0.28)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])
                )

                guard !samples.isEmpty else {
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: size.height - 2))
                    baseline.addLine(to: CGPoint(x: size.width, y: size.height - 2))
                    context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 1.25)
                    return
                }

                let scaleCeiling = max(displayPeak, 1024)
                let topInset: CGFloat = 6
                let bottomInset: CGFloat = 3
                let usableHeight = max(1, size.height - topInset - bottomInset)

                let points: [CGPoint]
                if samples.count == 1 {
                    let normalized = CGFloat(min(1.0, max(0.0, samples[0] / scaleCeiling)))
                    let y = size.height - bottomInset - normalized * usableHeight
                    points = [CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)]
                } else {
                    let stepX = size.width / CGFloat(samples.count - 1)
                    points = samples.enumerated().map { idx, value in
                        let clamped = value.isFinite ? max(0, value) : 0
                        let normalized = CGFloat(min(1.0, clamped / scaleCeiling))
                        let y = size.height - bottomInset - normalized * usableHeight
                        return CGPoint(x: CGFloat(idx) * stepX, y: y)
                    }
                }

                var line = Path()
                line.move(to: points[0])
                if points.count == 2 {
                    line.addLine(to: points[1])
                } else {
                    for index in 1..<points.count {
                        let prev = points[index - 1]
                        let curr = points[index]
                        let mid = CGPoint(x: (prev.x + curr.x) * 0.5, y: (prev.y + curr.y) * 0.5)
                        if index == 1 {
                            line.addLine(to: mid)
                        } else {
                            line.addQuadCurve(to: mid, control: prev)
                        }
                    }
                    if let last = points.last {
                        line.addLine(to: last)
                    }
                }

                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()

                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [strokeColor.opacity(0.24), strokeColor.opacity(0.02)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                context.stroke(
                    line,
                    with: .color(strokeColor),
                    style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
                )

                if isActive, let latest = points.last {
                    let halo = CGRect(x: latest.x - 4.5, y: latest.y - 4.5, width: 9, height: 9)
                    context.fill(Path(ellipseIn: halo), with: .color(strokeColor.opacity(0.24)))
                    let dot = CGRect(x: latest.x - 2.5, y: latest.y - 2.5, width: 5, height: 5)
                    context.fill(Path(ellipseIn: dot), with: .color(strokeColor))
                }
            }

            if displayPeak >= 1 {
                Text("Peak \(CuriumTransferFormatters.speed(displayPeak))")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground).opacity(0.85),
                        in: Capsule()
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Throughput history")
        .accessibilityValue(
            displayPeak >= 1
                ? "Peak \(CuriumTransferFormatters.speed(displayPeak))"
                : "No throughput recorded"
        )
    }
}
