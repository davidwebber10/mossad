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

    /// The cards of one call that wait for an answer.
    func findings(for record: CallRecord) -> [CoachFinding] {
        guard coachEnabled, let review = shownCoachReview(record.id) else { return [] }
        return FindingRules.deck(callID: record.id, date: record.start, review: review, profile: shownCoachProfile)
    }

    /// Reads the cards of all calls again, off the main thread: after each change of the coach's files and of
    /// the meetings. Only the calls of the last two weeks can have a card.
    func refreshFindings() {
        guard coachEnabled else {
            if !findings.isEmpty { findings = [] }
            return
        }
        let now = Date(), paths = paths, profile = shownCoachProfile
        let recent = meetings.filter { $0.status == .written && now.timeIntervalSince($0.start) <= FindingRules.expiryDays * 86_400 }.map { ($0.id, $0.start) }
        findingsAsk += 1
        let ask = findingsAsk
        Task {
            let cards = await Task.detached(priority: .utility) {
                FindingRules.deck(reviews: recent.compactMap { id, start in
                    CoachReview.load(in: paths.callDirectory(id)).map { (callID: id, date: start, review: $0) }
                }, profile: profile, now: now)
            }.value
            // A later ask is newer: its cards win.
            if ask == findingsAsk, cards != findings { findings = cards }
        }
    }

    /// Saves the owner's answer to a card: in the coach's memory, and next to the call's review.
    func answerFinding(_ finding: CoachFinding, _ verdict: FindingVerdict) {
        changeFindings { $0.answer(finding, verdict, at: Date()) }
    }

    /// Undo in the deck, and "Allow again" in Settings.
    func takeBackFinding(_ id: String) {
        changeFindings { $0.takeBack(id, at: Date()) }
    }

    /// Why the owner said no to a card: guidance for that card, read by the coach in later reviews.
    func explainFinding(_ id: String, note: String) {
        changeFindings { $0.explain(id, note: note, at: Date()) }
    }

    private func changeFindings(_ change: (inout CoachProfile) -> Void) {
        do {
            try changeCoachProfile(change)
            let answers = coachProfile.answers, paths = paths
            Task.detached(priority: .utility) { FindingStore.mirror(answers, paths: paths) }
        } catch { Log.error("Saving the coach's memory failed: \(error)") }
        coachVersion += 1
        syncNow()
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
