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
    private static let asideMark = ".unreadable.caf"
    /// Where the audio starts in a CAF file as the recorder writes it.
    private static let cafHeader = 4096

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

    /// The ids of every recording with audio in the folder, finished or not. Empty when there is no folder yet;
    /// nil when the folder cannot be listed, which is unknown and not "no recordings".
    public static func ids(in dir: URL) -> Set<String>? {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return Set(names.compactMap { name in
            if name.hasSuffix(".joining.m4a") || name.hasSuffix(asideMark) { return nil }
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

    /// Whether a recording that the app never finished is under `minimum` by every measure, so it can be deleted
    /// as the Mac drops a short call. Every part must open, and its bytes must agree with what it says: a part that
    /// does not open, or says less than it holds, may be the meeting. The app's own count is gone after a stop, so
    /// nothing else backs the number.
    public static func isSurelyShort(_ id: String, in dir: URL, minimum: TimeInterval) -> Bool {
        let done = finished(id, in: dir)
        if FileManager.default.fileExists(atPath: done.path) { return length(of: done).map { $0 < minimum } ?? false }
        let parts = parts(of: id, in: dir)
        guard !parts.isEmpty else { return false }
        var said: TimeInterval = 0, held: TimeInterval = 0
        for p in parts {
            guard let size = try? p.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            // A part the recorder created but never wrote to holds no audio.
            if size <= cafHeader { continue }
            guard let f = try? AVAudioFile(forReading: p), f.fileFormat.sampleRate > 0 else { return false }
            let bytesPerFrame = Double(max(1, f.fileFormat.streamDescription.pointee.mBytesPerFrame))
            said += Double(f.length) / f.fileFormat.sampleRate
            held += Double(size - cafHeader) / bytesPerFrame / f.fileFormat.sampleRate
        }
        return max(said, held) < minimum
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

    /// The result of a join: the seconds in the finished file, and the names of parts that could not be read in
    /// full, which stay on disk under a name that nothing deletes.
    public struct Joined: Equatable, Sendable {
        public var length: TimeInterval
        public var setAside: [String] = []
    }

    /// Joins the parts into `<id>.m4a` and deletes them. Safe to run again after a crash: the finished file appears
    /// only once complete. A part that cannot be read, or whose read stops before its end, throws `Unreadable` and
    /// every part stays on disk; any other error (such as a full disk) also leaves every part.
    ///
    /// With `salvage`, for a part that will not read: what can be read is joined (also the readable start of a bad
    /// part), and each bad part moves aside as `<id>.part<n>.unreadable.caf`. With nothing readable it still throws.
    @discardableResult
    public static func finish(_ id: String, in dir: URL, salvage: Bool = false) throws -> Joined {
        let out = finished(id, in: dir)
        let parts = parts(of: id, in: dir)
        if FileManager.default.fileExists(atPath: out.path) {
            for p in parts { try? FileManager.default.removeItem(at: p) }
            return Joined(length: length(of: out) ?? 0)
        }
        let partial = dir.appendingPathComponent("\(id).joining.m4a")
        try? FileManager.default.removeItem(at: partial)
        var written: AVAudioFramePosition = 0
        var bad: [URL] = []
        do {
            let output = try AVAudioFile(forWriting: partial, settings: PhoneRecording.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            for p in parts {
                guard let input = try? AVAudioFile(forReading: p) else {
                    // A part the recorder created but never wrote to holds no audio.
                    if ((try? p.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= cafHeader { continue }
                    guard salvage else { throw Unreadable(file: p.lastPathComponent) }
                    bad.append(p)
                    continue
                }
                written += try append(input, to: output)
                // A read throws at the end of a file and also when it fails in the middle; only the position tells
                // them apart. The parts are the only copy, so a short read never counts as the end.
                if input.framePosition < input.length {
                    guard salvage else { throw Unreadable(file: p.lastPathComponent) }
                    bad.append(p)
                }
            }
            output.close()
            guard written > 0 else { throw Unreadable(file: (bad.first ?? parts.first)?.lastPathComponent ?? id) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        // The bad parts move aside before the finished file appears: once it is there, a later pass deletes
        // whatever still has a part's name.
        var aside: [String] = []
        do {
            for p in bad {
                let name = String(p.lastPathComponent.dropLast(4)) + asideMark
                try FileManager.default.moveItem(at: p, to: dir.appendingPathComponent(name))
                aside.append(name)
            }
            try FileManager.default.moveItem(at: partial, to: out)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        for p in parts where !bad.contains(p) { try? FileManager.default.removeItem(at: p) }
        return Joined(length: Double(written) / TrackWriter.sampleRate, setAside: aside)
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
