import AVFoundation
import Foundation

/// Cuts a short sample of one speaker for the naming view.
public enum ClipExtractor {
    public static func clip(for key: String, utterances: [Utterance], source: URL, to destination: URL, seconds: TimeInterval = 5) throws {
        guard let longest = utterances.filter({ $0.speakerKey == key }).max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return }
        let samples = try AudioSamples.read(source, from: longest.start, to: min(longest.end, longest.start + seconds))
        let format = TrackWriter.outputFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? FileManager.default.removeItem(at: destination)
        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
