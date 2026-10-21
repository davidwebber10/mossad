import AVFoundation
import Foundation

/// When a track has sound, from 20 ms frames above the silence threshold. Each sound frame is widened by a
/// hangover so the short gaps between words, and the echo delay, still count as sound.
public struct SoundTimeline: Sendable {
    static let frameDuration: TimeInterval = 0.02
    static let hangover: TimeInterval = 0.2

    /// Sorted, non-overlapping sound intervals in seconds from the start of the track.
    let intervals: [(start: TimeInterval, end: TimeInterval)]
    let duration: TimeInterval

    init(frameRMS: [Float], threshold: Float = TrackWriter.soundThreshold) {
        duration = Double(frameRMS.count) * Self.frameDuration
        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        for (i, rms) in frameRMS.enumerated() where rms > threshold {
            let start = max(0, Double(i) * Self.frameDuration - Self.hangover)
            let end = min(duration, Double(i + 1) * Self.frameDuration + Self.hangover)
            if let last = merged.last, start <= last.end {
                merged[merged.count - 1].end = max(last.end, end)
            } else {
                merged.append((start, end))
            }
        }
        intervals = merged
    }

    /// Seconds of sound between two times.
    func sound(from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        intervals.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
    }

    /// The share of the whole track that has sound.
    var coverage: Double { duration > 0 ? sound(from: 0, to: duration) / duration : 0 }

    /// Reads the file in chunks, so an hour-long track never sits in memory at once.
    public static func measure(url: URL) throws -> SoundTimeline {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameSize = AVAudioFrameCount(format.sampleRate * frameDuration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameSize * 500)!
        var rms: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let data = buffer.floatChannelData![0]
            var i = 0
            while i < Int(buffer.frameLength) {
                let n = min(Int(frameSize), Int(buffer.frameLength) - i)
                var sum: Float = 0
                for j in i..<(i + n) { sum += data[j] * data[j] }
                rms.append((sum / Float(n)).squareRoot())
                i += n
            }
        }
        return SoundTimeline(frameRMS: rms)
    }
}
