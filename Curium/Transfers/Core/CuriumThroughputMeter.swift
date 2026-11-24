import Foundation
import os

/// Thread-safe EWMA throughput, ETA, elapsed-time, and 36-sample sparkline ring calculator
/// shared across all Curium transfer transports.
final class CuriumThroughputMeter: Sendable {
    static let ewmaAlpha: Double = 0.35
    static let sparklineSampleIntervalSeconds: Double = 0.5
    static let maxSparklineSamples: Int = 36
    static let defaultTickIntervalSeconds: Double = 0.22
    static let defaultPersistIntervalSeconds: Double = 3.0
    static let minimumETASpeedBytesPerSec: Double = 1024

    struct SampleSnapshot: Sendable, Equatable {
        let speedBytesPerSec: Double
        let peakSpeedBytesPerSec: Double
        let samples: [Double]
        let elapsedSeconds: Double
        let didSampleSparkline: Bool
        let shouldPersist: Bool
    }

    private struct State: Sendable {
        var lastBytes: Int64
        var sessionStartedAt: ContinuousClock.Instant
        var accumulatedElapsedSeconds: Double
        var lastTickAt: ContinuousClock.Instant
        var lastSparklineAt: ContinuousClock.Instant
        var lastPersistAt: ContinuousClock.Instant
        var speedBytesPerSec: Double
        var peakSpeedBytesPerSec: Double
        var samples: [Double]
        var isPaused: Bool
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        initialBytes: Int64 = 0,
        priorElapsedSeconds: Double = 0,
        priorPeakSpeedBytesPerSec: Double = 0,
        priorSamples: [Double] = [],
        startedAt now: ContinuousClock.Instant = .now
    ) {
        let clampedBytes = max(0, initialBytes)
        let clampedElapsed = priorElapsedSeconds.isFinite ? max(0, priorElapsedSeconds) : 0
        let clampedPeak = priorPeakSpeedBytesPerSec.isFinite ? max(0, priorPeakSpeedBytesPerSec) : 0
        let seededSamples = Array(priorSamples.suffix(Self.maxSparklineSamples))
        self.state = OSAllocatedUnfairLock(initialState: State(
            lastBytes: clampedBytes,
            sessionStartedAt: now,
            accumulatedElapsedSeconds: clampedElapsed,
            lastTickAt: now,
            lastSparklineAt: now,
            lastPersistAt: now,
            speedBytesPerSec: 0,
            peakSpeedBytesPerSec: clampedPeak,
            samples: seededSamples,
            isPaused: false
        ))
    }

    /// Current EWMA throughput in bytes/sec.
    var speedBytesPerSec: Double {
        state.withLock { $0.speedBytesPerSec }
    }

    /// Peak EWMA throughput in bytes/sec observed across the transfer lifetime.
    var peakSpeedBytesPerSec: Double {
        state.withLock { $0.peakSpeedBytesPerSec }
    }

    /// Up to 36 throughput samples captured at `0.5s` cadence for `CuriumThroughputSparklineView`.
    var samples: [Double] {
        state.withLock { $0.samples }
    }

    /// Active elapsed transfer time in seconds (excludes paused intervals).
    var elapsedSeconds: Double {
        elapsedSeconds(at: .now)
    }

    /// Active elapsed transfer time evaluated at a caller-provided monotonic instant.
    func elapsedSeconds(at now: ContinuousClock.Instant) -> Double {
        state.withLock { s in
            guard !s.isPaused else { return s.accumulatedElapsedSeconds }
            return s.accumulatedElapsedSeconds + max(0, Self.seconds(from: s.sessionStartedAt, to: now))
        }
    }

    /// Estimated seconds remaining given `remainingBytes`, or `nil` when indeterminate or stalled.
    func etaSeconds(remainingBytes: Int64?) -> TimeInterval? {
        guard let remainingBytes, remainingBytes > 0 else { return nil }
        let speed = speedBytesPerSec
        guard speed.isFinite, speed >= Self.minimumETASpeedBytesPerSec else { return nil }
        let eta = Double(remainingBytes) / speed
        return eta.isFinite ? eta : nil
    }

