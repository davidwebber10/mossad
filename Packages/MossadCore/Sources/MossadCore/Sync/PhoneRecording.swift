import AVFoundation
import Foundation

/// A meeting in a room recorded on the phone, or a call recording the owner shared to it. The phone sends the audio
/// through iCloud or the owner's server; the Mac turns it into a call and processes it like one it recorded itself.
public struct PhoneRecording: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case room, phoneCall }

    public var id: String
    public var start: Date
    public var end: Date
    public var title: String?
    /// Nil is a room recording, as every payload from before. A kind this build does not know also reads as nil.
    public var kind: Kind?
    /// The other person on a phone call, as the owner named them, and their saved id when they picked one.
    public var person: String?
    public var personID: String?

    public init(id: String, start: Date, end: Date, title: String?, kind: Kind? = nil, person: String? = nil, personID: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
        self.kind = kind
        self.person = person
        self.personID = personID
    }

    /// A phone call, with the plan's person.
    public init(_ plan: CallImport.Plan) {
        self.init(id: plan.id, start: plan.start, end: plan.end, title: plan.title, kind: .phoneCall,
                  person: plan.person?.name, personID: plan.person?.personID)
    }

    public var isPhoneCall: Bool { kind == .phoneCall }

    enum CodingKeys: String, CodingKey { case id, start, end, title, kind, person, personID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(Kind.init(rawValue:)) }
        person = try c.decodeIfPresent(String.self, forKey: .person)
        personID = try c.decodeIfPresent(String.self, forKey: .personID)
    }

    /// The store fields that a store from before may not know.
    static let newFields = ["kind", "person", "personID"]

    /// The record's fields in the store: start, end, and each of title, kind, person, and personID that is set.
    var fields: [String: StoredValue] {
        var f: [String: StoredValue] = ["start": .date(start), "end": .date(end)]
        if let title { f["title"] = .string(title) }
        if let kind { f["kind"] = .string(kind.rawValue) }
        if let person { f["person"] = .string(person) }
        if let personID { f["personID"] = .string(personID) }
        return f
    }

    /// The recording of a store record; nil without a start or an end.
    init?(id: String, fields: [String: StoredValue]) {
        guard let start = fields["start"]?.date, let end = fields["end"]?.date else { return nil }
        self.init(id: id, start: start, end: end, title: fields["title"]?.string,
                  kind: fields["kind"]?.string.flatMap(Kind.init(rawValue:)),
                  person: fields["person"]?.string, personID: fields["personID"]?.string)
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
            // Any audio file can arrive here: a format that no converter takes fails the import, never the app.
            guard let converter = AVAudioConverter(from: input.processingFormat, to: TrackWriter.outputFormat) else {
                throw ConversionFailed(reason: "no converter from \(input.processingFormat)")
            }
            // Mix every channel into the one: a call recording can have one person on each side.
            converter.downmix = true
            let chunk: AVAudioFrameCount = 16_384
            guard let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
                throw ConversionFailed(reason: "no buffer for \(input.processingFormat)")
            }
            var finished = false
            // A read error is not the end of the file: a cut-off upload must fail, so the store keeps its copy.
            var readError: Error?
            while !finished {
                guard let out = AVAudioPCMBuffer(pcmFormat: TrackWriter.outputFormat,
                                                 frameCapacity: AVAudioFrameCount(Double(chunk) * TrackWriter.sampleRate / input.processingFormat.sampleRate) + 1024) else {
                    throw ConversionFailed(reason: "no output buffer")
                }
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
            var r = CallRecord(id: p.id, platform: p.isPhoneCall ? .phoneCall : .inPerson, bundleID: bundleID, start: p.start, end: p.end,
                               status: .recorded)
            // The owner typed a phone call's title, so no calendar event replaces it; a room's is the invite's.
            if p.isPhoneCall { r.customTitle = p.title?.nonBlank } else { r.calendarTitle = p.title?.nonBlank }
            // The person the owner named is the call's one guest: the note, the filter, and the voices read it.
            if p.isPhoneCall, let name = p.person?.nonBlank {
                r.personHint = PersonHint(name: name, personID: p.personID)
                r.attendees = [name]
                r.invitees = [Invitee(name: name, email: nil, personID: p.personID)]
            }
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
