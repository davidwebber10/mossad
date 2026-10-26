import XCTest
@testable import MossadCore

/// The call that is recording now, for "this was just mentioned, do this" from Chat or another AI app.
final class LiveCallTests: XCTestCase {
    func turn(_ order: Int, _ text: String, speaker: String? = nil, final: Bool = true) -> Data {
        let label = speaker.map { #","speaker_label":"\#($0)""# } ?? ""
        return Data(#"{"type":"Turn","turn_order":\#(order),"end_of_turn":\#(final),"transcript":"\#(text)"\#(label)}"#.utf8)
    }

    func testCallLinesKeepTheirSpeakerAndAShortTurnKeepsTheOneItHad() {
        var live = LiveTranscript()
        live.apply(turn(0, "Can you send the deck", speaker: "A", final: false), source: .them, at: 5)
        live.apply(turn(0, "Can you send the deck by Friday?", speaker: "PENDING"), source: .them, at: 5)
        live.apply(turn(1, "Yes.", speaker: "B"), source: .them, at: 9)
        XCTAssertEqual(live.lines.map(\.speaker), ["A", "B"])
    }

    func testTheTextNamesTheOwnerAndTheSpeakersAndCanStartAtAMinute() {
        var live = LiveTranscript()
        live.apply(turn(0, "Morning, everyone."), source: .me, at: 2)
        live.apply(turn(0, "Can you send the deck by Friday?", speaker: "A"), source: .them, at: 65)
        live.apply(turn(1, "And the budget", final: false), source: .them, at: 130)
        XCTAssertEqual(live.text(owner: "Dana", since: nil), """
        [00:02] Dana: Morning, everyone.
        [01:05] Speaker A: Can you send the deck by Friday?
        [02:10] Others: And the budget (still speaking)
        """)
        XCTAssertEqual(live.text(owner: "Dana", since: 60), """
        [01:05] Speaker A: Can you send the deck by Friday?
        [02:10] Others: And the budget (still speaking)
        """)
    }

    func testTheLiveTranscriptSavesAndLoads() throws {
        let url = tempDirectory().appendingPathComponent(LiveTranscript.fileName)
        var live = LiveTranscript()
        live.apply(turn(0, "Hi.", speaker: "A"), source: .them, at: 1)
        try live.save(to: url)
        XCTAssertEqual(try LiveTranscript.load(from: url), live)
    }

    func testOnlyTheCallTrackAsksForSpeakers() {
        XCTAssertTrue(LiveTranscriber.url(speakers: true).absoluteString.contains("speaker_labels=true"))
        XCTAssertFalse(LiveTranscriber.url(speakers: false).absoluteString.contains("speaker_labels"))
    }

    func testTheCurrentCallToolReadsTheCallThatIsRecording() throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        XCTAssertEqual(ChatTools(records: [], owner: "Dana", paths: paths).run("current_call", input: [:]), "No call is recording now.")
        let start = Date().addingTimeInterval(-300)
        var r = CallRecord(id: "20261026-100000", platform: .meet, bundleID: "com.google.Chrome", start: start, end: start, status: .recording)
        r.calendarTitle = "Budget review"
        r.attendees = ["sam@example.com"]
        let dir = paths.callDirectory(r.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try r.save(to: dir)
        var live = LiveTranscript()
        live.apply(turn(0, "Can you send the deck by Friday?", speaker: "A"), source: .them, at: 65)
        try live.save(to: dir.appendingPathComponent(LiveTranscript.fileName))
        let text = ChatTools(records: [r], owner: "Dana", paths: paths).run("current_call", input: ["minutes": 10])
        XCTAssertTrue(text.contains("Budget review"), text)
        XCTAssertTrue(text.contains("sam@example.com"), text)
        XCTAssertTrue(text.contains("[01:05] Speaker A: Can you send the deck by Friday?"), text)
        XCTAssertTrue(ChatTools.allDefinitions.contains { $0.name == "current_call" })
        XCTAssertTrue(MCPServer.tools.contains { $0.name == "current_call" })
    }
}
