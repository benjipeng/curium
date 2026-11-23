import OSLog
import SwiftUI
import UIKit

/// The system's active occlusion regions (status cluster, Dynamic Island, cameras),
/// in window coordinates.
///
/// UIKit tracks `reservedRegions(kind:)` queries made inside `updateConstraints()` and
/// runs that pass again whenever a region changes, for example when a Live Activity
/// widens the island. Reading them there, instead of from a SwiftUI geometry pass,
/// keeps the bar in step with the island as it grows and shrinks.
struct CuriumOcclusionReader: UIViewRepresentable {
    let onChange: ([CGRect], Bool) -> Void

    func makeUIView(context: Context) -> Reader {
        let reader = Reader()
        reader.onChange = onChange
        return reader
    }

    func updateUIView(_ view: Reader, context: Context) {
        view.onChange = onChange
    }

    final class Reader: UIView {
        var onChange: (([CGRect], Bool) -> Void)?
        private var published: [CGRect]?
        private var lastBoundsSize: CGSize = .zero
        private var pendingSizeSnap = false

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init().") }

        override static var requiresConstraintBasedLayout: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            lastBoundsSize = bounds.size
            pendingSizeSnap = true
            setNeedsUpdateConstraints()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != lastBoundsSize else { return }
            lastBoundsSize = bounds.size
            pendingSizeSnap = true
            setNeedsUpdateConstraints() // Size or posture changed.
        }

        override func updateConstraints() {
            defer { super.updateConstraints() }
            guard #available(iOS 27.1, *), let window else { return }
            let regions = reservedRegions(kind: .occlusion)
                .filter(\.isActive)
                .map { (frame: convert($0.frame, to: window).integral, margins: $0.margins) }
                .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            var frames = regions.map(\.frame)
            #if DEBUG
            if let simulated = Self.simulatedFrames { frames = simulated }
            #endif
            let shouldAnimate = published != nil && !pendingSizeSnap
            pendingSizeSnap = false
            guard frames != published else { return }
            published = frames
            // The frame includes the margins; log them, since the Simulator reports zero.
            let described = regions.map {
                "\(NSCoder.string(for: $0.frame)) margins \(NSCoder.string(for: $0.margins))"
            }
            let summary = described.isEmpty ? "none" : described.joined(separator: "; ")
            Self.log.notice("occlusion: \(summary, privacy: .public)")
            CuriumDiagnostics.shared.record("layout", "occlusion: \(summary)")
            Task { @MainActor [weak self] in
                guard let self, self.published == frames else { return }
                self.onChange?(frames, shouldAnimate)
            }
        }

        #if DEBUG
        /// `CURIUM_SIMULATED_OCCLUSION="x,y,w,h;x,y,w,h"` replaces the reported regions,
        /// in window coordinates, so the Simulator can lay out against a region it never
        /// reports itself, such as a status region widened well past the clock ("413,0,256,82").
        private static let simulatedFrames: [CGRect]? = {
            guard let spec = ProcessInfo.processInfo.environment["CURIUM_SIMULATED_OCCLUSION"] else { return nil }
            let frames = spec.split(separator: ";").compactMap { item -> CGRect? in
                let v = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
            }
            log.notice("occlusion simulated: \(spec, privacy: .public)")
            return frames
        }()
        #endif

        private static let log = Logger(subsystem: "com.appautomaton.curium", category: "layout")
    }
}
