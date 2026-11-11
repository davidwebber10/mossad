import Foundation

// MARK: The change

extension CommunicationTrends {
    /// A shorter period has no trend: its thirds would be different days of the week, not different times.
    static let minimumDays = 21

    /// Whether the number moved from the first third of the period to the last, by the rules of the meeting
    /// baselines (`MeetingAnalytics.Reading`), which a single meeting must pass to stand out; here two medians
    /// must pass them:
    ///
    /// - each third has `Usual.firmSamples` meetings, or nothing is said;
    /// - the medians differ by the least difference that matters for the number (`PersonMetric.margin`);
    /// - the difference is `Reading.minimumScore` times what chance gives two medians of such meetings, with the
    ///   baselines' spread (the larger of the scaled median deviation and the standard deviation, never under
    ///   half the margin) and their allowance for a short history.
    ///
    /// A talk share and cut-ins follow the size of the meeting. With both sizes in `rows` (`mixed`), the part
    /// of the difference that more 1:1s or more groups alone would give is taken off first; a difference that
    /// does not hold without it is `.mixed`.
    static func change(_ metric: PersonMetric, _ rows: [Row], interval: DateInterval, days: Int, mixed: Bool) -> Change {
        guard days >= minimumDays else { return .tooShort }
        let third = interval.duration / 3
        let early = rows.filter { $0.point.date < interval.start.addingTimeInterval(third) }
        let late = rows.filter { $0.point.date >= interval.end.addingTimeInterval(-third) }
        typealias Usual = MeetingAnalytics.Usual
        guard let first = Usual(early.map(\.point.value)), let last = Usual(late.map(\.point.value)), first.isFirm, last.isFirm else { return .tooFew }

        let difference = last.median - first.median
        let margin = metric.margin(first)
        let spread = max(((first.spread * first.spread + last.spread * last.spread) / 2).squareRoot(), margin / 2)
        // What chance gives the difference of two medians: a median of n values is 1.2533 times less sure than
        // their mean.
        let chance = spread * 1.2533 * (1 / Double(first.samples) + 1 / Double(last.samples)).squareRoot()
            * Usual.student(first.samples + last.samples - 2) / 1.96
        func holds(_ d: Double) -> Bool { abs(d) >= margin && abs(d) / chance >= MeetingAnalytics.Reading.minimumScore }
        guard holds(difference) else { return .steady }

        if mixed, metric.followsSize {
            let own = difference - mixEffect(rows, early: early, late: late)
            guard holds(own), (own < 0) == (difference < 0) else { return .mixed }
        }
        return .moved(from: first.median, to: last.median)
    }

    /// The difference that the mix of sizes alone gives: how much more of the last third's meetings are 1:1s,
    /// times how far the owner's number in 1:1s is from the one in groups. 0 when one of the sizes has too few
    /// meetings to say what it is like.
    static func mixEffect(_ rows: [Row], early: [Row], late: [Row]) -> Double {
        func values(_ size: Split) -> [Double] { rows.filter { $0.size == size }.map(\.point.value) }
        let ones = values(.oneOnOne), groups = values(.group)
        guard ones.count >= MeetingAnalytics.Usual.minimumSamples, groups.count >= MeetingAnalytics.Usual.minimumSamples,
              let one = median(of: ones), let group = median(of: groups) else { return 0 }
        func share(_ part: [Row]) -> Double? {
            let sized = part.filter { $0.size != nil }
            return sized.isEmpty ? nil : Double(sized.filter { $0.size == .oneOnOne }.count) / Double(sized.count)
        }
        guard let before = share(early), let after = share(late) else { return 0 }
        return (after - before) * (one - group)
    }
}

// MARK: Words

extension CommunicationTrends.Split {
    public var title: String {
        switch self {
        case .all: "All"
        case .oneOnOne: "1:1s"
        case .group: "Groups"
        }
    }
}

extension CommunicationTrends {
    public static func title(_ metric: PersonMetric) -> String {
        switch metric {
        case .talkShare: "Talk share"
        case .questionsPerHour: "Questions you ask"
        case .cutInsPerHour: "You cut in"
        case .wordsPerMinute: "Pace"
        default: metric.rawValue
        }
    }

