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
    private(set) var isEngineRunning = false

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private nonisolated(unsafe) var interruptionObserver: (any NSObjectProtocol)?

    var shouldBeActive: Bool {
        isBackgrounded && activeTaskCount > 0
    }

    init() {
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
    }

    deinit {
        if let observer = interruptionObserver {
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

    func stopImmediately() {
        teardownEngine()
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
            if isEngineRunning {
                teardownEngine(deactivateSession: false)
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldBeActive && (options.contains(.shouldResume) || !isEngineRunning) {
                startEngineIfNeeded()
            } else if !shouldBeActive {
                teardownEngine()
            }
        @unknown default:
            break
        }
    }

    private func startEngineIfNeeded() {
        guard shouldBeActive, !isEngineRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }

        let engine = AVAudioEngine()
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        // Guard against headless Simulator audio routes reporting 0 Hz / 0 channels.
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        let sampleRate = outputFormat.sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(1024, Int(sampleRate)))
              ) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
            audioEngine = engine
            playerNode = player
            isEngineRunning = true
        } catch {
            player.stop()
            engine.stop()
            engine.reset()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func teardownEngine(deactivateSession: Bool = true) {
        let wasRunning = isEngineRunning || audioEngine != nil || playerNode != nil
        playerNode?.stop()
        playerNode = nil
        audioEngine?.stop()
        audioEngine?.reset()
        audioEngine = nil
        isEngineRunning = false

        if deactivateSession && wasRunning {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
