import Foundation

/// Makes the cards from what the coach already produced for a call, with no request to a model: the line, the
/// notes of the full review, the numbers that stood out, the patterns the call showed, the conclusions the coach
/// asks the owner to confirm, and the focus it proposes.
///
/// 1. Proof. Each card has a moment to play or a number with its usual value. Without one it is not made.
/// 2. Few. A call gives `perCall` cards at most, and an answer makes no room for one more. The deck of all
///    calls shows `deckLimit` at most: a short deck, never a backlog.
/// 3. Not for long. A card with no answer goes `expiryDays` after its call. A review from before the cards
///    gives cards only for `seedDays`, so the first launch does not start with weeks of cards.
/// 4. What the owner blocked is not made, and what the owner said no to a few times comes last.
public enum FindingRules {
    public static let perCall = 2
    public static let expiryDays = 14.0
    public static let seedDays = 7.0
    /// The most cards the deck of all calls shows. The newest calls come first; the others wait their turn or go.
    public static let deckLimit = 10

    public static func expires(_ finding: CoachFinding) -> Date { finding.date.addingTimeInterval(expiryDays * 86_400) }

    /// Whether a number that is above or below its usual is good or bad. Nil when it is neither: the card is
    /// then not made. More talk in a 1:1 leaves the other person less room; in a group it says nothing.
    static func kind(ofNumber id: String, above: Bool?, oneOnOne: Bool) -> CoachFinding.Kind? {
        guard let above else { return nil }
        switch id {
        case PersonMetric.talkShare.rawValue: return oneOnOne ? (above ? .couldBeBetter : .didWell) : nil
        case PersonMetric.longestTurn.rawValue, PersonMetric.averageTurn.rawValue, PersonMetric.cutInsPerHour.rawValue: return above ? .couldBeBetter : .didWell
        default: return nil
        }
    }

    private static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// The first words of a card's text, to name the card in one line: "Why didn't you agree with ...?".
    public static func shortTitle(_ text: String, words limit: Int = 6) -> String {
        let all = text.split(whereSeparator: \.isWhitespace)
        let cut = all.prefix(limit).joined(separator: " ")
        let trimmed = cut.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        return all.count > limit ? trimmed + "\u{2026}" : trimmed
    }

    /// The cards one review gives about how the owner acted, the line's card first. `measured` and `observations`
    /// are there when the review is made; a review from before the cards gives only what its file holds.
    static func cards(review: CoachReview, callID: String, date: Date, measured: CoachMeasured?, observations: [CoachObservation] = [],
                      training: CoachTraining = CoachTraining()) -> [CoachFinding] {
        var out: [CoachFinding] = []
        func add(_ kind: CoachFinding.Kind?, text: String, skill: String, quote: String? = nil, at: TimeInterval? = nil, number: String? = nil,
                 usual: String? = nil, say: String? = nil) {
            guard let kind, let text = text.nonBlank, !skill.isEmpty, !training.isBlocked(skill) else { return }
            let card = CoachFinding(id: "\(callID)|\(kind.rawValue)|\(skill)", callID: callID, date: date, kind: kind, text: text, skill: skill,
                               quote: quote?.nonBlank, at: at, number: number?.nonBlank, usual: usual?.nonBlank, say: say?.nonBlank)
            guard card.hasProof, !out.contains(where: { $0.id == card.id }) else { return }
            out.append(card)
        }
        func number(_ id: String) -> CoachFinding.Kind? {
            guard let measured, let s = measured.standouts.first(where: { $0.id == id }) else { return nil }
            return kind(ofNumber: id, above: s.above, oneOnOne: measured.oneOnOne)
        }
        func add(_ line: CoachLine) {
            switch line.kind {
            case .focus:
                add(line.outcome == .hit ? .didWell : line.outcome == .missed ? .missed : nil, text: line.text, skill: line.skill, quote: line.quote, at: line.at,
                    number: line.number)
            case .progress:
                // "You talked 48% in your last 5 with Sam; 62 to 70% in the 10 before."
                let parts = (line.number ?? "").components(separatedBy: "; ")
                add(.didWell, text: line.text, skill: line.skill, number: parts.first, usual: parts.count > 1 ? parts[1] : nil)
            case .tryNext:
                add(.couldBeBetter, text: line.text, skill: line.skill, quote: line.quote, at: line.at, number: line.number, say: line.say)
            case .again:
                add(.missed, text: line.text, skill: line.skill, quote: line.quote, at: line.at, number: line.number)
            case .number:
                let id = line.skill.hasPrefix("number:") ? String(line.skill.dropFirst(7)) : line.skill
                add(number(id), text: line.text, skill: line.skill, at: line.at, usual: line.number)
            case .didWell:
                add(.didWell, text: line.text, skill: line.skill, quote: line.quote, at: line.at, number: line.number)
            }
        }

        let line = review.shownLine
        if let line { add(line) }
        for other in review.others { add(other) }
        if line?.kind != .focus, let r = review.focusResult, r.quote != nil, let id = review.focusID {
            add(r.outcome == .hit ? .didWell : r.outcome == .missed ? .missed : nil, text: r.evidence, skill: "focus:\(id.uuidString)", quote: r.quote, at: r.at)
        }
        for s in measured?.standouts ?? [] {
            guard let l = CoachLineRules.number(s) else { continue }
            add(l)
        }
        // A pattern the call showed, with the owner's words. Not at the moment of a card that is there.
        for o in observations {
            guard let at = o.at, o.quote != nil, words(o.note) <= CoachLineRules.textWords, !CoachLineRules.judgesTrend(o.note),
                  !out.contains(where: { $0.at.map { abs($0 - at) < 1 } == true }) else { continue }
            add(o.result == .did ? .didWell : .missed, text: o.note, skill: "pattern:" + AdviceRules.key(o.pattern), quote: o.quote, at: at)
        }
        return out
    }

