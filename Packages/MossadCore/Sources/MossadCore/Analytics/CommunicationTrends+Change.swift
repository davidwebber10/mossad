import Foundation

// MARK: The change

extension CommunicationTrends {
    /// A shorter period has no trend: its thirds would be different days of the week, not different times.
    static let minimumDays = 21
    /// The most that chance may give a difference as large, for it to be said.
    static let chanceLimit = 0.01
    /// The shuffles that measure chance. Enough to tell 1% from 2%; the same on each run (`Shuffle`).
    static let shuffles = 999

    /// The period's meetings, each compared only with meetings of its own kind (`Row.kind`), so a change in the
    /// mix of kinds (more 1:1s, a new all-hands, a series that ended) is not a change of the owner.
    ///
    /// A kind of two or more meetings that is not in both the first and the last third (a new series, one that
    /// ended) keeps its own level and is not compared: its meetings say nothing of a change of the owner. A
    /// meeting that is the only one of its kind is compared within its group size. Each
    /// point is moved by the distance from its kind's median to the median of all: the kinds then sit at one
    /// level, the line of their medians moves only when the owner does, and with one kind a point stays as it is.
    struct Mix {
        /// The points with their moved values, oldest first.
        var points: [Point]
        /// The kind each point is compared within.
        var kinds: [String]
        /// True when more than one kind was moved.
        var held: Bool

        init(_ rows: [Row], interval: DateInterval) {
            let (firstEnd, lastStart) = CommunicationTrends.thirds(interval)
            var sides: [String: (first: Bool, last: Bool)] = [:]
            var counts: [String: Int] = [:]
            for r in rows {
                counts[r.kind, default: 0] += 1
                if r.point.date < firstEnd { sides[r.kind, default: (false, false)].first = true }
                if r.point.date >= lastStart { sides[r.kind, default: (false, false)].last = true }
            }
            // A kind of its own that is missing from one third has no pool on that side, so `change` leaves it out.
            kinds = rows.map { r in sides[r.kind].map { $0.first && $0.last } == true || counts[r.kind, default: 0] > 1 ? r.kind : r.sizeKind }
            var byKind: [String: [Double]] = [:]
            for (r, kind) in zip(rows, kinds) { byKind[kind, default: []].append(r.point.value) }
            let all = median(of: rows.map(\.point.value)) ?? 0
            let shift = byKind.mapValues { all - (median(of: $0) ?? all) }
            held = byKind.count > 1
            points = zip(rows, kinds).map { r, kind in
                var p = r.point
                // One kind: its median is the median of all and the shift is 0, so the value is unchanged.
                p.value += shift[kind] ?? 0
                return p
            }
        }
    }

    /// The end of the first third and the start of the last.
    static func thirds(_ interval: DateInterval) -> (Date, Date) {
        let third = interval.duration / 3
        return (interval.start.addingTimeInterval(third), interval.end.addingTimeInterval(-third))
    }

    /// Whether the number moved from the first third of the period to the last:
    ///
    /// - each third has `Usual.firmSamples` meetings of kinds that are in both, or nothing is said;
    /// - the medians of the two thirds, with the mix held (`Mix`), differ by the least difference that matters
    ///   for the number (`PersonMetric.margin`);
    /// - the meetings of the last third rank above (or below) those of the first, each among the meetings of its
    ///   own kind, further than chance takes them in all but `chanceLimit` of shuffles (`chance`).
    ///
    /// Ranks and shuffles know nothing of the shape of the numbers: two kinds of meeting that nothing names, a
    /// count that is often 0, or a few far meetings cannot make noise read as a change.
    static func change(_ metric: PersonMetric, _ mix: Mix, interval: DateInterval, days: Int) -> Change {
        guard days >= minimumDays else { return .tooShort }
        let (firstEnd, lastStart) = thirds(interval)
        var pools: [String: (first: [Double], last: [Double])] = [:]
        for (p, kind) in zip(mix.points, mix.kinds) {
            if p.date < firstEnd { pools[kind, default: ([], [])].first.append(p.value) }
            if p.date >= lastStart { pools[kind, default: ([], [])].last.append(p.value) }
        }
        let compared = pools.keys.sorted().compactMap { k in pools[k].flatMap { !$0.first.isEmpty && !$0.last.isEmpty ? $0 : nil } }
        let first = compared.flatMap(\.first), last = compared.flatMap(\.last)
        let firm = MeetingAnalytics.Usual.firmSamples
        guard first.count >= firm, last.count >= firm, let from = median(of: first), let to = median(of: last) else { return .tooFew }
        guard abs(to - from) >= metric.margin(median: from), let (rise, chance) = chance(compared),
              rise == (to > from), chance <= chanceLimit else { return .steady }
        return .moved(from: from, to: to)
    }

