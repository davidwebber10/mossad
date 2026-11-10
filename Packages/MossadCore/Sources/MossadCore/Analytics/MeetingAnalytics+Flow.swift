import Foundation

extension MeetingAnalytics {
    /// How the conversation moved: turns, people talking at once, who cut in on whom, pauses before answers, and
    /// silence. The rules are strict on purpose: a count here is a moment worth playing, not a guess.
    ///
    /// Two people talking at once can only be seen between the two tracks: the owner's microphone and the call.
    /// Inside one track the transcriber writes one line after the other, so two people of the call who talk at
    /// once leave no trace. Overlaps and cut-ins are therefore counted between the tracks only, and a call with
    /// speech on one track (a meeting in a room) has none that can be counted: `crossTalkMeasured` is false, and
    /// the counts are nil, never 0.
    public struct Flow: Sendable, Equatable {
        /// `by` began to talk while `of` was talking, and took the floor.
        public struct Interruption: Sendable, Equatable, Identifiable {
            public var id: String { "\(by)>\(of)" }
            public var by: String
            public var of: String
            /// When each one began, in call order.
            public var moments: [TimeInterval]
            public var count: Int { moments.count }
        }

        /// Two people talking at once, whoever began. `first` comes before `second` in the speakers' order.
        public struct Overlap: Sendable, Equatable, Identifiable {
            public var id: String { "\(first)|\(second)" }
            public var first: String
            public var second: String
            public var count: Int
            public var seconds: TimeInterval
        }

        public var turns: Int
        /// False when the call has speech of different people on one track only, so nothing below can be counted.
        public var crossTalkMeasured: Bool
        /// Between the microphone and the call only. The most times first.
        public var interruptions: [Interruption]
        /// Between the microphone and the call only. The most time first.
        public var overlaps: [Overlap]
        /// The median pause before one person answered another; nil when nobody did.
        public var medianResponse: TimeInterval?
        /// Pauses of `minimumSilence` or more with nobody talking, between the first word and the last.
        public var silenceSeconds: TimeInterval
        /// The silence as a part of the time from the first word to the last.
        public var silenceShare: Double
        public var longestSilence: Moment?

        public var interruptionCount: Int { interruptions.reduce(0) { $0 + $1.count } }
        public var overlapCount: Int { overlaps.reduce(0) { $0 + $1.count } }
        public var overlapSeconds: TimeInterval { overlaps.reduce(0) { $0 + $1.seconds } }

        /// Lines of one person closer than this are one turn, as the coach counts them.
        static let turnGap = CallMetrics.turnGap
        /// Two people must talk together this long before it counts: less is a hand-off.
        static let overlapGrace = DeliveryStats.overlapGrace
        /// The first person must have been talking this long, so two people who start together are an overlap,
        /// not an interruption.
        static let minimumLead: TimeInterval = 1
        /// "Yeah" and "right" while someone talks are listening.
        static let minimumCutInWords = Exchange.minimumCutInWords
        /// A longer pause is a new thought, not an answer.
        static let maxReplyGap = Exchange.maxReplyGap
        /// The one who cut in must go on this long after the other stopped. Less is an agreement said across a
        /// pause ("yeah, that makes sense"), not taking the floor.
        static let minimumHold: TimeInterval = 3
        /// A pause this long inside one line ends a run of speech, when the line has word times.
        static let runGap: TimeInterval = 1
        static let minimumSilence: TimeInterval = 3

        /// One line of the transcript, with its speaker as an index into the speakers.
        struct Line {
            var speaker: Int
            var track: Track
            var start: TimeInterval
            var end: TimeInterval
            var text: String
            var words: [Word]?

            init(speaker: Int, utterance u: Utterance) {
                self.speaker = speaker
                track = u.track
                start = u.start
                end = max(u.start, u.end)
                text = u.text
                words = u.words
            }
        }

        struct Turn: Equatable {
            var speaker: Int
            var start: TimeInterval
            var end: TimeInterval
            var seconds: TimeInterval { end - start }
        }

        /// A stretch of one person's speech with no pause of `runGap` in it.
        struct Run {
            var speaker: Int
            var track: Track
            var start: TimeInterval
            var end: TimeInterval
            var words: Int
        }

        /// Lines in start order. A turn is one person's lines with no line of anyone else between them and no
        /// pause of `turnGap`: the rule `CallMetrics` uses for the owner, for everyone.
        static func turns(_ lines: [Line]) -> [Turn] {
            var turns: [Turn] = []
            for l in lines {
                if let last = turns.last, last.speaker == l.speaker, l.start - last.end < turnGap {
                    turns[turns.count - 1].end = max(last.end, l.end)
                } else {
                    turns.append(Turn(speaker: l.speaker, start: l.start, end: l.end))
                }
            }
            return turns
        }

