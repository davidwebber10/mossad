import Foundation

/// One trait: a group of moments with one dimension and one value for one person, and where necessary one
/// setting. Code makes it from the evidence and the owner's answers each time; nothing here is stored as truth.
public struct PersonaTrait: Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case hidden, candidate, shown, confirmed, rejected }

    /// "<person>|<dimension>|<value>|<setting or any>": the same after a call is read again.
    public var id: String
    public var person: String
    public var dimension: String
    public var value: String
    public var condition: PersonaSetting?
    /// The moments that support it, and the moments in the same dimension (and setting) with an opposite value.
    public var support: [PersonaEvidence]
    public var counter: [PersonaEvidence]
    /// S and C of the formula: distinct days, a day with weak moments only as one half, counter-evidence by its age.
    public var supportDays: Double
    public var counterDays: Double
    public var text: PersonaText?
    public var answer: FindingVerdict?
    public var confidence: Double
    public var state: State

    public var isShown: Bool { state == .shown || state == .confirmed }
    public var supportCalls: Int { Set(support.map(\.callID)).count }
    public var counterCalls: Int { Set(counter.map(\.callID)).subtracting(support.map(\.callID)).count }

    /// "Likely", "Established", or "You confirmed"; nil when it does not show.
    public var label: String? {
        switch state {
        case .confirmed: "You confirmed"
        case .shown: confidence >= PersonaConfidence.established ? "Established" : "Likely"
        default: nil
        }
    }

    /// "seen in 3 of 4 calls": the count is the hedge.
    public var countLine: String { "seen in \(supportCalls) of \(supportCalls + counterCalls) \(supportCalls + counterCalls == 1 ? "call" : "calls")" }

    /// "Likely, seen in 3 of 4 calls".
    public var confidenceLine: String { (label.map { "\($0), " } ?? "") + countLine }

    /// The best moment to play: the newest clear one.
    public var bestMoment: PersonaPointer? {
        (support.filter { $0.strength == .clear }.last ?? support.last)?.pointer
    }

    public var lastSeen: Date? { support.map(\.date).max() }

    public static func id(person: String, dimension: String, value: String, condition: PersonaSetting?) -> String {
        "\(person)|\(dimension)|\(value)|\(condition?.rawValue ?? "any")"
    }

    /// The person, dimension, and value of a trait id: "never" blocks the value for that person in each setting.
    static func block(of id: String) -> String { id.split(separator: "|", omittingEmptySubsequences: false).prefix(3).joined(separator: "|") }
}

/// The numbers of the confidence. The eval sets the final values; these are the study's start values.
public enum PersonaConfidence {
    /// A trait shows on the pages at this number or more, before real answers move it.
    public static let threshold = 0.70
    /// From here to the threshold, a trait is only a question in the Findings deck, and shows after the owner's yes.
    /// Under it, a trait never shows and is never asked.
    public static let askBound = 0.50
    public static let established = 0.80

    /// The bounds in use: the owner's answers move them, only upward until 30 trait answers exist.
    public struct Bounds: Equatable, Sendable {
        public var show: Double
        public var ask: Double
        public static let start = Bounds(show: threshold, ask: askBound)
    }

