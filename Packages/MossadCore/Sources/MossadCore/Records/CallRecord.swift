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

/// One recording inside a merged meeting: when it ran, and where it begins in the joined audio.
public struct CallPart: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var offset: TimeInterval

    public init(start: Date, end: Date, offset: TimeInterval) {
        self.start = start
        self.end = end
        self.offset = offset
    }
}

/// A line in the transcript for something that happened to the recording, such as a pause.
public struct TranscriptMarker: Codable, Equatable, Sendable {
    /// Seconds into the recording.
    public var offset: TimeInterval
    public var text: String
    /// A moment the owner marked as important during the call.
    public var isBookmark = false

    public init(offset: TimeInterval, text: String, isBookmark: Bool = false) {
        self.offset = offset
        self.text = text
        self.isBookmark = isBookmark
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(TimeInterval.self, forKey: .offset)
        text = try c.decode(String.self, forKey: .text)
        isBookmark = try c.decodeIfPresent(Bool.self, forKey: .isBookmark) ?? false
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
    /// The meeting's ID from its link (Meet code, Zoom number, Teams meeting ID), when the call ran in a browser.
    public var meetingID: String?
    public var calendarTitle: String?
    public var attendees: [String] = []
    public var utterances: [Utterance] = []
    /// Per-track results, kept so a failed track does not force the other one to be transcribed again.
    public var meUtterances: [Utterance]?
    public var themUtterances: [Utterance]?
    /// The step that failed when `status` is `.failed`.
    public var failedStep: CallStatus?
    /// Short text for the last error, such as "AssemblyAI key missing"; nil once a step succeeds.
    public var failureReason: String?
    /// Speaker key (`me:A`, `them:B`) → person name.
    public var speakerNames: [String: String] = [:]
    public var unknownSpeakers: [String] = []
    /// Voice fingerprints per speaker key, kept so a speaker named later can be learned.
    public var speakerEmbeddings: [String: [Float]] = [:]
    /// Markdown; older records hold plain sentences.
    public var summary: String?
    public var topics: [SummaryTopic] = []
    public var kind: String?
    /// False for a meeting that only shares information; nil for records from before this field.
    public var hasOutcomes: Bool?
    public var actionItems: [ActionItem] = []
    public var decisions: [String] = []
    /// One sentence, at most about 140 characters.
    public var headline: String?
    public var markdownPath: String?
    /// The recordings joined into this meeting, oldest first; empty for a single recording.
    public var parts: [CallPart] = []
    /// Pauses and stops by the person, shown in the transcript.
    public var markers: [TranscriptMarker] = []
    /// Where the recording is archived in the bucket, once uploaded.
    public var cloudKey: String?

    public init(id: String, platform: Platform, bundleID: String, start: Date, end: Date, status: CallStatus) {
        self.id = id
        self.platform = platform
        self.bundleID = bundleID
        self.start = start
        self.end = end
        self.status = status
    }

    public var title: String { calendarTitle ?? "\(platform.displayName) call" }

    /// Every marker line of the transcript in time order: pauses, stops, and where a merged part begins.
    public var transcriptMarkers: [TranscriptMarker] {
        (markers + MeetingMerge.partBreaks(self).map { TranscriptMarker(offset: $0.offset, text: $0.text) }).sorted { $0.offset < $1.offset }
    }

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

extension CallRecord {
    // Fields added over time are missing from older call.json files, so each one falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), platform: try c.decode(Platform.self, forKey: .platform),
                  bundleID: try c.decode(String.self, forKey: .bundleID), start: try c.decode(Date.self, forKey: .start),
                  end: try c.decode(Date.self, forKey: .end), status: try c.decode(CallStatus.self, forKey: .status))
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttempt = try c.decodeIfPresent(Date.self, forKey: .nextAttempt)
        meetingID = try c.decodeIfPresent(String.self, forKey: .meetingID)
        calendarTitle = try c.decodeIfPresent(String.self, forKey: .calendarTitle)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        utterances = try c.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
        meUtterances = try c.decodeIfPresent([Utterance].self, forKey: .meUtterances)
        themUtterances = try c.decodeIfPresent([Utterance].self, forKey: .themUtterances)
        failedStep = try c.decodeIfPresent(CallStatus.self, forKey: .failedStep)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        unknownSpeakers = try c.decodeIfPresent([String].self, forKey: .unknownSpeakers) ?? []
        speakerEmbeddings = try c.decodeIfPresent([String: [Float]].self, forKey: .speakerEmbeddings) ?? [:]
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        topics = try c.decodeIfPresent([SummaryTopic].self, forKey: .topics) ?? []
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        hasOutcomes = try c.decodeIfPresent(Bool.self, forKey: .hasOutcomes)
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        markdownPath = try c.decodeIfPresent(String.self, forKey: .markdownPath)
        parts = try c.decodeIfPresent([CallPart].self, forKey: .parts) ?? []
        markers = try c.decodeIfPresent([TranscriptMarker].self, forKey: .markers) ?? []
        cloudKey = try c.decodeIfPresent(String.self, forKey: .cloudKey)
    }
}
