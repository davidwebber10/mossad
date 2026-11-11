import Foundation

/// Turns what the model wrote about one call into what the owner sees: one line or nothing. The model gives
/// the notes and a skill key for each. Code does the rest:
///
/// 1. Proof. Advice, praise, and the result on the focus need the owner's own words, found in the transcript.
///    A number needs its baseline. Without proof a note is dropped, with its detail point.
/// 2. No repeats. A skill that got a line in the last 30 days gets no line again (`AdviceRules`). A call that
///    shows it again is counted, with its moment; after enough calls and days the count is a line, not the advice.
/// 3. One. The first of: the result on the accepted focus, a measured trend, new advice, a number that is not
///    usual, something done well, a count that is due.
/// 4. Short. A note that is too long or that judges a trend is dropped, and a line over `lineWords` loses the
///    quote's text, then the words to say.
public enum CoachLineRules {
    /// A quote is the proof, not the review: it shows this many words at most, and all of them are checked.
    public static let quoteWords = 12
    /// Fewer words than this are in many lines: they prove nothing.
    static let minimumQuoteWords = 3
    /// The most words of a note's own text. The prompt asks for 16.
    static let textWords = 24
    /// The most words the owner reads for a call.
    public static let lineWords = 35

    /// A change against earlier calls is for code to measure. A note that claims one is dropped.
    static let trendWords = ["down from", "up from", "better than", "worse than", "than before", "than usual", "than last", "more than your", "less than your",
                             "once again", "yet again", "again you", "you again", "second time", "third time", "fourth time", "improved", "improving",
                             "got better", "got worse", "getting better", "getting worse"]

    static func judgesTrend(_ text: String) -> Bool {
        let plain = " " + AdviceRules.key(text) + " "
        return trendWords.contains { plain.contains(" \($0) ") }
    }

    private static func count(_ text: String?) -> Int { text?.split(whereSeparator: \.isWhitespace).count ?? 0 }