    /// From the answers to trait cards with the confidence they were asked at. Fewer than 8 in 10 yes on traits at or
    /// above the show bound raises it by 0.1 (10 answers at least, 0.9 at most). With 30 answers or more, 9 in 10 yes
    /// on traits from 0.6 to the bound lowers it to 0.6, never further. Fewer than 3 in 10 yes in the ask band raises
    /// the ask bound to 0.6.
    public static func bounds(_ answers: [FindingAnswer]) -> Bounds {
        let given = answers.filter { $0.traitID != nil && $0.verdict != nil && $0.confidence != nil }
        func share(_ a: [FindingAnswer]) -> Double { Double(a.filter { $0.verdict == .yes }.count) / Double(max(1, a.count)) }
        var b = Bounds.start
        for _ in 0..<2 {
            let above = given.filter { $0.confidence! >= b.show - 1e-9 }
            if above.count >= 10, share(above) < 0.8, b.show < 0.9 - 1e-9 { b.show += 0.1 } else { break }
        }
        if b.show == threshold, given.count >= twoCallAnswers {
            let near = given.filter { $0.confidence! >= 0.6 && $0.confidence! < threshold }
            if near.count >= 10, share(near) >= 0.9 { b.show = 0.6 }
        }
        let band = given.filter { $0.confidence! >= askBound && $0.confidence! < b.show }
        if band.count >= 10, share(band) < 0.3 { b.ask = 0.6 }
        b.ask = min(b.ask, b.show)
        return b
    }
    static let quantile = 0.10
    static let highRating = 0.10
    static let lowRating = 0.15
    static let oneTopic = 0.10
    static let ownerNo = 0.25
    /// After a no, a trait waits for this many new days of support.
    static let newDaysAfterNo = 2
    /// Counter-evidence older than the newest support weighs half for each this many days.
    static let halfLifeDays = 365.0
    /// A habit that changed: at least this many days of the new value at the end, the newest of them this many
    /// days after the newest opposite moment before them.
    static let changeRun = 3
    static let changeGapDays = 60.0

    /// The 2-call rule may come on. The eval can set this to false; it never turns the rule on. Real answers do.
    public static let twoCallAllowed = true
    /// The rule comes on when the owner answered this many trait cards, with this share of yes.
    public static let twoCallAnswers = 30
    public static let twoCallYesShare = 0.8

    /// Whether a trait of 2 calls can show without the owner's yes: only after enough real answers say the reads
    /// are right. Until then a 2-call trait is a question in the Findings deck.
    public static func twoCallRuleOn(_ answers: [FindingAnswer]) -> Bool {
        guard twoCallAllowed else { return false }
        let given = answers.filter { $0.traitID != nil && $0.verdict != nil }
        guard given.count >= twoCallAnswers else { return false }
        return Double(given.filter { $0.verdict == .yes }.count) / Double(given.count) >= twoCallYesShare
    }

    /// The low end of what the true rate can be, given S days for and C against: the 10th percentile of
    /// Beta(S + 1, C + 1). More calls raise it; one contradiction lowers it much.
    public static func base(support s: Double, counter c: Double) -> Double {
        let a = max(s, 0) + 1, b = max(c, 0) + 1
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if betaCDF(mid, a, b) < quantile { lo = mid } else { hi = mid }
        }
        return (((lo + hi) / 2) * 1000).rounded() / 1000
    }

    /// The regularized incomplete beta function for a and b of 1 or more, by Simpson's rule: the integrand has no
    /// pole, and the same steps give the same number on each device.
    static func betaCDF(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let n = 400
        let h = x / Double(n)
        func f(_ t: Double) -> Double { pow(t, a - 1) * pow(1 - t, b - 1) }
        var sum = f(0) + f(x)
        for i in 1..<n { sum += f(Double(i) * h) * (i % 2 == 1 ? 4 : 2) }
        let beta = exp(lgamma(a) + lgamma(b) - lgamma(a + b))
        return min(1, sum * h / 3 / beta)
    }
}

