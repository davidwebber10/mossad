import XCTest
@testable import MossadCore

final class TranscriptMergerTests: XCTestCase {
    func u(_ track: Track, _ label: String, _ start: Double, _ end: Double, _ text: String) -> Utterance {
        Utterance(track: track, speakerLabel: label, start: start, end: end, text: text)
    }

    func testInterleavesByStartTime() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 0, 2, "Morning."), u(.me, "A", 10, 12, "Sounds good.")],
            them: [u(.them, "A", 3, 8, "Hey David, quick update on cushions.")])
        XCTAssertEqual(merged.map(\.start), [0, 3, 10])
    }

    func testDropsBleedDuplicates() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 10.0, 12.0, "we should ship the cushions friday")],
            them: [u(.them, "B", 10.1, 12.1, "We should ship the cushions Friday.")])
        XCTAssertEqual(merged, [u(.them, "B", 10.1, 12.1, "We should ship the cushions Friday.")])
    }

    func testKeepsCrossTalk() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 10.0, 12.0, "Wait, which warehouse?")],
            them: [u(.them, "B", 10.1, 12.1, "We should ship the cushions Friday.")])
        XCTAssertEqual(merged.count, 2)
    }

    func testKeepsSameWordsAtDifferentTimes() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 30, 32, "we should ship the cushions friday")],
            them: [u(.them, "B", 10.1, 12.1, "We should ship the cushions Friday.")])
        XCTAssertEqual(merged.count, 2)
    }

    func testDropsPartialBleedFragment() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 252.5, 253.4, "ship the cushions")],
            them: [u(.them, "A", 250, 258, "So the plan is that we ship the cushions on Friday from Syracuse and the chairs next week.")])
        XCTAssertEqual(merged.map(\.track), [.them])
    }

    func testKeepsOwnSpeechThatRepeatsAWord() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 252.5, 255, "Wait, which cushions, the deep seating ones?")],
            them: [u(.them, "A", 250, 258, "So the plan is that we ship the cushions on Friday from Syracuse and the chairs next week.")])
        XCTAssertEqual(merged.count, 2)
    }
}
