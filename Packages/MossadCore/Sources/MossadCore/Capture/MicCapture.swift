import AVFoundation
import Foundation

/// Captures the microphone. With voice processing on, Apple's echo cancellation removes
/// what the speakers play, so other people's voices do not leak into the "me" track.
public final class MicCapture: TrackSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let voiceProcessing: Bool
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var observer: NSObjectProtocol?

    public init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
    }

    public func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.onBuffer = onBuffer
        // The engine stops itself when the input or output hardware changes (AirPods connect, a USB mic is
        // unplugged). Restart it on the new device; TrackWriter fills the short gap with silence.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.info("Audio configuration changed; restarting mic")
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            do { try self.configureAndStart() } catch { Log.error("Mic restart failed: \(error)") }
        }
        try configureAndStart()
    }

    private func configureAndStart() throws {
        guard let onBuffer else { return }
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Do not lower the meeting's own audio while we record.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in onBuffer(buffer) }
        engine.prepare()
        try engine.start()
        Log.info("Mic started (\(format.sampleRate) Hz, \(format.channelCount) ch, voice processing \(voiceProcessing))")
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        onBuffer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }
}
