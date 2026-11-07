import XCTest
@testable import MossadCore

final class LiveTalkShareTests: XCTestCase {
    private func turn(_ order: Int, _ text: String, speaker: String? = nil, words: [(Double, Double)] = []) -> Data {
        var object: [String: Any] = ["type": "Turn", "turn_order": order, "end_of_turn": true, "transcript": text]
        if let speaker { object["speaker_label"] = speaker }
        object["words"] = words.map { ["start": $0.0 * 1000, "end": $0.1 * 1000, "word_is_final": true] }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testTheOwnerComesFirstThenEachVoiceInTheOrderHeardWithItsSeconds() {
        var t = LiveTranscript()
        t.apply(turn(0, "Welcome, everyone, to the planning call.", speaker: "A", words: [(1, 11)]), source: .them, at: 1)
        t.apply(turn(1, "Thanks for having us here today.", speaker: "B", words: [(12, 16)]), source: .them, at: 12)
        t.apply(turn(0, "Glad to be here with you all.", words: [(20, 26)]), source: .me, at: 20)
        t.apply(turn(2, "Let us begin with the budget.", speaker: "A", words: [(30, 35)]), source: .them, at: 30)
        let shares = t.talkShares
        XCTAssertEqual(shares.map(\.voice), [.owner, .speaker("0A"), .speaker("0B")])
        XCTAssertEqual(shares.map(\.seconds), [6, 15, 4])
    }

    func testANamedVoiceCountsOnceByItsNameAcrossSessions() {
        var t = LiveTranscript()
        t.apply(turn(0, "First part of the call here.", speaker: "A", words: [(0, 4)]), source: .them, at: 0)
        t.newSession()
        t.apply(turn(0, "Second part after the pause.", speaker: "B", words: [(10, 13)]), source: .them, at: 10)
        t.names = ["0A": "Dana Lee", "1B": "Dana Lee"]
        XCTAssertEqual(t.talkShares.map(\.voice), [.named("Dana Lee")])
        XCTAssertEqual(t.talkShares.map(\.seconds), [7])
    }

    func testALineWithoutWordTimesCountsItsWords() {
        var t = LiveTranscript()
        t.apply(turn(0, "one two three four five", speaker: "A"), source: .them, at: 0)
        XCTAssertEqual(t.talkShares.first?.seconds ?? 0, 2, accuracy: 0.001, "five words at two and a half words a second")
    }
}
