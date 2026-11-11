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
    static func change(_ metric: PersonMetric, _ rows: [Row], interval: DateInterval, days: Int) -> Change {
        guard days >= minimumDays else { return .tooShort }
        let third = interval.duration / 3
        let early = rows.filter { $0.point.date < interval.start.addingTimeInterval(third) }.map(\.point.value)
        let late = rows.filter { $0.point.date >= interval.end.addingTimeInterval(-third) }.map(\.point.value)
        typealias Usual = MeetingAnalytics.Usual
        guard let first = Usual(early), let last = Usual(late), first.isFirm, last.isFirm else { return .tooFew }

        let difference = abs(last.median - first.median)
        let margin = metric.margin(first)
        let spread = max(((first.spread * first.spread + last.spread * last.spread) / 2).squareRoot(), margin / 2)
        // What chance gives the difference of two medians: a median of n values is 1.2533 times less sure than
        // their mean.
        let chance = spread * 1.2533 * (1 / Double(first.samples) + 1 / Double(last.samples)).squareRoot()
            * Usual.student(first.samples + last.samples - 2) / 1.96
        guard difference >= margin, difference / chance >= MeetingAnalytics.Reading.minimumScore else { return .steady }
        return .moved(from: first.median, to: last.median)
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
        let over = "over \(T.span(days: days))"
        func values(_ from: Double, _ to: Double) -> String { "from \(T.short(metric, from)) to \(T.text(metric, to))" }
        func direction(_ from: Double, _ to: Double) -> String { to > from ? "up" : "down" }
        func capital(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
        switch change {
        case .tooShort: return "The period is too short to show a trend"
        case .tooFew: return "Too few meetings to show a trend"
        case .steady: return "No clear change"
        case .moved(let from, let to): return capital("\(direction(from, to)) \(values(from, to)) \(over)")
        case .bySize(let one, let group):
            switch (one, group) {
            case (.moved(let a, let b), .moved(let c, let d)):
                // "from 1.0 to 3.0 an hour": the unit one time, at the end.
                func short(_ from: Double, _ to: Double) -> String { "from \(T.short(metric, from)) to \(T.short(metric, to))" }
                let unit = T.unit(metric).isEmpty ? "" : " \(T.unit(metric))"
                if direction(a, b) == direction(c, d) {
                    return capital("\(direction(a, b)) \(over): 1:1s \(short(a, b)), groups \(short(c, d))\(unit)")
                }
                return capital("\(direction(a, b)) in 1:1s \(short(a, b)), \(direction(c, d)) in groups \(short(c, d))\(unit) \(over)")
            case (.moved(let a, let b), let other), (let other, .moved(let a, let b)):
                let size = one.moved ? "1:1s" : "groups", rest = one.moved ? "groups" : "1:1s"
                let said = capital("\(direction(a, b)) in \(size) \(values(a, b)) \(over)")
                return other == .steady ? "\(said); no clear change in \(rest)" : said
            case (.steady, _), (_, .steady): return "No clear change"
            case (.tooShort, _), (_, .tooShort): return "The period is too short to show a trend"
            default: return "Too few meetings of one size to show a trend"
            }
        }
    }

    /// How the sentence was reached, for a tooltip.
    public var basis: String {
        let rule = "The typical meeting (the median) of the first third of the period against the last third. A change is said only when it is larger than chance gives."
        switch change {
        case .tooShort: return "A trend needs a period of at least \(T.minimumDays) days."
        case .tooFew: return "A trend needs \(MeetingAnalytics.Usual.firmSamples) meetings in the first third of the period and in the last."
        case .steady, .moved: return rule
        case .bySize: return "This number follows the size of the meeting, so 1:1s and groups are compared apart. \(rule)"
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
