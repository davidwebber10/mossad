import Foundation

/// Everything the meeting page's Analytics tab shows for one call: who talked and when, how the turns went, how
/// each person spoke, who was invited, what came out of it, what it cost, and how it compares with the owner's
/// other meetings. Pure, so it is tested without the app; the app builds it off the main thread, once per change
/// of the record. A part with nothing to show is nil or empty, so the tab leaves it out.
public struct MeetingAnalytics: Sendable, Equatable {
    /// A stretch of the call that can be played: where it starts, and how long it is.
    public struct Moment: Sendable, Equatable {
        public var start: TimeInterval
        public var seconds: TimeInterval

        public init(start: TimeInterval, seconds: TimeInterval) {
            self.start = start
            self.seconds = seconds
        }
    }

    /// One person who spoke. The order and the `id` are the lanes player's, so a person has one color on the page.
    public struct Speaker: Sendable, Equatable, Identifiable {
        /// The key of the person's lane.
        public var id: String
        public var name: String
        public var isOwner: Bool
        /// A voice with no name yet ("Speaker B").
        public var isUnknown: Bool
        public var seconds: TimeInterval
        /// Their part of all speech, 0 to 1.
        public var share: Double
        public var turns = 0
        public var averageTurn: TimeInterval = 0
        public var longestTurn: Moment?
        public var words = 0
        /// Nil when they spoke too little to measure a pace.
        public var wordsPerMinute: Double?
        public var fillers = 0
        public var fillersPerMinute: Double?
        public var questions = 0
        /// Where their first question is.
        public var firstQuestion: TimeInterval?
        /// The median pause before they answered someone; nil when they never did.
        public var medianResponse: TimeInterval?
        public var interruptionsMade = 0
        public var interruptionsReceived = 0
    }

    /// Who held the floor in one stretch of the call, for the strip under the talk time.
    public struct FloorBlock: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        /// The speaker's `id`.
        public var speaker: String
    }

    public struct Participation: Sendable, Equatable {
        public struct Attendee: Sendable, Equatable, Identifiable {
            public var id: String { label }
            /// As the invite wrote them, or the saved person's name for an email Mossad knows.
            public var label: String
            public var email: String?
            /// The saved person, when the name or the email stands for one.
            public var person: String?
            /// The `id` of the speaker they are, when they spoke.
            public var speaker: String?
        }

        public var invited: [Attendee]
        /// The `id`s of the people who spoke with no invite. Unnamed voices are not here.
        public var uninvited: [String]
        /// Voices with no name. While there are some, an invited person with no voice is not known to be silent.
        public var unnamedVoices: Int

        public var spoke: [Attendee] { invited.filter { $0.speaker != nil } }
        public var unheard: [Attendee] { invited.filter { $0.speaker == nil } }
    }

    public struct Outcomes: Sendable, Equatable {
        public struct Owner: Sendable, Equatable, Identifiable {
            public var id: String { name ?? "" }
            /// Nil for items with no owner.
            public var name: String?
            /// The `id` of the speaker who owns them, when the owner spoke.
            public var speaker: String?
            public var tasks: [String]
        }

        public struct TaskRef: Sendable, Equatable, Identifiable {
            public var id: UUID
            public var text: String
            public var done: Bool
        }

        public var decisions: Int
        public var actionItems: Int
        /// Most items first; the items with no owner last.
        public var owners: [Owner]
        /// The owner's own tasks (the Tasks page) that came from this call.
        public var tasks: [TaskRef]
    }

    public struct Coach: Sendable, Equatable {
        public var value: MeetingValue?
        public var scorecard: Scorecard?
    }

    public struct Screens: Sendable, Equatable {
        public struct Presenter: Sendable, Equatable, Identifiable {
            public var id: String { name ?? "" }
            /// Nil when the call app showed no name.
            public var name: String?
            public var sessions: Int
            public var screens: Int
            /// From the first kept frame to the last of each session. A slide that never changed counts nothing.
            public var seconds: TimeInterval
            /// Where their first screen is.
            public var first: TimeInterval
        }

        public var presenters: [Presenter]
        public var screens: Int { presenters.reduce(0) { $0 + $1.screens } }
        public var seconds: TimeInterval { presenters.reduce(0) { $0 + $1.seconds } }
    }

    public struct Cost: Sendable, Equatable {
        public struct Line: Sendable, Equatable, Identifiable {
            public var id: UsageEvent.Purpose { purpose }
            public var purpose: UsageEvent.Purpose
            public var dollars: Double
        }

        public var total: Double
        /// Batch and live transcription.
        public var transcription: Double
        /// The summary, the coach, and questions about the call.
        public var ai: Double
        public var lines: [Line]
        /// True when nothing was logged for the call and the numbers come from its length and transcript.
        public var estimated: Bool
    }

    /// The length of the recording, or the end of the last line when that is later.
    public let duration: TimeInterval
    public let speechSeconds: TimeInterval
    /// The owner first, then the most talk.
    public let speakers: [Speaker]
    /// Nil when the owner did not speak.
    public let ownerShare: Double?
    public let floor: [FloorBlock]
    public let flow: Flow?
    public let participation: Participation?
    public let outcomes: Outcomes?
    public let coach: Coach?
    public let screens: Screens?
    public let cost: Cost?
    /// This call as one row of the history that later calls are compared with.
    public let facts: MeetingFacts
    /// This call against the owner's earlier meetings.
    public let baselines: Baselines

    public var owner: Speaker? { speakers.first(where: \.isOwner) }
    public func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }
    public var isEmpty: Bool {
        speakers.isEmpty && participation == nil && outcomes == nil && coach == nil && screens == nil && cost == nil
    }

    /// Below this much speech a pace is noise.
    static let minimumPaceSeconds: TimeInterval = 20

    /// `history` is the owner's other meetings as facts (`MeetingFactsCache`); only the ones that started before
    /// this call count. `value` gives the coach's rating of one of them, read only for the few that are asked.
    /// `people` is the saved people, for the invited names; `commitments` the owner's tasks.
    public init(record r: CallRecord, owner: String, review: CoachReview? = nil, usage: [UsageEvent] = [], history: [MeetingFacts] = [],
                value: (String) -> MeetingValue.Rating? = { _ in nil }, people: PersonDirectory = PersonDirectory(),
                commitments: [Commitment] = []) {
        let voices = Voices(record: r, owner: owner)
        duration = voices.duration
        speechSeconds = voices.speechSeconds
        speakers = voices.speakers
        flow = voices.flow
        ownerShare = speakers.first(where: \.isOwner).flatMap { $0.seconds > 0 ? $0.share : nil }
        floor = Self.floor(voices.lanes, duration: duration)

        participation = Self.participation(r, speakers: speakers, people: people)
        outcomes = Self.outcomes(r, speakers: speakers, commitments: commitments)
        coach = review.flatMap { $0.value == nil && $0.scorecard == nil ? nil : Coach(value: $0.value, scorecard: $0.scorecard) }
        screens = Self.screens(r)
        cost = Self.cost(r, usage: usage)
        var facts = MeetingFacts(record: r, owner: owner, voices: voices)
        facts.values[.value] = review?.value.map { Double($0.rating.level) }
        self.facts = facts
        baselines = Baselines(facts, speakers: speakers, flow: flow, record: r, history: history, value: value)
    }
}

