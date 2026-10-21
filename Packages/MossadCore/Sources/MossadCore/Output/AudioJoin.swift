import AVFoundation
import Foundation

/// Joins audio files end to end. A missing file becomes silence of its duration, so later parts stay aligned.
public enum AudioJoin {
    /// Writes 16 kHz mono; the extension picks the format (`.caf` raw, `.m4a` AAC like `Recording`).
    public static func join(_ inputs: [URL?], durations: [TimeInterval], to destination: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: TrackWriter.sampleRate, channels: 1)!
        let settings: [String: Any] = destination.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: TrackWriter.sampleRate, AVNumberOfChannelsKey: 1,
               AVEncoderBitRateKey: Recording.bitRate]
            : format.settings
        try? FileManager.default.removeItem(at: destination)
        let out = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 160_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        for (input, duration) in zip(inputs, durations) {
            var remaining = AVAudioFramePosition(duration * TrackWriter.sampleRate)
            if let input, let file = try? AVAudioFile(forReading: input), file.processingFormat == format {
                while file.framePosition < file.length, remaining > 0 {
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining)))
                    guard buffer.frameLength > 0 else { break }
                    try out.write(from: buffer)
                    remaining -= AVAudioFramePosition(buffer.frameLength)
                }
            }
            // Silence for a missing file, or for the rest of a file shorter than its part.
            while remaining > 0 {
                let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
                memset(buffer.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
                buffer.frameLength = n
                try out.write(from: buffer)
                remaining -= AVAudioFramePosition(n)
            }
        }
    }
}
