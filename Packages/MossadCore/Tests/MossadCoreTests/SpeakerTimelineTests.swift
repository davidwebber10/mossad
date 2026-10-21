import XCTest
@testable import MossadCore

final class SpeakerTimelineTests: XCTestCase {
    func record(_ utterances: [Utterance]) -> CallRecord {
        var r = CallRecord(id: "x", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 0),
                           end: Date(timeIntervalSince1970: 600), status: .written)
        r.utterances = utterances
        r.speakerNames = ["me:A": "David Webber"]
        return r
    }

    func u(_ track: Track, _ label: String, _ start: TimeInterval, _ end: TimeInterval) -> Utterance {
        Utterance(track: track, speakerLabel: label, start: start, end: end, text: "t")
    }

    func testMergesShortGapsAndKeepsRealGaps() {
        let r = record([u(.me, "A", 0, 5), u(.me, "A", 6, 10), u(.me, "A", 20, 25), u(.them, "B", 25.5, 30)])
        XCTAssertEqual(SpeakerTimeline.segments(r), [
            SpeakerSegment(speakerKey: "me:A", speaker: "David Webber", start: 0, end: 10),
            SpeakerSegment(speakerKey: "me:A", speaker: "David Webber", start: 20, end: 25),
            SpeakerSegment(speakerKey: "them:B", speaker: "Speaker A", start: 25.5, end: 30),
        ])
    }

    func testAnotherSpeakerBreaksTheRun() {
        let r = record([u(.me, "A", 0, 5), u(.them, "B", 5, 6), u(.me, "A", 6, 10)])
        XCTAssertEqual(SpeakerTimeline.segments(r).map(\.speakerKey), ["me:A", "them:B", "me:A"])
    }

    func testMergeGapIsAdjustableAndOrderIsByStart() {
        let r = record([u(.me, "A", 20, 25), u(.me, "A", 0, 5)])
        XCTAssertEqual(SpeakerTimeline.segments(r, mergeGap: 30).map(\.end), [25])
        XCTAssertEqual(SpeakerTimeline.segments(r).map(\.start), [0, 20])
    }

    func testEmptyRecordHasNoSegments() {
        XCTAssertEqual(SpeakerTimeline.segments(record([])), [])
    }
}