// MARK: Who spoke

extension MeetingAnalytics {
    /// The speakers of one call with their numbers, and the flow between them: the part that both the tab and
    /// the history of earlier meetings need.
    struct Voices {
        let lanes: [SpeakerLanes.Lane]
        let duration: TimeInterval
        let speechSeconds: TimeInterval
        let speakers: [Speaker]
        let flow: Flow?

        init(record r: CallRecord, owner: String) {
            let names = MarkdownWriter.displayNames(r)
            let lanes = SpeakerLanes.make(r, names: names, ownerName: owner)
            self.lanes = lanes
            let recorded = r.parts.last.map { $0.offset + max(0, $0.end.timeIntervalSince($0.start)) } ?? max(0, r.end.timeIntervalSince(r.start))
            duration = max(recorded, r.utterances.map(\.end).max() ?? 0)

            // A named person has one lane for every key with their name; each unnamed voice has its own.
            var laneOfName: [String: Int] = [:], laneOfKey: [String: Int] = [:]
            for (i, lane) in lanes.enumerated() {
                if r.speakerNames[lane.key] != nil { laneOfName[lane.name] = i } else { laneOfKey[lane.key] = i }
            }
            func lane(_ key: String) -> Int? { r.speakerNames[key].flatMap { laneOfName[$0] } ?? laneOfKey[key] }
            let speech = lanes.reduce(0) { $0 + $1.seconds }
            speechSeconds = speech
            var speakers = lanes.map { lane in
                Speaker(id: lane.key, name: lane.name, isOwner: lane.name == owner && r.speakerNames[lane.key] != nil,
                        isUnknown: r.speakerNames[lane.key] == nil, seconds: lane.seconds, share: speech > 0 ? lane.seconds / speech : 0)
            }
            let lines = r.utterances.compactMap { u in lane(u.speakerKey).map { Flow.Line(speaker: $0, utterance: u) } }
                .sorted { $0.start < $1.start }
            MeetingAnalytics.delivery(lines, into: &speakers)
            let turns = Flow.turns(lines)
            MeetingAnalytics.turnNumbers(turns, into: &speakers)
            flow = lines.isEmpty ? nil : MeetingAnalytics.flow(lines, turns: turns, speakers: &speakers)
            self.speakers = speakers
        }
    }
}

