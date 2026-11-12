import XCTest
@testable import MossadCore

/// The chat with the call that records now: the prompt from the live transcript, the quick questions, the
/// summary of the older part of a long call, and the streamed answer.
final class LiveChatTests: XCTestCase {
    func turn(_ order: Int, _ text: String, speaker: String? = nil, final: Bool = true) -> Data {
        let label = speaker.map { #","speaker_label":"\#($0)""# } ?? ""
        return Data(#"{"type":"Turn","turn_order":\#(order),"end_of_turn":\#(final),"transcript":"\#(text)"\#(label)}"#.utf8)
    }

    /// Dana on the mic, Sam (named) as A, and B with no name yet.
    func call() -> LiveTranscript {
        var live = LiveTranscript()
        live.apply(turn(0, "Morning, everyone."), source: .me, at: 2)
        live.apply(turn(0, "Dana, can you send the deck by Friday?", speaker: "A"), source: .them, at: 65)
        live.apply(turn(1, "The budget is still open.", speaker: "B"), source: .them, at: 130)
        live.names = ["0A": "Sam Carter"]
        return live
    }

    let facts = LiveCallFacts(callID: "20261112-100000", title: "Budget review", platform: "Google Meet",
                              start: Date(timeIntervalSince1970: 1_800_000_000), invited: ["Sam Carter", "lee@example.com"],
                              owner: "Dana")

    // MARK: Entries

    func testEntriesUseNamesWhereKnownAndSpeakerLettersElse() {
        let lines = call().entries(owner: "Dana").map(\.line)
        XCTAssertEqual(lines, [
            "[00:02] Dana: Morning, everyone.",
            "[01:05] Sam Carter: Dana, can you send the deck by Friday?",
            "[02:10] Speaker B: The budget is still open.",
        ])
    }

    func testTheOwnersVoiceInARoomIsTheOwners() {
        var live = LiveTranscript()
        live.apply(turn(0, "Let us start.", speaker: "A"), source: .them, at: 3)
        live.names = ["0A": "Dana"]
        XCTAssertEqual(live.entries(owner: "Dana").map(\.mine), [true])
    }

    // MARK: The prompt

    func testThePromptHoldsTheTranscriptTheInviteAndTheRules() {
        let entries = call().entries(owner: "Dana")
        let now = facts.start.addingTimeInterval(200)
        let system = LiveChatPrompt.system(facts: facts, entries: entries, summary: nil, openQuestions: [], now: now)
        XCTAssertTrue(system.contains("[01:05] Sam Carter: Dana, can you send the deck by Friday?"))
        XCTAssertTrue(system.contains("[02:10] Speaker B: The budget is still open."))
        XCTAssertTrue(system.contains("Budget review"))
        XCTAssertTrue(system.contains("Invited: Sam Carter, lee@example.com"))
        XCTAssertTrue(system.contains("3 min so far"))
        XCTAssertTrue(system.contains("mossad://call/20261112-100000?t="), "answers cite the live moment")
        XCTAssertTrue(system.contains("only what was said so far"), "never invents what was not said")
        XCTAssertFalse(system.contains("Earlier in the call"), "no summary for a short call")
    }

    func testThePromptSaysWhenNobodyHasSpoken() {
        let system = LiveChatPrompt.system(facts: facts, entries: [], summary: nil, openQuestions: [], now: facts.start)
        XCTAssertTrue(system.contains("Nobody has said anything yet."))
    }

    func testWithASummaryOnlyTheLinesAfterItGoInWord_for_word() {
        let entries = call().entries(owner: "Dana")
        let summary = LiveSummary(through: 100, text: "Sam asked Dana for the deck by Friday.")
        let system = LiveChatPrompt.system(facts: facts, entries: entries, summary: summary, openQuestions: [], now: facts.start.addingTimeInterval(200))
        XCTAssertTrue(system.contains("Sam asked Dana for the deck by Friday."))
        XCTAssertTrue(system.contains("up to [01:40]"))
        XCTAssertFalse(system.contains("[01:05] Sam Carter"))
        XCTAssertTrue(system.contains("[02:10] Speaker B: The budget is still open."))
    }

    func testTheOpenQuestionsGoInWithTheirTimes() {
        let entries = call().entries(owner: "Dana")
        let open = LiveQuestions.forOwner(entries, owner: "Dana", now: 200)
        let system = LiveChatPrompt.system(facts: facts, entries: entries, summary: nil, openQuestions: open, now: facts.start.addingTimeInterval(200))
        XCTAssertTrue(system.contains("look unanswered"))
        XCTAssertTrue(system.contains("- [01:05] Sam Carter: Dana, can you send the deck by Friday?"))
    }

    // MARK: Questions for the owner

    func testAQuestionThatNamesTheOwnerAndGotNoReplyIsOpen() {
        let open = LiveQuestions.forOwner(call().entries(owner: "Dana"), owner: "Dana Reyes", now: 200)
        XCTAssertEqual(open.map(\.time), [65])
    }

    func testAReplyFromTheOwnerSoonAfterAnswersIt() {
        var live = call()
        live.apply(turn(1, "Yes, Friday works."), source: .me, at: 72)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 200), [])
    }

