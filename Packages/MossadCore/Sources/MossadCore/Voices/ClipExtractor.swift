import AVFoundation
import Foundation

/// Cuts a short sample of one speaker for the naming view.
public enum ClipExtractor {
    /// The speaker's lines that can serve as a sample, longest first.
    public static func candidates(for key: String, utterances: [Utterance]) -> [Utterance] {
        utterances.filter { $0.speakerKey == key }.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
    }

    /// Cuts the sample from candidate number `choice` (wrapping around), so a poor sample can be replaced
    /// by the next one. Returns the line the sample comes from.
    @discardableResult
    public static func clip(for key: String, utterances: [Utterance], source: URL, to destination: URL,
                            seconds: TimeInterval = 5, choice: Int = 0) throws -> Utterance? {
        let all = candidates(for: key, utterances: utterances)
        guard !all.isEmpty else { return nil }
        let line = all[((choice % all.count) + all.count) % all.count]
        let samples = try AudioSamples.read(source, from: line.start, to: min(line.end, line.start + seconds))
        let format = TrackWriter.outputFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? FileManager.default.removeItem(at: destination)
        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return line
    }
}
