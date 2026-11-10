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
        XCTAssertEqual(provider.calls - calls, 0, "a voice with no more speech than at the last try is not tried again")
    }

    /// A voice the library does not know was fingerprinted again every 20 s for the whole call.
    func testAnUnknownVoiceIsTriedAgainOnlyWhenItSaidHalfAsMuchAgain() async throws {
        let them = dir.appendingPathComponent("them.caf")
        try writeSegments(them, total: 40, [(0, 30, 800)])
        let library = VoiceLibrary(directory: dir)
        try library.add([0, 1, 0, 0], to: "Sam Lee")
        let provider = ToneEmbeddingProvider()
        let namer = LiveSpeakerNamer(library: library, provider: provider)
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 8), source: .them, at: 8)
        _ = await namer.names(for: live, themURL: them)
        let first = provider.calls
        XCTAssertGreaterThan(first, 0)
        live.apply(turn(1, "A", from: 9, to: 11), source: .them, at: 11)
        _ = await namer.names(for: live, themURL: them)
        XCTAssertEqual(provider.calls, first, "10 s after 8 s is not half as much again")
        live.apply(turn(2, "A", from: 12, to: 16), source: .them, at: 16)
        _ = await namer.names(for: live, themURL: them)
        XCTAssertGreaterThan(provider.calls, first, "14 s after 8 s is")
    }

    func testAVoiceWithAFullMinuteOfSpeechIsNotTriedAgain() {
        var tries = LiveNamingTries()
        XCTAssertTrue(tries.isDue("A", speech: 4))
        tries.tried("A", speech: 4)
        XCTAssertFalse(tries.isDue("A", speech: 5.9))
        XCTAssertTrue(tries.isDue("A", speech: 6))
        tries.tried("A", speech: 50)
        XCTAssertFalse(tries.isDue("A", speech: 59))
        XCTAssertTrue(tries.isDue("A", speech: 60), "the last try, with all the speech a fingerprint uses")
        tries.tried("A", speech: 60)
        XCTAssertFalse(tries.isDue("A", speech: 600))
        XCTAssertTrue(tries.isDue("B", speech: 4))
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

    /// In a room the owner is one of the voices on the one stream, so the owner's name is allowed.
    func testInARoomTheOwnerGetsTheirName() async throws {
        let room = dir.appendingPathComponent("me.caf")
        try writeSegments(room, total: 20, [(0, 8, 200), (10, 18, 400)])
        let library = VoiceLibrary(directory: dir)
        try library.add([1, 0, 0, 0], to: "Dana", isOwner: true)
        try library.add([0, 1, 0, 0], to: "Sam Lee")
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 8), source: .them, at: 8)
        live.apply(turn(1, "B", from: 10, to: 18), source: .them, at: 18)
        let call = await LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider()).names(for: live, themURL: room)
        XCTAssertEqual(call, ["0B": "Sam Lee"])
        let inRoom = await LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider(), room: true).names(for: live, themURL: room)
        XCTAssertEqual(inRoom, ["0A": "Dana", "0B": "Sam Lee"])
    }
}
