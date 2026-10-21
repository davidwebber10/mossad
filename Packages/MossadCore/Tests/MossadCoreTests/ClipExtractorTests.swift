import XCTest
@testable import MossadCore

final class ClipExtractorTests: XCTestCase {
    func testClipTakesLongestUtteranceUpToFiveSeconds() throws {
        let dir = tempDirectory()
        let source = dir.appendingPathComponent("them.caf")
        try writeSegments(source, total: 30, [(2, 4, 400), (10, 18, 400)])
        let utterances = [
            Utterance(track: .them, speakerLabel: "B", start: 2, end: 4, text: "short"),
            Utterance(track: .them, speakerLabel: "B", start: 10, end: 18, text: "long"),
            Utterance(track: .them, speakerLabel: "A", start: 20, end: 29, text: "other"),
        ]
        let clip = dir.appendingPathComponent("clip.caf")
        try ClipExtractor.clip(for: "them:B", utterances: utterances, source: source, to: clip)
        XCTAssertEqual(try audioDuration(clip), 5, accuracy: 0.01)
        let samples = try AudioSamples.read(clip, from: 0, to: 5)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.4)
    }

    func testCandidatesAreTheSpeakersLinesLongestFirst() {
        let utterances = [
            Utterance(track: .them, speakerLabel: "B", start: 2, end: 4, text: "short"),
            Utterance(track: .them, speakerLabel: "B", start: 10, end: 18, text: "long"),
            Utterance(track: .them, speakerLabel: "A", start: 20, end: 29, text: "other"),
            Utterance(track: .them, speakerLabel: "B", start: 30, end: 35, text: "middle"),
        ]
        XCTAssertEqual(ClipExtractor.candidates(for: "them:B", utterances: utterances).map(\.text), ["long", "middle", "short"])
    }

    func testChoiceCyclesThroughTheCandidates() throws {
        let dir = tempDirectory()
        let source = dir.appendingPathComponent("them.caf")
        try writeSegments(source, total: 30, [(2, 4, 400), (10, 18, 400)])
        let utterances = [
            Utterance(track: .them, speakerLabel: "B", start: 2, end: 4, text: "short"),
            Utterance(track: .them, speakerLabel: "B", start: 10, end: 18, text: "long"),
        ]
        let clip = dir.appendingPathComponent("clip.caf")
        let second = try ClipExtractor.clip(for: "them:B", utterances: utterances, source: source, to: clip, choice: 1)
        XCTAssertEqual(second?.text, "short")
        XCTAssertEqual(try audioDuration(clip), 2, accuracy: 0.01)
        // Past the last candidate it starts again at the first.
        XCTAssertEqual(try ClipExtractor.clip(for: "them:B", utterances: utterances, source: source, to: clip, choice: 2)?.text, "long")
    }
}
