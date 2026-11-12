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
        try writeSegments(them, total: 60, [(0, 12, 400), (14, 26, 600), (28, 37, 400), (40, 52, 800)])
        let library = VoiceLibrary(directory: dir)
        try library.add([1, 0, 0, 0], to: "Dana", isOwner: true)
        try library.add([0, 1, 0, 0], to: "Sam Lee")
        try library.add([0, 0, 1, 0], to: "Jo Park")
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 12), source: .them, at: 12)
        live.apply(turn(1, "B", from: 14, to: 26), source: .them, at: 26)
        live.apply(turn(2, "C", from: 28, to: 37), source: .them, at: 37)
        live.apply(turn(3, "D", from: 40, to: 52), source: .them, at: 52)
        let provider = ToneEmbeddingProvider()
        let namer = LiveSpeakerNamer(library: library, provider: provider)
        let names = await namer.names(for: live, themURL: them)
        XCTAssertEqual(names, ["0A": "Sam Lee", "0B": "Jo Park"], "9 s of speech is not enough, and an unknown voice has no name")
        live.names = names
        let calls = provider.calls
        let again = await namer.names(for: live, themURL: them)
        XCTAssertEqual(again, names)
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
        live.apply(turn(0, "A", from: 0, to: 10), source: .them, at: 10)
        _ = await namer.names(for: live, themURL: them)
        let first = provider.calls
        XCTAssertGreaterThan(first, 0)
        live.apply(turn(1, "A", from: 11, to: 15), source: .them, at: 15)
        _ = await namer.names(for: live, themURL: them)
        XCTAssertEqual(provider.calls, first, "14 s after 10 s is not half as much again")
        live.apply(turn(2, "A", from: 16, to: 18), source: .them, at: 18)
        _ = await namer.names(for: live, themURL: them)
        XCTAssertGreaterThan(provider.calls, first, "16 s after 10 s is")
    }

    /// The service gave one label to two people: the name it had goes, and its earlier lines show the letter again.
    func testAKeyThatTurnsOutToHoldTwoVoicesLosesItsName() async throws {
        let them = dir.appendingPathComponent("them.caf")
        try writeSegments(them, total: 40, [(0, 12, 400), (14, 26, 800)])
        let library = VoiceLibrary(directory: dir)
        try library.add([0, 1, 0, 0], to: "Sam Lee")
        try library.add([0, 0, 1, 0], to: "Jo Park")
        let namer = LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider())
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 12), source: .them, at: 12)
        live.names = await namer.names(for: live, themURL: them)
        XCTAssertEqual(live.names, ["0A": "Sam Lee"])
        live.apply(turn(1, "A", from: 14, to: 26), source: .them, at: 26)
        live.names = await namer.names(for: live, themURL: them)
        XCTAssertEqual(live.names, [:])
        XCTAssertEqual(live.text(owner: "Dana", since: nil).components(separatedBy: "\n").first, "[00:12] Speaker A: words")
    }

    /// Short halves that disagree are decided again: a later, longer fingerprint of one voice gives the name.
    func testALaterLongFingerprintClearsAnEarlyShortMixedResult() async throws {
        let them = dir.appendingPathComponent("them.caf")
        try writeSegments(them, total: 70, [(0, 10, 400), (12, 22, 800), (24, 60, 400)])
        let library = VoiceLibrary(directory: dir)
        try library.add([0, 1, 0, 0], to: "Sam Lee")
        let namer = LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider())
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 10), source: .them, at: 10)
        live.apply(turn(1, "A", from: 12, to: 22), source: .them, at: 22)
        live.names = await namer.names(for: live, themURL: them)
        XCTAssertEqual(live.names, [:])
        live.apply(turn(2, "A", from: 24, to: 60), source: .them, at: 60)
        live.names = await namer.names(for: live, themURL: them)
        XCTAssertEqual(live.names, ["0A": "Sam Lee"])
    }

    /// The live namer only reads the voice library.
    func testNamingChangesNoFileOfTheLibrary() async throws {
        let them = dir.appendingPathComponent("them.caf")
        try writeSegments(them, total: 30, [(0, 12, 400)])
        let library = VoiceLibrary(directory: dir)
        library.identity = VoiceIdentity(people: PeopleStore(directory: dir), samples: VoiceSampleStore(directory: dir))
        try library.add([0, 1, 0, 0], to: "Sam Lee")
        func files() throws -> [String: Data] {
            Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
                .map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) })
        }
        let before = try files()
        XCTAssertFalse(before.isEmpty)
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 12), source: .them, at: 12)
        let names = await LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider()).names(for: live, themURL: them)
        XCTAssertEqual(names, ["0A": "Sam Lee"])
        XCTAssertEqual(try files(), before)
    }

    /// A voice the library knows but the call did not invite needs a strong match; one that is only provisional
    /// is named only on a call that invites them.
    func testTheCallsInviteDecidesAsInThePipeline() async throws {
        let them = dir.appendingPathComponent("them.caf")
        try writeSegments(them, total: 30, [(0, 12, 400)])
        let library = VoiceLibrary(directory: dir)
        try library.add([0, 1, 0, 0], to: "Sam Lee", source: VoiceSampleSource(callID: "call-1", speakerKey: "them:A", recorded: Date(),
                                                                              seconds: 30, quality: 0.8, origin: .inviteInference))
        XCTAssertEqual(library.provisional["Sam Lee"], "call-1")
        _ = try library.setEmail("sam@example.com", for: "Sam Lee", actor: "test")
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 12), source: .them, at: 12)
        let other = CallInvite(guests: [CallInvite.Guest(email: "jo@example.com")])
        let withSam = CallInvite(guests: [CallInvite.Guest(email: "sam@example.com")])
        let no = await LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider()).names(for: live, themURL: them, invite: other)
        XCTAssertEqual(no, [:])
        let yes = await LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider()).names(for: live, themURL: them, invite: withSam)
        XCTAssertEqual(yes, ["0A": "Sam Lee"])
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
        try writeSegments(room, total: 30, [(0, 12, 200), (14, 26, 400)])
        let library = VoiceLibrary(directory: dir)
        try library.add([1, 0, 0, 0], to: "Dana", isOwner: true)
        try library.add([0, 1, 0, 0], to: "Sam Lee")
        var live = LiveTranscript()
        live.apply(turn(0, "A", from: 0, to: 12), source: .them, at: 12)
        live.apply(turn(1, "B", from: 14, to: 26), source: .them, at: 26)
        let call = await LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider()).names(for: live, themURL: room)
        XCTAssertEqual(call, ["0B": "Sam Lee"])
        let inRoom = await LiveSpeakerNamer(library: library, provider: ToneEmbeddingProvider(), room: true).names(for: live, themURL: room)
        XCTAssertEqual(inRoom, ["0A": "Dana", "0B": "Sam Lee"])
    }
}
