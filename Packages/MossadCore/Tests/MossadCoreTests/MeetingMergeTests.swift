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
        ], names: ["me:A": "David Webber", "them:A": "Mitch"])
        let second = record("two", start: 203, end: 500, [
            Utterance(track: .me, speakerLabel: "B", start: 2, end: 5, text: "Back."),
            Utterance(track: .them, speakerLabel: "A", start: 6, end: 8, text: "Who is this?"),
        ], names: ["me:B": "David Webber"], unknown: ["them:A"])

        let merged = MeetingMerge.combine([second, first], durations: ["one": 200, "two": 297])

        XCTAssertEqual(merged.id, "one")
        XCTAssertEqual(merged.start, t0)
        XCTAssertEqual(merged.end, t0.addingTimeInterval(500))
        XCTAssertEqual(merged.utterances.map(\.start), [1, 4, 202, 206])
        XCTAssertEqual(merged.utterances.map(\.speakerKey), ["me:A", "them:A", "me:B2", "them:A2"])
        XCTAssertEqual(merged.speakerNames, ["me:A": "David Webber", "them:A": "Mitch", "me:B2": "David Webber"])
        XCTAssertEqual(merged.unknownSpeakers, ["them:A2"])
        XCTAssertEqual(merged.parts, [CallPart(start: t0, end: t0.addingTimeInterval(200), offset: 0),
                                      CallPart(start: t0.addingTimeInterval(203), end: t0.addingTimeInterval(500), offset: 200)])
        XCTAssertNil(merged.summary)
        XCTAssertEqual(merged.status, .identified)
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