/// Makes the traits of one person from the evidence and the owner's answers. Pure: the same evidence and
/// answers give the same traits on each device.
public enum PersonaTraits {
    /// `answers` are the coach's answers to cards; only those with a trait id count, and a taken-back answer is none.
    /// `twoCallRule`: nil reads it from the answers (`PersonaConfidence.twoCallRuleOn`); the eval sets it.
    public static func build(_ persona: Persona, answers: [FindingAnswer], doNotProfile: Bool = false, twoCallRule: Bool? = nil) -> [PersonaTrait] {
        guard !doNotProfile else { return [] }
        let person = persona.person
        let twoCalls = twoCallRule ?? PersonaConfidence.twoCallRuleOn(answers)
        let bounds = PersonaConfidence.bounds(answers)
        let mine = answers.filter { a in a.verdict != nil && (a.traitID.map { PersonaTrait.block(of: $0).hasPrefix(person + "|") } ?? false) }
        let latest = Dictionary(grouping: mine, by: { $0.traitID ?? "" }).compactMapValues { $0.max { ($0.date, $0.id) < ($1.date, $1.id) } }
        let blocked = Set(mine.filter { $0.verdict == .never }.compactMap { $0.traitID.map(PersonaTrait.block(of:)) })

        let evidence = persona.evidence.filter { ev in
            ev.dimension != PersonaDimension.expects.rawValue || !ev.value.isEmpty
        }
        // The free dimensions with the most moments, two at most.
        let free = Dictionary(grouping: evidence.filter { $0.dimension.hasPrefix(PersonaDimension.freePrefix) }, by: \.dimension)
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.prefix(PersonaDimension.freeLimit).map(\.key)
        let kept = evidence.filter { !$0.dimension.hasPrefix(PersonaDimension.freePrefix) || free.contains($0.dimension) }

        var out: [PersonaTrait] = []
        for (dimension, moments) in Dictionary(grouping: kept, by: \.dimension) {
            for value in Set(moments.map(\.value)) {
                var support = moments.filter { $0.value == value }
                // A weak opposite moment counts too, at half: a model's doubt about the label must not hide a contradiction.
                var counter = moments.filter { PersonaDimension.contradicts(dimension, value, $0.value) }
                // All contradictions stay on the page; the ones of a habit of before do not count.
                var counted = afterChange(value: value, dimension: dimension, moments: moments, counter: counter)
                var condition: PersonaSetting?
                // Support in one setting and every contradiction in the other: a trait with a condition.
                let settings = Set(support.map(\.setting))
                if !counter.isEmpty, settings.count == 1, let only = settings.first, !counter.contains(where: { $0.setting == only }) {
                    condition = only
                    counter = []
                    counted = []
                }
                support.sort(by: order)
                counter.sort(by: order)
                let id = PersonaTrait.id(person: person, dimension: dimension, value: value, condition: condition)
                var trait = score(id: id, person: person, dimension: dimension, value: value, condition: condition, support: support, counter: counter,
                                  counted: counted, text: persona.texts[id], answer: latest[id] ?? latest[PersonaTrait.id(person: person, dimension: dimension, value: value, condition: nil)],
                                  twoCallRule: twoCalls, bounds: bounds)
                if blocked.contains(PersonaTrait.block(of: id)) {
                    trait.state = .rejected
                    trait.answer = .never
                }
                out.append(trait)
            }
        }
        return out.sorted { ($0.isShown ? 0 : 1, -$0.confidence, $0.id) < ($1.isShown ? 0 : 1, -$1.confidence, $1.id) }
    }

    /// The confidence of one trait, with no answers: for tests and the eval.
    public static func number(for id: String, in persona: Persona) -> Double? {
        build(persona, answers: []).first { $0.id == id }?.confidence
    }

    private static func order(_ a: PersonaEvidence, _ b: PersonaEvidence) -> Bool {
        (a.date, a.callID, a.pointer.at, a.value) < (b.date, b.callID, b.pointer.at, b.value)
    }

    /// People change. When the newest days of this dimension show this value only, at least `changeRun` of them and
    /// at least as many as the days of opposite values before them, those older opposite moments are no
    /// counter-evidence: they are the person of before. A rule by these two counts keeps the number monotone: one
    /// more contradiction can only end the rule, and one more call of support can only start it.
    static func afterChange(value: String, dimension: String, moments: [PersonaEvidence], counter: [PersonaEvidence]) -> [PersonaEvidence] {
        let relevant = moments.filter { $0.strength == .clear && ($0.value == value || PersonaDimension.contradicts(dimension, value, $0.value)) }
        let days = Dictionary(grouping: relevant, by: \.day).sorted { $0.key < $1.key }
        var run = 0, start: Int?
        for (day, ms) in days.reversed() {
            guard ms.allSatisfy({ $0.value == value }) else { break }
            run += 1
            start = day
        }
        guard run >= PersonaConfidence.changeRun, let start else { return counter }
        let older = counter.filter { $0.day < start }
        let before = Set(older.map(\.day)).count
        guard run >= before else { return counter }
        // Time, not only order: the newest support at least 60 days after the newest older contradiction. Four
        // moments in a row cannot show a change; a later call of support can only start the rule, a later
        // contradiction only end it.
        if let lastAgainst = older.map(\.date).max(), let lastFor = moments.filter({ $0.value == value }).map(\.date).max(),
           lastFor.timeIntervalSince(lastAgainst) < PersonaConfidence.changeGapDays * 86_400 {
            return counter
        }
        return counter.filter { $0.day >= start }
    }

