import AVFoundation
import Foundation

/// Copies one range of a track into a file of its own, for the cut of one recording into two meetings. The copy has
/// the source's own file format (a track of `TrackWriter` is 16 kHz mono Int16 CAF), so no sample changes.
public enum AudioCut {
    public enum Failure: LocalizedError, Equatable {
        case outOfRange
        case short(expected: Int64, written: Int64)

        public var errorDescription: String? {
            switch self {
            case .outOfRange: "the range is not inside the audio"
            case let .short(expected, written): "the copy has \(written) of \(expected) frames"
            }
        }
    }

    /// The frame of a time. Both parts of a border use this one rule, so each sample is in exactly one part.
    static func frame(_ seconds: TimeInterval, rate: Double) -> Int64 { Int64((seconds * rate).rounded()) }

    /// Copies `from` to `to` (seconds; nil is the end) and returns the frames written. Streamed in buffers. A range
    /// that is not inside the audio is refused and writes nothing. The target is synced before this returns.
    @discardableResult
    public static func copy(_ source: URL, from: TimeInterval, to: TimeInterval?, into target: URL) throws -> Int64 {
        let input = try AVAudioFile(forReading: source)
        let rate = input.processingFormat.sampleRate
        let first = frame(from, rate: rate)
        let last = to.map { frame($0, rate: rate) } ?? input.length
        guard from >= 0, first <= input.length, last <= input.length, last >= first else { throw Failure.outOfRange }
        try? FileManager.default.removeItem(at: target)
        var written: Int64 = 0
        do {
            let output = try AVAudioFile(forWriting: target, settings: input.fileFormat.settings,
                                         commonFormat: input.processingFormat.commonFormat,
                                         interleaved: input.processingFormat.isInterleaved)
            let chunk: AVAudioFrameCount = 16_000
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk)!
            input.framePosition = first
            while input.framePosition < last {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunk), last - input.framePosition)))
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                written += Int64(buffer.frameLength)
            }
            output.close()
            guard written == last - first else { throw Failure.short(expected: last - first, written: written) }
            let handle = try FileHandle(forUpdating: target)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return written
    }

    /// The frames of a track, as a copy counts them.
    public static func frames(_ url: URL) throws -> Int64 { try AVAudioFile(forReading: url).length }
}
