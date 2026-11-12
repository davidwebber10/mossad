import XCTest
@testable import MossadCore

final class MeetingMergeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ id: String, start: TimeInterval, end: TimeInterval, _ utterances: [Utterance], names: [String: String] = [:],
                unknown: [String] = []) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: t0.addingTimeInterval(start),
                           end: t0.addingTimeInterval(end), status: .written)
        r.utterances = utterances
        r.speakerNames = names
        r.unknownSpeakers = unknown
        r.meetingID = "abc-defg-hij"
        r.summary = "old"
        return r
    }

    func testCombinesTimesSpeakersAndParts() {
        let first = record("one", start: 0, end: 200, [
            Utterance(track: .me, speakerLabel: "A", start: 1, end: 3, text: "Hi."),
            Utterance(track: .them, speakerLabel: "A", start: 4, end: 6, text: "Hello."),
        ], names: ["me:A": "Avery Lane", "them:A": "Jordan"])
        let second = record("two", start: 203, end: 500, [
            Utterance(track: .me, speakerLabel: "B", start: 2, end: 5, text: "Back."),
            Utterance(track: .them, speakerLabel: "A", start: 6, end: 8, text: "Who is this?"),
        ], names: ["me:B": "Avery Lane"], unknown: ["them:A"])

        let merged = MeetingMerge.combine([second, first], durations: ["one": 200, "two": 297])

        XCTAssertEqual(merged.id, "one")
        XCTAssertEqual(merged.start, t0)
        XCTAssertEqual(merged.end, t0.addingTimeInterval(500))
        XCTAssertEqual(merged.utterances.map(\.start), [1, 4, 202, 206])
        XCTAssertEqual(merged.utterances.map(\.speakerKey), ["me:A", "them:A", "me:B2", "them:A2"])
        XCTAssertEqual(merged.speakerNames, ["me:A": "Avery Lane", "them:A": "Jordan", "me:B2": "Avery Lane"])
        XCTAssertEqual(merged.unknownSpeakers, ["them:A2"])
        XCTAssertEqual(merged.parts, [CallPart(start: t0, end: t0.addingTimeInterval(200), offset: 0),
                                      CallPart(start: t0.addingTimeInterval(203), end: t0.addingTimeInterval(500), offset: 200)])
        XCTAssertNil(merged.summary)
        XCTAssertEqual(merged.status, .identified)
    }

    /// A call split two times: B joins A, then C joins the joined record. C's "A" must not take B's key.
    func testAThirdPartJoinedLaterKeepsEveryVoiceApart() {
        func part(_ id: String, _ start: TimeInterval, _ name: String?) -> CallRecord {
            var r = record(id, start: start, end: start + 100, [Utterance(track: .them, speakerLabel: "A", start: 1, end: 3, text: id)],
                           names: name.map { ["them:A": $0] } ?? [:], unknown: name == nil ? ["them:A"] : [])
            r.speakerEmbeddings = ["them:A": [Float(start)]]
            return r
        }
        let durations: [String: TimeInterval] = ["one": 100, "two": 100, "three": 100]
        let ab = MeetingMerge.combine([part("one", 0, "Sam Carter"), part("two", 103, "Dana Lee")], durations: durations)
        let abc = MeetingMerge.combine([ab, part("three", 206, nil)], durations: ["one": 200, "three": 100])

        XCTAssertEqual(abc.utterances.map(\.speakerKey), ["them:A", "them:A2", "them:A3"])
        XCTAssertEqual(abc.speakerNames, ["them:A": "Sam Carter", "them:A2": "Dana Lee"])
        XCTAssertEqual(abc.unknownSpeakers, ["them:A3"])
        XCTAssertEqual(abc.speakerEmbeddings.count, 3)
        XCTAssertEqual(abc.parts.count, 3)

        // A joined record that comes second moves its own part numbers too.
        let later = MeetingMerge.combine([part("zero", -200, "Alex Rivera"), ab.with { $0.id = "one" }], durations: ["zero": 100, "one": 200])
        XCTAssertEqual(later.speakerNames, ["them:A": "Alex Rivera", "them:A2": "Sam Carter", "them:A3": "Dana Lee"])
    }

    /// The joined recording is a new file: the old upload does not hold it.
    func testTheJoinedRecordIsNotArchivedYet() {
        var first = record("one", start: 0, end: 200, [])
        first.cloudKey = "calls/one/recording.m4a"
        first.cloudSize = 100
        first.summaryMissing = true
        let merged = MeetingMerge.combine([first, record("two", start: 203, end: 500, [])], durations: ["one": 200, "two": 297])
        XCTAssertNil(merged.cloudKey)
        XCTAssertNil(merged.cloudSize)
        XCTAssertNil(merged.summaryMissing)
        XCTAssertEqual(merged.cloudLeftovers, [ArchivedObject(key: "calls/one/recording.m4a", kind: .bucket)], "the old upload goes once the joined recording is safe")
        // On the owner's server too, and the place's name does not stay on a record with no archived copy.
        first.cloudKey = "recordings/one/recording.m4a"
        first.cloudBackend = "server"
        let onServer = MeetingMerge.combine([first, record("two", start: 203, end: 500, [])], durations: ["one": 200, "two": 297])
        XCTAssertNil(onServer.cloudBackend)
        XCTAssertEqual(onServer.cloudLeftovers, [ArchivedObject(key: "recordings/one/recording.m4a", kind: .server)])
    }

    func testBookmarkNotesMoveWithTheirPart() {
        let first = record("one", start: 0, end: 200, [])
        var second = record("two", start: 203, end: 500, [])
        second.markers = [TranscriptMarker(offset: 10, text: "★ Bookmarked at 3:00 PM", isBookmark: true, note: "Ask Alex")]
        let merged = MeetingMerge.combine([first, second], durations: ["one": 200, "two": 297])
        XCTAssertEqual(merged.markers.first?.note, "Ask Alex")
    }

    func testBookmarksMoveWithTheirPartAndStayBookmarks() {
        let first = record("one", start: 0, end: 200, [])
        var second = record("two", start: 203, end: 500, [])
        second.markers = [TranscriptMarker(offset: 10, text: "★ Bookmarked at 3:00 PM", isBookmark: true)]
        let merged = MeetingMerge.combine([first, second], durations: ["one": 200, "two": 297])
        XCTAssertEqual(merged.markers, [TranscriptMarker(offset: 210, text: "★ Bookmarked at 3:00 PM", isBookmark: true)])
    }

    func testResumeLineSaysHowLongTheGapWas() {
        var r = record("one", start: 0, end: 500, [])
        r.parts = [CallPart(start: t0, end: t0.addingTimeInterval(200), offset: 0),
                   CallPart(start: t0.addingTimeInterval(203), end: t0.addingTimeInterval(500), offset: 200)]
        let breaks = MeetingMerge.partBreaks(r)
        XCTAssertEqual(breaks.map(\.offset), [200])
        XCTAssertTrue(breaks[0].text.hasPrefix("Recording resumed at "), breaks[0].text)
        XCTAssertTrue(breaks[0].text.hasSuffix(", 3 s later"), breaks[0].text)
    }

    func testJoinsAudioAndFillsMissingPartsWithSilence() throws {
        let dir = tempDirectory()
        let a = dir.appendingPathComponent("a.caf"), b = dir.appendingPathComponent("b.caf")
        try writeSegments(a, total: 2, [(0, 2, 400)])
        try writeSegments(b, total: 3, [(0, 3, 400)])
        let out = dir.appendingPathComponent("out.caf")
        try AudioJoin.join([a, nil, b], durations: [2, 1.5, 3], to: out)
        XCTAssertEqual(try audioDuration(out), 6.5, accuracy: 0.05)
        XCTAssertLessThan(try AudioSamples.read(out, from: 2.2, to: 3.3).map(abs).max() ?? 1, 0.01)
    }
}

private extension CallRecord {
    func with(_ change: (inout CallRecord) -> Void) -> CallRecord {
        var copy = self
        change(&copy)
        return copy
    }
}
