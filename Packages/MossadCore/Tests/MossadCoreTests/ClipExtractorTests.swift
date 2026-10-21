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
}
