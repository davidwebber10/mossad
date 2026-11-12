import XCTest
@testable import MossadCore

/// Where the live chat meets the live names and the recording's clock: a name that changes or goes, and times that
/// leave the pauses out.
final class LiveSeamTests: XCTestCase {
    func turn(_ order: Int, _ text: String, speaker: String? = nil, final: Bool = true) -> Data {
        let label = speaker.map { #","speaker_label":"\#($0)""# } ?? ""
        return Data(#"{"type":"Turn","turn_order":\#(order),"end_of_turn":\#(final),"transcript":"\#(text)"\#(label)}"#.utf8)
    }

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var facts: LiveCallFacts {
        LiveCallFacts(callID: "c1", title: "Budget review", platform: "Zoom", start: start, invited: [], owner: "Dana")
    }

    // MARK: S-1 names that change

    func testThePromptSaysNamesCanChangeAndEarlierAnswersMayBeOld() {
        let system = LiveChatPrompt.system(facts: facts, entries: [], summary: nil, openQuestions: [], now: start)
        XCTAssertTrue(system.contains("A name can change or go during the call"))
        XCTAssertTrue(system.contains("earlier answer"))
    }

    func testAFoldKeepsTheNamesItUsedByLabel() {
        let fold = [
            LiveEntry(time: 10, who: "Sam Carter", text: "I will send the deck.", isFinal: true, mine: false),
            LiveEntry(time: 20, who: "Speaker B", text: "Fine.", isFinal: true, mine: false),
        ]
        let names = LiveSummaryRules.names(in: fold, voices: ["Speaker A": "Sam Carter", "Speaker C": "Lee Morgan"], old: ["Priya Shah": ["Speaker D"]])
        XCTAssertEqual(names, ["Sam Carter": Set(["Speaker A"]), "Priya Shah": Set(["Speaker D"])])
    }

    func testANameThatWentAfterTheFoldIsCalledOut() {
        var f = facts
        f.voices = [:]
        let summary = LiveSummary(through: 100, text: "Sam Carter promised the deck [00:10].", names: ["Sam Carter": ["Speaker A"]])
        let system = LiveChatPrompt.system(facts: f, entries: [], summary: summary, openQuestions: [], now: start)
        XCTAssertTrue(system.contains("The summary calls Speaker A \u{201C}Sam Carter\u{201D}. That name is no longer right: the voice has no name now."))
    }

    func testANameThatMovedAfterTheFoldIsCalledOut() {
        var f = facts
        f.voices = ["Speaker A": "Tom Brady"]
        let summary = LiveSummary(through: 100, text: "Sam Carter promised the deck.", names: ["Sam Carter": ["Speaker A"]])
        let system = LiveChatPrompt.system(facts: f, entries: [], summary: summary, openQuestions: [], now: start)
        XCTAssertTrue(system.contains("That name is no longer right: the voice is Tom Brady now."))
    }

    func testANameThatStaysIsNotCalledOut() {
        var f = facts
        f.voices = ["Speaker A": "Sam Carter"]
        let summary = LiveSummary(through: 100, text: "Sam Carter promised the deck.", names: ["Sam Carter": ["Speaker A"]])
        let system = LiveChatPrompt.system(facts: f, entries: [], summary: summary, openQuestions: [], now: start)
        XCTAssertFalse(system.contains("no longer right"))
    }

    func testTheCacheKeepsTheNamesOfEachFold() async {
        let model = SummaryModel()
        let cache = LiveSummaryCache()
        let all = (0..<300).map { i in
            LiveEntry(time: TimeInterval(i * 10), who: i == 0 ? "Sam Carter" : "Speaker B", text: String(repeating: "w", count: 200),
                      isFinal: true, mine: false)
        }
        let made = await cache.summary(for: "c1", entries: all, owner: "Dana", llm: model,
                                       limits: LiveLimits(verbatim: 40_000, keep: 20_000), voices: ["Speaker A": "Sam Carter"])
        XCTAssertEqual(made?.names, ["Sam Carter": Set(["Speaker A"])])
    }

    // MARK: S-2 the recording's clock

    func testTheSavedClockGivesTheRecordingsSecondsNow() {
        var live = LiveTranscript()
        live.clock = LiveTranscript.Clock(recorded: 1_800, at: start, paused: false)
        XCTAssertEqual(live.recordedNow(at: start.addingTimeInterval(60)), 1_860)
        live.clock?.paused = true
        XCTAssertEqual(live.recordedNow(at: start.addingTimeInterval(60)), 1_800, "a pause records nothing")
        XCTAssertNil(LiveTranscript().recordedNow(at: start))
    }

    func testTheClockSavesAndLoads() throws {
        var live = LiveTranscript()
        live.clock = LiveTranscript.Clock(recorded: 12, at: start, paused: true)
        let url = tempDirectory().appendingPathComponent(LiveTranscript.fileName)
        try live.save(to: url)
        XCTAssertEqual(try LiveTranscript.load(from: url).clock, live.clock)
    }

    func testCurrentCallCountsTheLastMinutesInRecordingSecondsAfterAPause() throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        // 40 minutes on the clock, 10 of them paused: 30 minutes recorded.
        let begun = Date().addingTimeInterval(-2_400)
        var r = CallRecord(id: CallRecorder.callID(for: begun), platform: .zoom, bundleID: "us.zoom.xos", start: begun, end: begun, status: .recording)
        r.calendarTitle = "Budget review"
        let dir = paths.callDirectory(r.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try r.save(to: dir)
        var live = LiveTranscript()
        live.apply(turn(0, "Early words."), source: .me, at: 600)
        live.apply(turn(1, "The newest words.", speaker: "A"), source: .them, at: 1_780)
        live.clock = LiveTranscript.Clock(recorded: 1_800, at: Date(), paused: false)
        try live.save(to: dir.appendingPathComponent(LiveTranscript.fileName))
        let text = ChatTools(records: [r], owner: "Dana", paths: paths).run("current_call", input: ["minutes": 5])
        XCTAssertTrue(text.contains("The newest words."), text)
        XCTAssertFalse(text.contains("Early words."), text)
        XCTAssertTrue(text.contains("30 min recorded"), text)
        XCTAssertTrue(text.contains("paused for about 10 min"), text)
        XCTAssertTrue(text.contains("into the recording"), text)
    }

    func testThePromptCountsRecordedMinutesAndNamesAPauseThatEnded() {
        var f = facts
        f.recorded = 1_800
        let system = LiveChatPrompt.system(facts: f, entries: [], summary: nil, openQuestions: [], now: start.addingTimeInterval(2_400))
        XCTAssertTrue(system.contains("30 min recorded"))
        XCTAssertTrue(system.contains("paused for about 10 min"))
    }

    // MARK: S-4, S-5, S-7

    func testASessionLabelIsASpeakerInAQuote() {
        XCTAssertEqual(ChatBlocks.parse("> [41:10](mossad://call/c1?t=2470) Speaker A2: We ship Friday"),
                       [.quote(ChatQuote(speaker: "Speaker A2", time: "41:10", link: "mossad://call/c1?t=2470", text: "We ship Friday"))])
    }

    func testAnAnswerFromTheCallIsMarkedAndTheMeetingChatIsToldItsNamesWereNotFinal() throws {
        var m = ChatMessage(role: .assistant, text: "Sam asked for it.")
        m.live = true
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: data).live, true)
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"id":"\#(UUID().uuidString)","role":"assistant","text":"x","steps":[]}"#.utf8))
        XCTAssertNil(old.live)
        let tools = ChatTools(records: [], owner: "Dana")
        XCTAssertTrue(ChatAgent.system(owner: "Dana", tools: tools, now: start, liveHistory: true).contains("during the call"))
        XCTAssertFalse(ChatAgent.system(owner: "Dana", tools: tools, now: start).contains("names were not final"))
    }

    func testANumberedLabelIsExplained() {
        let system = LiveChatPrompt.system(facts: facts, entries: [], summary: nil, openQuestions: [], now: start)
        XCTAssertTrue(system.contains("A label with a number"))
        XCTAssertTrue(ChatTools.currentCallDefinition.description.contains("A label with a number"))
    }
}

private final class SummaryModel: LanguageModel, @unchecked Sendable {
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: ["summary": "Sam Carter spoke."]))
    }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}
