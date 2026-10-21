import AVFoundation
import Foundation

enum AudioSamples {
    static func sampleRate(_ url: URL) throws -> Double {
        try AVAudioFile(forReading: url).processingFormat.sampleRate
    }

    /// Reads mono Float32 samples between two times (seconds) from a track file.
    static func read(_ url: URL, from start: TimeInterval, to end: TimeInterval) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        let first = max(0, AVAudioFramePosition(start * sr))
        let last = min(file.length, AVAudioFramePosition(end * sr))
        guard last > first else { return [] }
        file.framePosition = first
        var samples: [Float] = []
        samples.reserveCapacity(Int(last - first))
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
        // `read` may return fewer frames than asked for, so read until the range is complete.
        while file.framePosition < last {
            try file.read(into: chunk, frameCount: AVAudioFrameCount(min(16_000, last - file.framePosition)))
            if chunk.frameLength == 0 { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength)))
        }
        return samples
    }
}