    func testAOneWordNoiseIsNoReply() {
        var live = call()
        live.apply(turn(1, "Hmm."), source: .me, at: 70)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 200).count, 1)
    }

    func testInAGroupAQuestionThatDoesNotNameTheOwnerIsNotTheirs() {
        var live = call()
        live.apply(turn(2, "What do we think about the vendor?", speaker: "B"), source: .them, at: 150)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 200).map(\.time), [65])
    }

    func testInAOneToOneEveryQuestionIsForTheOwner() {
        var live = LiveTranscript()
        live.apply(turn(0, "How was the launch?", speaker: "A"), source: .them, at: 10)
        live.apply(turn(1, "And the hiring plan?", speaker: "A"), source: .them, at: 100)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 120, invitedOthers: 1).map(\.time), [10, 100])
    }

    func testAQuestionStillBeingSpokenIsNotYetOpen() {
        var live = LiveTranscript()
        live.apply(turn(0, "Dana, could you", speaker: "A", final: false), source: .them, at: 10)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 20), [])
    }

    func testAQuestionAskedASecondAgoIsOpenOnlyAfterTheOwnerHadTimeToAnswer() {
        var live = LiveTranscript()
        live.apply(turn(0, "Dana, any thoughts?", speaker: "A"), source: .them, at: 10)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 12), [])
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 45).count, 1)
    }

    func testTheOwnersOwnQuestionsAreNeverOpenForThem() {
        var live = LiveTranscript()
        live.apply(turn(0, "Dana, did I say that right?"), source: .me, at: 10)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 100), [])
    }

    // MARK: The quick questions

    func testNoChipsBeforeAnyoneSpeaks() {
        XCTAssertEqual(LiveChips.chips([], owner: "Dana", openQuestions: 0), [])
    }

    func testTheChipsNameTheLastSpeakerAndOfferQuestionsOnlyWhenThereAreSome() {
        let entries = call().entries(owner: "Dana")
        XCTAssertEqual(LiveChips.chips(entries, owner: "Dana", openQuestions: 0).map(\.label),
                       ["What did I miss?", "Summarize so far", "Action items so far", "What did Speaker B just say?"])
        XCTAssertEqual(LiveChips.chips(entries, owner: "Dana", openQuestions: 2).map(\.label).last, "Questions for me")
    }

    func testTheLastSpeakerIsByFirstNameAndNeverTheOwner() {
        var live = call()
        live.apply(turn(2, "Agreed.", speaker: "A"), source: .them, at: 150)
        live.apply(turn(1, "Great."), source: .me, at: 160)
        let chips = LiveChips.chips(live.entries(owner: "Dana"), owner: "Dana", openQuestions: 0)
        XCTAssertEqual(chips.map(\.label).last, "What did Sam just say?")
        XCTAssertEqual(chips.last?.question, "What did Sam Carter just say?")
    }

    func testNoLastSpeakerChipWhenOnlyTheOwnerSpoke() {
        var live = LiveTranscript()
        live.apply(turn(0, "Testing, one two."), source: .me, at: 2)
        XCTAssertEqual(LiveChips.chips(live.entries(owner: "Dana"), owner: "Dana", openQuestions: 0).count, 3)
    }

    // MARK: The summary of the older part

    func entries(_ count: Int, length: Int = 200) -> [LiveEntry] {
        (0..<count).map { i in
            LiveEntry(time: TimeInterval(i * 10), who: "Speaker A", text: String(repeating: "w", count: length), isFinal: true, mine: false)
        }
    }

    let small = LiveLimits(verbatim: 40_000, keep: 20_000)

    func testAShortCallNeedsNoSummary() {
        XCTAssertNil(LiveSummaryRules.due(entries(10), summary: nil))
    }

    func testALongCallFoldsTheOlderLinesAndKeepsTheNewestWordForWord() throws {
        let all = entries(300)
        let step = try XCTUnwrap(LiveSummaryRules.due(all, summary: nil, limits: small))
        XCTAssertEqual(step.fold.first?.time, 0)
        let kept = all.filter { $0.time >= step.through }
        let keptSize = kept.reduce(0) { $0 + $1.line.count + 1 }
        XCTAssertLessThanOrEqual(keptSize, small.keep)
        XCTAssertGreaterThan(keptSize, small.keep / 2)
        XCTAssertEqual(step.fold.count + kept.count, all.count)
    }

    func testOnceFoldedTheSummaryWaitsUntilTheNewPartIsLongAgain() throws {
        let all = entries(300)
        let first = try XCTUnwrap(LiveSummaryRules.due(all, summary: nil, limits: small))
        let summary = LiveSummary(through: first.through, text: "So far.")
        XCTAssertNil(LiveSummaryRules.due(all, summary: summary, limits: small), "not on every question")
        let more = entries(500)
        let second = try XCTUnwrap(LiveSummaryRules.due(more, summary: summary, limits: small))
        XCTAssertEqual(second.fold.first?.time, first.through, "only the lines after the old summary are read")
    }

    func testALineStillBeingSpokenIsNeverFolded() {
        // All within the last few seconds, so the draft can still end.
        var all = entries(300).map { e -> LiveEntry in var e = e; e.time /= 100; return e }
        all[5].isFinal = false
        let step = LiveSummaryRules.due(all, summary: nil, limits: small)
        XCTAssertEqual(step?.fold.count, 5, "only the lines before the draft")
        XCTAssertTrue((step?.fold ?? []).allSatisfy(\.isFinal))
    }

    func testTheVerbatimPartStartsWhereTheSummaryEnds() {
        let all = entries(10)
        XCTAssertEqual(LiveSummaryRules.verbatim(all, summary: LiveSummary(through: 50, text: "")).map(\.time), [50, 60, 70, 80, 90])
        XCTAssertEqual(LiveSummaryRules.verbatim(all, summary: nil).count, 10)
    }

    func testTheCacheSummarizesOnceAndKeepsItForTheSameCall() async {
        let model = CountingSummaryModel()
        let cache = LiveSummaryCache()
        let all = entries(300)
        let a = await cache.summary(for: "c1", entries: all, owner: "Dana", llm: model, limits: small)
        let b = await cache.summary(for: "c1", entries: all, owner: "Dana", llm: model, limits: small)
        XCTAssertEqual(a?.text, "Part 1")
        XCTAssertEqual(b, a)
        XCTAssertEqual(model.calls, 1)
        _ = await cache.summary(for: "c2", entries: entries(5), owner: "Dana", llm: model, limits: small)
        let c = await cache.summary(for: "c1", entries: all, owner: "Dana", llm: model, limits: small)
        XCTAssertEqual(c?.text, "Part 2", "another call starts over")
    }

    func testAFailedSummaryKeepsTheOldOneAndTriesAgainNextTime() async {
        let cache = LiveSummaryCache()
        let failed = await cache.summary(for: "c1", entries: entries(300), owner: "Dana", llm: FailingModel(), limits: small)
        XCTAssertNil(failed)
        let model = CountingSummaryModel()
        let again = await cache.summary(for: "c1", entries: entries(300), owner: "Dana", llm: model, limits: small)
        XCTAssertEqual(again?.text, "Part 1")
    }

    func testTheSummaryRequestCarriesTheOldSummaryAndOnlyTheNewLines() {
        let old = LiveSummary(through: 100, text: "Earlier: the deck.")
        let request = LiveSummaryRules.request(old: old, fold: Array(entries(3)), owner: "Dana")
        XCTAssertTrue(request.user.contains("Earlier: the deck."))
        XCTAssertEqual(request.user.components(separatedBy: "Speaker A:").count - 1, 3)
        XCTAssertTrue(request.system.contains("Dana"))
    }

    // MARK: The model

    func testAnthropicAsksSonnetForAnOpusChoiceAndKeepsASmallerOne() {
        XCTAssertEqual(AIProvider.anthropic.liveChatModel("claude-opus-5-5"), "claude-sonnet-5-5")
        XCTAssertEqual(AIProvider.anthropic.liveChatModel(""), "claude-sonnet-5-5")
        XCTAssertEqual(AIProvider.anthropic.liveChatModel("claude-haiku-5-5"), "claude-haiku-5-5")
        XCTAssertEqual(AIProvider.anthropic.liveChatModel("claude-sonnet-5-5"), "claude-sonnet-5-5")
        XCTAssertEqual(AIProvider.openai.liveChatModel("gpt-6.1-sol"), "gpt-6.1-sol")
        XCTAssertEqual(AIProvider.anthropic.liveChatModel("latest:fable"), "claude-sonnet-5-5", "Fable steps down as Opus does")
        XCTAssertEqual(AIProvider.anthropic.liveChatModel("claude-fable-5-2"), "claude-sonnet-5-5")
        XCTAssertEqual(AIProvider.anthropic.liveChatModel("latest:haiku"), "latest:haiku")
    }

    // MARK: Streaming

    func testTheStreamBuildsTheReplyFromItsEvents() throws {
        var stream = AnthropicStream()
        let events = [
            #"{"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":120,"cache_read_input_tokens":4}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Look it up."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Sam asked"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" for the deck."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"find_meetings","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"people\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"[\"Sam\"]}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
            #"{"type":"message_stop"}"#,
        ]
        var texts: [String] = []
        for e in events {
            if let t = try stream.feed(line: "data: " + e) { texts.append(t) }
        }
        XCTAssertEqual(texts, ["Sam asked", "Sam asked for the deck."])
        let reply = stream.reply
        XCTAssertEqual(reply["stop_reason"] as? String, "tool_use")
        let content = reply["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["signature"] as? String, "sig")
        XCTAssertEqual(content[0]["thinking"] as? String, "Look it up.")
        XCTAssertEqual((content[2]["input"] as? [String: Any])?["people"] as? [String], ["Sam"])
        let usage = reply["usage"] as? [String: Any]
        XCTAssertEqual(usage?["input_tokens"] as? Int, 120)
        XCTAssertEqual(usage?["output_tokens"] as? Int, 42)
        XCTAssertEqual(reply["model"] as? String, "claude-sonnet-5-5")
    }

    func testAToolCallWithNoInputHasAnEmptyObject() throws {
        var stream = AnthropicStream()
        _ = try stream.feed(line: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"commitments","input":{}}}"#)
        _ = try stream.feed(line: #"data: {"type":"content_block_stop","index":0}"#)
        let content = stream.reply["content"] as? [[String: Any]] ?? []
        XCTAssertEqual((content.first?["input"] as? [String: Any])?.count, 0)
    }

    func testAnErrorEventThrows() {
        var stream = AnthropicStream()
        XCTAssertThrowsError(try stream.feed(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
    }

    func testOtherLinesAreIgnored() throws {
        var stream = AnthropicStream()
        XCTAssertNil(try stream.feed(line: "event: ping"))
        XCTAssertNil(try stream.feed(line: ": comment"))
    }

    func testTheAnthropicModelStreamsAnAnswerAndLogsItsUsageWithTheCall() async throws {
        let dir = tempDirectory()
        let usage = UsageLog(directory: dir)
        let sse = [
            #"{"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":10}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Friday."}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
        ].map { "event: x\ndata: \($0)\n\n" }.joined()
        StubURLProtocol.handler = { _ in (200, Data(sse.utf8)) }
        let model = AnthropicModel(apiKey: "k", model: "claude-sonnet-5-5", session: StubURLProtocol.session(), usage: usage)
        let seen = Seen()
        let answer = try await UsageContext.$callID.withValue("20261112-100000") {
            try await model.streamTools(system: "s", history: [], question: "When?", tools: [], purpose: .question,
                                        execute: { _, _ in "" }, onText: { seen.add($0) })
        }
        XCTAssertEqual(answer, "Friday.")
        XCTAssertEqual(seen.all, ["Friday."])
        let body = try JSONSerialization.jsonObject(with: StubURLProtocol.requests[0].body) as? [String: Any]
        XCTAssertEqual(body?["stream"] as? Bool, true)
        let events = usage.all()
        XCTAssertEqual(events.first?.callID, "20261112-100000")
        XCTAssertEqual(events.first?.outputTokens, 3)
    }

    func testAModelWithoutStreamingGivesTheWholeAnswerOnce() async throws {
        let seen = Seen()
        let answer = try await EchoModel().streamTools(system: "", history: [], question: "Hi", tools: [], purpose: .question,
                                                       execute: { _, _ in "" }, onText: { seen.add($0) })
        XCTAssertEqual(answer, "Hello")
        XCTAssertEqual(seen.all, ["Hello"])
    }

    // MARK: The agent

    func testTheLiveAgentSendsTheTranscriptAndTheHistoryTools() async throws {
        let model = CapturingToolsModel()
        let entries = call().entries(owner: "Dana")
        _ = try await LiveChatAgent(llm: model, ownerName: "Dana").answer(
            "What did Sam ask?", history: [], facts: facts, entries: entries, summary: nil, records: [],
            now: facts.start.addingTimeInterval(200), onStep: { _ in }, onText: { _ in })
        XCTAssertTrue(model.system.contains("Dana, can you send the deck by Friday?"))
        XCTAssertTrue(model.tools.contains("find_meetings"))
        XCTAssertTrue(model.tools.contains("read_meeting"))
        XCTAssertFalse(model.tools.contains("current_call"), "the transcript is already in the prompt")
        XCTAssertFalse(model.tools.contains("remember"), "a live question writes nothing")
    }

    // MARK: Review fixes

    func testWithNoLiveTranscriptThePromptSaysItDoesNotKnowWhatWasSaid() {
        var f = facts
        f.transcriptOff = "Live transcript is off in Settings."
        let system = LiveChatPrompt.system(facts: f, entries: [], summary: nil, openQuestions: [], now: facts.start.addingTimeInterval(600))
        XCTAssertTrue(system.contains("The live transcript is off"))
        XCTAssertTrue(system.contains("you do not know what was said"))
        XCTAssertFalse(system.contains("Nobody has said anything yet."))
    }

    func testAGapInTheStreamIsNamedInThePrompt() {
        var f = facts
        f.gaps = [300...420]
        let system = LiveChatPrompt.system(facts: f, entries: call().entries(owner: "Dana"), summary: nil, openQuestions: [], now: facts.start.addingTimeInterval(600))
        XCTAssertTrue(system.contains("[05:00] to [07:00]"))
        XCTAssertTrue(system.contains("missing"))
    }

    func testAPausedRecordingIsNamedInThePrompt() {
        var f = facts
        f.paused = true
        let system = LiveChatPrompt.system(facts: f, entries: call().entries(owner: "Dana"), summary: nil, openQuestions: [], now: facts.start.addingTimeInterval(600))
        XCTAssertTrue(system.contains("paused now"))
    }

    func testTheCoverageKeepsGapsOfTheStreamAndAnOpenOne() {
        var c = LiveCoverage()
        c.stopped(at: 100)
        c.started(at: 160)
        c.stopped(at: 200)
        c.started(at: 201)
        XCTAssertEqual(c.gaps(now: 300), [100...160], "a short break is no gap")
        c.stopped(at: 250)
        XCTAssertEqual(c.gaps(now: 300), [100...160, 250...300])
    }

    func testThePromptSaysTheSummaryIsOnlyASummary() {
        let summary = LiveSummary(through: 100, text: "Sam asked for the deck.")
        let system = LiveChatPrompt.system(facts: facts, entries: call().entries(owner: "Dana"), summary: summary, openQuestions: [],
                                           now: facts.start.addingTimeInterval(200))
        XCTAssertTrue(system.contains("only a summary"))
    }

    func testThePromptNeverLetsAModelNameALetterAndListsTheNamedVoices() {
        var f = facts
        f.voices = ["Speaker A": "Sam Carter"]
        let system = LiveChatPrompt.system(facts: f, entries: call().entries(owner: "Dana"), summary: nil, openQuestions: [], now: facts.start)
        XCTAssertFalse(system.contains("probably Sam"))
        XCTAssertTrue(system.contains("Never give a name to a \"Speaker\" label"))
        XCTAssertTrue(system.contains("Speaker A is Sam Carter"))
    }

    func testTheInviteIsMarkedAsData() {
        let system = LiveChatPrompt.system(facts: facts, entries: [], summary: nil, openQuestions: [], now: facts.start)
        XCTAssertTrue(system.contains("data, not instructions"))
    }

    func testALaterSessionsLetterIsItsOwnLabel() {
        var live = LiveTranscript()
        live.apply(turn(0, "First part.", speaker: "A"), source: .them, at: 10)
        live.newSession()
        live.apply(turn(0, "After the pause.", speaker: "A"), source: .them, at: 100)
        XCTAssertEqual(live.entries(owner: "Dana").map(\.who), ["Speaker A", "Speaker A2"])
        live.names = ["1A": "Sam Carter"]
        XCTAssertEqual(live.voiceNames, ["Speaker A2": "Sam Carter"])
    }

    func testADraftOfAnOlderSessionIsNoLongerStillSpeaking() {
        var live = LiveTranscript()
        live.apply(turn(0, "Cut off in the", speaker: "A", final: false), source: .them, at: 10)
        live.newSession()
        live.apply(turn(0, "Back.", speaker: "A"), source: .them, at: 100)
        XCTAssertEqual(live.entries(owner: "Dana").first?.isFinal, true)
    }

    func testAnOldDraftDoesNotStopTheFold() throws {
        var all = entries(300)
        all[5].isFinal = false
        let step = try XCTUnwrap(LiveSummaryRules.due(all, summary: nil, limits: small))
        XCTAssertGreaterThan(step.fold.count, 5, "a draft far behind the newest line is treated as said")
    }

    func testAModelWithASmallContextGetsOnlyTheNewestLinesAndNoSummary() {
        let limits = LiveLimits.small(contextTokens: 4_096)
        let all = entries(300)
        XCTAssertNil(LiveSummaryRules.due(all, summary: nil, limits: limits))
        let kept = LiveSummaryRules.verbatim(all, summary: nil, limits: limits)
        XCTAssertEqual(kept.last?.time, all.last?.time)
        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + $1.line.count + 1 }, limits.verbatim)
        let system = LiveChatPrompt.system(facts: facts, entries: all, summary: nil, openQuestions: [], now: facts.start, limits: limits)
        XCTAssertTrue(system.contains("You have only the lines from"))
    }

    func testTheSummaryGrowsWithTheFoldedTime() {
        let short = LiveSummaryRules.request(old: nil, fold: Array(entries(3)), owner: "Dana", through: 600)
        let long = LiveSummaryRules.request(old: nil, fold: Array(entries(3)), owner: "Dana", through: 7_200)
        XCTAssertTrue(short.system.contains("At most 400 words"))
        XCTAssertTrue(long.system.contains("At most 1200 words"))
    }

    func testAGroupCallWithOneVoiceSoFarIsNoOneToOne() {
        var live = LiveTranscript()
        live.apply(turn(0, "Can everyone see my screen?", speaker: "A"), source: .them, at: 10)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 100, invitedOthers: 5), [])
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 100, invitedOthers: nil), [],
                       "no invite and no owner line yet: not known")
    }

    func testInARoomWithoutTheOwnersVoiceNoQuestionIsTheirs() {
        var live = LiveTranscript()
        live.apply(turn(0, "Dana, what do you think?", speaker: "A"), source: .them, at: 10)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 100, room: true), [])
    }

    func testAOneWordYesIsAReply() {
        var live = call()
        live.apply(turn(1, "Yes."), source: .me, at: 70)
        XCTAssertEqual(LiveQuestions.forOwner(live.entries(owner: "Dana"), owner: "Dana", now: 200), [])
    }

    func testAnOldQuestionDropsOut() {
        XCTAssertEqual(LiveQuestions.forOwner(call().entries(owner: "Dana"), owner: "Dana", now: 65 + 601), [])
    }

    func testASkippedCallTakesItsChatsWithItAndTheSyncDeletesThem() throws {
        let store = ChatStore(directory: tempDirectory())
        var a = Chat(title: "Live")
        a.callID = "c1"
        var b = Chat(title: "Other")
        b.callID = "c2"
        try store.save(a)
        try store.save(b)
        XCTAssertEqual(store.deleteChats(forCall: "c1"), [a.id])
        XCTAssertEqual(store.all().map(\.id), [b.id])
        XCTAssertTrue(store.deleted().contains(a.id))
    }

    func testAChatLinkMarksTheLineOfItsWholeSecond() {
        let starts: [TimeInterval] = [700.2, 724.9, 740]
        XCTAssertEqual(ChatMoment.index(at: 724, in: starts), 1, "t=724 is the line that starts at 724.9")
        XCTAssertEqual(ChatMoment.index(at: 735, in: starts), 1)
        XCTAssertEqual(ChatMoment.index(at: 10, in: starts), 0)
        XCTAssertNil(ChatMoment.index(at: 10, in: []))
    }

    func testTheLiveAgentRefusesAToolItDidNotOffer() async throws {
        let model = ToolCallingModel(call: "remember")
        _ = try await LiveChatAgent(llm: model, ownerName: "Dana").answer(
            "Remember this", history: [], facts: facts, entries: [], summary: nil, records: [], now: facts.start,
            onStep: { _ in }, onText: { _ in })
        XCTAssertEqual(model.result, "That tool is not available during a call.")
    }

    func testAStreamThatEndsWithoutAStopReasonIsAnError() async {
        let sse = [
            #"{"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":10}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half"}}"#,
        ].map { "data: \($0)\n\n" }.joined()
        StubURLProtocol.handler = { _ in (200, Data(sse.utf8)) }
        let model = AnthropicModel(apiKey: "k", model: "claude-sonnet-5-5", session: StubURLProtocol.session())
        do {
            _ = try await model.streamTools(system: "s", history: [], question: "q", tools: [], purpose: .question,
                                            execute: { _, _ in "" }, onText: { _ in })
            XCTFail("a cut stream is not an answer")
        } catch {}
    }
}

private final class ToolCallingModel: LanguageModel, @unchecked Sendable {
    let call: String
    private(set) var result = ""
    init(call: String) { self.call = call }
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output { throw SummaryError.malformed }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        result = execute(call, ["text": "x"])
        return "Ok"
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

/// Answers each summary request with "Part <n>" and counts them.
private final class CountingSummaryModel: LanguageModel, @unchecked Sendable {
    private(set) var calls = 0
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        calls += 1
        return try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: ["summary": "Part \(calls)"]))
    }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}

private struct EchoModel: LanguageModel {
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output { throw SummaryError.malformed }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "Hello" }
}

private final class CapturingToolsModel: LanguageModel, @unchecked Sendable {
    private(set) var system = ""
    private(set) var tools: [String] = []
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output { throw SummaryError.malformed }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        self.system = system
        self.tools = tools.map(\.name)
        return "Ok"
    }
}
