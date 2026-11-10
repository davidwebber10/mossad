import Foundation

/// The sentence that opens each group of a meeting's Analytics tab, as `AnalyticsFindings` does for a period.
/// A sentence about one person keeps the person apart from the words, so the page can link the name.
public enum MeetingFindings {
    public struct Sentence: Sendable, Equatable {
        /// The `id` of the speaker the sentence is about, or a presenter's name; nil for a sentence about the call.
        public var subject: String?
        /// The whole sentence without a subject; with one, what follows the name.
        public var text: String

        public init(subject: String? = nil, _ text: String) {
            self.subject = subject
            self.text = text
        }
    }

    /// "48 s", "3 min 12 s", "1 h 4 min".
    public static func span(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return AnalyticsFindings.duration(seconds)
    }

    /// "0.8 s", "12 s": a pause before an answer.
    public static func pause(_ seconds: TimeInterval) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : span(seconds)
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    public static func talk(_ a: MeetingAnalytics) -> Sentence? {
        guard let top = a.speakers.max(by: { ($0.seconds, $1.name) < ($1.seconds, $0.name) }), top.seconds > 0 else { return nil }
        if a.speakers.filter({ $0.seconds > 0 }).count == 1 { return Sentence(subject: top.id, "was the only voice, for \(span(top.seconds))") }
        return Sentence(subject: top.id, "talked most: \(span(top.seconds)), \(percent(top.share)) of the talk")
    }

    public static func flow(_ a: MeetingAnalytics) -> Sentence? {
        guard let flow = a.flow else { return nil }
        let cuts = flow.interruptionCount
        let tail = cuts == 0 ? "nobody cut in" : cuts == 1 ? "one person cut in once" : "people cut in \(cuts) times"
        guard let holder = a.speakers.max(by: { ($0.longestTurn?.seconds ?? 0) < ($1.longestTurn?.seconds ?? 0) }),
              let longest = holder.longestTurn, longest.seconds > 0 else { return Sentence(tail.prefix(1).uppercased() + tail.dropFirst()) }
        return Sentence(subject: holder.id, "held the longest turn, \(span(longest.seconds)); \(tail)")
    }

    public static func delivery(_ a: MeetingAnalytics) -> Sentence? {
        let paced = a.speakers.filter { $0.wordsPerMinute != nil }
        guard let fastest = paced.max(by: { $0.wordsPerMinute! < $1.wordsPerMinute! }) else { return nil }
        let pace = "\(Int(fastest.wordsPerMinute!.rounded())) words a minute"
        return Sentence(subject: fastest.id, paced.count == 1 ? "spoke at \(pace)" : "spoke fastest, at \(pace)")
    }

    public static func participation(_ p: MeetingAnalytics.Participation) -> String {
        let invited = p.invited.count, spoke = p.spoke.count
        let people = invited == 1 ? "person" : "people"
        if p.unnamedVoices > 0, spoke < invited {
            return "\(spoke) of \(invited) invited \(people) spoke by name; \(count(p.unnamedVoices, "voice has", "voices have")) no name yet"
        }
        if spoke == invited { return invited == 1 ? "The one invited person spoke" : "All \(invited) invited people spoke" }
        if spoke == 0 { return invited == 1 ? "The one invited person did not speak" : "None of the \(invited) invited people spoke" }
        return "\(spoke) of \(invited) invited \(people) spoke"
    }

    public static func outcomes(_ o: MeetingAnalytics.Outcomes) -> String {
        let decisions = count(o.decisions, "decision", "decisions"), items = count(o.actionItems, "action item", "action items")
        switch (o.decisions > 0, o.actionItems > 0) {
        case (true, true): return "\(decisions) and \(items)"
        case (true, false): return "\(decisions), no action items"
        case (false, true): return "\(items), no decisions"
        case (false, false): return "No decisions or action items"
        }
    }