    /// What follows a value: "an hour", "words a minute". A share has its sign and no unit.
    public static func unit(_ metric: PersonMetric) -> String {
        switch metric {
        case .questionsPerHour, .cutInsPerHour, .cutOffsPerHour: "an hour"
        case .wordsPerMinute: "words a minute"
        default: ""
        }
    }

    /// What the value axis counts, for its label: "Share of the talk", "Questions an hour".
    public static func axis(_ metric: PersonMetric) -> String {
        switch metric {
        case .talkShare: "Your share of the talk"
        case .questionsPerHour: "Questions an hour"
        case .cutInsPerHour: "Cut-ins an hour"
        case .wordsPerMinute: "Words a minute"
        default: metric.rawValue
        }
    }

    /// The value alone, as an axis writes it: "42%", "4.0", "152".
    public static func short(_ metric: PersonMetric, _ value: Double) -> String {
        switch metric {
        case .talkShare: "\(Int((value * 100).rounded()))%"
        case .questionsPerHour, .cutInsPerHour, .cutOffsPerHour: String(format: "%.1f", value)
        default: "\(Int(value.rounded()))"
        }
    }

    /// The value with its unit: "42%", "1.3 an hour", "152 words a minute".
    public static func text(_ metric: PersonMetric, _ value: Double) -> String { with(unit(metric), short(metric, value)) }

    /// "50 to 70%", "3.0 to 8.5 an hour"; one value when both ends read the same.
    public static func range(_ metric: PersonMetric, _ low: Double, _ high: Double) -> String {
        let a = short(metric, low), b = short(metric, high)
        if a == b { return text(metric, high) }
        return with(unit(metric), "\(metric == .talkShare ? String(a.dropLast()) : a) to \(b)")
    }

    private static func with(_ unit: String, _ value: String) -> String { unit.isEmpty ? value : "\(value) \(unit)" }

    /// "90 days", "12 months": the length of a period as a sentence says it.
    static func span(days: Int) -> String {
        if days <= 120 { return "\(days) \(days == 1 ? "day" : "days")" }
        let months = Int((Double(days) / 30.44).rounded())
        return "\(months) months"
    }
}

extension CommunicationTrends.Series {
    /// The chart's subtitle: "Down from 68% to 59% over 90 days", or that there is no clear change, or why
    /// nothing can be said.
    public var sentence: String {
        switch change {
        case .tooShort: "The period is too short to show a trend"
        case .tooFew: "Too few meetings to show a trend"
        case .steady: "No clear change"
        case .mixed: "No clear change apart from the mix of 1:1s and groups"
        case .moved(let from, let to):
            "\(to > from ? "Up" : "Down") from \(T.short(metric, from)) to \(T.text(metric, to)) over \(T.span(days: days))"
        }
    }

    /// How the sentence was reached, for a tooltip.
    public var basis: String {
        switch change {
        case .tooShort: "A trend needs a period of at least \(T.minimumDays) days."
        case .tooFew: "A trend needs \(MeetingAnalytics.Usual.firmSamples) meetings in the first third of the period and in the last."
        case .mixed: "The typical meeting moved, but only because the last third of the period has a different mix of 1:1s and groups. Pick one size to see its own trend."
        case .steady, .moved: "The typical meeting (the median) of the first third of the period against the last third. A change is said only when it is larger than chance gives."
        }
    }

    /// The label over the usual band: "Usual before this period 50 to 70%".
    public var usualText: String? {
        usual.map { "\($0.fromBefore ? "Usual before this period" : "Usual in this period") \(T.range(metric, $0.low, $0.high))" }
    }

    /// The whole chart in words, for VoiceOver.
    public var spoken: String {
        guard let typical else { return "\(T.title(metric)). No meetings with this number in the period." }
        var parts = [T.title(metric), sentence,
                     "Typical meeting \(T.text(metric, typical)), in \(points.count) \(points.count == 1 ? "meeting" : "meetings")"]
        if let usualText { parts.append(usualText) }
        return parts.joined(separator: ". ") + "."
    }
}