    /// The cards of one call that wait for an answer, in the order of the deck: the offered goal, the line's
    /// card, what the coach asks the owner to confirm, then the rest, with a skill the owner said no to a few
    /// times last.
    public static func deck(callID: String, date: Date, review: CoachReview, profile: CoachProfile, now: Date = Date()) -> [CoachFinding] {
        guard now.timeIntervalSince(date) <= (review.findings == nil ? seedDays : expiryDays) * 86_400 else { return [] }
        let training = profile.training(asOf: now)
        var base = (review.findings ?? cards(review: review, callID: callID, date: date, measured: nil,
                                             observations: profile.observations.filter { $0.callID == callID }))
            .filter { $0.kind.isKnown && $0.hasProof && !training.isBlocked($0.skill) }

        var head: [CoachFinding] = []
        // The focus that the coach proposed from this call, with the moment of this call that shows its skill.
        if let focus = profile.proposedFocus, abs(focus.proposed.timeIntervalSince(date)) < 1, !training.isGoalBlocked(focus.skillID),
           let proof = base.first(where: { $0.at != nil && AdviceRules.key($0.skill) == AdviceRules.key(focus.skillID) }) {
            head.append(CoachFinding(id: "\(callID)|\(CoachFinding.Kind.goalOffer.rawValue)|\(focus.id.uuidString)", callID: callID, date: date, kind: .goalOffer, text: focus.plan,
                                skill: focus.skillID, detail: focus.why.nonBlank, quote: proof.quote, at: proof.at, focusID: focus.id))
            // The offer stands for the advice about its skill.
            base.removeAll { $0.kind != .didWell && AdviceRules.key($0.skill) == AdviceRules.key(focus.skillID) }
        }
        if let line = review.shownLine, let first = base.first, first.skill == line.skill { head.append(base.removeFirst()) }
        for q in profile.questions where q.status == .open && q.callID == callID {
            guard let at = q.at, let quote = q.evidence.nonBlank, let text = q.statement.nonBlank else { continue }
            head.append(CoachFinding(id: "\(callID)|\(CoachFinding.Kind.learning.rawValue)|\(q.id.uuidString)", callID: callID, date: date, kind: .learning, text: text, skill: "",
                                quote: quote, at: at, questionID: q.id, person: q.person, personName: q.personName))
        }
        let all = head + base.filter { !training.isLowered($0.skill) } + base.filter { training.isLowered($0.skill) }
        return all.prefix(perCall).filter { card in
            if card.kind == .learning, let q = profile.questions.first(where: { $0.id == card.questionID }), q.dismissed != nil { return false }
            return profile.answer(to: card.id) == nil
        }
    }

    /// "No, never again" is not offered on a card of the active focus: the owner would block the skill they
    /// chose to work on, and the coach would get two orders. Ending the focus is the way.
    public static func offersNever(_ card: CoachFinding, profile: CoachProfile) -> Bool {
        guard let focus = profile.activeFocus else { return true }
        return card.skill != "focus:\(focus.id.uuidString)" && AdviceRules.key(card.skill) != AdviceRules.key(focus.skillID)
    }

    /// The cards of all calls that wait for an answer, the newest call first.
    public static func deck(reviews: [(callID: String, date: Date, review: CoachReview)], profile: CoachProfile, now: Date = Date()) -> [CoachFinding] {
        Array(reviews.sorted { $0.date > $1.date }.flatMap { deck(callID: $0.callID, date: $0.date, review: $0.review, profile: profile, now: now) }.prefix(deckLimit))
    }
}
