import XCTest
@testable import MossadCore

/// Mossad did not hear the people of a meeting it has only the Gemini notes of, so the reads of how each person
/// thinks never come from one, and no request is sent for it.
final class PersonaNotesOnlyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func call(_ id: String, notesOnly: Bool) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        if notesOnly { r.source = CallRecord.geminiNotesSource }
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 5, text: "What do you think of the plan?"),
                        Utterance(track: .them, speakerLabel: "A", start: 6, end: 20, text: "I want the numbers first, then the plan.")]
        return r
    }

    func testANotesOnlyMeetingIsNeverDueForTheReads() {
        let records = [call("20261102-090000-notes", notesOnly: true), call("20261102-100000", notesOnly: false)]
        let due = PersonaRunner.due(records, ledger: PersonaLedger(), since: nil, saved: CoachPeople(people: []), owner: "Avery Webb")
        XCTAssertEqual(due.map(\.id), ["20261102-100000"])
    }
}