    /// How far the last third ranks from the first, each meeting ranked among its own kind (the rank-sum test of
    /// van Elteren), and the share of shuffles that rank as far, when each kind's meetings of the two thirds are
    /// dealt between them again at random. Nil when the ranks do not lean either way. Stops as soon as the share
    /// cannot be under `chanceLimit`.
    static func chance(_ pools: [(first: [Double], last: [Double])]) -> (rise: Bool, chance: Double)? {
        // Each kind's ranks, ties sharing their mean rank, weighted by one over its size plus one.
        let decks: [[Double]] = pools.map { pool in
            let values = pool.first + pool.last
            let order = values.indices.sorted { values[$0] < values[$1] }
            var ranks = [Double](repeating: 0, count: values.count)
            var i = 0
            while i < order.count {
                var j = i
                while j + 1 < order.count, values[order[j + 1]] == values[order[i]] { j += 1 }
                for k in i...j { ranks[order[k]] = Double(i + j + 2) / 2 / Double(values.count + 1) }
                i = j + 1
            }
            return ranks
        }
        let dealt = pools.map(\.last.count)
        // What the last third's ranks add up to when it does not lean: half of each of its meetings.
        let middle = Double(dealt.reduce(0, +)) / 2
        let seen = zip(decks, dealt).reduce(0) { $0 + $1.0[($1.0.count - $1.1)...].reduce(0, +) } - middle
        guard abs(seen) > 1e-9 else { return nil }

        var shuffle = Shuffle()
        var orders = decks.map { Array($0.indices) }
        let allowed = Int(chanceLimit * Double(shuffles + 1))
        var beyond = 0
        for _ in 0..<shuffles {
            var sum = 0.0
            for i in orders.indices {
                let n = orders[i].count
                for j in 0..<dealt[i] {
                    orders[i].swapAt(j, j + shuffle.below(n - j))
                    sum += decks[i][orders[i][j]]
                }
            }
            if abs(sum - middle) >= abs(seen) - 1e-9 {
                beyond += 1
                if beyond >= allowed { return (seen > 0, 1) }
            }
        }
        return (seen > 0, Double(beyond + 1) / Double(shuffles + 1))
    }

    /// Numbers that look random and are the same on each run: one history always reads the same.
    struct Shuffle {
        private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        /// A whole number from 0 up to `n`, not `n`.
        mutating func below(_ n: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Int(z % UInt64(n))
        }
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
        let rule = "The typical meeting (the median) of the first third of the period against the last third, each kind of meeting against its own kind. A change is said only when it matters and chance gives one as large in fewer than 1 in 100 shuffles of the meetings."
        switch change {
        case .tooShort: return "A trend needs a period of at least \(T.minimumDays) days."
        case .tooFew:
            return "A trend needs \(MeetingAnalytics.Usual.firmSamples) meetings in the first third of the period and in the last, of kinds of meeting that are in both. A series that started or ended in the period is not compared."
        case .steady, .moved: return rule
        case .bySize: return "This number follows the size of the meeting, so 1:1s and groups are compared apart. \(rule)"
        }
    }

    /// The label over the usual band: "Usual before this period 50 to 70%".
    public var usualText: String? {
        usual.map { "\($0.fromBefore ? "Usual before this period" : "Usual in this period") \(T.range(metric, $0.low, $0.high))" }
    }

    /// "Median of each week", "1:1s, median of each 2 weeks".
    public static func lineName(days: Int, split: CommunicationTrends.Split? = nil, held: Bool = false) -> String {
        let weeks = days / 7
        let each = weeks <= 1 ? "median of each week" : "median of each \(weeks) weeks"
        let named = split.map { "\($0 == .oneOnOne ? "1:1s" : "Groups"), \(each)" } ?? each.prefix(1).uppercased() + each.dropFirst()
        return held ? "\(named), the mix of meetings held" : named
    }

    /// The whole chart in words, for VoiceOver.
    public var spoken: String {
        guard !points.isEmpty else { return "\(T.title(metric)). No meetings with this number in the period." }
        let count = "\(points.count) \(points.count == 1 ? "meeting" : "meetings")"
        var said = [T.title(metric), sentence]
        if let typical {
            said.append("Typical meeting \(T.text(metric, typical)), in \(count)")
        } else {
            let each = parts.compactMap { p in p.typical.map { "\(p.split == .oneOnOne ? "1:1" : "group") \(T.text(metric, $0))" } }
            said.append("Typical \(each.joined(separator: ", typical ")), in \(count)")
        }
        if let usualText { said.append(usualText) }
        // The basis is whole sentences already.
        return said.joined(separator: ". ") + ". " + basis
    }
}
