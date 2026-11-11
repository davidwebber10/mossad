import Foundation

/// Turns what the model wrote about one call into what the owner sees: one line or nothing. Code decides, so
/// the rules hold whatever the model sends:
///
/// 1. Proof. Advice and praise need the owner's own words, found in the transcript at their time. A number
///    needs its baseline. Without proof a note is dropped.
/// 2. No repeats. What was said in the last 30 days is not said again (`AdviceRules`). A call that shows it
///    again is counted, with its moment; after enough calls and days the count is a line, not the advice.
/// 3. One. The first of: the result on the accepted focus, a measured trend, new advice, a count that is due,
///    a number that is not usual, something done well.
public enum CoachLineRules {
    /// A quote is the proof, not the review: it shows this many words at most.
    public static let quoteWords = 12

    public static func settle(_ result: CoachResult, record r: CallRecord, owner: String, profile: CoachProfile, measured: CoachMeasured) -> CoachResult {
        var out = result
        var review = result.review
        var said: [CoachAdvice] = []
        var unproven = 0
        let log = profile.advice

        /// The note with the owner's line that holds its quote; nil when code cannot find one.
        func proven(_ note: CoachNote?) -> CoachNote? {
            guard var note else { return nil }
            guard let quote = note.quote?.nonBlank, let line = CommitmentFinder.ownerLine(quote: quote, at: note.at, in: r, owner: owner) else {
                unproven += 1
                return nil
            }
            note.quote = clip(quote)
            note.at = line.start
            if note.measure == .commitmentDay { note.number = measured.commitments?.text }
            return note
        }
        func earlier(_ kind: CoachLine.Kind, _ note: CoachNote) -> CoachAdvice? {
            AdviceRules.earlier(kind: kind, skill: note.skill ?? "", text: note.text, measure: note.measure, in: log, callID: r.id, date: r.start)
        }

        review.didWell = proven(review.didWell)
        review.tryNext = proven(review.tryNext)
        review.seenAgain = proven(review.seenAgain)

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
            let name = first.skill.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            note.text = name
            note.skill = first.skill
            note.measure = first.measure ?? note.measure
            note.say = nil
            note.number = note.measure == .commitmentDay ? measured.commitments?.text : nil
            review.seenAgain = note
            let count = AdviceRules.again(after: first, in: log, callID: r.id, date: r.start)
            if count.due {
                again = CoachLine(kind: .again, text: "\(name): \(count.calls) more calls since \(day(first.date)) showed it.", skill: first.skill,
                                  quote: note.quote, at: note.at, number: note.number, measure: note.measure)
            }
        } else {
            // Nothing like it was said in the last 30 days: there is nothing to see again.
            review.seenAgain = nil
        }

        var candidates: [CoachLine] = []
        if let focus = profile.activeFocus, review.focusID == focus.id, let result = review.focusResult, result.outcome != .noChance {
            let chances = focus.chances.filter { $0.callID != r.id } + [result]
            var number = "\(chances.filter { $0.outcome == .hit }.count) of \(chances.count) chances"
            if focus.measure == .commitmentDay, let share = measured.commitments { number += ". \(share.text)" }
            let length = max(r.end.timeIntervalSince(r.start), r.utterances.map(\.end).max() ?? 0)
            candidates.append(CoachLine(kind: .focus, text: result.evidence, skill: focus.plan, at: result.at.flatMap { $0 >= 0 && $0 <= length ? $0 : nil },
                                        number: number, measure: focus.measure, outcome: result.outcome))
        }
        if let trend = measured.trend {
            candidates.append(CoachLine(kind: .progress, text: trend.text, skill: "progress:\(trend.id)", number: trend.proof))
        }
        if let note = review.tryNext { candidates.append(CoachLine(kind: .tryNext, note: note)) }
        if let again { candidates.append(again) }
        candidates += measured.standouts.compactMap(number)
        if let note = review.didWell { candidates.append(CoachLine(kind: .didWell, note: note)) }

        let line = candidates.first { c in
            guard c.hasProof else { return false }
            // The notes and the count passed the log above; a number and a trend are checked here.
            guard c.kind == .number || c.kind == .progress else { return true }
            return AdviceRules.earlier(kind: c.kind, skill: c.skill, text: c.text, measure: nil, in: log, callID: r.id, date: r.start) == nil
        }
        review.line = line
        review.version = CoachReview.currentVersion

        // The log keeps what the review says: its line, and the advice and praise that wait in the full review.
        if let note = review.tryNext { said.append(CoachAdvice(CoachLine(kind: .tryNext, note: note), callID: r.id, date: r.start)) }
        if let note = review.didWell { said.append(CoachAdvice(CoachLine(kind: .didWell, note: note), callID: r.id, date: r.start)) }
        if let line, line.kind != .tryNext, line.kind != .didWell { said.append(CoachAdvice(line, callID: r.id, date: r.start)) }
        if let note = review.seenAgain, line?.kind != .again {
            said.append(CoachAdvice(callID: r.id, date: r.start, kind: .again, skill: note.skill ?? note.text, text: note.text, at: note.at,
                                    measure: note.measure, held: true))
        }

        // A pattern's moment is kept only as the owner's own words.
        out.update.patterns = result.update.patterns.map { p in
            var p = p
            if let quote = p.quote?.nonBlank, let line = CommitmentFinder.ownerLine(quote: quote, at: p.at, in: r, owner: owner) {
                p.quote = clip(quote)
                p.at = line.start
            } else {
                p.quote = nil
                p.at = nil
            }
            return p
        }
        out.review = review
        out.advice = said
        out.unproven = unproven
        return out
    }

    /// "talked 81% of the time; usually 62 to 70% in your 1:1s with Sam" as a line and its baseline.
    static func number(_ s: CoachMeasured.Standout) -> CoachLine? {
        guard let cut = s.text.range(of: "; ") else { return nil }
        let basis = String(s.text[cut.upperBound...])
        return CoachLine(kind: .number, text: "You \(s.text[..<cut.lowerBound]).", skill: "number:\(s.id)", at: s.at,
                         number: basis.prefix(1).uppercased() + basis.dropFirst())
    }

    static func clip(_ quote: String) -> String {
        let words = quote.split(whereSeparator: \.isWhitespace)
        return words.count <= quoteWords ? quote : words.prefix(quoteWords).joined(separator: " ") + "…"
    }

    private static func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
}
