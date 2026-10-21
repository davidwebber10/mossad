import XCTest
@testable import MossadCore

final class SoundTimelineTests: XCTestCase {
    /// 20 ms frames: `on` lists the sounding seconds as (start, end).
    func timeline(seconds: Double, on: [(Double, Double)]) -> SoundTimeline {
        let frames = (0..<Int(seconds / 0.02)).map { i -> Float in
            let t = Double(i) * 0.02
            return on.contains { t >= $0.0 && t < $0.1 } ? 0.05 : 0.0005
        }
        return SoundTimeline(frameRMS: frames)
    }

    func testHangoverBridgesAShortGap() {
        let t = timeline(seconds: 10, on: [(2, 3), (3.1, 4)])
        XCTAssertEqual(t.sound(from: 2, to: 4), 2, accuracy: 0.05)
    }

    func testOverlapAndCoverage() {
        let t = timeline(seconds: 10, on: [(2, 3)])
        XCTAssertEqual(t.sound(from: 0, to: 10), 1.4, accuracy: 0.05)  // 1 s plus 200 ms either side
        XCTAssertEqual(t.coverage, 0.14, accuracy: 0.01)
        XCTAssertEqual(t.sound(from: 5, to: 6), 0)
    }

    func testMeasuresAFile() throws {
        let url = tempDirectory().appendingPathComponent("them.caf")
        try writeSegments(url, total: 6, [(2, 3, 400)])
        let t = try SoundTimeline.measure(url: url)
        XCTAssertEqual(t.sound(from: 0, to: 6), 1.4, accuracy: 0.1)
        XCTAssertEqual(t.sound(from: 1.7, to: 3.3), 1.4, accuracy: 0.1)
    }
}

final class EchoLabelTests: XCTestCase {
    func u(_ label: String, _ start: Double, _ end: Double, _ text: String = "Yeah.") -> Utterance {
        Utterance(track: .me, speakerLabel: label, start: start, end: end, text: text)
    }

    /// The call audio has sound in these ranges over a 100 s call.
    func sound(_ on: [(Double, Double)], seconds: Double = 100) -> SoundTimeline {
        SoundTimeline(frameRMS: (0..<Int(seconds / 0.02)).map { i in
            let t = Double(i) * 0.02
            return on.contains { t >= $0.0 && t < $0.1 } ? 0.05 : 0.0005
        })
    }

    func testDropsMicLabelHeardOnlyDuringTheirSound() {
        let me = [u("A", 0, 10, "I think we should ship it on Friday then."), u("B", 21, 22, "Yeah."), u("B", 31, 34, "Good morning, David.")]
        let echo = TranscriptMerger.echoLabels(me: me, themSound: sound([(20, 40)]))
        XCTAssertEqual(echo, ["B"])
        let merged = TranscriptMerger.merge(me: me, them: [], themSound: sound([(20, 40)]))
        XCTAssertEqual(merged.map(\.speakerLabel), ["A"])
    }

    func testKeepsOwnerBackchannelDuringTheirSpeech() {
        // The owner talks mostly while they are quiet, and also says "Yeah." while they talk.
        let me = [u("A", 0, 10, "Long point."), u("A", 25, 26, "Yeah."), u("A", 45, 55, "Another point.")]
        XCTAssertEqual(TranscriptMerger.echoLabels(me: me, themSound: sound([(20, 40)])), [])
    }

    func testKeepsInRoomSpeakerWhoAlsoTalksWhileTheyAreQuiet() {
        // Speaker B is in the room: 40% of their speech overlaps the call audio, 60% does not.
        let me = [u("A", 0, 20, "Owner."), u("B", 36, 40, "Crosstalk."), u("B", 60, 66, "Alone.")]
        XCTAssertEqual(TranscriptMerger.echoLabels(me: me, themSound: sound([(30, 40)])), [])
    }

    func testNeverDropsTheLabelWithMostQuietSpeech() {
        // Everything on the mic overlaps their sound; the owner is still kept.
        let me = [u("A", 10, 30, "Owner."), u("B", 50, 52, "Echo.")]
        let echo = TranscriptMerger.echoLabels(me: me, themSound: sound([(5, 30), (40, 60)]))
        XCTAssertEqual(echo, ["B"])
    }

    func testSkipsLabelRuleWhenTheyAreNeverQuiet() {
        let me = [u("A", 0, 10, "Owner."), u("B", 50, 52, "Echo?")]
        XCTAssertEqual(TranscriptMerger.echoLabels(me: me, themSound: sound([(0, 95)])), [])
    }

    func testWithoutTimelineOnlyTheWordRuleApplies() {
        let me = [u("A", 0, 10, "Owner."), u("B", 21, 22, "Yeah.")]
        XCTAssertEqual(TranscriptMerger.merge(me: me, them: [], themSound: nil).count, 2)
    }
}