        /// With word times a line is cut at its pauses, so a pause inside a long line is not speech. A line
        /// without them is one run.
        static func runs(_ lines: [Line]) -> [Run] {
            var out: [Run] = []
            for l in lines {
                guard let words = l.words, !words.isEmpty else {
                    out.append(Run(speaker: l.speaker, track: l.track, start: l.start, end: l.end, words: DeliveryStats.tokens(l.text).count))
                    continue
                }
                var current: Run?
                for w in words {
                    if let c = current, w.start - c.end < runGap {
                        current = Run(speaker: c.speaker, track: c.track, start: c.start, end: max(c.end, w.end), words: c.words + 1)
                    } else {
                        if let c = current { out.append(c) }
                        current = Run(speaker: l.speaker, track: l.track, start: w.start, end: max(w.start, w.end), words: 1)
                    }
                }
                if let current { out.append(current) }
            }
            return out.sorted { $0.start < $1.start }
        }
    }

    /// Builds the flow and adds each person's part of it (answers, cut-ins) to `speakers`.
    static func flow(_ lines: [Flow.Line], turns: [Flow.Turn], speakers: inout [Speaker]) -> Flow {
        let runs = Flow.runs(lines)

        // Overlaps and interruptions, in one pass over the runs in start order. `active` holds the runs that
        // are still going, so each later run meets only the few it can overlap. Only a pair on two tracks counts.
        let measured = runs.contains { a in runs.contains { $0.track != a.track && $0.speaker != a.speaker } }
        var active: [Flow.Run] = []
        var together: [[Int]: (count: Int, seconds: TimeInterval)] = [:]
        var cuts: [[Int]: [TimeInterval]] = [:]
        for r in runs {
            active.removeAll { $0.end <= r.start }
            for a in active where a.speaker != r.speaker && a.track != r.track {
                let shared = min(a.end, r.end) - r.start
                guard shared >= Flow.overlapGrace else { continue }
                let pair = [min(a.speaker, r.speaker), max(a.speaker, r.speaker)]
                together[pair, default: (0, 0)].count += 1
                together[pair]!.seconds += shared
                // The later one cut in when the first was well into their words, the later one said more than
                // a word or two, and held the floor after the first one stopped. One start is one cut-in, also
                // when the first person has two lines there.
                if r.start - a.start >= Flow.minimumLead, r.words >= Flow.minimumCutInWords, r.end - a.end >= Flow.minimumHold,
                   cuts[[r.speaker, a.speaker]]?.last != r.start {
                    cuts[[r.speaker, a.speaker], default: []].append(r.start)
                }
            }
            active.append(r)
        }
        if measured {
            for i in speakers.indices { speakers[i].interruptionsMade = 0; speakers[i].interruptionsReceived = 0 }
            for (pair, moments) in cuts {
                speakers[pair[0]].interruptionsMade! += moments.count
                speakers[pair[1]].interruptionsReceived! += moments.count
            }
        }

        // An answer: a turn that begins after everyone before it stopped, within `maxReplyGap` of the last word,
        // which was someone else's.
        var gaps: [Int: [TimeInterval]] = [:]
        var last: Flow.Turn?
        for t in turns {
            if let l = last, l.speaker != t.speaker {
                let gap = t.start - l.end
                if gap >= 0, gap <= Flow.maxReplyGap { gaps[t.speaker, default: []].append(gap) }
            }
            if last == nil || t.end >= last!.end { last = t }
        }
        for (i, g) in gaps { speakers[i].medianResponse = median(of: g) }

        // Silence between the first word and the last.
        var silence: TimeInterval = 0
        var longest: Moment?
        var spokenUntil = runs.first?.start ?? 0
        for r in runs {
            let gap = r.start - spokenUntil
            if gap >= Flow.minimumSilence {
                silence += gap
                if gap > (longest?.seconds ?? 0) { longest = Moment(start: spokenUntil, seconds: gap) }
            }
            spokenUntil = max(spokenUntil, r.end)
        }
        let span = spokenUntil - (runs.first?.start ?? 0)

        return Flow(
            turns: turns.count,
            crossTalkMeasured: measured,
            interruptions: cuts.map { Flow.Interruption(by: speakers[$0.key[0]].id, of: speakers[$0.key[1]].id, moments: $0.value.sorted()) }
                .sorted { ($0.count, -($0.moments.first ?? 0), $1.id) > ($1.count, -($1.moments.first ?? 0), $0.id) },
            overlaps: together.map { Flow.Overlap(first: speakers[$0.key[0]].id, second: speakers[$0.key[1]].id, count: $0.value.count, seconds: $0.value.seconds) }
                .sorted { ($0.seconds, $1.id) > ($1.seconds, $0.id) },
            medianResponse: median(of: gaps.values.flatMap { $0 }),
            silenceSeconds: silence, silenceShare: span > 0 ? silence / span : 0, longestSilence: longest)
    }
}
