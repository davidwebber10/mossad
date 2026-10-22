import XCTest
@testable import MossadCore

final class SyncTests: XCTestCase {
    private func meeting(_ id: String, status: CallStatus = .written) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_001_800), status: status)
        r.calendarTitle = "Launch sync"
        r.speakerNames = ["me:A": "David Webber"]
        r.speakerEmbeddings = ["me:A": [0.1, 0.2]]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 1, end: 2, text: "Hi.", words: [Word(text: "Hi.", start: 1, end: 2)])]
        r.meUtterances = r.utterances
        r.headline = "H"
        r.tags = ["Budget"]
        return r
    }

    func testThePayloadDropsWhatThePhoneDoesNotNeed() throws {
        let payload = SyncPayload(record: meeting("a"), coach: nil)
        let r = try JSONDecoder.callRecord.decode(CallRecord.self, from: payload.record)
        XCTAssertTrue(r.speakerEmbeddings.isEmpty)
        XCTAssertNil(r.meUtterances)
        XCTAssertNil(r.utterances.first?.words)
        XCTAssertEqual(r.utterances.first?.text, "Hi.")
        XCTAssertEqual(payload.fields.title, "Launch sync")
        XCTAssertEqual(payload.fields.tags, ["Budget"])
    }

    func testOnlyChangedFinishedMeetingsUploadAndMissingOnesAreDeleted() {
        let a = SyncPayload(record: meeting("a"), coach: nil)
        var changed = meeting("b")
        let b = SyncPayload(record: changed, coach: nil)
        var state = SyncState()
        state.uploaded = ["a": a.hash, "b": b.hash, "gone": "x"]
        changed.headline = "New headline"
        let plan = state.plan([a, SyncPayload(record: changed, coach: nil), SyncPayload(record: meeting("c"), coach: nil)])
        XCTAssertEqual(plan.upload.map(\.id).sorted(), ["b", "c"])
        XCTAssertEqual(plan.delete, ["gone"])
    }

    func testRecordingsAreNotSyncedUntilWritten() {
        XCTAssertFalse(SyncPayload.isSyncable(meeting("r", status: .recording)))
        XCTAssertFalse(SyncPayload.isSyncable(meeting("p", status: .transcribed)))
        XCTAssertTrue(SyncPayload.isSyncable(meeting("w")))
    }

    func testACoachReviewChangesTheHash() {
        let without = SyncPayload(record: meeting("a"), coach: nil)
        let with = SyncPayload(record: meeting("a"), coach: CoachReview(headline: "C", overview: "O", strengths: [], improvements: [], focusProgress: nil))
        XCTAssertNotEqual(without.hash, with.hash)
    }

    func testStateRoundTrips() throws {
        let dir = tempDirectory()
        var state = SyncState()
        state.uploaded = ["a": "h"]
        state.changeToken = Data([1, 2])
        try state.save(to: dir)
        XCTAssertEqual(try SyncState.load(from: dir), state)
        XCTAssertEqual(try SyncState.load(from: dir.appendingPathComponent("none")), SyncState())
    }
}