    public static func coach(_ c: MeetingAnalytics.Coach) -> String? {
        let value = c.value.map { "rated the meeting \($0.rating.rawValue) value" }
        let score = c.scorecard.map { "scored the call \($0.score) of 5" }
        let parts = [score, value].compactMap { $0 }
        return parts.isEmpty ? nil : "The coach " + parts.joined(separator: " and ")
    }

    public static func screens(_ s: MeetingAnalytics.Screens) -> Sentence {
        let amount = count(s.screens, "screen", "screens")
        let time = s.seconds >= 60 ? " over \(span(s.seconds))" : ""
        let named = s.presenters.filter { $0.name != nil }
        if named.count == 1, s.presenters.count == 1, let name = named[0].name { return Sentence(subject: name, "shared \(amount)\(time)") }
        if named.count > 1 { return Sentence("\(named.count) people shared \(amount)\(time)") }
        return Sentence(s.screens == 1 ? "1 screen was shared" : "\(amount) were shared\(time)")
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    // MARK: Against the usual

    private static func whole(_ v: Double) -> String { "\(Int(v.rounded()))" }
    private static func tenth(_ v: Double) -> String { String(format: "%.1f", v) }

    /// "30 to 40%", or "35%" when both ends read the same.
    private static func span(_ low: String, _ high: String, unit: String = "") -> String {
        low == high ? "\(low)\(unit)" : "\(low) to \(high)\(unit)"
    }

    /// Two lengths of time: "15 to 25 s", "1 min to 2 min 10 s".
    private static func spans(_ low: TimeInterval, _ high: TimeInterval) -> String {
        if high.rounded() < 60 { return span(whole(low), whole(high), unit: " s") }
        return span(span(low), span(high))
    }

    /// Two lengths of a meeting, to the minute: "25 to 35 min", "50 min to 1 h 10 min".
    private static func lengths(_ low: TimeInterval, _ high: TimeInterval) -> String {
        if high < 3600 { return span(whole(low / 60), whole(high / 60), unit: " min") }
        return span(AnalyticsFindings.duration(low), AnalyticsFindings.duration(high))
    }

    /// One person's number as the tab's tables show it: "60%", "182", "4.2", "48 s".
    public static func value(_ metric: PersonMetric, _ v: Double) -> String {
        switch metric {
        case .talkShare: percent(v)
        case .wordsPerMinute, .questionsPerHour, .cutInsPerHour, .cutOffsPerHour: whole(v)
        case .fillersPerMinute: tenth(v)
        case .averageTurn, .longestTurn: span(v)
        case .responseGap: pause(v)
        }
    }

    /// The usual range of one person's number: "30 to 40%".
    public static func range(_ metric: PersonMetric, _ u: MeetingAnalytics.Usual) -> String {
        switch metric {
        case .talkShare: span(whole(u.low * 100), whole(u.high * 100), unit: "%")
        case .wordsPerMinute, .questionsPerHour, .cutInsPerHour, .cutOffsPerHour: span(whole(u.low), whole(u.high))
        case .fillersPerMinute: span(tenth(u.low), tenth(u.high))
        case .averageTurn, .longestTurn: spans(u.low, u.high)
        case .responseGap: span(tenth(u.low), tenth(u.high), unit: " s")
        }
    }

    public static func range(_ metric: MeetingMetric, _ u: MeetingAnalytics.Usual) -> String {
        switch metric {
        case .length: lengths(u.low, u.high)
        case .voices, .decisions, .actionItems, .screens, .wordsPerMinute: span(whole(u.low), whole(u.high))
        case .silenceShare: span(whole(u.low * 100), whole(u.high * 100), unit: "%")
        case .value: span(rating(u.low), rating(u.high))
        }
    }

    private static func rating(_ level: Double) -> String { MeetingValue.Rating(level: level)?.rawValue ?? whole(level) }

    /// What a person did, to follow their name or "You": "talked 60% of the time".
    public static func did(_ metric: PersonMetric, _ v: Double, you: Bool) -> String {
        let n = Int(v.rounded())
        switch metric {
        case .talkShare: return "talked \(percent(v)) of the time"
        case .wordsPerMinute: return "spoke at \(n) words a minute"
        case .fillersPerMinute: return "used \(tenth(v)) filler words a minute"
        case .questionsPerHour: return n == 0 ? "asked no questions" : "asked \(count(n, "question", "questions")) an hour"
        case .averageTurn: return "took turns of \(span(v)) on average"
        case .longestTurn: return "held one turn for \(span(v))"
        case .cutInsPerHour: return n == 0 ? "did not cut in" : "cut in \(count(n, "time", "times")) an hour"
        case .cutOffsPerHour: return n == 0 ? "\(you ? "were" : "was") not cut off" : "\(you ? "were" : "was") cut off \(count(n, "time", "times")) an hour"
        case .responseGap: return "took \(pause(v)) to answer"
        }
    }

    /// "usually 30 to 40% in 1:1s with you": the range and where it comes from. Counts say that they are per hour.
    public static func usually(_ metric: PersonMetric, _ u: MeetingAnalytics.Usual, context: MeetingAnalytics.Context) -> String {
        let perHour: Set<PersonMetric> = [.questionsPerHour, .cutInsPerHour, .cutOffsPerHour]
        return "usually \(range(metric, u))\(perHour.contains(metric) ? " an hour" : "") \(context.label)"
    }

    /// The sentence over the meeting's own numbers: "Compared with 8 earlier meetings in Weekly sync".
    public static func compared(_ context: MeetingAnalytics.Context) -> String {
        let n = context.meetings
        switch context.kind {
        case .recent:
            return "Compared with your last \(n) meetings"
        // "in meetings of 3 to 4 people" already says "meetings"; "in your 1:1s with Sam" says whose.
        case .setting where context.label.hasPrefix("in "):
            return "Compared with \(n) earlier \(context.label.dropFirst(3))"
        case .oneOnOne where context.label.hasPrefix("in your "):
            return "Compared with your \(n) earlier \(context.label.dropFirst(8))"
        default:
            return "Compared with \(count(n, "earlier meeting", "earlier meetings")) \(context.label)"
        }
    }

    public static func usually(_ metric: MeetingMetric, _ u: MeetingAnalytics.Usual, context: MeetingAnalytics.Context) -> String {
        "usually \(range(metric, u)) \(context.label)"
    }

    /// What follows the person's name in "What stood out": "talked 60% of the time; usually 30 to 40% in 1:1s with you".
    static func sentence(_ metric: PersonMetric, _ r: MeetingAnalytics.Reading, you: Bool, context: MeetingAnalytics.Context) -> String {
        guard let usual = r.usual else { return did(metric, r.value, you: you) }
        return "\(did(metric, r.value, you: you)); \(usually(metric, usual, context: context))"
    }

    /// A whole sentence about the meeting: "The meeting ran 52 min; usually 25 to 35 min in Weekly sync".
    static func sentence(_ metric: MeetingMetric, _ r: MeetingAnalytics.Reading, context: MeetingAnalytics.Context) -> String {
        let n = Int(r.value.rounded())
        let what = switch metric {
        case .length: "The meeting ran \(AnalyticsFindings.duration(r.value))"
        case .voices: "\(count(n, "person", "people")) spoke"
        case .decisions: n == 0 ? "No decisions" : count(n, "decision", "decisions")
        case .actionItems: n == 0 ? "No action items" : count(n, "action item", "action items")
        case .screens: n == 0 ? "No screens were shared" : n == 1 ? "1 screen was shared" : "\(n) screens were shared"
        case .silenceShare: "\(percent(r.value)) of the call was silence"
        case .wordsPerMinute: "People spoke at \(n) words a minute"
        case .value: "The coach rated it \(rating(r.value))"
        }
        guard let usual = r.usual else { return what }
        return "\(what); \(usually(metric, usual, context: context))"
    }
}