    public static func settle(_ result: CoachResult, record r: CallRecord, owner: String, profile: CoachProfile, measured: CoachMeasured) -> CoachResult {
        var out = result
        var review = result.review
        var dropped: [String] = []
        let log = AdviceRules.said(profile)
        let focus = profile.activeFocus

        /// The note with the owner's moment that holds its quote; nil when it has no proof or breaks a rule.
        func checked(_ note: CoachNote?, _ name: String) -> CoachNote? {
            guard var note else { return nil }
            guard let moment = ownerMoment(quote: note.quote ?? "", in: r, owner: owner) else {
                dropped.append("\(name): its quote is not in the owner's lines")
                return nil
            }
            guard count(note.text) <= textWords else { dropped.append("\(name): \(count(note.text)) words"); return nil }
            guard !judgesTrend(note.text) else { dropped.append("\(name): it judges a trend"); return nil }
            let id = note.skill ?? ""
            // The count of calls for earlier advice has no text of its own; advice and praise need a skill with a name.
            guard CoachSkill.isNamed(id) else { dropped.append("\(name): no skill name"); return nil }
            if let skill = CoachSkill(id: id), !skill.isCoached, !(skill == .pace && focus?.metric == .pace) {
                dropped.append("\(name): \(skill.rawValue) is not coached")
                return nil
            }
            note.quote = moment.quote
            note.at = moment.at
            note.skill = id
            note.measure = CoachSkill(id: id)?.measure
            note.number = note.measure == .commitmentDay ? measured.commitments?.text : nil
            return note
        }
        func earlier(_ kind: CoachLine.Kind, _ note: CoachNote) -> CoachAdvice? {
            AdviceRules.earlier(kind: kind, skill: note.skill ?? "", in: log, callID: r.id, date: r.start)
        }

        review.didWell = checked(review.didWell, "did_well")
        review.tryNext = checked(review.tryNext, "try_next")
        review.seenAgain = checked(review.seenAgain, "seen_again")

        // The result on the focus says how the call went on that skill: advice about it would say it twice.
        if let note = review.tryNext, let focus, AdviceRules.key(note.skill ?? "") == AdviceRules.key(focus.skillID) { review.tryNext = nil }
        // Advice that was said: this call's moment is evidence for it, and the advice is not written again.
        var first = review.seenAgain.flatMap { earlier(.again, $0) }
        if let note = review.tryNext, let before = earlier(.tryNext, note) {
            if first == nil {
                review.seenAgain = CoachNote(text: "", quote: note.quote, at: note.at)
                first = before
            }
            review.tryNext = nil
        }
        if let note = review.didWell, earlier(.didWell, note) != nil { review.didWell = nil }

        var again: CoachLine?
        if var note = review.seenAgain, let first {
            let name = CoachSkill.title(of: first.skill)
            note.text = name
            note.skill = first.skill
            note.measure = first.measure
            note.say = nil
            note.number = note.measure == .commitmentDay ? measured.commitments?.text : nil
            review.seenAgain = note
            let count = AdviceRules.again(after: first, in: log, reviewed: profile.history, callID: r.id, date: r.start)
            if count.due {
                again = CoachLine(kind: .again, text: "\(name): \(count.calls) of your \(count.of) calls since \(day(first.date)) showed it.", skill: first.skill,
                                  quote: note.quote, at: note.at, number: note.number, measure: note.measure)
            }
        } else {
            // Nothing like it was said in the last 30 days: there is nothing to see again.
            review.seenAgain = nil
        }

        var candidates: [CoachLine] = []
        if let focus, review.focusID == focus.id, let result = review.focusResult, result.outcome != .noChance {
            if let moment = ownerMoment(quote: result.quote ?? "", in: r, owner: owner), !judgesTrend(result.evidence), count(result.evidence) <= textWords {
                let chances = focus.chances.filter { $0.callID != r.id } + [result]
                var number = "\(chances.filter { $0.outcome == .hit }.count) of \(chances.count) chances"
                if focus.measure == .commitmentDay, let share = measured.commitments { number += ". \(share.text)" }
                candidates.append(CoachLine(kind: .focus, text: result.evidence, skill: focus.skillID, quote: moment.quote, at: moment.at, number: number,
                                            measure: focus.measure, outcome: result.outcome))
                review.focusResult?.at = moment.at
                review.focusResult?.quote = moment.quote
            } else {
                // The result still counts for the focus. It is not a line: nothing shows that the owner said it.
                dropped.append("focus_result: no proof, or too long")
                review.focusResult?.quote = nil
            }
        }
        if let trend = measured.trend {
            candidates.append(CoachLine(kind: .progress, text: trend.text, skill: "progress:\(trend.id)", number: trend.proof))
        }
        if let note = review.tryNext { candidates.append(CoachLine(kind: .tryNext, note: note)) }
        candidates += measured.standouts.compactMap(number)
        if let note = review.didWell { candidates.append(CoachLine(kind: .didWell, note: note)) }
        // Last: a count is no news when the call has any.
        if let again { candidates.append(again) }

        let line = candidates.first { c in
            guard c.hasProof else { return false }
            // The notes and the count passed the log above; a number and a trend are checked here.
            guard c.kind == .number || c.kind == .progress else { return true }
            return AdviceRules.earlier(kind: c.kind, skill: c.skill, in: log, callID: r.id, date: r.start) == nil
        }.map(fit)
        review.line = line
        review.version = CoachReview.currentVersion

        // A note that did not get the line waits in the full review, one time: not in the full review of each call.
        if let note = review.tryNext, line?.kind != .tryNext, AdviceRules.waits(kind: .tryNext, skill: note.skill ?? "", in: log, callID: r.id, date: r.start) {
            review.tryNext = nil
        }
        if let note = review.didWell, line?.kind != .didWell, AdviceRules.waits(kind: .didWell, skill: note.skill ?? "", in: log, callID: r.id, date: r.start) {
            review.didWell = nil
        }
        // A detail point is the evidence behind a note. Without its note it would be the advice that the rules
        // removed. With it, its quote needs the same proof.
        func proven(_ points: [CoachPoint]) -> [CoachPoint] {
            points.compactMap { p in
                guard let moment = ownerMoment(quote: p.quote, in: r, owner: owner), !judgesTrend(p.observation) else { return nil }
                var p = p
                p.quote = moment.quote
                p.at = moment.at
                return p
            }
        }
        review.strengths = review.didWell == nil ? [] : proven(review.strengths)
        review.improvements = review.tryNext == nil ? [] : proven(review.improvements)

        // The log keeps what the owner got as the line, what waits in the full review, and what was only counted.
        var said: [CoachAdvice] = []
        if let line { said.append(CoachAdvice(line, callID: r.id, date: r.start)) }
        for other in review.others where other.kind != .again { said.append(CoachAdvice(other, callID: r.id, date: r.start, shown: false)) }
        if let note = review.seenAgain, line?.kind != .again {
            said.append(CoachAdvice(callID: r.id, date: r.start, kind: .again, skill: note.skill ?? note.text, text: note.text, at: note.at, held: true))
        }

        // A pattern's moment is kept only as the owner's own words.
        out.update.patterns = result.update.patterns.map { p in
            var p = p
            let moment = ownerMoment(quote: p.quote ?? "", in: r, owner: owner)
            p.quote = moment?.quote
            p.at = moment?.at
            return p
        }
        out.review = review
        out.advice = said
        out.dropped = dropped
        return out
    }

