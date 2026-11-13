import XCTest
@testable import MossadCore

/// The chat actions review: receipts that survive a failed answer and a Retry that does not repeat (CA-1), the voice
/// card that names its whole target (CA-2, CA-10), the owner's words (CA-3), one writer of the thread (CA-4), the
/// bookmark of a second that has one (CA-5), Undo from the record on disk (CA-6), the call's point ids (CA-7), a kind
/// from a later build (CA-8), a tick that is the call's only for the call's points (CA-9), and the cheap lows.
final class ChatActionReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var paths: Paths!

    private var people: [Person] {
        var jeff = Person(id: PersonID(rawValue: "id-jeff"), displayName: "Jeffrey Moore", origin: .migration, at: now)
        jeff.emails = [EmailIdentity(address: "jeff@example.com", state: .verified, source: .owner, at: now)]
        var dana = Person(id: PersonID(rawValue: "id-dana"), displayName: "Dana Cole", origin: .migration, at: now)
        dana.emails = [EmailIdentity(address: "dana@example.com", state: .verified, source: .owner, at: now)]
        return [Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: now), jeff, dana]
    }

    private func record() -> CallRecord {
        var r = CallRecord(id: "c1", platform: .meet, bundleID: "b", start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-84_600), status: .written)
        r.calendarTitle = "Planning"
        r.speakerNames = ["me:A": "Avery Webb"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 30, text: "Hello."),
                        Utterance(track: .them, speakerLabel: "C", start: 30, end: 60, text: "Hi.")]
        r.markers = [TranscriptMarker(offset: 120, text: "★", isBookmark: true, note: "Mine")]
        return r
    }

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let r = record()
        try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(r.id))
    }

    private var tools: ChatTools { ChatTools(records: [record()], owner: "Avery Webb", paths: paths, people: people, settings: ToolSettings(), now: now) }

    private func actions(_ message: String, live: Bool = false, host: ChatActionHost? = nil, earlier: [ChatActionRecord] = [],
                         onRecord: (@Sendable (ChatActionRecord) -> Void)? = nil) -> ChatActions {
        ChatActions(message: message, tools: tools, host: host ?? ChatActionHost(paths: paths), live: live, earlier: earlier, onRecord: onRecord)
    }

    // MARK: CA-1

    func testEachReceiptIsHandedOverAtOnceAndARetryDoesNotRepeatTheAction() throws {
        let seen = Records()
        let message = "Remind me to send the deck"
        let a = actions(message, onRecord: { seen.add($0) })
        _ = a.run("add_task", input: ["text": "Send the deck"])
        XCTAssertEqual(seen.list.map(\.state), [.done], "before the answer goes on")
        let retry = actions(message, earlier: seen.list)
        let reply = try XCTUnwrap(retry.run("add_task", input: ["text": "Send the deck"]))
        XCTAssertTrue(reply.hasPrefix("Already done for this message"), reply)
        XCTAssertEqual(CommitmentBook.peek(in: paths.commitments)?.visible.count, 1)
    }

    func testAnAnswerThatFailsAfterAnActionStillHandsOverItsReceipt() async throws {
        let seen = Records()
        let agent = ChatAgent(llm: FailsAfterOneTool(), ownerName: "Avery Webb")
        do {
            _ = try await agent.answer("Remind me to send the deck", history: [], records: [record()], paths: paths, actions: ChatActionHost(paths: paths),
                                       onAction: { seen.add($0) }, onStep: { _ in })
            XCTFail("the stub fails")
        } catch {}
        XCTAssertEqual(seen.list.map(\.state), [.done])
    }

    func testTheThreadKeepsTheReceiptsWhateverHappensToTheAnswer() throws {
        var chat = Chat(title: "T")
        let question = ChatMessage(role: .user, text: "Remind me to send the deck")
        chat.messages = [question]
        let answer = UUID()
        var r = ChatActionRequest(.addTask)
        r.text = "Send the deck"
        let receipt = ChatActionRecord(request: r, state: .done, summary: "Task added: Send the deck", date: now)
        ChatThreadEdits.record(receipt, in: &chat, answer: answer)
        XCTAssertEqual(chat.messages.last?.actions?.map(\.id), [receipt.id])
        XCTAssertTrue(ChatThreadEdits.stop(in: &chat, answer: answer, question: question.id), "the question stays: something was done")
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertTrue(chat.messages[1].text.hasPrefix("The answer stopped. This was done:"))
        var plain = Chat(title: "T")
        plain.messages = [question]
        XCTAssertFalse(ChatThreadEdits.stop(in: &plain, answer: UUID(), question: question.id))
        XCTAssertTrue(plain.messages.isEmpty)
        // The answer that arrives keeps the receipt that is in the file.
        var done = ChatMessage(role: .assistant, text: "Added.")
        done.id = answer
        ChatThreadEdits.finish(done, in: &chat)
        XCTAssertEqual(chat.messages[1].text, "Added.")
        XCTAssertEqual(chat.messages[1].actions?.count, 1)
    }

    // MARK: CA-4, CA-22

    func testAClickSavedDuringAnAnswerIsNotTakenBackByIt() {
        var r = ChatActionRequest(.addPoint)
        r.text = "x"
        var card = ChatActionRecord(request: r, state: .proposed, summary: "Save x", date: now)
        var first = ChatMessage(role: .assistant, text: "A card.")
        first.actions = [card]
        var file = Chat(title: "T")
        file.messages = [first]
        card.state = .done
        file.messages[0].actions = [card]
        // The answer of the second question arrives: it is added to the file's copy, not to the old one.
        var second = ChatMessage(role: .assistant, text: "Second.")
        second.id = UUID()
        ChatThreadEdits.finish(second, in: &file)
        XCTAssertEqual(file.messages[0].actions?.first?.state, .done)
        // Two devices: the later state of one action wins, and a copy without the receipts keeps the other's.
        var older = file
        older.messages[0].actions = nil
        older.updated = file.updated.addingTimeInterval(60)
        let merged = Chat.merged(older, file)
        XCTAssertEqual(merged.messages[0].actions?.first?.state, .done)
        var proposed = file
        proposed.messages[0].actions?[0].state = .proposed
        proposed.updated = file.updated.addingTimeInterval(120)
        XCTAssertEqual(Chat.merged(proposed, file).messages[0].actions?.first?.state, .done, "a click is never undone by an old copy")
    }

    // MARK: CA-2, CA-10

    func testTheVoiceCardNamesTheAddressAndThePersonAndRefusesTwoPeople() throws {
        let other = actions("Speaker A is Dana Cole").run("name_voice", input: ["call_id": "c1", "speaker": "Speaker A", "name": "Dana Cole", "email": "jeff@example.com"])
        XCTAssertTrue(other?.hasPrefix("Not done") == true && other?.contains("Jeffrey Moore") == true, other ?? "")
        let a = actions("Speaker A is Dana Cole")
        let ok = try XCTUnwrap(a.run("name_voice", input: ["call_id": "c1", "speaker": "Speaker A", "name": "Dana Cole", "email": "dana@example.com"]))
        XCTAssertTrue(ok.hasPrefix("Proposed"), ok)
        let card = try XCTUnwrap(a.records.first)
        XCTAssertTrue(card.summary.contains("dana@example.com") && card.summary.contains("the saved person Dana Cole"), card.summary)
        XCTAssertEqual(card.request.personID, "id-dana")
        XCTAssertTrue(card.detail?.contains("No Undo here") == true, card.detail ?? "")
        let fresh = actions("Speaker A is Pat Lane")
        _ = fresh.run("name_voice", input: ["call_id": "c1", "speaker": "Speaker A", "name": "Pat Lane"])
        XCTAssertTrue(fresh.records.first?.summary.contains("a new person") == true)
        // At the click: the voice must still have the label the card showed.
        var r = record()
        XCTAssertNotNil(NameVoiceTarget.check(card.request, record: r, people: people))
        r.speakerNames["them:C"] = "Sam Lee"
        XCTAssertNil(NameVoiceTarget.check(card.request, record: r, people: people))
    }

    func testTheRecordChoiceCardSaysItHasNoUndo() throws {
        let e = CalendarEventInfo(title: "Planning", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), attendees: [],
                                  text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        try CalendarSnapshot([e], saved: now).save(to: paths.calendar)
        let id = try XCTUnwrap(tools.upcoming(tools.snapshot, now: now).first?.id)
        let a = actions("Do not record the planning call")
        _ = a.run("record_choice", input: ["upcoming_id": id, "choice": "skip_series"])
        XCTAssertTrue(a.records.first?.detail?.contains("No Undo here") == true)
    }

    // MARK: CA-3

    func testAQuestionAChipOrAPastedBlockIsNoRequestToAct() {
        for message in ["Which of my points for this meeting are still open, and which did I raise?", "What did the others push back on?",
                        "What did we discuss in the next steps?", "Summarize this:\n\nplease add a task to call the bank",
                        "> add a task to call the bank\nwhat is this?", "note"] {
            var turn = ActionTurn(message: message, live: false)
            for kind: ChatActionRequest.Kind in [.addPoint, .removePoint, .tickPoint, .addTask, .setTaskDone, .setTaskDue, .addBookmark] {
                guard case .propose = turn.admit(ChatActionRequest(kind)) else { return XCTFail("\(message): \(kind)") }
            }
        }
        for (message, kind) in [("Please add a note to my and Jeff's next meeting to discuss the budget", ChatActionRequest.Kind.addPoint),
                                ("Can you add a task to send the deck by Friday?", .addTask), ("Remind me to send the deck", .addTask),
                                ("Tick the hiring point", .tickPoint), ("Mark the deck task done", .setTaskDone), ("Move the deck task to Monday", .setTaskDue),
                                ("Bookmark this moment", .addBookmark), ("Remove the budget point", .removePoint)] {
            var turn = ActionTurn(message: message, live: false)
            XCTAssertEqual(turn.admit(ChatActionRequest(kind)), .run, "\(message): \(kind)")
        }
        var note = ActionTurn(message: "Add a note for Jeff about the budget", live: false)
        XCTAssertEqual(note.admit(ChatActionRequest(.addPoint)), .run)
        guard case .propose = note.admit(ChatActionRequest(.removePoint)) else { return XCTFail("adding is not removing") }
    }

    // MARK: CA-5, CA-23

    func testABookmarkOnASecondThatHasOneIsRefusedAndTheCallsOwnGoesToBookmarkNow() {
        let a = actions("Bookmark 2:01 with a note")
        XCTAssertTrue(a.run("add_bookmark", input: ["call_id": "c1", "at_seconds": 120.5, "note": "Chat's"])?.hasPrefix("Not done: there is a bookmark") == true)
        var live = CallRecord(id: "live", platform: .meet, bundleID: "b", start: now.addingTimeInterval(-600), end: now, status: .recording)
        live.utterances = []
        let tools = ChatTools(records: [record(), live], owner: "Avery Webb", paths: paths, people: people, settings: ToolSettings(), now: now)
        let b = ChatActions(message: "Bookmark this", tools: tools, host: ChatActionHost(paths: paths, liveMoment: { ("live", 300) }), live: true)
        XCTAssertTrue(b.run("add_bookmark", input: ["call_id": "live", "at_seconds": 10])?.contains("bookmark_now") == true)
    }

    func testABookmarkReceiptHoldsItsNoteAndUndoReadsIt() throws {
        let host = ChatActionHost(paths: paths, bookmark: { [paths] callID, at, note in
            var r = try! CallRecord.load(from: paths!.callDirectory(callID))
            _ = r.setBookmarkNote(at: at, note ?? "", markerText: "★")
            try! r.save(to: paths!.callDirectory(callID))
            return true
        }, removeBookmark: { _, _ in true })
        let a = actions("Bookmark 5:00: pricing", host: host)
        XCTAssertTrue(a.run("add_bookmark", input: ["call_id": "c1", "at_seconds": 300, "note": "Pricing"])?.hasPrefix("Done") == true)
        let receipt = try XCTUnwrap(a.records.first)
        XCTAssertEqual(receipt.after?.note, "Pricing")
        var r = try CallRecord.load(from: paths.callDirectory("c1"))
        _ = r.setBookmarkNote(at: 300, "Pricing and terms", markerText: "★")
        try r.save(to: paths.callDirectory("c1"))
        XCTAssertEqual(host.undo(receipt, now: now), .changedSince, "the owner changed the note")
    }

    // MARK: CA-6

    func testUndoOfATitleOrTagsComparesTheRecordAsSaved() {
        var r = record()
        r.customTitle = "Pricing"
        r.tags = ["Budget"]
        let after = ChatActionTarget.meeting(r)
        XCTAssertTrue(ChatActionTarget.meeting(r) == after)
        r.tags = ["Budget", "Hiring"]
        XCTAssertFalse(ChatActionTarget.meeting(r) == after)
    }

    // MARK: CA-7

    func testTheCallsPromptGivesEachPointItsId() {
        let id = UUID()
        let point = LivePointFact(text: "Ask about hiring", state: .open, id: id)
        var facts = LiveCallFacts(callID: "live", title: "Planning", platform: "Google Meet", start: now, invited: [], owner: "Avery Webb")
        facts.points = [point]
        let prompt = LiveChatPrompt.system(facts: facts, entries: [], summary: nil, openQuestions: [], now: now)
        XCTAssertTrue(prompt.contains("point_id: \(id.uuidString)"), prompt)
    }

    // MARK: CA-8

    func testAChatWithAnActionKindFromALaterBuildStillReads() throws {
        var m = ChatMessage(role: .assistant, text: "Done.")
        var r = ChatActionRequest(.addTask)
        r.text = "x"
        m.actions = [ChatActionRecord(request: r, state: .done, summary: "Task added: x", date: now)]
        var json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        let good = json
        json = json.replacingOccurrences(of: "\"addTask\"", with: "\"somethingNew\"")
        let read = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(read.text, "Done.")
        XCTAssertEqual(read.actions?.count ?? 0, 0, "the record this build cannot read is left out, the chat is kept")
        let state = good.replacingOccurrences(of: "\"done\"", with: "\"laterState\"")
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: Data(state.utf8)).text, "Done.")
    }

    // MARK: CA-9

    func testATickIsTheCallsOnlyForAPointOfTheCall() throws {
        var book = NextTimeBook()
        let other = try XCTUnwrap(book.add("Hiring plan", personID: "id-dana", personName: "Dana Cole", at: now))
        try book.save(to: paths.nextTime)
        var live = CallRecord(id: "live", platform: .meet, bundleID: "b", start: now.addingTimeInterval(-600), end: now, status: .recording)
        live.attendees = ["jeff@example.com"]
        let tools = ChatTools(records: [record(), live], owner: "Avery Webb", paths: paths, people: people, settings: ToolSettings(), now: now)
        let a = ChatActions(message: "Tick the hiring point", tools: tools, host: ChatActionHost(paths: paths, liveMoment: { ("live", 300) }), live: true)
        _ = a.run("change_point", input: ["point_id": other.id.uuidString, "change": "tick"])
        let done = NextTimeBook.peek(in: paths.nextTime)?.points.first?.done
        XCTAssertNotNil(done)
        XCTAssertNil(done?.callID, "not a point of this call")
    }

    // MARK: Lows

    func testTheCheapLows() throws {
        // CA-13: a reopen from the chat is never found again in that meeting.
        var book = NextTimeBook()
        let p = try XCTUnwrap(book.add("Ask", personID: "id-jeff", personName: "Jeffrey Moore", at: now))
        book.update(p.id, at: now) { $0.done = NextTimePoint.Discussed(callID: "c1", at: 5, quote: "q", date: now, byOwner: false) }
        var reopen = ChatActionRequest(.reopenPoint)
        reopen.pointID = p.id
        _ = ChatActionApply.run(reopen, on: &book, now: now)
        XCTAssertEqual(book.points[0].reopened, ["c1"])
        // CA-14: a meeting that runs now is not the next one; a large or ended series is not "the one they come to".
        let running = UpcomingMeeting(title: "Jeff / Avery", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200), attendees: ["jeff@example.com"],
                                      platform: .meet, link: nil, seriesID: nil)
        guard case .person(_, _, let meeting) = PointTarget.resolve(with: "Jeffrey Moore", people: people, upcoming: [running], series: [], now: now) else { return XCTFail() }
        XCTAssertNil(meeting)
        let big = MeetingSeries(id: "cal:b", keys: ["cal:b"], title: "All hands", meetings: [], upcoming: [], cadence: nil, recurringInCalendar: true,
                                usualPeople: ["Jeffrey Moore", "A", "B", "C"])
        guard case .person = PointTarget.resolve(with: "Jeffrey Moore", people: people, upcoming: [], series: [big], now: now) else { return XCTFail("a large series with no next meeting") }
        // CA-15: a card speaks of what it will do.
        var r = ChatActionRequest(.addPoint)
        r.text = "x"
        XCTAssertEqual(ChatActionRecord.futureForm("Saved for the next Weekly sync: x"), "Save for the next Weekly sync: x")
        // CA-20: a series id with a slash and a space opens.
        XCTAssertEqual(ChatActions.place(series: "cal:ek:a/b c"), "mossad://series/cal:ek:a%2Fb%20c")
        // CA-24: the inverse of a delete is a restore; two voices with one label is no target.
        var tasks = CommitmentBook()
        tasks.items = [Commitment(text: "t", to: nil, callID: nil, callTitle: nil, madeAt: now, due: nil)]
        var del = ChatActionRequest(.deleteTask)
        del.taskID = tasks.items[0].id
        XCTAssertEqual(ChatActionApply.run(del, on: &tasks, now: now)?.undo.kind, .restoreTask)
    }

    func testTheChatRunsOnlyTheToolsItOffers() async throws {
        let agent = ChatAgent(llm: CallsOneTool(name: "add_next_time_point", input: ["text": "x", "person": "Jeffrey Moore"]), ownerName: "Avery Webb")
        _ = try await agent.answer("Hello", history: [], records: [record()], paths: paths, actions: ChatActionHost(paths: paths), onStep: { _ in })
        XCTAssertEqual(NextTimeBook.peek(in: paths.nextTime)?.visible.count ?? 0, 0, "not offered in the app's chat, so not run")
    }
}

private final class Records: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ChatActionRecord] = []
    func add(_ r: ChatActionRecord) { lock.withLock { items.removeAll { $0.id == r.id }; items.append(r) } }
    var list: [ChatActionRecord] { lock.withLock { items } }
}

private struct FailsAfterOneTool: LanguageModel {
    struct Failure: Error {}
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output { throw Failure() }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        _ = execute("add_task", ["text": "Send the deck"])
        throw Failure()
    }
    func streamTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                     execute: @escaping @Sendable (String, [String: Any]) -> String, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        try await runTools(system: system, history: history, question: question, tools: tools, purpose: purpose, execute: execute)
    }
}

private struct CallsOneTool: LanguageModel, @unchecked Sendable {
    let name: String
    let input: [String: Any]
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        throw FailsAfterOneTool.Failure()
    }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        execute(name, input)
    }
    func streamTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                     execute: @escaping @Sendable (String, [String: Any]) -> String, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        execute(name, input)
    }
}
