import AVFoundation
import XCTest
@testable import MossadCore

final class LiveTranscriptTests: XCTestCase {
    func turn(_ order: Int, _ text: String, final: Bool, formatted: Bool = false) -> Data {
        Data(#"{"type":"Turn","turn_order":\#(order),"end_of_turn":\#(final),"turn_is_formatted":\#(formatted),"transcript":"\#(text)","words":[]}"#.utf8)
    }

    func testDraftTextIsReplacedByTheFinalText() {
        var live = LiveTranscript()
        XCTAssertTrue(live.apply(turn(0, "hello how", final: false), source: .me, at: 3))
        XCTAssertTrue(live.apply(turn(0, "hello how are you", final: false), source: .me, at: 4))
        XCTAssertTrue(live.apply(turn(0, "Hello, how are you?", final: true, formatted: true), source: .me, at: 5))
        XCTAssertEqual(live.lines.map(\.text), ["Hello, how are you?"])
        XCTAssertTrue(live.lines[0].isFinal)
        XCTAssertEqual(live.lines[0].time, 3, "a line keeps the time it began")
    }

    func testTheTwoSourcesStayApartAndInTimeOrder() {
        var live = LiveTranscript()
        live.apply(turn(0, "Morning.", final: true), source: .me, at: 1)
        live.apply(turn(0, "Hi there.", final: true), source: .them, at: 2)
        live.apply(turn(1, "Ready?", final: false), source: .me, at: 4)
        XCTAssertEqual(live.lines.map(\.text), ["Morning.", "Hi there.", "Ready?"])
        XCTAssertEqual(live.lines.map(\.source), [.me, .them, .me])
    }

    func testOtherMessagesChangeNothing() {
        var live = LiveTranscript()
        XCTAssertFalse(live.apply(Data(#"{"type":"Begin","id":"x","expires_at":1}"#.utf8), source: .me, at: 0))
        XCTAssertFalse(live.apply(Data("not json".utf8), source: .me, at: 0))
        XCTAssertTrue(live.lines.isEmpty)
    }

    func testAudioBecomes16BitLittleEndianPCM() {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, frameCapacity: 3)!
        buffer.frameLength = 3
        buffer.floatChannelData![0][0] = 0
        buffer.floatChannelData![0][1] = 1
        buffer.floatChannelData![0][2] = -1
        let data = LiveTranscriber.pcm16(buffer)
        XCTAssertEqual(Array(data), [0x00, 0x00, 0xff, 0x7f, 0x01, 0x80])
    }

    private func turn(_ order: Int, _ text: String) -> Data {
        json(["type": "Turn", "turn_order": order, "end_of_turn": true, "transcript": text])
    }

    func testAYouLineThatRepeatsTheCallIsEchoAndHidden() {
        var t = LiveTranscript()
        t.apply(turn(1, "I wonder if, um, where there's maybe a little bit of a"), source: .them, at: 10)
        t.apply(turn(1, "Right. Um, where there's maybe a little bit of a"), source: .me, at: 10.5)
        t.apply(turn(2, "divergence from the PSYOP stamp cycle and the budget."), source: .me, at: 13)
        t.apply(turn(2, "divergence from the PSYOP stamp cycle."), source: .them, at: 13.2)
        t.apply(turn(3, "I'm just trying to get into the headspace of this."), source: .me, at: 20)
        t.apply(turn(3, "Yeah."), source: .them, at: 21)
        t.apply(turn(4, "Yeah."), source: .me, at: 40)
        let shown = t.visibleLines.map { "\($0.source.rawValue): \($0.text)" }
        XCTAssertEqual(shown, [
            "them: I wonder if, um, where there's maybe a little bit of a",
            "them: divergence from the PSYOP stamp cycle.",
            "me: I'm just trying to get into the headspace of this.",
            "them: Yeah.",
            "me: Yeah.",
        ])
        XCTAssertEqual(t.lines.count, 7, "the echo stays in the data; only the view hides it")
    }
}