// MARK: Delivery and turns

extension MeetingAnalytics {
    /// Words, pace, fillers, and questions per person, by the coach's rules (`DeliveryStats`), so the owner's
    /// numbers here are the ones the coach saw.
    static func delivery(_ lines: [Flow.Line], into speakers: inout [Speaker]) {
        for line in lines {
            let tokens = DeliveryStats.tokens(line.text)
            speakers[line.speaker].words += tokens.count
            speakers[line.speaker].fillers += tokens.filter(DeliveryStats.isFiller).count
            if line.text.contains("?") {
                speakers[line.speaker].questions += 1
                if speakers[line.speaker].firstQuestion == nil { speakers[line.speaker].firstQuestion = line.start }
            }
        }
        for i in speakers.indices where speakers[i].seconds >= minimumPaceSeconds {
            let minutes = speakers[i].seconds / 60
            speakers[i].wordsPerMinute = Double(speakers[i].words) / minutes
            speakers[i].fillersPerMinute = Double(speakers[i].fillers) / minutes
        }
    }

    static func turnNumbers(_ turns: [Flow.Turn], into speakers: inout [Speaker]) {
        for i in speakers.indices {
            let mine = turns.filter { $0.speaker == i }
            guard !mine.isEmpty else { continue }
            speakers[i].turns = mine.count
            speakers[i].averageTurn = mine.reduce(0) { $0 + $1.seconds } / Double(mine.count)
            // The first of equal turns, as `CallMetrics` picks it.
            speakers[i].longestTurn = mine.max { $0.seconds < $1.seconds }.map { Moment(start: $0.start, seconds: $0.seconds) }
        }
    }

    static let floorBuckets = 120
    /// A bucket belongs to nobody when less than this part of it is speech.
    static let floorMinimumShare = 0.15

    /// The call in `floorBuckets` equal stretches, each given to the person who talked most in it; neighbors of
    /// one person join. Quiet stretches are left out.
    static func floor(_ lanes: [SpeakerLanes.Lane], duration: TimeInterval) -> [FloorBlock] {
        guard duration > 0, !lanes.isEmpty else { return [] }
        let step = duration / Double(floorBuckets)
        var talk = [[TimeInterval]](repeating: [TimeInterval](repeating: 0, count: lanes.count), count: floorBuckets)
        for (i, lane) in lanes.enumerated() {
            for s in lane.segments {
                let first = min(floorBuckets - 1, max(0, Int(s.lowerBound / step)))
                let last = min(floorBuckets - 1, max(0, Int(s.upperBound / step)))
                guard first <= last else { continue }
                for b in first...last {
                    talk[b][i] += max(0, min(s.upperBound, Double(b + 1) * step) - max(s.lowerBound, Double(b) * step))
                }
            }
        }
        var blocks: [FloorBlock] = []
        for b in 0..<floorBuckets {
            // The first lane wins a tie, so the result does not depend on dictionary order.
            guard let top = talk[b].indices.max(by: { talk[b][$0] < talk[b][$1] || (talk[b][$0] == talk[b][$1] && $0 > $1) }),
                  talk[b][top] >= step * floorMinimumShare else { continue }
            let start = Double(b) * step, end = Double(b + 1) * step
            if let last = blocks.last, last.speaker == lanes[top].key, abs(last.end - start) < step / 2 {
                blocks[blocks.count - 1].end = end
            } else {
                blocks.append(FloorBlock(start: start, end: end, speaker: lanes[top].key))
            }
        }
        return blocks
    }
}

// MARK: The stamp

extension MeetingAnalytics {
    /// Changes when anything the analytics read from the record changes. Cheap enough for a view to compare on
    /// each draw: it reads counts and the small lists, never the words.
    public static func stamp(_ r: CallRecord) -> Int {
        var h = Hasher()
        h.combine(r.id)
        h.combine(r.status)
        h.combine(r.start)
        h.combine(r.end)
        h.combine(r.title)
        h.combine(r.utterances.count)
        h.combine(r.utterances.last?.end)
        h.combine(r.speakerNames)
        h.combine(r.attendees)
        h.combine(r.actionItems)
        h.combine(r.decisions.count)
        h.combine(r.parts.count)
        h.combine(r.kind)
        h.combine(r.tags)
        h.combine(r.plannedStart)
        h.combine(r.plannedEnd)
        for s in r.screens ?? [] {
            h.combine(s.file)
            h.combine(s.presenter)
        }
        return h.finalize()
    }
}
