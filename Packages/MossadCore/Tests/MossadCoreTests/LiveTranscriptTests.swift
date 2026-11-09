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

final class LiveTranscriberFailureTests: XCTestCase {
    /// After a socket error the session only logged: the track kept converting audio for a dead socket, and the live
    /// transcript stayed empty to the end of the call. Now the owner of the session is told, once.
    func testAConnectionThatFailsReportsItOnceAndTakesNoMoreAudio() {
        let failed = expectation(description: "failure reported")
        failed.assertForOverFulfill = true
        // Nothing listens on this local port, so the connection is refused at once. No network is used.
        let session = LiveTranscriber(apiKey: "test", url: URL(string: "ws://127.0.0.1:9/")!, onFailure: { failed.fulfill() }) { _ in }
        XCTAssertTrue(session.isAlive)
        wait(for: [failed], timeout: 10)
        XCTAssertFalse(session.isAlive)
        session.send(sineBuffer(seconds: 0.5, sampleRate: 16_000, channels: 1))
        session.stop()
    }

    func testAStoppedSessionDoesNotReportAFailure() {
        let failed = expectation(description: "no failure")
        failed.isInverted = true
        let session = LiveTranscriber(apiKey: "test", url: URL(string: "ws://127.0.0.1:9/")!, onFailure: { failed.fulfill() }) { _ in }
        session.stop()
        XCTAssertFalse(session.isAlive)
        wait(for: [failed], timeout: 1)
    }

    /// The filter ran over every pair of lines four times a second, on the main thread, for the whole call.
    func testTheEchoFilterWithItsMemoShowsTheSameLinesAtEveryStep() {
        func turn(_ order: Int, _ text: String, final: Bool) -> Data {
            Data(#"{"type":"Turn","turn_order":\#(order),"end_of_turn":\#(final),"transcript":"\#(text)","speaker_label":"A","words":[]}"#.utf8)
        }
        var live = LiveTranscript()
        var memo = LiveTranscript.EchoMemo()
        var hidden = 0
        for i in 0..<120 {
            let t = Double(i) * 5
            let call = "we should move the shipment to friday number \(i)"
            // A draft first, then the final text, as the service sends them.
            live.apply(turn(i, "we should move", final: false), source: .them, at: t)
            XCTAssertEqual(live.visibleLines(memo: &memo), live.visibleLines)
            // Every third mic line is the echo of the call line; the others are the owner's own words.
            let mine = i % 3 == 0 ? call : "I will send the forecast today number \(i)"
            live.apply(turn(i, mine, final: false), source: .me, at: t + 2)
            XCTAssertEqual(live.visibleLines(memo: &memo), live.visibleLines)
            live.apply(turn(i, call, final: true), source: .them, at: t)
            live.apply(turn(i, mine, final: true), source: .me, at: t + 2)
            XCTAssertEqual(live.visibleLines(memo: &memo), live.visibleLines)
            hidden = live.lines.count - live.visibleLines.count
        }
        XCTAssertEqual(hidden, 40, "the echo lines are hidden")
        XCTAssertGreaterThan(memo.shown.count, 110, "nearly every mic line is settled and is not looked at again")
        XCTAssertLessThan(memo.shown.count, 120, "the last lines can still change")
    }

    func testAMicLineIsNotSettledWhileACallLineNearItIsStillSpoken() {
        func turn(_ order: Int, _ text: String, final: Bool) -> Data {
            Data(#"{"type":"Turn","turn_order":\#(order),"end_of_turn":\#(final),"transcript":"\#(text)","speaker_label":"A","words":[]}"#.utf8)
        }
        var live = LiveTranscript()
        var memo = LiveTranscript.EchoMemo()
        // A long turn on the call that is still a draft when the mic line is final and old.
        live.apply(turn(0, "we should", final: false), source: .them, at: 0)
        live.apply(turn(0, "we should move the shipment to friday", final: true), source: .me, at: 2)
        live.apply(turn(1, "something else entirely", final: true), source: .them, at: 60)
        XCTAssertEqual(live.visibleLines(memo: &memo).count, 3, "the draft does not match yet")
        live.apply(turn(0, "we should move the shipment to friday", final: true), source: .them, at: 0)
        XCTAssertEqual(live.visibleLines(memo: &memo).count, 2, "the mic line was not settled early, so it is hidden now")
        XCTAssertEqual(live.visibleLines(memo: &memo), live.visibleLines)
    }

    // MARK: What waits for the network

    func testAudioGoesOutOneMessageAtATimeInOrder() {
        var q = LiveSendQueue()
        XCTAssertTrue(q.add(Data([1, 1]), at: 0))
        XCTAssertEqual(q.next(), Data([1, 1]))
        XCTAssertTrue(q.add(Data([2]), at: 0.1))
        XCTAssertTrue(q.add(Data([3]), at: 0.2))
        XCTAssertNil(q.next(), "one message is on its way")
        q.sent()
        XCTAssertEqual(q.next(), Data([2, 3]), "what waited goes out together")
        q.sent()
        XCTAssertNil(q.next())
        XCTAssertEqual(q.waitingBytes, 0)
    }

    /// On a slow uplink the waiting audio grew in memory for the whole call.
    func testWaitingAudioHasALimitAndTheOldestGoesFirst() {
        var q = LiveSendQueue()
        for i in 0..<30 { XCTAssertTrue(q.add(Data(repeating: UInt8(i), count: 3_200), at: Double(i) * 0.1)) }
        XCTAssertLessThanOrEqual(q.waitingBytes, LiveSendQueue.limitBytes)
        XCTAssertEqual(q.droppedBytes, 10 * 3_200)
        XCTAssertEqual(q.next()?.first, 10, "the oldest chunks were dropped; the newest wait")
    }

    func testAQueueThatStaysFullSaysTheUplinkCannotCarryTheStream() {
        var q = LiveSendQueue()
        var carries = true
        var time = 0.0
        while carries, time < 60 {
            carries = q.add(Data(count: 3_200), at: time)
            time += 0.1
        }
        XCTAssertFalse(carries)
        XCTAssertEqual(time, 2 + LiveSendQueue.stuckAfter, accuracy: 0.3, "2 s to fill, then 10 s of dropping")
    }

    func testAQueueThatRunsEmptyStartsItsCountAgain() {
        var q = LiveSendQueue()
        for i in 0..<25 { _ = q.add(Data(count: 3_200), at: Double(i) * 0.1) }
        while q.next() != nil { q.sent() }
        XCTAssertEqual(q.waitingBytes, 0)
        for i in 0..<25 { XCTAssertTrue(q.add(Data(count: 3_200), at: 100 + Double(i) * 0.1), "an old burst does not count") }
    }

    /// While muted, the mic stream was silence at the full 32 KB each second.
    func testAMutedMicSendsItsFirstSecondAndThenOnlyAKeepAlive() {
        var t = SilenceThrottle()
        var sent = 0
        for _ in 0..<600 where t.shouldSend(bytes: 3_200, silent: true) { sent += 3_200 }
        XCTAssertEqual(sent, 32_000 + 11 * 3_200, "1 s, then one chunk each 5 s of the minute")
        XCTAssertTrue(t.shouldSend(bytes: 3_200, silent: false), "speech always goes out")
        XCTAssertTrue(t.shouldSend(bytes: 3_200, silent: true), "and the next silence starts with its first second again")
    }
}
