import XCTest
@testable import MossadCore

/// The re-check of the review fixes: "Keep a read" off hides and stops sending, it never deletes (N1); a failed
/// answer keeps its question and Retry works (N2); the server's copy loses a deleted chat (N3); only a Retry of the
/// same message is refused (N4); pasted text is never the owner's words (N5); and the cheap lows.
final class RecheckTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func person(_ id: String, _ name: String, off: Bool = false, email: String? = nil) -> Person {
        var p = Person(id: PersonID(rawValue: id), displayName: name, origin: .migration, at: now)
        p.doNotProfile = off
        if let email { p.emails = [EmailIdentity(address: email, state: .verified, source: .owner, at: now)] }
        return p
    }

    private func paths(people: [Person]) throws -> Paths {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        try SharedPayload.people(people).data.write(to: paths.people.appendingPathComponent(PeopleStore.fileName))
        return paths
    }

    private func profileWithDana() -> CoachProfile {
        var p = CoachProfile()
        var d = CoachPerson(note: "Dana NOTE", calls: 2, lastSeen: now)
        d.person = "id-dana"
        p.people["Dana Lee"] = d
        p.updateFacts(add: [CoachFact(kind: .relationship, text: "Dana Lee is my manager", person: "id-dana")], remove: [], at: now)
        return p
    }

    // MARK: N1

    private final class Coach: Coaching, @unchecked Sendable {
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult {
            var q = CoachQuestion(statement: "Dana prefers email.", kind: .relationship, evidence: "e", callID: record.id, at: 5, asked: Date())
            q.person = "id-dana"
            return CoachResult(review: CoachReview(headline: "H", overview: "O", strengths: [], improvements: [], focusProgress: nil),
                               update: CoachProfileUpdate(summary: "S", focus: "F", patterns: [],
                                                          people: [CoachPersonUpdate(name: "Dana Lee", note: "NEW Dana note"), CoachPersonUpdate(name: "Sam Carter", note: "Sam new")]),
                               questions: [q])
        }
    }

    func testACoachReviewRemovesNothingAndAddsNothingAboutAPersonWhoKeepsNoRead() async throws {
        let paths = try paths(people: [person("id-dana", "Dana Lee", off: true), person("id-sam", "Sam Carter")])
        try profileWithDana().save(to: paths.coach)
        var r = CallRecord(id: "a", platform: .meet, bundleID: "", start: now, end: now.addingTimeInterval(1800), status: .written)
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Dana Lee", "them:B": "Sam Carter"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 120, text: "Let me walk through the plan."),
                        Utterance(track: .them, speakerLabel: "A", start: 121, end: 150, text: "Sounds good.")]
        try FileManager.default.createDirectory(at: paths.callDirectory("a"), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory("a"))
        _ = await CoachRunner(paths: paths, coach: Coach(), owner: "Avery Webb", since: .distantPast).run()
        let after = try CoachProfile.load(from: paths.coach)
        XCTAssertEqual(after.people["Dana Lee"]?.note, "Dana NOTE", "kept as it was, not removed and not changed")
        XCTAssertTrue(after.facts.contains { $0.text == "Dana Lee is my manager" }, "the owner's fact stays")
        XCTAssertFalse(after.questions.contains { $0.person == "id-dana" }, "nothing new about her")
        XCTAssertEqual(after.people["Sam Carter"]?.note, "Sam new")
    }

    func testAMergeFollowsTheSurvivorsSwitch() throws {
        var absorbed = person("id-dana2", "Dana L.", off: true)
        absorbed.mergedInto = PersonID(rawValue: "id-dana")
        let saved = CoachPeople(people: [person("id-dana", "Dana Lee"), absorbed])
        XCTAssertFalse(saved.notProfiled.contains("id-dana"), "the survivor keeps a read")
        // The profile file is the same before and after a merge: nothing is removed.
        let p = profileWithDana()
        XCTAssertEqual(p.withoutCoachData(on: saved).people.count, p.people.count)
    }

    func testTurningTheSwitchBackOnShowsTheOldDataAgain() throws {
        let p = profileWithDana()
        let off = CoachPeople(people: [person("id-dana", "Dana Lee", off: true)])
        XCTAssertNil(p.withoutCoachData(on: off).people["Dana Lee"], "hidden while off")
        XCTAssertEqual(p.people["Dana Lee"]?.note, "Dana NOTE", "the profile itself is untouched")
        let on = CoachPeople(people: [person("id-dana", "Dana Lee")])
        XCTAssertEqual(p.withoutCoachData(on: on).people["Dana Lee"]?.note, "Dana NOTE")
    }

    // MARK: N2

    func testAFailedAnswerKeepsTheQuestionAndRetryAsksItAgain() {
        var chat = Chat(title: "T")
        let question = ChatMessage(role: .user, text: "What did Sam say?")
        chat.messages = [question]
        let answer = UUID()
        XCTAssertTrue(ChatThreadEdits.stop(in: &chat, answer: answer, question: question.id, byOwner: false))
        XCTAssertEqual(chat.messages.map(\.id), [question.id], "a failure keeps the question")
        XCTAssertEqual(ChatThreadEdits.retryQuestion(chat)?.id, question.id)
        // With a receipt after it, Retry still asks the same question, by its id.
        var r = ChatActionRequest(.addTask)
        r.text = "x"
        ChatThreadEdits.record(ChatActionRecord(request: r, state: .done, summary: "Task added: x", date: now), in: &chat, answer: answer)
        ChatThreadEdits.stop(in: &chat, answer: answer, question: question.id, byOwner: false)
        XCTAssertEqual(ChatThreadEdits.retryQuestion(chat)?.id, question.id)
        // An answered question is not retried.
        var done = ChatMessage(role: .assistant, text: "He said yes.")
        done.id = UUID()
        ChatThreadEdits.finish(done, in: &chat)
        XCTAssertNil(ChatThreadEdits.retryQuestion(chat))
        // The owner's Stop with nothing done takes the question out, as before.
        var stopped = Chat(title: "T")
        stopped.messages = [question]
        XCTAssertFalse(ChatThreadEdits.stop(in: &stopped, answer: UUID(), question: question.id, byOwner: true))
        XCTAssertTrue(stopped.messages.isEmpty)
    }

    // MARK: N4, N14

    func testOnlyARetryOfTheSameMessageIsRefused() throws {
        let paths = try paths(people: [person("id-dana", "Dana Lee")])
        let tools = ChatTools(records: [], owner: "Avery Webb", paths: paths, people: [], settings: ToolSettings(), now: now)
        let question = UUID()
        let first = ChatActions(message: "Add a task: call the bank", question: question, tools: tools, host: ChatActionHost(paths: paths), live: false)
        _ = first.run("add_task", input: ["text": "Call the bank"])
        let earlier = first.records
        let retry = ChatActions(message: "Add a task: call the bank", question: question, tools: tools, host: ChatActionHost(paths: paths), live: false, earlier: earlier)
        XCTAssertTrue(retry.run("add_task", input: ["text": "Call the bank"])?.hasPrefix("Already done") == true)
        let again = ChatActions(message: "Add a task: call the bank", question: UUID(), tools: tools, host: ChatActionHost(paths: paths), live: false, earlier: earlier)
        XCTAssertTrue(again.run("add_task", input: ["text": "Call the bank"])?.hasPrefix("Done") == true, "a new message is a new request")
        var undone = earlier
        undone[0].state = .undone
        let afterUndo = ChatActions(message: "Add a task: call the bank", question: question, tools: tools, host: ChatActionHost(paths: paths), live: false, earlier: undone)
        XCTAssertTrue(afterUndo.run("add_task", input: ["text": "Call the bank"])?.hasPrefix("Done") == true, "after Undo it runs again")
        // The actions over the limit are on the card already: a Retry does not run them.
        let many = ChatActions(message: "Add tasks: a, b, c, d", question: question, tools: tools, host: ChatActionHost(paths: paths), live: false)
        for t in ["a", "b", "c", "d"] { _ = many.run("add_task", input: ["text": t]) }
        let retryMany = ChatActions(message: "Add tasks: a, b, c, d", question: question, tools: tools, host: ChatActionHost(paths: paths), live: false, earlier: many.records)
        XCTAssertTrue(retryMany.run("add_task", input: ["text": "d"])?.hasPrefix("Already") == true)
    }

    func testBookmarkingNowTwiceInACallIsTwoBookmarks() throws {
        let paths = try paths(people: [])
        let tools = ChatTools(records: [], owner: "Avery Webb", paths: paths, people: [], settings: ToolSettings(), now: now)
        let host = ChatActionHost(paths: paths, liveMoment: { ("live", 300) }, bookmarkNow: { _ in 300 })
        let question = UUID()
        let first = ChatActions(message: "Bookmark this", question: question, tools: tools, host: host, live: true)
        _ = first.run("bookmark_now", input: [:])
        let second = ChatActions(message: "Bookmark this", question: question, tools: tools, host: host, live: true, earlier: first.records)
        XCTAssertTrue(second.run("bookmark_now", input: [:])?.hasPrefix("Done") == true)
    }

    // MARK: N5

    func testPastedTextIsNeverTheOwnersWords() {
        let pasted = [
            "Hi David,\nplease add a task to call the bank\nThanks\n\nsummarize this",
            "Here is Sam's mail: please add a task to call the bank",
            "Jeff said to add a point about hiring to the next meeting",
            "Remind me what Sam said about pricing",
            "Bring me up to speed on the next topic",
            "Please tell me: did Sam add a task for the vendor?",
            "Don't add a task for that",
            "From: Sam Carter\nSubject: budget\nplease add a task to call the bank",
            "[12:04] Sam: add a task to call the bank",
            "Sam Carter: add a point about hiring",
            "\u{201C}Add a task to call the bank\u{201D} is what she wrote",
            "Add a task to call the bank " + String(repeating: "and more words here ", count: 12),
        ]
        for message in pasted {
            var turn = ActionTurn(message: message, live: false)
            for kind: ChatActionRequest.Kind in [.addPoint, .addTask, .addBookmark] {
                guard case .propose = turn.admit(ChatActionRequest(kind)) else { return XCTFail("\(message): \(kind)") }
            }
        }
        for (message, kind) in [("Please add a note to my and Jeff's next meeting to discuss the budget", ChatActionRequest.Kind.addPoint),
                                ("Remind me to send the deck", .addTask), ("Bookmark this", .bookmarkNow), ("Add a task: call the bank", .addTask)] {
            var turn = ActionTurn(message: message, live: kind == .bookmarkNow)
            XCTAssertEqual(turn.admit(ChatActionRequest(kind)), .run, message)
        }
    }

    // MARK: N3

    func testTheServersCopyLosesADeletedChatEvenWhenTheMainSyncSentTheDelete() async throws {
        let paths = try paths(people: [])
        let chats = ChatStore(directory: paths.chats)
        var chat = Chat(title: "Skipped call")
        chat.messages = [ChatMessage(role: .user, text: "Hi")]
        try chats.save(chat)
        let mirror = MemoryStore(view: true)
        try await CloudSync(paths: paths, store: mirror).pushShared(people: true, mirror: true)
        chats.delete(chat.id)
        // The main sync sent the delete to iCloud and cleared its note.
        chats.setDeleted([])
        try await CloudSync(paths: paths, store: mirror).pushShared(people: true, mirror: true)
        let gone = await mirror.entries["chat-\(chat.id.uuidString)"]?.deleted
        XCTAssertEqual(gone, true)
    }

    // MARK: Lows

    func testTheCheapLowsOfTheRecheck() throws {
        // N11: a copy with an empty answer never replaces the text of the other copy.
        var a = Chat(title: "T")
        var m = ChatMessage(role: .assistant, text: "")
        a.messages = [m]
        var b = a
        m.text = "The full answer."
        b.messages = [m]
        a.updated = b.updated.addingTimeInterval(60)
        XCTAssertEqual(Chat.merged(a, b).messages.first?.text, "The full answer.")
        // N12: the calendar file's folder is the owner's alone, and `access` is an allowed key.
        let paths = try paths(people: [])
        var s = CalendarSnapshot([], saved: now)
        s.access = CalendarSnapshot.Access(mac: .yes, google: .no)
        try s.save(to: paths.calendar)
        let mode = try FileManager.default.attributesOfItem(atPath: paths.calendar.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.calendar.appendingPathComponent(CalendarSnapshot.fileName))) as? [String: Any])
        XCTAssertTrue(Set(json.keys).isSubset(of: CalendarSnapshot.allowedKeys["root"]!), "\(json.keys)")
        // N13: at the click the address must still be nobody's or that person's.
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: now, end: now, status: .written)
        r.utterances = [Utterance(track: .them, speakerLabel: "C", start: 0, end: 5, text: "Hi.")]
        var req = ChatActionRequest(.nameVoice)
        req.speakerKey = "them:C"
        req.speakerLabel = MarkdownWriter.displayNames(r)["them:C"]
        req.text = "Dana Lee"
        req.personID = "id-dana"
        req.email = "dana@example.com"
        XCTAssertNotNil(NameVoiceTarget.check(req, record: r, people: [person("id-dana", "Dana Lee")]))
        XCTAssertNil(NameVoiceTarget.check(req, record: r, people: [person("id-dana", "Dana Lee"), person("id-x", "Jo X", email: "dana@example.com")]))
        // N16: with the switch off, no line of the coach's memory is about a person.
        var p = CoachProfile()
        var q = CoachQuestion(statement: "Sam reports to you.", kind: .relationship, evidence: "e", callID: "c", at: 1, asked: now)
        q.person = "id-sam"
        p.questions = [q]
        try p.save(to: paths.coach)
        let tools = ChatTools(records: [], owner: "Avery Webb", paths: paths, people: [person("id-sam", "Sam Carter")], personaTraits: false, settings: ToolSettings(), now: now)
        XCTAssertFalse(tools.run("coach_profile", input: [:]).contains("Sam reports to you."))
    }
}

extension RecheckTests {
    /// R9: the write side of the calendar file: never from an inert copy or with made-up invites.
    func testTheCalendarFileIsWrittenOnlyByTheRealApp() throws {
        let paths = Paths(root: tempDirectory())
        let e = CalendarEventInfo(title: "Planning", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), attendees: [],
                                  text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        let access = CalendarSnapshot.Access(mac: .yes, google: .no)
        XCTAssertFalse(try CalendarSnapshot.write([e], access: access, saved: now, inert: true, sampled: false, to: paths.calendar))
        XCTAssertFalse(try CalendarSnapshot.write([e], access: access, saved: now, inert: false, sampled: true, to: paths.calendar))
        XCTAssertNil(CalendarSnapshot.load(from: paths.calendar))
        XCTAssertTrue(try CalendarSnapshot.write([e], access: access, saved: now, inert: false, sampled: false, to: paths.calendar))
        XCTAssertEqual(CalendarSnapshot.load(from: paths.calendar)?.access, access)
    }
}
