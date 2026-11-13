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
    private final class Generation: Sendable {
        let value = Atomic<Int>(0)
        /// The buffers that reached the feed, for the check that a started engine sends anything.
        let buffers = Atomic<Int>(0)
    }
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
        // A new plan for each start: a stopped plan restarts nothing.
        plan = MicRestartPlan()
        do {
            try configureAndStart(lastChance: false)
            // An engine that sends nothing is not recording: the restart plan takes over.
            checkLiveness { [weak self] alive in
                guard let self, !alive, let step = self.plan.configurationChanged() else { return }
                Log.info("Mic sent nothing in \(Int(MicRestartPlan.livenessWait)) s; restarting it")
                self.run(step)
            }
        } catch Settling.formats {
            // The route may still be changing as the call starts: one short wait, then a last chance.
            if let step = plan.firstStartSettling() { run(step) }
        }
    }

    /// The node's two formats disagree: maybe a route that settles.
    private enum Settling: Error { case formats }

    /// After `livenessWait`, whether the engine started now sent a buffer. Only for the engine of now.
    private func checkLiveness(_ verdict: @escaping (Bool) -> Void) {
        let generation = generation
        let mine = generation.value.load(ordering: .relaxed), before = generation.buffers.load(ordering: .relaxed)
        CaptureQueue.queue.asyncAfter(deadline: .now() + MicRestartPlan.livenessWait) {
            guard generation.value.load(ordering: .relaxed) == mine else { return }
            verdict(generation.buffers.load(ordering: .relaxed) > before)
        }
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

    /// One restart on a fresh engine. It counts only once a buffer arrives.
    private func attempt(_ token: Int) {
        guard plan.isCurrent(token) else { return }
        tearDown()
        engine = AVAudioEngine()
        do {
            try configureAndStart(lastChance: plan.isLastChance(token))
            checkLiveness { [weak self] alive in
                guard let self, self.plan.isCurrent(token) else { return }
                if alive { self.plan.succeeded(token: token); return }
                Log.info("Mic sent nothing in \(Int(MicRestartPlan.livenessWait)) s after a restart")
                if let next = self.plan.failed(token: token) { self.run(next) }
            }
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

    /// `lastChance`: install the tap with the node's own format even when the two sides disagree; the catcher turns
    /// a raise into a failed start.
    private func configureAndStart(lastChance: Bool) throws {
        guard let feed else { return }
        let engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: CaptureQueue.operations) { [weak self, weak engine] _ in
            guard let engine else { return }
            self?.configurationChanged(from: engine)
        }
        // The node and its formats are read inside the catcher too: a node in a route change can raise.
        var node: AVAudioInputNode?
        try ObjCException.catching { node = engine.inputNode }
        guard let input = node else { throw CaptureError.message("the input node is not there") }
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
        var formats: (AVAudioFormat, AVAudioFormat)?
        try ObjCException.catching { formats = (input.inputFormat(forBus: 0), input.outputFormat(forBus: 0)) }
        guard let (hardware, format) = formats else { throw CaptureError.message("the input formats could not be read") }
        let hw = MicFormat(sampleRate: hardware.sampleRate, channels: hardware.channelCount)
        let out = MicFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        switch MicStartDecision.decide(MicStartCheck.check(hardware: hw, output: out), lastChance: lastChance) {
        case .install: break
        case .noInput: try Self.checkInput(sampleRate: 0, channels: 0)
        case .wait:
            Log.info("Mic waits for the audio route (hardware \(hw), tap \(out))")
            throw Settling.formats
        case .installAnyway:
            Log.info("Mic formats still differ (hardware \(hw), tap \(out)); installing the tap with the node's own format")
        }
        // Also after a restart on a new device: its first buffer is placed exactly on the timeline.
        feed.beginSegment()
        let generation = generation
        let mine = generation.value.add(1, ordering: .relaxed).newValue
        // The hardware can still change between the check and the tap: an exception here is a failed start, not a crash.
        try ObjCException.catching {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
                guard generation.value.load(ordering: .relaxed) == mine else { return }
                generation.buffers.add(1, ordering: .relaxed)
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
