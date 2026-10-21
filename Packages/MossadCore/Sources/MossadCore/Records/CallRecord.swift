import Foundation

public enum CallStatus: String, Codable, Sendable {
    case recording, recorded, transcribed, identified, summarized, written, failed
}

public enum Track: String, Codable, Sendable {
    case me, them

    public var fileName: String { "\(rawValue).caf" }
}

/// One recognised word with its time in the track, in seconds.
public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Utterance: Codable, Equatable, Sendable {
    public var track: Track
    public var speakerLabel: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Word times, when the transcriber gave them (older records have none).
    public var words: [Word]?

    /// Key used for speaker naming, e.g. `them:A`.
    public var speakerKey: String { "\(track.rawValue):\(speakerLabel)" }

    public init(track: Track, speakerLabel: String, start: TimeInterval, end: TimeInterval, text: String, words: [Word]? = nil) {
        self.words = words
        self.track = track
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Everything known about one call; saved as `call.json` in the call's audio directory.
public struct CallRecord: Codable, Equatable, Sendable {
    public var id: String
    public var platform: Platform
    public var bundleID: String
    public var start: Date
    public var end: Date
    public var status: CallStatus
    public var attempts = 0
    public var nextAttempt: Date?
    public var calendarTitle: String?
    public var attendees: [String] = []
    public var utterances: [Utterance] = []
    /// Per-track results, kept so a failed track does not force the other one to be transcribed again.
    public var meUtterances: [Utterance]?
    public var themUtterances: [Utterance]?
    /// The step that failed when `status` is `.failed`.
    public var failedStep: CallStatus?
    /// Speaker key (`me:A`, `them:B`) → person name.
    public var speakerNames: [String: String] = [:]
    public var unknownSpeakers: [String] = []
    /// Voice fingerprints per speaker key, kept so a speaker named later can be learned.
    public var speakerEmbeddings: [String: [Float]] = [:]
    public var summary: String?
    public var actionItems: [String] = []
    public var markdownPath: String?

    public init(id: String, platform: Platform, bundleID: String, start: Date, end: Date, status: CallStatus) {
        self.id = id
        self.platform = platform
        self.bundleID = bundleID
        self.start = start
        self.end = end
        self.status = status
    }

    public var title: String { calendarTitle ?? "\(platform.displayName) call" }

    static let fileName = "call.json"

    public func save(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func load(from dir: URL) throws -> CallRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CallRecord.self, from: Data(contentsOf: dir.appendingPathComponent(fileName)))
    }
}