    /// Records a monotonic `totalBytesNow` observation. Returns `nil` if throttled below `minTickInterval`
    /// unless `force == true`.
    @discardableResult
    func record(
        totalBytesNow: Int64,
        at now: ContinuousClock.Instant = .now,
        minTickInterval: Double = CuriumThroughputMeter.defaultTickIntervalSeconds,
        force: Bool = false
    ) -> SampleSnapshot? {
        state.withLock { s in
            if s.isPaused {
                s.isPaused = false
                s.sessionStartedAt = now
                s.lastTickAt = now
                s.lastSparklineAt = now
                s.lastPersistAt = now
                s.lastBytes = max(0, totalBytesNow)
                if !force {
                    return nil
                }
            }

            let elapsedSinceTick = Self.seconds(from: s.lastTickAt, to: now)
            guard force || elapsedSinceTick >= minTickInterval else {
                return nil
            }

            let clampedTotal = max(s.lastBytes, max(0, totalBytesNow))
            let deltaBytes = clampedTotal - s.lastBytes
            let safeSeconds = max(elapsedSinceTick, 0.001)
            let instantSpeed = Double(deltaBytes) / safeSeconds

            if s.speedBytesPerSec <= 0 {
                s.speedBytesPerSec = instantSpeed
            } else {
                s.speedBytesPerSec = Self.ewmaAlpha * instantSpeed + (1.0 - Self.ewmaAlpha) * s.speedBytesPerSec
            }

            if s.speedBytesPerSec > s.peakSpeedBytesPerSec {
                s.peakSpeedBytesPerSec = s.speedBytesPerSec
            }

            s.lastBytes = clampedTotal
            s.lastTickAt = now

            let sparkElapsed = Self.seconds(from: s.lastSparklineAt, to: now)
            let didSample = sparkElapsed >= Self.sparklineSampleIntervalSeconds
            if didSample {
                s.lastSparklineAt = now
                s.samples.append(s.speedBytesPerSec)
                if s.samples.count > Self.maxSparklineSamples {
                    s.samples.removeFirst(s.samples.count - Self.maxSparklineSamples)
                }
            }

            let persistElapsed = Self.seconds(from: s.lastPersistAt, to: now)
            let shouldPersist = persistElapsed >= Self.defaultPersistIntervalSeconds
            if shouldPersist {
                s.lastPersistAt = now
            }

            let elapsed = s.accumulatedElapsedSeconds + max(0, Self.seconds(from: s.sessionStartedAt, to: now))
            return SampleSnapshot(
                speedBytesPerSec: s.speedBytesPerSec,
                peakSpeedBytesPerSec: s.peakSpeedBytesPerSec,
                samples: s.samples,
                elapsedSeconds: elapsed,
                didSampleSparkline: didSample,
                shouldPersist: shouldPersist
            )
        }
    }

    /// Freezes elapsed time and zeros live speed when transitioning to `.paused`.
    func markPaused(at now: ContinuousClock.Instant = .now) {
        state.withLock { s in
            guard !s.isPaused else { return }
            s.accumulatedElapsedSeconds += max(0, Self.seconds(from: s.sessionStartedAt, to: now))
            s.speedBytesPerSec = 0
            s.isPaused = true
        }
    }

    /// Resets transient EWMA speed and sampling anchors for a fresh active interval after pause,
    /// preserving accumulated elapsed time, peak speed, and prior sparkline history.
    func resetForResume(currentBytes: Int64? = nil, at now: ContinuousClock.Instant = .now) {
        state.withLock { s in
            if !s.isPaused {
                // Accumulate up to the last active observation so idle pause time never inflates elapsedSeconds.
                s.accumulatedElapsedSeconds += max(0, Self.seconds(from: s.sessionStartedAt, to: s.lastTickAt))
            }
            if let currentBytes {
                s.lastBytes = max(0, currentBytes)
            }
            s.sessionStartedAt = now
            s.lastTickAt = now
            s.lastSparklineAt = now
            s.lastPersistAt = now
            s.speedBytesPerSec = 0
            s.isPaused = false
        }
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
