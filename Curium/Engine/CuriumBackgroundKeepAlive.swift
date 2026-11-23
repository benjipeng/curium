import AVFAudio
import Foundation

/// LiveContainer background keep-alive controller.
///
/// LiveContainer declares `UIBackgroundModes = [audio]` on its host bundle, whereas
/// guest-bound `BGContinuedProcessingTask` and cross-guest `nsurlsessiond` handoffs
/// are unavailable to unsigned guests. This controller runs a zeroed-PCM `AVAudioEngine`
/// (`.playback` + `.mixWithOthers`) **strictly when `isBackgrounded && activeTaskCount > 0`**
/// and tears it down immediately on foreground return or queue drain so foreground browsing
/// incurs zero audio-session overhead or thermal cost.
@MainActor
final class CuriumBackgroundKeepAlive {
    private(set) var isBackgrounded = false
    private(set) var activeTaskCount = 0
    private(set) var isExternalMediaActive = false

    private let isMediaPlayingProvider: (@MainActor () -> Bool)?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private nonisolated(unsafe) var interruptionObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var mediaServicesResetObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var engineConfigObserver: (any NSObjectProtocol)?

    var isEngineRunning: Bool {
        audioEngine?.isRunning == true
    }

    var shouldBeActive: Bool {
        isBackgrounded && activeTaskCount > 0
    }

    private var hasActiveExternalMedia: Bool {
        isExternalMediaActive || (isMediaPlayingProvider?() == true)
    }

    init(isMediaPlayingProvider: (@MainActor () -> Bool)? = nil) {
        self.isMediaPlayingProvider = isMediaPlayingProvider
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        }
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded
        reconcileAudioEngine()
    }

    func setActiveTaskCount(_ count: Int) {
        let clamped = max(0, count)
        guard activeTaskCount != clamped else { return }
        activeTaskCount = clamped
        reconcileAudioEngine()
    }

    func setExternalMediaPlaybackActive(_ active: Bool) {
        isExternalMediaActive = active
    }

    func stopImmediately() {
        teardownEngine()
    }

    // MARK: - Policy Helpers (Testable)

    /// Preserves WebRTC microphone capture (`.playAndRecord`) and active video/PiP's
    /// non-mixing `.playback` session so keep-alive never steals mic input or Lock Screen controls.
    static func shouldPreserveExistingAudioCategory(
        currentCategory: AVAudioSession.Category,
        currentOptions: AVAudioSession.CategoryOptions,
        isMediaPlaying: Bool
    ) -> Bool {
        if currentCategory == .playAndRecord {
            return true
        }
        if isMediaPlaying && currentCategory == .playback && !currentOptions.contains(.mixWithOthers) {
            return true
        }
        return false
    }

    /// Skips deactivating the process-global `AVAudioSession` while WebRTC capture or tab media/PiP is active.
    static func shouldDeactivateAudioSession(
        deactivateRequested: Bool,
        wasRunning: Bool,
        currentCategory: AVAudioSession.Category,
        isMediaPlaying: Bool
    ) -> Bool {
        guard deactivateRequested, wasRunning else { return false }
        if isMediaPlaying || currentCategory == .playAndRecord {
            return false
        }
        return true
    }

    /// Honors iOS's `.shouldResume` interruption option instead of unconditionally restarting.
    static func shouldResumeAfterInterruptionEnd(
        shouldBeActive: Bool,
        options: AVAudioSession.InterruptionOptions
    ) -> Bool {
        shouldBeActive && options.contains(.shouldResume)
    }

    // MARK: - Private

    private func reconcileAudioEngine() {
        if shouldBeActive {
            startEngineIfNeeded()
        } else {
            teardownEngine()
        }
    }

    private func handleAudioInterruption(rawType: UInt?, rawOptions: UInt) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }
        switch type {
        case .began:
            if audioEngine != nil || playerNode != nil {
                teardownEngine(deactivateSession: false)
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if Self.shouldResumeAfterInterruptionEnd(shouldBeActive: shouldBeActive, options: options) {
                startEngineIfNeeded()
            } else if !shouldBeActive {
                teardownEngine()
            }
        @unknown default:
            break
        }
    }

    private func handleEngineConfigurationChange() {
        teardownEngine(deactivateSession: false)
        if shouldBeActive {
            startEngineIfNeeded()
        }
    }

    private func handleMediaServicesReset() {
        teardownEngine(deactivateSession: false)
        if shouldBeActive {
            startEngineIfNeeded()
        }
    }

    private func startEngineIfNeeded() {
        guard shouldBeActive, !isEngineRunning else { return }

        // Clean up any stopped engine left behind by a route/hardware configuration change.
        if audioEngine != nil || playerNode != nil {
            teardownEngine(deactivateSession: false)
        }

        let session = AVAudioSession.sharedInstance()
        let mediaPlaying = hasActiveExternalMedia
        let preserveCategory = Self.shouldPreserveExistingAudioCategory(
            currentCategory: session.category,
            currentOptions: session.categoryOptions,
            isMediaPlaying: mediaPlaying
        )

        do {
            if !preserveCategory {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            return
        }

        let engine = AVAudioEngine()
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        // Guard against headless Simulator audio routes reporting 0 Hz / 0 channels.
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            if Self.shouldDeactivateAudioSession(
                deactivateRequested: true,
                wasRunning: true,
                currentCategory: session.category,
                isMediaPlaying: hasActiveExternalMedia
            ) {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            return
        }

        let sampleRate = outputFormat.sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(1024, Int(sampleRate)))
              ) else {
            if Self.shouldDeactivateAudioSession(
                deactivateRequested: true,
                wasRunning: true,
                currentCategory: session.category,
                isMediaPlaying: hasActiveExternalMedia
            ) {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            return
        }

        buffer.frameLength = buffer.frameCapacity
        if let floatChannels = buffer.floatChannelData {
            memset(floatChannels[0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()
            guard engine.isRunning else {
                player.stop()
                engine.stop()
                engine.reset()
                if Self.shouldDeactivateAudioSession(
                    deactivateRequested: true,
                    wasRunning: true,
                    currentCategory: session.category,
                    isMediaPlaying: hasActiveExternalMedia
                ) {
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                }
                return
            }
            audioEngine = engine
            playerNode = player
            engineConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleEngineConfigurationChange()
                }
            }
        } catch {
            player.stop()
            engine.stop()
            engine.reset()
            if Self.shouldDeactivateAudioSession(
                deactivateRequested: true,
                wasRunning: true,
                currentCategory: session.category,
                isMediaPlaying: hasActiveExternalMedia
            ) {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func teardownEngine(deactivateSession: Bool = true) {
        let wasRunning = isEngineRunning || audioEngine != nil || playerNode != nil
        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigObserver = nil
        }
        playerNode?.stop()
        playerNode = nil
        audioEngine?.stop()
        audioEngine?.reset()
        audioEngine = nil

        let session = AVAudioSession.sharedInstance()
        if Self.shouldDeactivateAudioSession(
            deactivateRequested: deactivateSession,
            wasRunning: wasRunning,
            currentCategory: session.category,
            isMediaPlaying: hasActiveExternalMedia
        ) {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
