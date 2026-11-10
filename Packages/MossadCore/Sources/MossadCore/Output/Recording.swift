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
        // One encoder for a folder at a time. A second one (the pipeline's write step and the app's later pass for
        // the same meeting) waits, and then finds the file: two encoders once wrote the same partial file, and a
        // half file got the final name for some seconds.
        let key = dir.standardizedFileURL.path
        busy.lock()
        while inProgress.contains(key) { busy.wait() }
        inProgress.insert(key)
        busy.unlock()
        defer {
            busy.lock()
            inProgress.remove(key)
            busy.broadcast()
            busy.unlock()
        }
        guard !FileManager.default.fileExists(atPath: url(in: dir).path) else { return }
        do { try make(in: dir) } catch { Log.error("Recording for \(dir.lastPathComponent) failed: \(error)") }
    }

    private static let busy = NSCondition()
    nonisolated(unsafe) private static var inProgress: Set<String> = []

    /// The folders of the written calls that have no recording yet: calls from before this feature, and calls
    /// written while another call recorded.
    public static func missing(audioRoot: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)) ?? []).filter { dir in
            // The file check first: nearly every call has its recording, and then its record is not read at all.
            guard !FileManager.default.fileExists(atPath: url(in: dir).path),
                  let r = try? RecordCache.shared.record(in: dir), r.status == .written else { return false }
            // A recording that lives in the archive, or whose tracks are gone (the 30 day rule), cannot be made
            // again here. Listing it gave one false error line for each such meeting at each pass.
            guard r.cloudKey == nil else { return false }
            return [Track.me, .them].contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }
        }
    }

    /// Makes the recording for written calls that have none yet.
    public static func backfill(audioRoot: URL) {
        for dir in missing(audioRoot: audioRoot) { makeIfMissing(in: dir) }
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
