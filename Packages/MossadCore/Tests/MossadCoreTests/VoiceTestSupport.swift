import AVFoundation
import Foundation
@testable import MossadCore

/// Writes a 16 kHz mono file of `total` seconds with sine tones in the given ranges and silence elsewhere.
func writeSegments(_ url: URL, total: Double, _ segments: [(start: Double, end: Double, freq: Double)]) throws {
    let sr = 16_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let frames = AVAudioFrameCount(total * sr)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(frames) { data[i] = 0 }
    for s in segments {
        for i in Int(s.start * sr)..<min(Int(s.end * sr), Int(frames)) {
            data[i] = Float(sin(2 * .pi * s.freq * Double(i) / sr) * 0.5)
        }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

/// "Voice" = tone frequency. 200 Hz → [1,0,0,0], 400 → [0,1,0,0], 600 → [0,0,1,0], 800 → [0,0,0,1].
final class ToneEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    var calls = 0
    func embedding(for samples: [Float]) async throws -> [Float] {
        calls += 1
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        let freq = Double(crossings) / 2 / (Double(samples.count) / 16_000)
        var v = [Float](repeating: 0, count: 4)
        v[max(0, min(3, Int((freq / 200).rounded()) - 1))] = 1
        return v
    }
}
