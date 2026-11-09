import AVFoundation
import Foundation

/// A meeting in a room, recorded on the phone. The phone sends the audio through iCloud; the Mac turns it into an
/// in-person call and processes it like one it recorded itself.
public struct PhoneRecording: Codable, Equatable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date
    public var title: String?

    public init(id: String, start: Date, end: Date, title: String?) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }

    /// AAC at 16 kHz mono: about 15 MB an hour, small enough to send, plenty for speech.
    public static var settings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: TrackWriter.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ] }

    public static func recordName(_ id: String) -> String { "rec-\(id)" }

    /// What marks a call as a phone recording.
    public static let bundleID = "iphone"

    struct Exists: Error {}
    struct ConversionFailed: Error, CustomStringConvertible {
        var reason: String
        var description: String { "The recording could not be converted: \(reason)" }
    }

    /// Writes the call folder: the audio as the mic track, an empty second track, and the record ready to process.
    /// Throws rather than overwrite a call that is already there.
    @discardableResult
    public static func importAudio(_ audio: URL, recording p: PhoneRecording, into paths: Paths) throws -> CallRecord {
        let dir = paths.callDirectory(p.id)
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(CallRecord.fileName).path) else { throw Exists() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let input = try AVAudioFile(forReading: audio)
            let output = try AVAudioFile(forWriting: dir.appendingPathComponent(Track.me.fileName), settings: TrackWriter.fileSettings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let converter = AVAudioConverter(from: input.processingFormat, to: TrackWriter.outputFormat)!
            let chunk: AVAudioFrameCount = 16_384
            let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk)!
            var finished = false
            // A read error is not the end of the file: a cut-off upload must fail, so the store keeps its copy.
            var readError: Error?
            while !finished {
                let out = AVAudioPCMBuffer(pcmFormat: TrackWriter.outputFormat,
                                           frameCapacity: AVAudioFrameCount(Double(chunk) * TrackWriter.sampleRate / input.processingFormat.sampleRate) + 1024)!
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, state in
                    // At the end a read throws on some formats; that is the end, not a failure.
                    if input.framePosition >= input.length { state.pointee = .endOfStream; return nil }
                    do {
                        try input.read(into: source, frameCount: chunk)
                    } catch {
                        readError = error
                        state.pointee = .endOfStream
                        return nil
                    }
                    if source.frameLength == 0 { state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return source
                }
                if let error { throw error }
                if let readError { throw readError }
                if status == .error { throw ConversionFailed(reason: "the converter stopped") }
                if out.frameLength > 0 { try output.write(from: out) }
                finished = status == .endOfStream
            }
            let inSeconds = Double(input.length) / input.processingFormat.sampleRate
            let outSeconds = Double(output.length) / TrackWriter.sampleRate
            if outSeconds < inSeconds - max(1, inSeconds * 0.01) {
                throw ConversionFailed(reason: "only \(Int(outSeconds)) of \(Int(inSeconds)) s converted")
            }
            _ = try AVAudioFile(forWriting: dir.appendingPathComponent(Track.them.fileName), settings: TrackWriter.fileSettings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
            var r = CallRecord(id: p.id, platform: .inPerson, bundleID: bundleID, start: p.start, end: p.end, status: .recorded)
            r.calendarTitle = p.title?.nonBlank
            try r.save(to: dir)
            return r
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }
}

/// Call IDs are the start time, "20270115-090000", on the Mac and the phone alike.
public enum CallID {
    public static func make(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}

/// What the room recorder does when the system interrupts its audio, such as for a phone call.
public enum RoomInterruption {
    public enum Action: Equatable, Sendable { case none, pause, resume, tellOwner }

    /// The end of an interruption resumes only a pause the interruption caused, and only when the system allows
    /// it; otherwise the owner hears about it, because a recording that stays paused loses the meeting.
    public static func action(began: Bool, shouldResume: Bool, recording: Bool, pausedByInterruption: Bool) -> Action {
        if began { return recording ? .pause : .none }
        guard pausedByInterruption, !recording else { return .none }
        return shouldResume ? .resume : .tellOwner
    }
}
