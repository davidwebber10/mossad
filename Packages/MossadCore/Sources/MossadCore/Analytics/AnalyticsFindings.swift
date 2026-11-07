import Foundation

/// The sentence that opens each Analytics section: the finding first, the chart under it as the evidence. Nil
/// when the period has nothing to say for that section.
public enum AnalyticsFindings {
    /// "14 h 11 min", "3 h", "45 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// A share in words, as people say it: "a third of", "most of", or a percent when no word fits.
    public static func shareWords(_ share: Double) -> String {
        switch share {
        case 0.95...: "almost all of"
        case 0.7...: "most of"
        case 0.63...: "two thirds of"
        case 0.55...: "over half of"
        case 0.45...: "half of"
        case 0.36...: "over a third of"
        case 0.3...: "a third of"
        case 0.23...: "a quarter of"
        case 0.18...: "a fifth of"
        default: "\(percent(share)) of"
        }
    }

    public static func time(_ r: AnalyticsReport) -> String {
        let days = (r.interval.duration / 86_400).rounded()
        if days >= 14 {
            return "\(duration(r.callSeconds)) in calls, about \(duration(r.callSeconds / (days / 7))) a week"
        }
        return "\(duration(r.callSeconds)) in \(r.calls) \(r.calls == 1 ? "call" : "calls")"
    }

    /// From the share of call time matched to a calendar invite.
    public static func scheduled(_ r: AnalyticsReport) -> String? {
        guard r.callSeconds > 0 else { return nil }
        let share = r.scheduled.seconds / r.callSeconds
        return switch share {
        case 0.9...: "Almost all of it is on the calendar"
        case 0.6...: "Most of it is on the calendar"
        case 0.5...: share == 0.5 ? "Half of it is on the calendar" : "Over half is on the calendar"
        case 0.4...: "Over half is not on the calendar"
        case 0.1...: "Most of it is not on the calendar"
        default: "Almost none of it is on the calendar"
        }
    }

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// The two fullest weekday hours. Ties go to the earlier one in a Monday-first week.
    public static func busiestHours(_ heat: [AnalyticsReport.HeatCell]) -> String? {
        let order = { (c: AnalyticsReport.HeatCell) in ((c.weekday + 5) % 7) * 100 + c.hour }
        let top = heat.filter { $0.seconds >= 60 }
            .sorted { ($0.seconds, -order($0)) > ($1.seconds, -order($1)) }
            .prefix(2)
            .sorted { order($0) < order($1) }
        guard let first = top.first else { return nil }
        func hour(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12)" }
        func at(_ c: AnalyticsReport.HeatCell) -> String { "\(weekdays[c.weekday - 1]) at \(hour(c.hour))" }
        guard top.count == 2 else { return "\(at(first)) is your busiest hour" }
        let second = top[1]
        let pair = second.weekday == first.weekday ? "\(at(first)) and \(hour(second.hour))" : "\(at(first)) and \(at(second))"
        return "\(pair) are your busiest hours"
    }

    public static func workdays(_ w: AnalyticsReport.Workday) -> String? {
        guard w.workdays > 0 else { return nil }
        if Double(w.callFreeDays) / Double(w.workdays) > 0.5 { return "Most work days have no calls" }
        if w.callFreeDays == 0 { return "Every work day had a call" }
        return "You had calls on \(w.workdays - w.callFreeDays) of \(w.workdays) work days"
    }

    /// The top two tags, with a call tagged with both counted once.
    public static func topics(_ r: AnalyticsReport) -> String? {
        let top = Array(r.tags.prefix(2))
        guard !top.isEmpty, r.callSeconds > 0 else { return nil }
        let names = Set(top.map { $0.name.lowercased() })
        let seconds = r.records.filter { !names.isDisjoint(with: $0.tags.map { $0.lowercased() }) }
            .reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
        let subject = top.map(\.name).joined(separator: " and ")
        return "\(subject) took \(shareWords(seconds / r.callSeconds)) your call time"
    }

    /// From the coach's rating of each meeting's worth.
    public static func value(_ r: AnalyticsReport) -> String? {
        guard r.valueSeconds.values.reduce(0, +) > 0 else { return nil }
        let low = r.valueSeconds[.low] ?? 0
        return low > 0 ? "\(duration(low)) went to meetings the coach rated low" : "The coach rated none of your meetings low"
    }

    public static func people(_ r: AnalyticsReport) -> String? {
        guard let first = r.people.first, r.callSeconds > 0 else { return nil }
        return "\(first.name) is \(percent(first.seconds / r.callSeconds)) of your call time"
    }

    /// Talk share against the period before (groups when both periods have group calls), then who cuts in more.
    public static func communication(_ c: AnalyticsReport.Communication, talkShare: Double?,
                                     before: AnalyticsReport.Communication?, beforeDays: Int) -> String? {
        var clauses: [String] = []
        if let now = c.groupShare, let then = before?.groupShare, abs(now - then) >= 0.03 {
            clauses.append("you talk \(now < then ? "less" : "more") in groups than in the \(beforeDays) days before")
        } else if let talkShare {
            clauses.append("you talk \(percent(talkShare)) of the time")
        }
        if let made = c.interruptionsMadePerHour, let received = c.interruptionsReceivedPerHour, made + received > 0 {
            if made > received * 1.2, made - received >= 0.5 {
                clauses.append("you cut in more than others do")
            } else if received > made * 1.2, received - made >= 0.5 {
                clauses.append("others cut in more than you do")
            } else {
                clauses.append("you cut in about as often as others do")
            }
        }
        guard let first = clauses.first else { return nil }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + clauses.dropFirst()).joined(separator: "; ")
    }

    public static func outcomes(_ o: AnalyticsReport.Outcomes) -> String? {
        guard let share = o.withOutcomesShare else { return nil }
        let calls = switch share {
        case 0.9...: "Almost every call produced an item or a decision"
        case 0.6...: "Most calls produced an item or a decision"
        default: "\(percent(share)) of calls produced an item or a decision"
        }
        guard o.commitmentsMade > 0 else { return calls }
        let kept = switch (o.commitmentsMade, o.commitmentsDone) {
        case (1, 1): "your one commitment is done"
        case (1, _): "your one commitment is still open"
        case let (made, done) where made == done: "all \(made) of your commitments are done"
        case let (made, done): "\(done) of your \(made) commitments are done"
        }
        return "\(calls); \(kept)"
    }

    private static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}
