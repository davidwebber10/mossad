import AVFoundation
import Foundation

/// Captures the microphone. With voice processing on, Apple's echo cancellation removes
/// what the speakers play, so other people's voices do not leak into the "me" track.
public final class MicCapture: TrackSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let voiceProcessing: Bool

    public init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
    }

    public func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }
}
