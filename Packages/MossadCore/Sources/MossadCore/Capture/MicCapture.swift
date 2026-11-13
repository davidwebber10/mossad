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
    /// The restarts after a route change: one at a time, with waits while the route settles (`MicRestartPlan`).
    /// Read and changed on `CaptureQueue.queue` only: the notifications run there, and so do start and stop.
    private var plan = MicRestartPlan()

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

    /// The engine stops itself when the input or output hardware changes (AirPods connect, a headset switches
    /// to or from call mode). Restart on a new engine for the new device; TrackWriter fills the gap with silence.
    /// Changes that come while a restart waits join it.
    private func configurationChanged(from changed: AVAudioEngine) {
        // A notification of an engine that was already replaced was queued before its observer went.
        guard changed === engine, let step = plan.configurationChanged() else { return }
        Log.info("Audio configuration changed; restarting mic")
        run(step)
    }

    private func run(_ step: MicRestartPlan.Step) {
        switch step {
        case .giveUp:
            Log.error("Mic restart failed after the audio route settled for 10 s; the recorder tries again")
            failureHandler?()
        case .restart(let token, let after):
            if after == 0 { attempt(token) } else {
                CaptureQueue.queue.asyncAfter(deadline: .now() + after) { [weak self] in self?.attempt(token) }
            }
        }
    }

    /// One restart on a fresh engine.
    private func attempt(_ token: Int) {
        guard plan.isCurrent(token) else { return }
        tearDown()
        engine = AVAudioEngine()
        do {
            try configureAndStart()
            plan.succeeded(token: token)
        } catch {
            Log.info("Mic restart waits for the audio route: \(error)")
            if let next = plan.failed(token: token) { run(next) }
        }
    }

    /// Stops the current engine and its tap. Every call here is guarded: a node in the middle of a route change can
    /// raise.
    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        generation.value.add(1, ordering: .relaxed)
        let engine = engine, voiceProcessing = voiceProcessing
        try? ObjCException.catching {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        }
    }

    private func configureAndStart() throws {
        guard let feed else { return }
        let engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: CaptureQueue.operations) { [weak self, weak engine] _ in
            guard let engine else { return }
            self?.configurationChanged(from: engine)
        }
        let input = engine.inputNode
        if voiceProcessing {
            var vpError: Error?
            try ObjCException.catching {
                do { try input.setVoiceProcessingEnabled(true) } catch { vpError = error }
            }
            if let vpError { throw vpError }
            // Do not lower the meeting's own audio while we record.
            try ObjCException.catching {
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        switch MicStartCheck.check(hardware: MicFormat(sampleRate: hardware.sampleRate, channels: hardware.channelCount),
                                   output: MicFormat(sampleRate: format.sampleRate, channels: format.channelCount)) {
        case .ok: break
        case .noInput: try Self.checkInput(sampleRate: 0, channels: 0)
        case .settling:
            throw CaptureError.message("the audio route is still changing (hardware \(MicFormat(sampleRate: hardware.sampleRate, channels: hardware.channelCount)), "
                                       + "tap \(MicFormat(sampleRate: format.sampleRate, channels: format.channelCount)))")
        }
        // Also after a restart on a new device: its first buffer is placed exactly on the timeline.
        feed.beginSegment()
        let generation = generation
        let mine = generation.value.add(1, ordering: .relaxed).newValue
        // The hardware can still change between the check and the tap: an exception here is a failed start, not a crash.
        try ObjCException.catching {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
                guard generation.value.load(ordering: .relaxed) == mine else { return }
                feed.push(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
            }
        }
        var startError: Error?
        try ObjCException.catching {
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if let startError { throw startError }
        Log.info("Mic started (\(format.sampleRate) Hz, \(format.channelCount) ch, voice processing \(voiceProcessing))")
    }

    public func onFailure(_ handler: @escaping () -> Void) { failureHandler = handler }

    public func stop() {
        plan.stop()
        feed = nil
        tearDown()
    }
}
#endif
