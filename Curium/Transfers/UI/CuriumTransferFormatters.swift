import Foundation
import SwiftUI

/// Pure monospaced-digit formatters and semantic status helpers shared across
/// Curium's transfer cards, inspector, browser capsule banner, and Media Radar.
enum CuriumTransferFormatters {
    struct BadgeAppearance: Sendable {
        let title: String
        let foreground: Color
        let background: Color
    }

    nonisolated static func bytes(_ count: Int64) -> String {
        let clamped = max(0, count)
        if clamped == 0 { return "0 B" }
        return clamped.formatted(.byteCount(style: .file))
    }

    nonisolated static func speed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec.isFinite, bytesPerSec >= 1 else { return "0 B/s" }
        let rounded = Int64(min(bytesPerSec.rounded(), Double(Int64.max / 2)))
        return "\(bytes(rounded))/s"
    }

    /// Formats remaining time (`11s left`, `2m 14s left`, `1h 04m left`), or `nil` when indeterminate.
    nonisolated static func eta(_ seconds: TimeInterval?, suffix: String = " left") -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0.5 else { return nil }
        let capped = min(seconds, 99 * 3600)
        let total = Int(capped.rounded())
        if total < 60 {
            return "\(total)s\(suffix)"
        }
        let mins = total / 60
        let secs = total % 60
        if mins < 60 {
            return "\(mins)m \(String(format: "%02d", secs))s\(suffix)"
        }
        let hrs = mins / 60
        let remMins = mins % 60
        return "\(hrs)h \(String(format: "%02d", remMins))m\(suffix)"
    }

    nonisolated static func etaDisplay(_ seconds: TimeInterval?) -> String {
        eta(seconds, suffix: "") ?? "—"
    }

    /// Formats elapsed durations (`4.2s`, `38s`, `2m 14s`, `1h 04m`).
    nonisolated static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 {
            return seconds < 10
                ? String(format: "%.1fs", seconds)
                : String(format: "%.0fs", seconds)
        }
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        if mins < 60 {
            return "\(mins)m \(String(format: "%02d", secs))s"
        }
        return "\(mins / 60)h \(String(format: "%02d", mins % 60))m"
    }

    nonisolated static func percentage(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite else { return nil }
        let clamped = min(1.0, max(0.0, fraction))
        return "\(Int((clamped * 100).rounded()))%"
    }

    nonisolated static func transportSummary(
        kind: CuriumTransferTransportKind,
        configuredLanes: Int
    ) -> String {
        switch kind {
        case .multiLaneRange:
            let lanes = max(1, configuredLanes)
            return "\(lanes)-Lane Range"
        case .singleStream:
            return "Single Stream"
        case .hlsRemuxMP4:
            return "HLS → MP4"
        case .blinkNativeStream:
            return "Blink Stream"
        }
    }

    nonisolated static func shortFolderName(from destinationLabel: String?) -> String {
        guard let raw = destinationLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "Downloads"
        }
        if let lastSegment = raw.split(separator: "›").last {
            let trimmed = lastSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return raw
    }

    @MainActor
    static func subtitle(for download: CuriumDownload) -> String {
        let transport = transportSummary(
            kind: download.transportKind,
            configuredLanes: download.configuredLanes
        )
        let rawDomain = download.sourceDomain
            ?? download.resolvedURL?.host(percentEncoded: false)
            ?? download.originalURL?.host(percentEncoded: false)
        if let rawDomain {
            let clean = CuriumSiteIdentity.cleanHost(from: rawDomain)
            if !clean.isEmpty {
                return "\(clean) · \(transport)"
            }
        }
        return transport
    }

    @MainActor
    static func badge(for download: CuriumDownload, tint: Color) -> BadgeAppearance {
        switch download.phase {
        case .pendingConfirmation:
            return BadgeAppearance(title: "Confirm", foreground: tint, background: tint.opacity(0.14))
        case .queued:
            return BadgeAppearance(title: "Queued", foreground: .secondary, background: Color(uiColor: .tertiarySystemFill))
        case .probing:
            return BadgeAppearance(title: "Probing", foreground: tint, background: tint.opacity(0.14))
        case .downloading:
            if let pct = percentage(download.fraction) {
                return BadgeAppearance(title: pct, foreground: tint, background: tint.opacity(0.14))
            }
            return BadgeAppearance(title: "Stream", foreground: tint, background: tint.opacity(0.14))
        case .remuxing:
            return BadgeAppearance(title: "Muxing", foreground: .green, background: Color.green.opacity(0.14))
        case .saving:
            return BadgeAppearance(title: "Saving", foreground: tint, background: tint.opacity(0.14))
        case .paused:
            return BadgeAppearance(title: "Paused", foreground: .orange, background: Color.orange.opacity(0.16))
        case .completed:
            return BadgeAppearance(title: "Saved", foreground: .green, background: Color.green.opacity(0.14))
        case .failed:
            return BadgeAppearance(title: "Failed", foreground: .red, background: Color.red.opacity(0.14))
        case .cancelled:
            return BadgeAppearance(title: "Cancelled", foreground: .secondary, background: Color(uiColor: .tertiarySystemFill))
        }
    }

    /// Compact progress line for transfer cards (never blank even when total length is unknown).
    @MainActor
    static func compactProgressLine(
        for download: CuriumDownload,
        includeETA: Bool = true,
        includeLanes: Bool = true
    ) -> String {
        switch download.phase {
        case .pendingConfirmation:
            if let total = download.knownTotalBytes, total > 0 {
                return "\(bytes(total)) · Ready to save"
            }
            return "Ready to save"
        case .queued:
            if let total = download.knownTotalBytes, total > 0 {
                return "Queued · \(bytes(total))"
            }
            return "Queued"
        case .probing:
            return "Probing server…"
        case .remuxing:
            return "Remuxing to MP4…"
        case .saving:
            return "Saving to \(shortFolderName(from: download.saveDestinationLabel))…"
        case .completed:
            let finalSize = max(download.receivedBytes, download.knownTotalBytes ?? 0)
            if finalSize > 0, download.elapsedSeconds >= 0.5 {
                return "\(bytes(finalSize)) · \(duration(download.elapsedSeconds))"
            }
            if finalSize > 0 {
                return bytes(finalSize)
            }
            return "Saved"
        case .cancelled:
            return download.receivedBytes > 0 ? "\(bytes(download.receivedBytes)) · Cancelled" : "Cancelled"
        case .failed:
            return download.receivedBytes > 0 ? "\(bytes(download.receivedBytes)) · Failed" : "Failed"
        case .downloading, .paused:
            var parts: [String] = [byteOrSegmentReadout(for: download)]
            if download.phase == .downloading {
                if includeETA, let etaText = eta(download.etaSeconds, suffix: " left") {
                    parts.append(etaText)
                }
                if includeLanes,
                   download.transportKind == .multiLaneRange,
                   download.configuredLanes > 1 {
                    parts.append("\(download.activeLanes)/\(download.configuredLanes)×")
                }
            } else if let total = download.knownTotalBytes, total > 0,
                      let pct = percentage(download.fraction) {
                parts.append(pct)
            }
            return parts.joined(separator: " · ")
        }
    }

    /// High-density single-line telemetry tailored for the floating Liquid Glass download banner.
    @MainActor
    static func bannerTelemetryLine(for download: CuriumDownload) -> String {
        switch download.phase {
        case .pendingConfirmation:
            if let total = download.knownTotalBytes, total > 0 {
                return "\(bytes(total)) · Ready to save"
            }
            return "Ready to save"
        case .queued:
            return "Queued…"
        case .probing:
            return "Probing server…"
        case .remuxing:
            return "Remuxing to MP4…"
        case .saving:
            return "Saving to \(shortFolderName(from: download.saveDestinationLabel))…"
        case .paused:
            return "\(byteOrSegmentReadout(for: download, compactEstimated: false)) · Paused"
        case .completed:
            let folder = shortFolderName(from: download.saveDestinationLabel)
            let finalSize = max(download.receivedBytes, download.knownTotalBytes ?? 0)
            return finalSize > 0 ? "\(bytes(finalSize)) · Saved to \(folder)" : "Saved to \(folder)"
        case .failed:
            return download.failure ?? "Download failed"
        case .cancelled:
            return "Cancelled"
        case .downloading:
            var parts: [String] = []
            if let totalSegs = download.totalSegments, totalSegs > 0 {
                parts.append("\(download.completedSegments)/\(totalSegs) segs · \(bytes(download.receivedBytes))")
            } else if let total = download.knownTotalBytes, total > 0 {
                let pctSuffix = percentage(download.fraction).map { " (\($0))" } ?? ""
                parts.append("\(bytes(download.receivedBytes)) / \(bytes(total))\(pctSuffix)")
            } else {
                parts.append(bytes(download.receivedBytes))
            }
            if download.speedBytesPerSec >= 1 {
                parts.append(speed(download.speedBytesPerSec))
            }
            if let etaText = eta(download.etaSeconds, suffix: "") {
                parts.append(etaText)
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Compact inline telemetry for Media Radar candidate and HLS variant rows.
    @MainActor
    static func mediaRadarProgressLine(for download: CuriumDownload) -> String {
        switch download.phase {
        case .probing:
            return "Probing server…"
        case .queued:
            return "Queued…"
        case .remuxing:
            return "Remuxing to MP4…"
        case .saving:
            return "Saving to \(shortFolderName(from: download.saveDestinationLabel))…"
        case .paused:
            return "\(byteOrSegmentReadout(for: download, compactEstimated: false)) · Paused"
        case .completed:
            let finalSize = max(download.receivedBytes, download.knownTotalBytes ?? 0)
            return finalSize > 0 ? "Saved · \(bytes(finalSize))" : "Saved"
        case .failed:
            return download.failure ?? "Download failed"
        case .cancelled:
            return "Cancelled"
        case .pendingConfirmation:
            return "Ready to save"
        case .downloading:
            var parts: [String] = []
            if let totalSegs = download.totalSegments, totalSegs > 0 {
                parts.append("\(download.completedSegments)/\(totalSegs) segs · \(bytes(download.receivedBytes))")
                if let est = download.estimatedTotalBytes, est > 0 {
                    parts.append("~\(bytes(est))")
                }
            } else if let total = download.knownTotalBytes, total > 0 {
                parts.append("\(bytes(download.receivedBytes)) / \(bytes(total))")
            } else {
                parts.append(bytes(download.receivedBytes))
            }
            if let pct = percentage(download.fraction) {
                parts.append(pct)
            }
            if download.speedBytesPerSec >= 1 {
                parts.append(speed(download.speedBytesPerSec))
            }
            return parts.joined(separator: " · ")
        }
    }

    @MainActor
    private static func byteOrSegmentReadout(
        for download: CuriumDownload,
        compactEstimated: Bool = true
    ) -> String {
        if let totalSegs = download.totalSegments, totalSegs > 0 {
            let base = "\(download.completedSegments)/\(totalSegs) segs · \(bytes(download.receivedBytes))"
            if compactEstimated, let est = download.estimatedTotalBytes, est > 0 {
                return "\(base) (~\(bytes(est)))"
            }
            return base
        }
        if let total = download.knownTotalBytes, total > 0 {
            return "\(bytes(download.receivedBytes)) / \(bytes(total))"
        }
        return bytes(download.receivedBytes)
    }
}