    /// "talked 81% of the time; usually 62 to 70% in your 1:1s with Sam" as a line and its baseline.
    static func number(_ s: CoachMeasured.Standout) -> CoachLine? {
        guard let cut = s.text.range(of: "; ") else { return nil }
        let basis = String(s.text[cut.upperBound...])
        return CoachLine(kind: .number, text: "You \(s.text[..<cut.lowerBound]).", skill: "number:\(s.id)", at: s.at,
                         number: basis.prefix(1).uppercased() + basis.dropFirst())
    }

    /// The line within `lineWords`. The quote's text goes first: its time stays and plays the moment, so the
    /// proof stays. Then the words to say.
    static func fit(_ line: CoachLine) -> CoachLine {
        var line = line
        if line.words > lineWords, line.at != nil { line.quote = nil }
        if line.words > lineWords { line.say = nil }
        return line
    }

    private static func plain(_ s: String) -> [String] {
        AdviceRules.key(s.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")).split(separator: " ").map(String.init)
    }

    /// The first words of a quote, as they are shown, and the same words as code compares them. The shown text
    /// ends at the last word that is compared: "follow-up" is two words for the check, so a cut by spaces alone
    /// could show a word that nobody checked.
    static func shown(_ quote: String) -> (text: String, words: [String]) {
        let tokens = quote.split(whereSeparator: \.isWhitespace).map(String.init)
        var words: [String] = [], kept = 0
        for token in tokens {
            let next = plain(token)
            guard words.count + next.count <= quoteWords else { break }
            words += next
            kept += 1
        }
        return (tokens.prefix(kept).joined(separator: " ") + (kept < tokens.count ? "\u{2026}" : ""), words)
    }

    /// Where the owner said the quote: the words as they are shown, and the time of their first word. Nil when
    /// the quote is under `minimumQuoteWords` words, or when no single line of the owner holds every word that
    /// is shown, in order. A paraphrase and another person's words are not proof.
    static func ownerMoment(quote: String, in r: CallRecord, owner: String) -> (quote: String, at: TimeInterval)? {
        let (text, wanted) = shown(quote)
        guard wanted.count >= minimumQuoteWords else { return nil }
        let keys = Set(r.speakerNames.filter { $0.value == owner }.keys)
        for u in r.utterances.sorted(by: { $0.start < $1.start }) where keys.contains(u.speakerKey) {
            // Each word of the line with its time: from the transcriber when it gave word times, else spread over the line.
            var said: [(word: String, at: TimeInterval)] = []
            if let words = u.words, !words.isEmpty {
                for w in words { said += plain(w.text).map { ($0, w.start) } }
            } else {
                let tokens = u.text.split(whereSeparator: \.isWhitespace)
                for (i, t) in tokens.enumerated() {
                    said += plain(String(t)).map { ($0, u.start + max(0, u.end - u.start) * Double(i) / Double(max(1, tokens.count))) }
                }
            }
            guard said.count >= wanted.count else { continue }
            for i in 0...(said.count - wanted.count) where said[i].word == wanted[0] && (0..<wanted.count).allSatisfy({ said[i + $0].word == wanted[$0] }) {
                return (text, said[i].at)
            }
        }
        return nil
    }

    private static func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
}
