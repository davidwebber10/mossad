import AVFoundation
import Foundation

/// The copy of a track that is sent for transcription: mono AAC at 48 kbps (the most AAC allows for 16 kHz mono), about 21 MB an hour instead of
/// 115 MB for the raw track. On a slow network (a plane, a hotel) the upload was most of the wait.
public enum UploadAudio {
    /// Speech at 16 kHz loses nothing a recognizer uses at this rate; speaker identification reads the raw track.
    static let bitRate = 48_000

    /// Writes `upload-<track>.m4a` in `dir` and returns it. The caller deletes it after the upload.
    public static func compress(_ track: URL, into dir: URL) throws -> URL {
        let input = try AVAudioFile(forReading: track)
        let format = input.processingFormat
        let out = dir.appendingPathComponent("upload-\(track.deletingPathExtension().lastPathComponent).m4a")
        try? FileManager.default.removeItem(at: out)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate]
        do {
            let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: format.commonFormat, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000)!
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try file.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}
