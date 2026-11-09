import AVFoundation
import Foundation

/// The room recording's files on the phone. The recorder writes 16-bit PCM in CAF parts, which stay readable up to
/// the last write when the app is stopped mid-recording (an MPEG-4 file gets its index only at the end). A finished
/// recording is joined into one small AAC file to send: `<id>.m4a`.
public enum RoomAudio {
    /// What the recorder writes: about 115 MB an hour, for a short time.
    public static func recordingSettings(sampleRate: Double = TrackWriter.sampleRate) -> [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ] }

    private static let partMark = ".part"

    /// `<id>.part<n>.caf`, from 1.
    public static func part(_ id: String, _ n: Int, in dir: URL) -> URL {
        dir.appendingPathComponent("\(id)\(partMark)\(n).caf")
    }

    public static func finished(_ id: String, in dir: URL) -> URL { dir.appendingPathComponent("\(id).m4a") }

    /// The parts of one recording, in order.
    public static func parts(of id: String, in dir: URL) -> [URL] {
        let prefix = id + partMark
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".caf"),
                  let n = Int(name.dropFirst(prefix.count).dropLast(4)) else { return nil }
            return (n, dir.appendingPathComponent(name))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    /// The ids of every recording with audio in the folder, finished or not.
    public static func ids(in dir: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { name in
            if name.hasSuffix(".joining.m4a") { return nil }
            if name.hasSuffix(".m4a") { return String(name.dropLast(4)) }
            if name.hasSuffix(".caf"), let r = name.range(of: partMark) { return String(name[..<r.lowerBound]) }
            return nil
        })
    }

    /// The start of a recording from its id, which is the start time (`CallID`), for audio that lost its entry.
    public static func start(of id: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: id)
    }

    /// Seconds of audio in a file, or nil when it cannot be read.
    public static func length(of url: URL) -> TimeInterval? {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// Seconds of audio in a recording: the finished file, or the sum of its parts. Nil when nothing can be read.
    public static func length(of id: String, in dir: URL) -> TimeInterval? {
        let done = finished(id, in: dir)
        if FileManager.default.fileExists(atPath: done.path) { return length(of: done) }
        let lengths = parts(of: id, in: dir).compactMap { length(of: $0) }
        return lengths.isEmpty ? nil : lengths.reduce(0, +)
    }

    /// When the recorder last wrote to the recording: the end of a recording the app never finished.
    public static func lastWrite(of id: String, in dir: URL) -> Date? {
        let files = parts(of: id, in: dir) + [finished(id, in: dir)]
        return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    public struct Unreadable: LocalizedError {
        public let file: String
        public var errorDescription: String? { "The recording part \(file) could not be read." }
    }

    /// Joins the parts into `<id>.m4a` and deletes them, and returns the length. Safe to run again after a crash:
    /// the finished file appears only once complete. A part that cannot be read stops the join and stays on disk.
    @discardableResult
    public static func finish(_ id: String, in dir: URL) throws -> TimeInterval {
        let out = finished(id, in: dir)
        let parts = parts(of: id, in: dir)
        if FileManager.default.fileExists(atPath: out.path) {
            for p in parts { try? FileManager.default.removeItem(at: p) }
            return length(of: out) ?? 0
        }
        let partial = dir.appendingPathComponent("\(id).joining.m4a")
        try? FileManager.default.removeItem(at: partial)
        var written: AVAudioFramePosition = 0
        do {
            let output = try AVAudioFile(forWriting: partial, settings: PhoneRecording.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            for p in parts {
                guard let input = try? AVAudioFile(forReading: p) else {
                    // A part the recorder created but never wrote to holds no audio.
                    if ((try? p.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 4096 { continue }
                    throw Unreadable(file: p.lastPathComponent)
                }
                written += try append(input, to: output)
            }
            output.close()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try FileManager.default.moveItem(at: partial, to: out)
        for p in parts { try? FileManager.default.removeItem(at: p) }
        return Double(written) / TrackWriter.sampleRate
    }

    /// Deletes every file of a recording.
    public static func delete(_ id: String, in dir: URL) {
        for f in parts(of: id, in: dir) + [finished(id, in: dir)] { try? FileManager.default.removeItem(at: f) }
    }

    private static func append(_ input: AVAudioFile, to output: AVAudioFile) throws -> AVAudioFramePosition {
        guard let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat) else {
            throw Unreadable(file: input.url.lastPathComponent)
        }
        let chunk: AVAudioFrameCount = 16_384
        let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk)!
        let ratio = output.processingFormat.sampleRate / input.processingFormat.sampleRate
        var written: AVAudioFramePosition = 0
        var finished = false
        while !finished {
            let out = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 1024)!
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, state in
                do {
                    try input.read(into: source, frameCount: chunk)
                } catch {
                    state.pointee = .endOfStream
                    return nil
                }
                if source.frameLength == 0 { state.pointee = .endOfStream; return nil }
                state.pointee = .haveData
                return source
            }
            if let error { throw error }
            if out.frameLength > 0 {
                try output.write(from: out)
                written += AVAudioFramePosition(out.frameLength)
            }
            finished = status == .endOfStream || status == .error
        }
        return written
    }
}
