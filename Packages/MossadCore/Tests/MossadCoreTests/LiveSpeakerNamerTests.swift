import AVFoundation
import XCTest
@testable import MossadCore

/// Names on the live call's speakers, from the voice library, while the call records.
final class LiveSpeakerNamerTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = tempDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A final turn whose words span `from`...`to` seconds of the session's audio.
    func turn(_ order: Int, _ speaker: String, from: Double, to: Double, final: Bool = true) -> Data {
        let words = #"[{"start":\#(Int(from * 1000)),"end":\#(Int(from * 1000 + 500)),"word_is_final":true},{"start":\#(Int(to * 1000 - 500)),"end":\#(Int(to * 1000)),"word_is_final":true}]"#
        return Data(#"{"type":"Turn","turn_order":\#(order),"end_of_turn":\#(final),"transcript":"words","speaker_label":"\#(speaker)","words":\#(words)}"#.utf8)
    }

    func testALineKnowsWhereItsAudioIsInTheTrack() {
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 1, to: 4), source: .them, at: 5, audioOffset: 10)
        XCTAssertEqual(live.lines[0].audioStart, 11)
        XCTAssertEqual(live.lines[0].audioEnd, 14)
    }

    func testAfterAPauseTheNewSessionsTurnsAreNewLines() {
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 1, to: 4), source: .them, at: 5)
        live.newSession()
        live.apply(turn(0, "A", from: 1, to: 4), source: .them, at: 60)
        XCTAssertEqual(live.lines.count, 2)
        XCTAssertEqual(live.lines.map(\.speakerKey), ["0A", "1A"], "a label belongs to its session")
    }

    func testANamedSpeakerShowsByName() {
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 1, to: 4), source: .them, at: 65)
        live.names["0A"] = "Sam Lee"
        XCTAssertEqual(live.text(owner: "Dana", since: nil), "[01:05] Sam Lee: words")
    }

    func testKnownVoicesGetNamesAndShortOrUnknownOnesWait() async throws {
        let them = dir.appendingPathComponent("them.caf")
        try writeSegments(them, total: 30, [(0, 8, 400), (10, 18, 600), (20, 21, 400), (22, 29, 800)])
        let library = VoiceLibrary(directory: dir)
        try library.add([1, 0, 0, 0], to: "Dana", isOwner: true)
        try library.add([0, 1, 0, 0], to: "Sam Lee")
        try library.add([0, 0, 1, 0], to: "Jo Park")
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 8), source: .them, at: 8)
        live.apply(turn(1, "B", from: 10, to: 18), source: .them, at: 18)
        live.apply(turn(2, "C", from: 20, to: 21), source: .them, at: 21)
        live.apply(turn(3, "D", from: 22, to: 29), source: .them, at: 29)
        let provider = ToneEmbeddingProvider()
        let namer = LiveSpeakerNamer(library: library, provider: provider)
        let names = await namer.names(for: live, themURL: them)
        XCTAssertEqual(names, ["0A": "Sam Lee", "0B": "Jo Park"])
        live.names = names
        let calls = provider.calls
        _ = await namer.names(for: live, themURL: them)
        XCTAssertEqual(provider.calls - calls, 1, "only the unnamed voice with enough speech is tried again")
    }

    func testATrackStillRecordingCanBeRead() throws {
        let url = dir.appendingPathComponent("live.caf")
        var now = Date(timeIntervalSince1970: 0)
        let writer = try TrackWriter(url: url, startTime: now, clock: { now })
        for _ in 0..<50 {
            now = now.addingTimeInterval(0.1)
            try writer.append(sineBuffer(seconds: 0.1, sampleRate: 16_000, channels: 1))
        }
        XCTAssertGreaterThanOrEqual(try AudioSamples.read(url, from: 1, to: 4).count, 3 * 16_000 - 1_600)
        writer.close()
    }
}
