import Foundation

/// A number about one person in one meeting that can be compared across meetings. Counts are per hour of the
/// call, so a long meeting and a short one compare.
public enum PersonMetric: String, Sendable, CaseIterable {
    case talkShare, wordsPerMinute, fillersPerMinute, questionsPerHour, averageTurn, longestTurn, cutInsPerHour, cutOffsPerHour, responseGap
}

/// A number about a whole meeting that can be compared across meetings.
public enum MeetingMetric: String, Sendable, CaseIterable {
    case length, voices, decisions, actionItems, screens, silenceShare, wordsPerMinute
    /// The coach's rating of the meeting's worth: 1 low, 2 medium, 3 high.
    case value
}

extension MeetingValue.Rating {
    /// The rating as a number, for a range and a trend line.
    public var level: Int {
        switch self {
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public init?(level: Double) {
        switch level.rounded() {
        case 1: self = .low
        case 2: self = .medium
        case 3: self = .high
        default: return nil
        }
    }
}

/// One meeting as a row of history: the few numbers a later call is compared with. Small, so every meeting's
/// facts stay in memory while the words do not have to be read again.
public struct MeetingFacts: Sendable, Equatable {
    /// How many voices: the setting a person's numbers belong to.
    public enum Size: Sendable, Equatable {
        case oneOnOne, small, medium, large

        public init(voices: Int) {
            self = voices <= 2 ? .oneOnOne : voices <= 4 ? .small : voices <= 8 ? .medium : .large
        }

        /// "3 to 4 people".
        public var words: String {
            switch self {
            case .oneOnOne: "2 people"
            case .small: "3 to 4 people"
            case .medium: "5 to 8 people"
            case .large: "9 or more people"
            }
        }
    }

    /// A named speaker. A voice with no name cannot be followed from one meeting to the next.
    public struct Person: Sendable, Equatable {
        public var name: String
        public var isOwner: Bool
        public var values: [PersonMetric: Double]
    }

    public var id: String
    /// `MeetingAnalytics.stamp` of the record these facts were read from.
    public var stamp: Int
    public var start: Date
    public var title: String
    /// The title in one spelling, for finding the series; nil for a call named only after its app.
    public var series: String?
    public var kind: String?
    public var tags: [String]
    /// Every voice, named or not.
    public var voices: Int
    public var people: [Person]
    public var values: [MeetingMetric: Double]

    public var size: Size { Size(voices: voices) }
    public func person(_ name: String) -> Person? { people.first { $0.name == name } }
    public var owner: Person? { people.first(where: \.isOwner) }
    /// The other person of a meeting of two named voices.
    public var partner: Person? {
        voices == 2 && people.count == 2 && owner != nil ? people.first { !$0.isOwner } : nil
    }

    /// Counts are measured against at least this much of an hour, so three questions in a five-minute call are
    /// not "36 an hour".
    static let minimumHours = 0.25

    public init(record r: CallRecord, owner: String) {
        self.init(record: r, owner: owner, voices: MeetingAnalytics.Voices(record: r, owner: owner))
    }

    init(id: String, stamp: Int, start: Date, title: String, series: String?, kind: String?, tags: [String], voices: Int, people: [Person],
         values: [MeetingMetric: Double]) {
        self.id = id
        self.stamp = stamp
        self.start = start
        self.title = title
        self.series = series
        self.kind = kind
        self.tags = tags
        self.voices = voices
        self.people = people
        self.values = values
    }

    init(record r: CallRecord, owner: String, voices v: MeetingAnalytics.Voices) {
        id = r.id
        stamp = MeetingAnalytics.stamp(r)
        start = r.start
        title = r.title
        series = r.titleSource == .platform ? nil : PeopleDuplicates.normalized(r.title)
        kind = r.kind
        tags = r.tags
        voices = v.speakers.count
        let hours = max(v.duration / 3600, Self.minimumHours)
        people = v.speakers.filter { !$0.isUnknown && $0.seconds > 0 }.map { s in
            var values: [PersonMetric: Double] = [
                .talkShare: s.share, .questionsPerHour: Double(s.questions) / hours, .averageTurn: s.averageTurn,
                .cutInsPerHour: Double(s.interruptionsMade) / hours, .cutOffsPerHour: Double(s.interruptionsReceived) / hours,
            ]
            values[.wordsPerMinute] = s.wordsPerMinute
            values[.fillersPerMinute] = s.fillersPerMinute
            values[.longestTurn] = s.longestTurn?.seconds
            values[.responseGap] = s.medianResponse
            return Person(name: s.name, isOwner: s.isOwner, values: values)
        }
        var values: [MeetingMetric: Double] = [
            .length: max(0, r.end.timeIntervalSince(r.start)), .voices: Double(v.speakers.count), .decisions: Double(r.decisions.count),
            .actionItems: Double(r.actionItems.count), .screens: Double(r.screens?.count ?? 0),
        ]
        if let flow = v.flow { values[.silenceShare] = flow.silenceShare }
        let words = v.speakers.reduce(0) { $0 + $1.words }
        if v.speechSeconds >= MeetingAnalytics.minimumPaceSeconds { values[.wordsPerMinute] = Double(words) / (v.speechSeconds / 60) }
        self.values = values
    }
}

/// Every written meeting's facts, kept between openings of the Analytics tab. A meeting's facts are read again
/// only when its record changed, so one new or edited meeting costs one meeting's work.
public final class MeetingFactsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: MeetingFacts] = [:]
    private var owner = ""
    private var reads = 0
    /// How many records were read for their facts so far, for tests.
    var readCount: Int { lock.withLock { reads } }

    public init() {}

    /// The facts of the written meetings with speech among `records`. Call it off the main thread: the first
    /// call reads every meeting.
    public func facts(for records: [CallRecord], owner: String) -> [MeetingFacts] {
        let known: [String: MeetingFacts] = lock.withLock {
            // Another owner name changes who "you" is in every meeting.
            if self.owner != owner { entries = [:]; self.owner = owner }
            return entries
        }
        var kept: [String: MeetingFacts] = [:]
        var out: [MeetingFacts] = []
        var read = 0
        for r in records where r.status == .written && !r.utterances.isEmpty {
            let facts: MeetingFacts
            if let hit = known[r.id], hit.stamp == MeetingAnalytics.stamp(r) {
                facts = hit
            } else {
                facts = MeetingFacts(record: r, owner: owner)
                read += 1
            }
            kept[r.id] = facts
            out.append(facts)
        }
        lock.withLock {
            // A slower call for another owner must not put its facts under the new one.
            if self.owner == owner { entries = kept }
            reads += read
        }
        return out
    }
}
