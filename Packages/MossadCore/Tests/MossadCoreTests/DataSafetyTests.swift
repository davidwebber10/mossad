import AVFoundation
import XCTest
@testable import MossadCore

/// Unreadable is not empty, and a paid request that fails is not tried without end.
final class DataSafetyTests: XCTestCase {
    private func tempPaths(_ records: [CallRecord] = []) throws -> Paths {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.ensureDirectories()
        for r in records {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        return paths
    }

    private func record(_ id: String, start: TimeInterval) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: Date(timeIntervalSince1970: start),
                           end: Date(timeIntervalSince1970: start + 1800), status: .written)
        r.speakerNames = ["me:A": "Sam Carter"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 120, text: "I will send the plan to Dana Lee by Friday.")]
        return r
    }

    private func kept(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".unreadable-") }
    }

    // MARK: Files that do not decode

    func testADamagedVoiceFileIsKeptAsideAndNotSavedOver() throws {
        let dir = tempDirectory()
        try Data("[{ damaged".utf8).write(to: dir.appendingPathComponent("voices.json"))
        let library = VoiceLibrary(directory: dir)
        XCTAssertNotNil(library.loadError)
        try library.add([1, 0, 0], to: "Sam Carter", isOwner: true)
        let aside = kept(in: dir)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(aside[0]), encoding: .utf8), "[{ damaged", "the old voices are still on disk")
    }

    func testADamagedCoachProfileOrCommitmentBookThrowsAndIsKeptAside() throws {
        let paths = try tempPaths()
        for (dir, name) in [(paths.coach, CoachProfile.fileName), (paths.commitments, CommitmentBook.fileName)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{ damaged".utf8).write(to: dir.appendingPathComponent(name))
        }
        XCTAssertThrowsError(try CoachProfile.load(from: paths.coach)) { XCTAssertTrue($0 is UnreadableFile) }
        XCTAssertThrowsError(try CommitmentBook.load(from: paths.commitments))
        XCTAssertEqual(kept(in: paths.coach).count, 1)
        XCTAssertEqual(kept(in: paths.commitments).count, 1)
        // A missing file is an empty one.
        XCTAssertEqual(try CoachProfile.load(from: paths.coach), CoachProfile())
    }

    /// The owner's "do not record" wins: with rules that cannot be read, a call with an invite is not recorded,
    /// on this launch and on the next ones, until the owner sets a choice again.
    func testADoNotRecordListThatCannotBeReadBlocksCallsWithAnInvite() throws {
        let dir = tempDirectory()
        try Data("{ damaged".utf8).write(to: dir.appendingPathComponent(NoRecordBook.fileName))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEventInfo(title: "Budget review", start: now, end: now.addingTimeInterval(1800), attendees: [],
                                      text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        for _ in 1...2 {
            let book = NoRecordBook.load(from: dir)
            XCTAssertTrue(book.unreadable)
            XCTAssertTrue(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: now.addingTimeInterval(60), events: [event]))
            XCTAssertFalse(book.blocks(platform: .meet, meetingID: "zzz-zzzz-zzz", at: now.addingTimeInterval(60), events: []), "no invite, no block")
        }
        XCTAssertThrowsError(try NoRecordBook.loadChecked(from: tempDirectoryWithDamagedBook()))
        try NoRecordBook().save(to: dir)
        XCTAssertFalse(NoRecordBook.load(from: dir).unreadable)
    }

    private func tempDirectoryWithDamagedBook() throws -> URL {
        let dir = tempDirectory()
        try Data("nope".utf8).write(to: dir.appendingPathComponent(NoRecordBook.fileName))
        return dir
    }

    func testTheSameVoiceSampleIsLearnedOnce() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        for _ in 1...3 { try library.add([0.2, 0.9, 0.1], to: "Dana Lee") }
        try library.add([0.3, 0.8, 0.1], to: "Dana Lee")
        XCTAssertEqual(library.profiles.first?.embeddings.count, 2)
    }

    func testAScanSaysWhichRecordsCouldNotBeRead() throws {
        let paths = try tempPaths([record("a", start: 100), record("b", start: 200)])
        try Data("{".utf8).write(to: paths.callDirectory("b").appendingPathComponent(CallRecord.fileName))
        let queue = ProcessingQueue(paths: paths)
        var scan = try queue.scan()
        XCTAssertEqual(scan.records.map(\.id), ["a"])
        XCTAssertEqual(scan.unreadable, ["b"])
        XCTAssertEqual(scan.folders, ["a", "b"])
        // A changed file is read again; an unchanged one comes from the cache.
        var a = record("a", start: 100)
        a.customTitle = "Freight"
        try a.save(to: paths.callDirectory("a"))
        scan = try queue.scan()
        XCTAssertEqual(scan.records.first?.customTitle, "Freight")
        try FileManager.default.removeItem(at: paths.audio)
        XCTAssertThrowsError(try queue.scan())
    }

    // MARK: Retries

    func testTheLedgerWaitsLongerEachTimeThenGivesUp() {
        var ledger = RetryLedger()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ledger.state("a", now: t0), .ready)
        ledger.fail("a", reason: "bad JSON", now: t0)
        XCTAssertEqual(ledger.state("a", now: t0.addingTimeInterval(3000)), .waiting)
        XCTAssertEqual(ledger.state("a", now: t0.addingTimeInterval(3700)), .ready)
        ledger.fail("a", reason: "bad JSON", now: t0)
        XCTAssertEqual(ledger.state("a", now: t0.addingTimeInterval(3700)), .waiting)
        ledger.fail("a", reason: "bad JSON", now: t0)
        XCTAssertEqual(ledger.state("a", now: .distantFuture), .gaveUp)
        ledger.clear("a")
        XCTAssertEqual(ledger.state("a", now: t0), .ready)
    }

    func testNoConnectionAndABadKeyAreNotBilledFailures() {
        XCTAssertTrue(RetryLedger.isUnbilled(URLError(.notConnectedToInternet)))
        XCTAssertTrue(RetryLedger.isUnbilled(SummaryError.http(529, "")))
        XCTAssertTrue(RetryLedger.isUnbilled(SummaryError.http(401, "")))
        XCTAssertTrue(RetryLedger.isUnbilled(MissingAPIKey(service: "Anthropic")))
        XCTAssertFalse(RetryLedger.isUnbilled(SummaryError.malformed))
        XCTAssertFalse(RetryLedger.isUnbilled(SummaryError.cutOff))
        XCTAssertFalse(RetryLedger.isUnbilled(SummaryError.refused))
    }

    private final class FakeCoach: Coaching, @unchecked Sendable {
        var seen: [String] = []
        var failOn: String?
        var error: Error = SummaryError.malformed
        var during: (() -> Void)?
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult {
            seen.append(record.id)
            during?()
            if record.id == failOn { throw error }
            return CoachResult(review: CoachReview(headline: "H \(record.id)", overview: "O", strengths: [], improvements: [], focusProgress: nil),
                               update: CoachProfileUpdate(summary: "S", focus: "after \(record.id)", patterns: [], people: []))
        }
    }

    /// One call that makes the coach fail every time: three paid tries, hours apart, then the later calls go on.
    func testACallTheCoachCannotReviewIsTriedThreeTimesThenLeftOut() async throws {
        let paths = try tempPaths([record("a", start: 100), record("b", start: 200)])
        let coach = FakeCoach()
        coach.failOn = "a"
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        func run() async -> Int { await CoachRunner(paths: paths, coach: coach, owner: "Sam Carter", since: .distantPast, now: { clock.now }).run() }

        _ = await run()
        _ = await run()
        _ = await run()
        XCTAssertEqual(coach.seen, ["a"], "runs in the same hour do not pay again")
        XCTAssertNil(CoachReview.load(in: paths.callDirectory("b")), "the order holds while a waits")

        clock.advance(3700)
        _ = await run()
        clock.advance(7 * 3600)
        let done = await run()
        XCTAssertEqual(coach.seen, ["a", "a", "a", "b"])
        XCTAssertEqual(done, 1)
        XCTAssertNotNil(CoachReview.load(in: paths.callDirectory("b")))

        clock.advance(30 * 86_400)
        _ = await run()
        XCTAssertEqual(coach.seen.filter { $0 == "a" }.count, 3, "never again by itself")

        // "Review again" lets the owner try.
        CoachRunner.forget("a", paths: paths)
        coach.failOn = nil
        _ = await run()
        XCTAssertNotNil(CoachReview.load(in: paths.callDirectory("a")))
    }

    func testNoNetworkDoesNotUseUpTheCoachesTries() async throws {
        let paths = try tempPaths([record("a", start: 100)])
        let coach = FakeCoach()
        coach.failOn = "a"
        coach.error = URLError(.notConnectedToInternet)
        for _ in 1...5 { _ = await CoachRunner(paths: paths, coach: coach, owner: "Sam Carter", since: .distantPast).run() }
        XCTAssertTrue(RetryLedger.load(from: paths.coach).entries.isEmpty)
        coach.failOn = nil
        let done = await CoachRunner(paths: paths, coach: coach, owner: "Sam Carter", since: .distantPast).run()
        XCTAssertEqual(done, 1)
    }

    /// A meeting deleted while the coach reads it: no folder comes back, and the profile learns nothing from it.
    func testAMeetingDeletedDuringItsReviewLeavesNoFolderAndNoMemory() async throws {
        let paths = try tempPaths([record("a", start: 100)])
        let coach = FakeCoach()
        coach.during = { try? FileManager.default.removeItem(at: paths.callDirectory("a")) }
        let done = await CoachRunner(paths: paths, coach: coach, owner: "Sam Carter", since: .distantPast).run()
        XCTAssertEqual(done, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory("a").path))
        XCTAssertTrue(try CoachProfile.load(from: paths.coach).history.isEmpty)
    }

    private struct BadReplies: LanguageModel {
        let calls: Counter
        func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                     purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
            calls.add()
            throw SummaryError.cutOff
        }
        func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                      execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func add() { lock.withLock { n += 1 } }
    }

    func testACallTheCommitmentFinderCannotReadIsNotTriedOnEveryRun() async throws {
        let paths = try tempPaths([record("a", start: 100)])
        let calls = Counter()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        func run() async {
            _ = await CommitmentRunner(paths: paths, finder: CommitmentFinder(llm: BadReplies(calls: calls), ownerName: "Sam Carter"),
                                       since: .distantPast, now: { clock.now }).run()
        }
        for _ in 1...4 { await run() }
        XCTAssertEqual(calls.count, 1)
        for _ in 1...6 { clock.advance(2 * 86_400); await run() }
        XCTAssertEqual(calls.count, RetryLedger.maxAttempts)
    }

    private final class Mail: Mailing, DigestWriting, @unchecked Sendable {
        var failSend = true
        var digests = 0, sent = 0
        func send(to: String, subject: String, html: String, text: String) async throws {
            if failSend { throw MailError.http(403, "The domain is not verified.") }
            sent += 1
        }
        func digest(owner: String, reviews: [(title: String, date: Date, review: CoachReview)], profile: CoachProfile, kind: CoachEmailKind) async throws -> WeeklyDigest {
            digests += 1
            return WeeklyDigest(subject: "Week", intro: "I", improved: [], toWork: [], focus: "F")
        }
    }

    /// The mail provider refuses the send. The digest was paid for once; later runs send the same one.
    func testAMailerThatRefusesDoesNotBuyANewDigestOnEveryRun() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func date(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }
        var r = record("in", start: 0)
        r.start = date(14)
        let paths = try tempPaths([r])
        try CoachReview(headline: "in", overview: "", strengths: [], improvements: [], focusProgress: nil).save(in: paths.callDirectory("in"))
        let mail = Mail()
        for _ in 1...4 {
            let sent = await WeeklyEmail.sendIfDue(paths: paths, owner: "Sam Carter", to: "me@example.com", lastSent: date(12), now: date(21),
                                                   writer: mail, mailer: mail, calendar: cal)
            XCTAssertNil(sent)
        }
        XCTAssertEqual(mail.digests, 1)
        mail.failSend = false
        let sent = await WeeklyEmail.sendIfDue(paths: paths, owner: "Sam Carter", to: "me@example.com", lastSent: date(12), now: date(21),
                                               writer: mail, mailer: mail, calendar: cal)
        XCTAssertEqual(sent, date(21))
        XCTAssertEqual(mail.digests, 1)
        XCTAssertEqual(mail.sent, 1)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: paths.coach.path)) ?? []).filter { $0.hasPrefix("email-") }.isEmpty)
    }

    // MARK: Anthropic

    struct Out: Decodable, Equatable { let headline: String }

    func testAReplyCutAtTheTokenLimitSaysSo() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"content":[{"type":"text","text":"{\"headline\":\"Goo"}],"stop_reason":"max_tokens"}"#.utf8)) }
        let model = AnthropicModel(apiKey: "k", model: "claude-opus-5-5", session: StubURLProtocol.session())
        do {
            _ = try await model.json(system: "Coach.", user: "Review.", schema: Schema.object(["headline": Schema.string]), effort: .high, purpose: .coach, as: Out.self)
            XCTFail("expected an error")
        } catch SummaryError.cutOff {
        } catch { XCTFail("\(error)") }
    }

    func testTheSmallModelIsNotSentAFallback() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"content":[{"type":"text","text":"{\"headline\":\"Good\"}"}],"stop_reason":"end_turn"}"#.utf8)) }
        func body(_ model: String) async throws -> [String: Any] {
            let m = AnthropicModel(apiKey: "k", model: model, session: StubURLProtocol.session())
            _ = try await m.json(system: "S", user: "U", schema: Schema.object(["headline": Schema.string]), effort: .low, purpose: .coach, as: Out.self)
            return try JSONSerialization.jsonObject(with: StubURLProtocol.requests[0].body) as! [String: Any]
        }
        let haiku = try await body("claude-haiku-5-5")
        XCTAssertNil(haiku["fallbacks"])
        let opus = try await body("claude-opus-5-5")
        XCTAssertEqual(opus["fallbacks"] as? String, "default")
    }

    // MARK: Names and letters

    func testTheTwentySeventhVoiceIsNotSpeakerAAgain() {
        XCTAssertEqual([0, 1, 25, 26, 27, 51, 52, 701, 702].map(SpeakerLetter.at), ["A", "B", "Z", "AA", "AB", "AZ", "BA", "ZZ", "AAA"])
        var r = record("a", start: 100)
        r.speakerNames = [:]
        r.utterances = (0..<27).map { Utterance(track: .them, speakerLabel: "S\($0)x", start: Double($0), end: Double($0) + 1, text: "Hi.") }
        let names = MarkdownWriter.displayNames(r)
        XCTAssertEqual(names["them:S0x"], "Speaker A")
        XCTAssertEqual(names["them:S26x"], "Speaker AA")
        XCTAssertEqual(Set(names.values).count, 27)
    }

    func testANoteNameIsOneLineAndFitsTheFileSystem() {
        var r = record("20261020-143000", start: 1_800_000_000)
        r.customTitle = String(repeating: "Quarterly freight review ", count: 20) + "\nsecond line: yes/no"
        let name = MarkdownWriter.fileName(for: r)
        XCTAssertLessThanOrEqual(name.utf8.count, 230)
        XCTAssertFalse(name.contains("\n") || name.contains("/") || name.contains(":"))
        r.customTitle = "Plan\nfor Q4"
        let note = MarkdownWriter.render(r)
        XCTAssertTrue(note.contains("title: \"Plan for Q4\"\n"), note)
        XCTAssertTrue(note.contains("\n# Plan for Q4\n"))
    }

    func testTwoCallsWithTheSameMinuteAndTitleGetTwoNotes() throws {
        let folder = tempDirectory()
        var a = record("20261020-143000", start: 1_800_000_000), b = record("20261020-143030", start: 1_800_000_030)
        a.customTitle = "Standup"; b.customTitle = "Standup"
        let first = MarkdownWriter.noteURL(for: a, in: folder)
        try "a".write(to: first, atomically: true, encoding: .utf8)
        a.markdownPath = first.path
        let second = MarkdownWriter.noteURL(for: b, in: folder)
        XCTAssertNotEqual(first, second)
        try "b".write(to: second, atomically: true, encoding: .utf8)
        b.markdownPath = second.path
        // Each keeps its own file on a later save.
        XCTAssertEqual(MarkdownWriter.noteURL(for: a, in: folder), first)
        XCTAssertEqual(MarkdownWriter.noteURL(for: b, in: folder), second)
    }

    func testTheSignedHostCarriesAPortThatIsNotTheDefault() {
        let local = S3Config(endpoint: URL(string: "http://127.0.0.1:9000")!, bucket: "mossad", region: "us-east-1",
                             accessKeyID: "id", secret: "secret", pathStyle: true)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let url = S3Presigner.url(local, method: "PUT", key: "a.m4a", date: date)
        XCTAssertEqual(url.port, 9000)
        XCTAssertEqual(url.host, "127.0.0.1")
        // The port is part of what is signed: the same request without it has another signature.
        let plain = S3Config(endpoint: URL(string: "http://127.0.0.1")!, bucket: "mossad", region: "us-east-1",
                             accessKeyID: "id", secret: "secret", pathStyle: true)
        func signature(_ u: URL) -> String { String(u.absoluteString.split(separator: "=").last!) }
        XCTAssertNotEqual(signature(url), signature(S3Presigner.url(plain, method: "PUT", key: "a.m4a", date: date)))
    }

    // MARK: Phone recording

    /// An upload that was cut off must fail, so the store and the phone keep the recording.
    func testACutOffPhoneRecordingIsNotImported() throws {
        let whole = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            let file = try AVAudioFile(forWriting: whole, settings: PhoneRecording.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480_000)!
            buffer.frameLength = 480_000
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
            try file.write(from: buffer)
        }
        let data = try Data(contentsOf: whole)
        let cut = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try data.prefix(data.count / 3).write(to: cut)
        let paths = try tempPaths()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = PhoneRecording(id: "20270115-090000", start: start, end: start.addingTimeInterval(10), title: nil)
        XCTAssertThrowsError(try PhoneRecording.importAudio(cut, recording: rec, into: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(rec.id).path), "no half call is left")
    }

    // MARK: Review fixes

    /// The block for a list that cannot be read ends when the owner makes a choice or resets the list, at once.
    func testAChoiceOrAResetEndsTheBlockOfADamagedList() throws {
        let dir = tempDirectory()
        try Data("{ damaged".utf8).write(to: dir.appendingPathComponent(NoRecordBook.fileName))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEventInfo(title: "Budget review", start: now, end: now.addingTimeInterval(1800), attendees: [],
                                      text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        let other = CalendarEventInfo(title: "Hiring", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000), attendees: [],
                                      text: "https://meet.google.com/xyz-wxyz-xyz", isAllDay: false)
        var book = NoRecordBook.load(from: dir)
        let chrome = "com.google.Chrome"
        let gate = NoRecordGate()
        gate.update(book: book)
        gate.update(events: [event, other])

        XCTAssertTrue(gate.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: now.addingTimeInterval(60)))
        XCTAssertEqual(gate.currentBlock, NoRecordGate.Block(title: "Budget review", listUnreadable: true), "the app can say why")
        // The owner's Record on the notice always wins.
        XCTAssertFalse(gate.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: now.addingTimeInterval(90), forced: true))
        XCTAssertNil(gate.currentBlock)

        // A choice for any meeting starts a readable list: no restart needed.
        book.set(.skipThisMeeting, for: UpcomingMeeting.from([other], now: now, days: 30)[0])
        XCTAssertFalse(book.unreadable)
        gate.update(book: book)
        XCTAssertFalse(gate.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: now.addingTimeInterval(120)))
        XCTAssertTrue(gate.blocksStart(platform: .meet, bundleID: chrome, meetingID: "xyz-wxyz-xyz", at: now.addingTimeInterval(7260)))
        XCTAssertEqual(gate.currentBlock?.listUnreadable, false, "this one is the owner's choice")

        var damaged = NoRecordBook.load(from: dir)
        XCTAssertTrue(damaged.unreadable)
        // A choice that cannot be kept (the meeting has no link to know it by) changes nothing, so it does not end
        // the block either.
        damaged.set(.record, for: UpcomingMeeting(title: "No link", start: now, end: now.addingTimeInterval(1800), attendees: [], platform: .meet, link: nil))
        XCTAssertTrue(damaged.unreadable)
        damaged.reset()
        XCTAssertFalse(damaged.unreadable)
        try damaged.save(to: dir)
        XCTAssertFalse(NoRecordBook.load(from: dir).unreadable)
    }

    /// A call that was blocked only by the damaged list, and that starts again after the reset, records.
    func testACallBlockedByTheDamagedListRecordsWhenItStartsAgainAfterAReset() throws {
        let dir = tempDirectory()
        try Data("{ damaged".utf8).write(to: dir.appendingPathComponent(NoRecordBook.fileName))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEventInfo(title: "Budget review", start: now, end: now.addingTimeInterval(600), attendees: [],
                                      text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        var book = NoRecordBook.load(from: dir)
        let gate = NoRecordGate()
        gate.update(book: book)
        gate.update(events: [event])
        XCTAssertTrue(gate.blocksStart(platform: .meet, bundleID: "com.google.Chrome", meetingID: "abc-defg-hij", at: now.addingTimeInterval(60)))
        _ = gate.callEnded(at: now.addingTimeInterval(700))
        book.reset()
        gate.update(book: book)
        // Past the planned end: before, the session held the block for the same meeting code.
        XCTAssertFalse(gate.blocksStart(platform: .meet, bundleID: "com.google.Chrome", meetingID: "abc-defg-hij", at: now.addingTimeInterval(760)))
    }

    func testRememberDoesNotSaveOverACoachMemoryThatCannotBeRead() throws {
        let paths = try tempPaths()
        try FileManager.default.createDirectory(at: paths.coach, withIntermediateDirectories: true)
        try Data("{ damaged".utf8).write(to: paths.coach.appendingPathComponent(CoachProfile.fileName))
        let tools = ChatTools(records: [], owner: "Sam Carter", paths: paths)
        let answer = tools.runCoachTool("remember", input: ["kind": "preference", "text": "Short answers"], from: nil, to: nil, people: [], limit: 10)
        XCTAssertEqual(answer, "Could not save: the coach's memory cannot be read.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.coach.appendingPathComponent(CoachProfile.fileName).path))
        XCTAssertEqual(kept(in: paths.coach).count, 1)
    }

    func testThePaidJobsWaitWhileARecoveredFileAwaitsTheOtherCopy() async throws {
        let paths = try tempPaths([record("a", start: 100)])
        for (dir, name) in [(paths.coach, CoachProfile.fileName), (paths.commitments, CommitmentBook.fileName)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{".utf8).write(to: dir.appendingPathComponent(name))
        }
        _ = try? CoachProfile.load(from: paths.coach)
        _ = try? CommitmentBook.load(from: paths.commitments)
        let coach = FakeCoach(), calls = Counter()
        let reviewed = await CoachRunner(paths: paths, coach: coach, owner: "Sam Carter", since: .distantPast).run()
        let read = await CommitmentRunner(paths: paths, finder: CommitmentFinder(llm: BadReplies(calls: calls), ownerName: "Sam Carter"), since: .distantPast).run()
        XCTAssertEqual(reviewed + read, 0)
        XCTAssertTrue(coach.seen.isEmpty)
        XCTAssertEqual(calls.count, 0)
        CloudSync.nothingToMerge(paths: paths)
        let after = await CoachRunner(paths: paths, coach: coach, owner: "Sam Carter", since: .distantPast).run()
        XCTAssertEqual(after, 1)
    }

    /// The app stopped after the note was written and before its path was saved: the next run uses that note.
    func testANoteOfTheSameCallIsUsedAgainNotWrittenASecondTime() throws {
        let folder = tempDirectory()
        var r = record("20261020-143000", start: 1_800_000_000)
        r.customTitle = "Standup"
        let first = MarkdownWriter.noteURL(for: r, in: folder)
        try MarkdownWriter.render(r).write(to: first, atomically: true, encoding: .utf8)
        XCTAssertEqual(MarkdownWriter.noteURL(for: r, in: folder), first)
        var other = record("20261020-143030", start: 1_800_000_030)
        other.customTitle = "Standup"
        XCTAssertNotEqual(MarkdownWriter.noteURL(for: other, in: folder), first)
    }
}
