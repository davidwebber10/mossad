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
            them: [u(.them, "A", 250, 258, "So the plan is that we ship the cushions on Friday from the north plant and the chairs next week.")])
        XCTAssertEqual(merged.map(\.track), [.them])
    }

    func testKeepsAShortReplyDuringTheirSpeech() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 19, 19.5, "Yes.")],
            them: [u(.them, "A", 10, 20, "Yes, we can ship Friday once finance approves.")])
        XCTAssertEqual(merged.count, 2)
    }

    func testKeepsAThreeWordReplyThatRepeatsTheirEarlierWords() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 19, 19.5, "Ship it Friday")],
            them: [u(.them, "A", 10, 20, "Can we ship it Friday once finance approves?")])
        XCTAssertEqual(merged.count, 2)
    }

    func timed(_ track: Track, _ words: [(String, Double)]) -> Utterance {
        let w = words.map { Word(text: $0.0, start: $0.1, end: $0.1 + 0.2) }
        return Utterance(track: track, speakerLabel: "A", start: w.first!.start, end: w.last!.end,
                         text: words.map(\.0).joined(separator: " "), words: w)
    }

    func testKeepsAReplyThatRepeatsWordsSaidASecondEarlier() {
        let them = timed(.them, [("Can", 10), ("we", 10.4), ("ship", 11), ("it", 11.5), ("Friday", 12), ("once", 12.5), ("finance", 13), ("approves", 13.6)])
        let me = timed(.me, [("Ship", 12.6), ("it", 12.8), ("Friday", 13.0)])
        XCTAssertEqual(TranscriptMerger.merge(me: [me], them: [them]).count, 2)
    }

    func testDropsEchoWhoseWordsArriveWithTheirs() {
        let them = timed(.them, [("Can", 10), ("we", 10.4), ("ship", 11), ("it", 11.5), ("Friday", 12), ("once", 12.5)])
        let me = timed(.me, [("ship", 11.2), ("it", 11.7), ("Friday", 12.2)])
        XCTAssertEqual(TranscriptMerger.merge(me: [me], them: [them]).map(\.track), [.them])
    }

    func testKeepsOwnSpeechThatRepeatsAWord() {
        let merged = TranscriptMerger.merge(
            me: [u(.me, "A", 252.5, 255, "Wait, which cushions, the deep seating ones?")],
            them: [u(.them, "A", 250, 258, "So the plan is that we ship the cushions on Friday from the north plant and the chairs next week.")])
        XCTAssertEqual(merged.count, 2)
    }
}
