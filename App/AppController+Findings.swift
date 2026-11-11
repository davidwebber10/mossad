import Foundation
import MossadCore

/// The findings deck: the cards that wait for an answer, the owner's answers, and the people the coach's
/// memory is linked to.
extension AppController {
    /// The saved people as of the last coach change, for reading the coach's memory by a person's id. Empty
    /// while the people store is off: the memory is then read by the name.
    var shownCoachPeople: CoachPeople {
        coachPeopleCache.value(0, version: coachVersion) { CoachPeople(people: library.identity?.people.people ?? []) }
    }

    /// The one writer of the owner's answers: off the main thread, one after the other. `changeCoachProfile`
    /// and each read of the memory from disk wait for it first, and so does the quit.
    nonisolated static let answerWriter = DispatchQueue(label: "com.dwebber.mossad.coach-answers", qos: .userInitiated)

    /// The cards of one call that wait for an answer, as of the last coach change: a page that draws on each tick
    /// of the player does not make them again.
    func findings(for record: CallRecord) -> [CoachFinding] {
        guard coachEnabled else { return [] }
        let trait = traitCards[record.id]
        return coachFindingsCache.value("\(record.id)|\(trait?.id ?? "")", version: coachVersion) {
            guard let review = shownCoachReview(record.id) else { return [] }
            return FindingRules.deck(callID: record.id, date: record.start, review: review, profile: shownCoachProfile, trait: trait)
        }
    }

    /// Reads the cards of all calls again, off the main thread: after each change of the coach's files and of
    /// the meetings. Only the calls of the last two weeks can have a card.
    func refreshFindings() {
        guard coachEnabled else {
            if !findings.isEmpty { findings = [] }
            return
        }
        let now = Date(), paths = paths, profile = shownCoachProfile, saved = personaPeople, personas = personasOn
        let recent = meetings.filter { $0.status == .written && now.timeIntervalSince($0.start) <= FindingRules.expiryDays * 86_400 }.map { ($0.id, $0.start) }
        findingsAsk += 1
        let ask = findingsAsk
        Task {
            let (cards, reads, traits) = await Task.detached(priority: .utility) {
                // The reads of how people think, and the trait card of each call: from the files, off the main thread.
                let reads = personas ? PersonaReads.all(paths: paths, saved: saved, answers: profile.answers) : [:]
                let traits = personas ? PersonaFindings.cards(PersonaReads.sources(paths: paths, saved: saved, answers: profile.answers),
                                                              calls: recent.map { (callID: $0.0, date: $0.1) }, profile: profile, now: now,
                                                              quote: { PersonaReads.words($0, paths: paths) }) : [:]
                let cards = FindingRules.deck(reviews: recent.compactMap { id, start in
                    CoachReview.load(in: paths.callDirectory(id)).map { (callID: id, date: start, review: $0) }
                }, profile: profile, now: now, traits: traits)
                return (cards, reads, traits)
            }.value
            // A later ask is newer: its cards win.
            guard ask == findingsAsk else { return }
            if reads != personaReads { personaReads = reads }
            traitCards = traits
            if cards != findings { findings = cards }
        }
    }

    /// Saves the owner's answer to a card: in the coach's memory, and next to the call's review.
    func answerFinding(_ finding: CoachFinding, _ verdict: FindingVerdict) {
        let now = Date()
        changeFindings(callID: finding.callID) { $0.answer(finding, verdict, at: now) }
    }

    /// Undo in the deck.
    func takeBackFinding(_ id: String) {
        let now = Date()
        changeFindings(callID: callID(ofAnswer: id)) { $0.takeBack(id, at: now) }
    }

    /// Undo in the list of what was blocked for good: on a goal it only takes the block away.
    func allowFindingAgain(_ id: String) {
        let now = Date()
        changeFindings(callID: callID(ofAnswer: id)) { $0.allowAgain(id, at: now) }
    }

    /// Why the owner said no to a card: guidance for that card, read by the coach in later reviews.
    func explainFinding(_ id: String, note: String) {
        let now = Date()
        changeFindings(callID: callID(ofAnswer: id)) { $0.explain(id, note: note, at: now) }
    }

    private func callID(ofAnswer id: String) -> String? { shownCoachProfile.answers.first { $0.id == id }?.callID }

    /// The change shows at once: the memory in view is changed in memory, and the next card rises in the same
    /// frame. The file is read, changed, and saved by the writer, off the main thread, with the call's own copy.
    private func changeFindings(callID: String?, _ change: @escaping @Sendable (inout CoachProfile) -> Void) {
        var shown = shownCoachProfile
        change(&shown)
        let next = coachVersion + 1
        coachProfileCache.set(0, version: next, value: shown)
        coachVersion = next
        let paths = paths
        Self.answerWriter.async {
            do {
                var profile = try CoachProfile.load(from: paths.coach)
                let before = profile
                change(&profile)
                if profile != before { try profile.save(to: paths.coach) }
                if let callID { FindingStore.mirror(profile.answers, callID: callID, paths: paths) }
            } catch {
                Log.error("Saving the coach's memory failed: \(error)")
            }
            Task { @MainActor in self.syncNow() }
        }
    }

    /// Gives the coach's notes on people, its conclusions, and the facts the id of their person, where the people
    /// store is in step and the name is one saved person on a sure match. It changes nothing when there is
    /// nothing new to link.
    func linkCoachPeople() {
        guard !isInert, coachEnabled, meetingsLoaded, let people = library.identity?.people.people, !people.isEmpty else { return }
        let records = meetings
        do {
            var linked = 0
            if try changeCoachProfile({ linked = $0.linkPeople(CoachPeople(people: people), records: records) }) {
                Log.info("The coach's memory: \(linked) \(linked == 1 ? "entry is" : "entries are") linked to a saved person")
                coachVersion += 1
            }
        } catch { Log.error("The coach's memory was not linked to the people: \(error)") }
    }
}
