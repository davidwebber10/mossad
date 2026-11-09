#if os(macOS)
import AVFoundation
import Foundation
import Synchronization

/// Captures the microphone. The app records it raw (`voiceProcessing: false`): macOS gives a second voice-processing
/// client silence when the browser also uses it, and the echo from the speakers is dropped later by `TranscriptMerger`.
public final class MicCapture: TrackSource, @unchecked Sendable {
    /// Replaced on every restart: after a device change the old engine can report the old format and send nothing.
    private var engine = AVAudioEngine()
    private let voiceProcessing: Bool
    private var feed: AudioFeed?
    /// Each engine start has its own number. AVAudioEngine does not promise that no tap block runs after
    /// `removeTap`, so a late block of an older engine checks the number and writes nothing.
    private let generation = Generation()
    private final class Generation: Sendable { let value = Atomic<Int>(0) }
    private var observer: NSObjectProtocol?
    private var failureHandler: (() -> Void)?

    public init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
    }

    public func start(_ feed: AudioFeed) throws {
        self.feed = feed
        try configureAndStart()
    }

    /// With no input device (a closed MacBook whose headset disconnected) the input format has 0 Hz and no channels.
    /// `installTap` raises an Objective-C exception for it, which Swift cannot catch, so it must never get there.
    static func checkInput(sampleRate: Double, channels: UInt32) throws {
        guard sampleRate > 0, channels > 0 else { throw CaptureError.message("no microphone is connected") }
    }

    /// The engine stops itself when the input or output hardware changes (AirPods connect, a USB mic is
    /// unplugged). Restart on a new engine for the new device; TrackWriter fills the short gap with silence.
    private func restart() {
        Log.info("Audio configuration changed; restarting mic")
        if let observer { NotificationCenter.default.removeObserver(observer) }
        generation.value.add(1, ordering: .relaxed)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        engine = AVAudioEngine()
        do { try configureAndStart() } catch {
            Log.error("Mic restart failed: \(error)")
            failureHandler?()
        }
    }

    private func configureAndStart() throws {
        guard let feed else { return }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: CaptureQueue.operations) { [weak self] _ in self?.restart() }
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Do not lower the meeting's own audio while we record.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        try Self.checkInput(sampleRate: format.sampleRate, channels: format.channelCount)
        // Also after a restart on a new device: its first buffer is placed exactly on the timeline.
        feed.beginSegment()
        let generation = generation
        let mine = generation.value.add(1, ordering: .relaxed).newValue
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            guard generation.value.load(ordering: .relaxed) == mine else { return }
            feed.push(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
        }
        engine.prepare()
        try engine.start()
        Log.info("Mic started (\(format.sampleRate) Hz, \(format.channelCount) ch, voice processing \(voiceProcessing))")
    }

    public func onFailure(_ handler: @escaping () -> Void) { failureHandler = handler }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        feed = nil
        generation.value.add(1, ordering: .relaxed)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }
}
#endif
