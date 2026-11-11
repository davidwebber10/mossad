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
        /// The id in `people.json`, when the record has it: two people with one name have their own history.
        public var personID: String? = nil
        public var isOwner: Bool
        /// False for a voice that said almost nothing; see `MeetingFacts.isMain`.
        public var isMain = true
        /// A number that the meeting cannot give is absent, never 0.
        public var values: [PersonMetric: Double]
    }

    public var id: String
    /// `MeetingAnalytics.stamp` of the record these facts were read from.
    public var stamp: Int
    public var start: Date
    public var title: String
    /// The title in one spelling, for finding the series. Only a title from the calendar or from the owner makes
    /// a series: two unrelated calls can get the same title from the model.
    public var series: String?
    public var kind: String?
    public var tags: [String]
    /// Every voice, named or not.
    public var voices: Int
    /// The voices that count for the setting: without the ones that said almost nothing. A three-second voice
    /// from a split by the transcriber does not turn a 1:1 into a group.
    public var mainVoices: Int
    public var people: [Person]
    /// A number that the meeting cannot give is absent, never 0: no screens entry without screen capture, no
    /// decisions or action items without a summary, no rating without a review.
    public var values: [MeetingMetric: Double]
    /// False for a record without the times of its words, such as a synced copy on the iPhone: a pause inside a
    /// line is then speech, and an overlap is counted where the Mac counts none.
    public var hasWordTimes = true

    public var size: Size { Size(voices: mainVoices) }
    public func person(_ name: String) -> Person? { people.first { $0.name == name } }
    /// The same person in this meeting: by the id when both have one, else by the name.
    public func person(_ p: Person) -> Person? { people.first { $0.isSame(as: p) } }
    public var owner: Person? { people.first(where: \.isOwner) }
    /// The other person of a meeting of two main voices, both named.
    public var partner: Person? {
        let main = people.filter(\.isMain)
        return mainVoices == 2 && main.count == 2 && main.contains(where: \.isOwner) ? main.first { !$0.isOwner } : nil
    }

    /// A voice counts for the setting with at least this much speech and this part of the talk.
    static let mainSeconds: TimeInterval = 10
    static let mainShare = 0.02
    static func isMain(seconds: TimeInterval, share: Double) -> Bool { seconds >= mainSeconds && share >= mainShare }

    /// Counts are measured against at least this much of an hour, so three questions in a five-minute call are
    /// not "36 an hour".
    static let minimumHours = 0.25

    public init(record r: CallRecord, owner: String) {
        self.init(record: r, owner: owner, voices: MeetingAnalytics.Voices(record: r, owner: owner))
    }

    init(id: String, stamp: Int, start: Date, title: String, series: String?, kind: String?, tags: [String], voices: Int, mainVoices: Int? = nil,
         people: [Person], values: [MeetingMetric: Double]) {
        self.id = id
        self.stamp = stamp
        self.start = start
        self.title = title
        self.series = series
        self.kind = kind
        self.tags = tags
        self.voices = voices
        self.mainVoices = mainVoices ?? voices
        self.people = people
        self.values = values
    }

    static let minimumTurns = 6

    init(record r: CallRecord, owner: String, voices v: MeetingAnalytics.Voices) {
        id = r.id
        stamp = MeetingAnalytics.stamp(r)
        start = r.start
        title = r.title
        series = r.titleSource == .calendar || r.titleSource == .custom ? PeopleDuplicates.normalized(r.title) : nil
        kind = r.kind
        tags = r.tags
        hasWordTimes = r.utterances.contains { $0.words?.isEmpty == false }
        voices = v.speakers.count
        mainVoices = v.speakers.filter { Self.isMain(seconds: $0.seconds, share: $0.share) }.count
        let hours = max(v.duration / 3600, Self.minimumHours)
        people = v.speakers.filter { !$0.isUnknown && $0.seconds > 0 }.map { s in
            var values: [PersonMetric: Double] = [.talkShare: s.share, .questionsPerHour: Double(s.questions) / hours]
            // A typical turn from a few turns is noise, here and in the history.
            if s.turns >= Self.minimumTurns { values[.averageTurn] = s.averageTurn }
            values[.wordsPerMinute] = s.wordsPerMinute
            values[.fillersPerMinute] = s.fillersPerMinute
            values[.longestTurn] = s.longestTurn?.seconds
            values[.responseGap] = s.medianResponse
            // Nil in a call that cannot show who talked over whom.
            values[.cutInsPerHour] = s.interruptionsMade.map { Double($0) / hours }
            values[.cutOffsPerHour] = s.interruptionsReceived.map { Double($0) / hours }
            return Person(name: s.name, personID: r.speakerPeople?[s.id], isOwner: s.isOwner, isMain: Self.isMain(seconds: s.seconds, share: s.share), values: values)
        }
        // A joined meeting's end minus its start holds the time between its recordings; its audio does not.
        var values: [MeetingMetric: Double] = [
            .length: r.parts.isEmpty ? max(0, r.end.timeIntervalSince(r.start)) : v.duration, .voices: Double(v.speakers.count),
        ]
        if r.summary != nil {
            values[.decisions] = Double(r.decisions.count)
            values[.actionItems] = Double(r.actionItems.count)
        }
        if let screens = r.screens { values[.screens] = Double(screens.count) }
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
    /// Held for a whole pass: a second caller waits and then finds the first one's work, so two meetings opened
    /// at launch do not both read every meeting.
    private let working = NSLock()
    private var entries: [String: MeetingFacts] = [:]
    private var owner = ""
    private var reads = 0
    /// How many records were read for their facts so far, for tests.
    var readCount: Int { lock.withLock { reads } }

    public init() {}

    /// The facts of the written meetings with speech among `records`. Call it off the main thread: the first
    /// call reads every meeting.
    public func facts(for records: [CallRecord], owner: String) -> [MeetingFacts] {
        working.lock()
        defer { working.unlock() }
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

extension MeetingFacts.Person {
    /// One person in two meetings: the same id when both have one, else the same name. A record from before ids
    /// counts by the name.
    public func isSame(as other: MeetingFacts.Person) -> Bool {
        if let a = personID, let b = other.personID { return a == b }
        return name == other.name
    }
}
