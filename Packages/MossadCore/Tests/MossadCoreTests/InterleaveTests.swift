import XCTest
@testable import MossadCore

final class InterleaveTests: XCTestCase {
    func words(_ text: String, from start: Double) -> [Word] {
        text.split(separator: " ").enumerated().map { i, w in Word(text: String(w), start: start + Double(i), end: start + Double(i) + 0.8) }
    }

    func testAnInterjectionCutsTheLongLineAtTheRightWord() {
        var long = Utterance(track: .me, speakerLabel: "A", start: 0, end: 7.8, text: "one two three four five six seven eight")
        long.words = words("one two three four five six seven eight", from: 0)
        let yeah = Utterance(track: .them, speakerLabel: "A", start: 4.5, end: 4.9, text: "Yeah.")

        let lines = Transcript.interleaved([long, yeah])

        XCTAssertEqual(lines.map(\.text), ["one two three four five", "Yeah.", "six seven eight"])
        XCTAssertEqual(lines.map(\.start), [0, 4.5, 5])
        XCTAssertEqual(lines[2].speakerKey, "me:A")
    }

    func testALineWithoutWordTimesStaysWhole() {
        let long = Utterance(track: .me, speakerLabel: "A", start: 0, end: 8, text: "one two three")
        let yeah = Utterance(track: .them, speakerLabel: "A", start: 4, end: 4.5, text: "Yeah.")
        XCTAssertEqual(Transcript.interleaved([long, yeah]).map(\.text), ["one two three", "Yeah."])
    }

    func testTheSameSpeakerDoesNotCutItsOwnLine() {
        var long = Utterance(track: .me, speakerLabel: "A", start: 0, end: 3.8, text: "a b c d")
        long.words = words("a b c d", from: 0)
        let same = Utterance(track: .me, speakerLabel: "A", start: 2, end: 2.5, text: "x")
        XCTAssertEqual(Transcript.interleaved([long, same]).count, 2)
    }
}