    static func score(id: String, person: String, dimension: String, value: String, condition: PersonaSetting?, support: [PersonaEvidence],
                      counter: [PersonaEvidence], counted: [PersonaEvidence], text: PersonaText?, answer: FindingAnswer?, twoCallRule: Bool = true, bounds: PersonaConfidence.Bounds = .start) -> PersonaTrait {
        // S: one for a day with a clear moment, one half for a day with weak moments only.
        let byDay = Dictionary(grouping: support, by: \.day)
        let s = byDay.values.reduce(0.0) { $0 + ($1.contains { $0.strength == .clear } ? 1 : 0.5) }
        // C: each day against, weighed by how much older it is than the newest support.
        let newest = support.map(\.date).max() ?? .distantPast
        let c = Dictionary(grouping: counted, by: \.day).values.reduce(0.0) { sum, ms in
            let date = ms.map(\.date).max() ?? newest
            let age = max(0, newest.timeIntervalSince(date) / 86_400)
            return sum + pow(0.5, age / PersonaConfidence.halfLifeDays) * (ms.contains { $0.strength == .clear } ? 1 : 0.5)
        }
        var number = PersonaConfidence.base(support: s, counter: c)
        let rating = text?.rating ?? .medium
        if rating == .high { number += PersonaConfidence.highRating }
        if rating == .low { number -= PersonaConfidence.lowRating }
        let diverse = isDiverse(support)
        // One call is one topic by itself. The penalty holds for it too, so a second call never lowers the number.
        if !diverse { number -= PersonaConfidence.oneTopic }
        var waits = false
        if let answer, answer.verdict == .no {
            number -= PersonaConfidence.ownerNo
            let newDays = Set(support.filter { $0.date > answer.date }.map(\.day)).count
            waits = newDays < PersonaConfidence.newDaysAfterNo
        }
        number = (min(1, max(0, number)) * 1000).rounded() / 1000

        let days = byDay.count
        let words = text.map { PersonaWords.passes(statement: $0.statement, soDoThis: $0.soDoThis) } ?? false
        // Hard gates: one call never shows; two calls only with a high rating, two topics or settings, and no
        // contradiction; a trait needs a sentence that passes the word check.
        let gate = days >= 3 || (twoCallRule && days == 2 && rating == .high && diverse && counted.isEmpty)
        // Pace follows the meeting's format as much as the person: kept as evidence, not shown in this version.
        let measured = dimension == PersonaDimension.pace.rawValue
        let state: PersonaTrait.State
        if answer?.verdict == .never {
            state = .rejected
        } else if answer?.verdict == .yes, text != nil {
            state = .confirmed
        } else if days >= 2, gate, words, !waits, !measured, number >= bounds.show - 1e-9 {
            state = .shown
        } else if days >= 2, !measured, !waits, number >= bounds.ask - 1e-9 {
            // Only a question in the Findings deck: it shows after the owner's yes.
            state = .candidate
        } else {
            state = .hidden
        }
        return PersonaTrait(id: id, person: person, dimension: dimension, value: value, condition: condition, support: support, counter: counter,
                            supportDays: s, counterDays: (c * 1000).rounded() / 1000, text: text, answer: answer?.verdict, confidence: number, state: state)
    }

    /// Two topics or two settings: not all support from one series or one topic tag, or support in both settings.
    static func isDiverse(_ support: [PersonaEvidence]) -> Bool {
        let days = Dictionary(grouping: support, by: \.day)
        guard days.count >= 2 else { return false }
        if Set(support.map(\.setting)).count >= 2 { return true }
        if Set(support.map(\.series)).count < 2 { return false }
        let tagSets = Dictionary(grouping: support, by: \.callID).values.map { Set($0.flatMap(\.tags).map { $0.lowercased() }) }
        let shared = tagSets.dropFirst().reduce(tagSets.first ?? []) { $0.intersection($1) }
        return shared.isEmpty
    }
}
