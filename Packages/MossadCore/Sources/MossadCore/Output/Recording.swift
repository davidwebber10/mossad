import AVFoundation
import Foundation

/// The file a person listens to: both tracks mixed to mono AAC, about 14 MB an hour. The raw tracks are
/// 16-bit 16 kHz (about 115 MB an hour each) and are deleted after the retention period; this file is kept.
public enum Recording {
    public static let fileName = "recording.m4a"
    static let bitRate = 32_000

    public struct NoTracks: Error {}

    public static func url(in dir: URL) -> URL { dir.appendingPathComponent(fileName) }

    /// Never fails a step: without a recording the raw tracks are simply kept longer.
    public static func makeIfMissing(in dir: URL) {
        guard !FileManager.default.fileExists(atPath: url(in: dir).path) else { return }
        do { try make(in: dir) } catch { Log.error("Recording for \(dir.lastPathComponent) failed: \(error)") }
    }

    /// Makes the recording for written calls that have none yet, such as calls from before this feature.
    public static func backfill(audioRoot: URL) {
        for dir in (try? FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)) ?? [] {
            guard let r = try? CallRecord.load(from: dir), r.status == .written else { continue }
            makeIfMissing(in: dir)
        }
    }

    @discardableResult
    public static func make(in dir: URL) throws -> URL {
        let tracks = [Track.me, .them].compactMap { try? AVAudioFile(forReading: dir.appendingPathComponent($0.fileName)) }
        guard !tracks.isEmpty else { throw NoTracks() }
        let format = AVAudioFormat(standardFormatWithSampleRate: TrackWriter.sampleRate, channels: 1)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: TrackWriter.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate]
        // Written under a temporary name so a crash never leaves a half file that looks finished.
        let temp = dir.appendingPathComponent("recording.partial.m4a")
        try? FileManager.default.removeItem(at: temp)
        do {
            let out = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk: AVAudioFrameCount = 160_000
            let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            let read = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            while true {
                var frames: AVAudioFrameCount = 0
                memset(mix.floatChannelData![0], 0, Int(chunk) * MemoryLayout<Float>.size)
                for track in tracks where track.framePosition < track.length {
                    try track.read(into: read, frameCount: chunk)
                    let m = mix.floatChannelData![0], r = read.floatChannelData![0]
                    for i in 0..<Int(read.frameLength) { m[i] += r[i] }
                    frames = max(frames, read.frameLength)
                }
                guard frames > 0 else { break }
                let m = mix.floatChannelData![0]
                for i in 0..<Int(frames) { m[i] = max(-1, min(1, m[i])) }
                mix.frameLength = frames
                try out.write(from: mix)
            }
        }
        let url = url(in: dir)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }
}
