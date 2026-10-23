import XCTest
@testable import MossadCore

final class FakeTranscriber: Transcribing, @unchecked Sendable {
    var result: [Track: [Utterance]] = [:]
    var error: Error?
    var failingTracks: Set<Track> = []
    var delay: Duration = .zero
    private let lock = NSLock()
    private var _calls: [Track] = []
    var calls: [Track] { lock.withLock { _calls } }
    func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        lock.withLock { _calls.append(track) }
        progress(.uploading)
        progress(.transcribing)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        if failingTracks.contains(track) { throw Boom() }
        return result[track] ?? []
    }
}

final class FakeSummarizer: Summarizing, @unchecked Sendable {
    var fail = false
    var calls = 0
    var lastTranscript = ""
    var delayOnCall: [Int: Duration] = [:]
    var lastKnownTags: [String] = []
    func summarize(transcript: String, title: String, knownTags: [String]) async throws -> MeetingSummary {
        lastKnownTags = knownTags
        calls += 1
        let call = calls
        lastTranscript = transcript
        if let delay = delayOnCall[call] { try await Task.sleep(for: delay) }
        if fail { throw SummaryError.malformed }
        return MeetingSummary(summary: "Summary \(call)", actionItems: [ActionItem(owner: "Alex Rivera", task: "send forecast")],
                              decisions: ["Decision \(call)"], headline: "Headline \(call)")
    }
}

struct FakeCalendar: CalendarSource {
    var events: [CalendarEventInfo] = []
    func events(from: Date, to: Date) async -> [CalendarEventInfo] { events }
}

struct Boom: Error {}

final class Notifications: @unchecked Sendable {
    var records: [CallRecord] = []
    var steps: [CallRecord] = []
    private let lock = NSLock()
    private var _details: [String] = []
    var details: [String] { lock.withLock { _details } }
    func detail(_ text: String?) { if let text { lock.withLock { _details.append(text) } } }
}

final class PipelineTests: XCTestCase {
    var paths: Paths!
    let transcriber = FakeTranscriber()
    let summarizer = FakeSummarizer()
    var library: VoiceLibrary!
    let notifications = Notifications()
    var notified: [CallRecord] { notifications.records }
    let start = localDate(2026, 10, 20, 14, 30)

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        library = VoiceLibrary(directory: paths.voices)
        transcriber.result = [
            .me: [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Where is the shipment?")],
            .them: [Utterance(track: .them, speakerLabel: "A", start: 11, end: 20, text: "It leaves Friday."),
                    Utterance(track: .them, speakerLabel: "B", start: 21, end: 28, text: "I can book freight.")],
        ]
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func makeRecord(meetingID: String? = nil) throws -> String {
        let id = "20261020-143000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 400), (21, 28, 800)])
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(1800), status: .recorded)
        r.meetingID = meetingID
        try r.save(to: dir)
        return id
    }

    func pipeline(calendar: FakeCalendar = FakeCalendar(), voiceFingerprints: Bool = true) -> Pipeline {
        let notifications = notifications
        let later = start.addingTimeInterval(3600)
        return Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                        calendar: calendar, summarizer: summarizer, notify: { notifications.records.append($0) },
                        now: { later }, ownerName: "David Webber", voiceFingerprints: voiceFingerprints,
                        onStep: { notifications.steps.append($0) }, onDetail: { _, text in notifications.detail(text) })
    }

    func testAMicVoiceNamedLikeSomeoneOnTheCallIsTheirEcho() async throws {
        // Alex Rivera is known; his voice (400 Hz) is on the call audio and also leaks into the mic as me:B.
        // The owner barely speaks (only while the call audio plays), so the echo label has the most quiet-time
        // speech and the echo filter keeps it as the owner. Only its name gives it away.
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        transcriber.result[.me] = [
            Utterance(track: .me, speakerLabel: "A", start: 21, end: 22, text: "Okay."),
            Utterance(track: .me, speakerLabel: "B", start: 11, end: 20, text: "It leaves Friday."),
            Utterance(track: .me, speakerLabel: "B", start: 29, end: 32, text: "Right, it leaves Friday."),
        ]
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 34, [(21, 22, 200), (11, 20, 400), (29, 32, 400)])
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertFalse(r.utterances.contains { $0.speakerKey == "me:B" })
        XCTAssertNil(r.speakerNames["me:B"])
        XCTAssertEqual(r.speakerNames["them:A"], "Alex Rivera")
    }

    func testRegenerateSummaryWritesANewSummaryForAFinishedMeeting() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).summary, "Summary 1")
        await p.regenerateSummary(id)
        let r = try load(id)
        XCTAssertEqual(r.summary, "Summary 2")
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(transcriber.calls.count, 2, "no new transcription")
    }

    func testSetTagsCleansThemAndRewritesTheNote() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.setTags(callID: id, ["Budget", " budget ", "", "Databricks"])
        let r = try load(id)
        XCTAssertEqual(r.tags, ["Budget", "Databricks"])
        let note = try String(contentsOfFile: XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("tags: [\"Budget\", \"Databricks\"]"))
    }

    func testTheSummaryGetsTheTagsOfEarlierMeetings() async throws {
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        await p.setTags(callID: first, ["Freight"])
        await p.regenerateSummary(first)
        XCTAssertEqual(summarizer.lastKnownTags, ["Freight"])
    }

    func testDetailsDescribeEachSubStep() async throws {
        // Like the real service, the transcription takes a moment after its stage updates.
        transcriber.delay = .milliseconds(50)
        let id = try makeRecord()
        await pipeline().process(id)
        let details = notifications.details
        for expected in ["Uploading", "AssemblyAI is transcribing", "Joining the two tracks", "Identifying speakers",
                         "Finding the calendar invite", "Claude is writing the summary", "Writing the note"] {
            XCTAssertTrue(details.contains { $0.contains(expected) }, "missing \(expected) in \(details)")
        }
    }

    func testOnStepReportsEachSavedStep() async throws {
        let id = try makeRecord()
        await pipeline().process(id)
        let statuses = notifications.steps.map(\.status)
        XCTAssertEqual(statuses.filter { $0 != .recorded }, [.transcribed, .identified, .summarized, .written])
        XCTAssertEqual(notifications.steps.last, try load(id))
    }

    func testOnStepReportsAFailedAttempt() async throws {
        transcriber.error = Boom()
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertEqual(notifications.steps.last?.attempts, 1)
    }

    func testFailureReasonForAMissingKey() async throws {
        transcriber.error = MissingAPIKey(service: "AssemblyAI")
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertEqual(try load(id).failureReason, "AssemblyAI key missing")
    }

    func testFailureReasonIsSetAndClearedOnSuccess() async throws {
        transcriber.error = TranscriptionError.http(401, "Unauthorized")
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).failureReason, "invalid API key")
        transcriber.error = nil
        await p.retry(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertNil(r.failureReason)
    }

    func testFailureReasonText() {
        XCTAssertEqual(Pipeline.failureReason(MissingAPIKey(service: "Anthropic")), "Anthropic key missing")
        XCTAssertEqual(Pipeline.failureReason(SummaryError.http(401, "x")), "invalid API key")
        XCTAssertEqual(Pipeline.failureReason(TranscriptionError.http(500, "x")), "AssemblyAI error 500")
        XCTAssertEqual(Pipeline.failureReason(SummaryError.http(529, "x")), "Anthropic error 529")
        XCTAssertEqual(Pipeline.failureReason(SummaryError.refused), "Claude refused to summarize this transcript")
        XCTAssertEqual(Pipeline.failureReason(URLError(.notConnectedToInternet)), "no network connection")
        XCTAssertEqual(Pipeline.failureReason(Boom()), "unexpected error")
    }

    func testWithoutVoiceFingerprintsNoVoiceIsStoredOrMatched() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        let id = try makeRecord()
        await pipeline(voiceFingerprints: false).process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.speakerNames, ["me:A": "David Webber"])
        XCTAssertEqual(r.speakerEmbeddings, [:])
        XCTAssertEqual(library.profiles.map(\.name), ["Alex Rivera"])
        XCTAssertTrue(notified.isEmpty)
    }

    func load(_ id: String) throws -> CallRecord { try CallRecord.load(from: paths.callDirectory(id)) }

    func testDropsAMicVoiceHeardOnlyWhileTheCallAudioPlays() async throws {
        // The them track (from makeRecord) has sound at 11–20 s and 21–28 s.
        transcriber.result[.me]!.append(Utterance(track: .me, speakerLabel: "B", start: 22, end: 23, text: "Yeah."))
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertFalse(try load(id).utterances.contains { $0.track == .me && $0.speakerLabel == "B" })
    }

    func testRenamePersonUpdatesEveryMeetingAndItsNote() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.speakerNames["them:A"] = "jo@example.com"
        r.actionItems = [ActionItem(owner: "jo@example.com", task: "send the forecast")]
        r.summary = "jo@example.com will send the forecast."
        try r.save(to: paths.callDirectory(id))

        let changed = await p.renamePerson("jo@example.com", to: "Jo Lee")
        XCTAssertEqual(changed, 1)
        r = try load(id)
        XCTAssertEqual(r.speakerNames["them:A"], "Jo Lee")
        XCTAssertEqual(r.actionItems.first?.owner, "Jo Lee")
        XCTAssertEqual(r.summary, "Jo Lee will send the forecast.")
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("Jo Lee"))
        XCTAssertFalse(note.contains("jo@example.com"))
    }

    func testRenamePersonLeavesOtherTextAloneForPlainNames() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.speakerNames["them:A"] = "Jo"
        r.summary = "Jo said Joe would call."
        try r.save(to: paths.callDirectory(id))
        await p.renamePerson("Jo", to: "Jo Lee")
        r = try load(id)
        XCTAssertEqual(r.speakerNames["them:A"], "Jo Lee")
        XCTAssertEqual(r.summary, "Jo said Joe would call.", "a short name can be part of other words")
    }

    func testSkipRemovesTheVoiceFromTheNameRequest() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).unknownSpeakers, ["them:A", "them:B"])
        await p.dismissSpeakers(callID: id, keys: ["them:B"])
        XCTAssertEqual(try load(id).unknownSpeakers, ["them:A"])
        XCTAssertEqual(try load(id).skippedSpeakers, ["them:B"])
    }

    func testASkippedVoiceCanBeAskedForAgainOrNamed() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.dismissSpeakers(callID: id, keys: ["them:A", "them:B"])
        await p.restoreSpeakers(callID: id, keys: ["them:B"])
        XCTAssertEqual(try load(id).unknownSpeakers, ["them:B"])
        XCTAssertEqual(try load(id).skippedSpeakers, ["them:A"])
        await p.applyNames(callID: id, names: ["them:A": "Jo"])
        XCTAssertEqual(try load(id).skippedSpeakers, [])
    }

    /// A second written recording of the same meeting, `gap` seconds after the first one ended.
    func makeSecondPart(after firstID: String, gap: TimeInterval, meetingID: String?) throws -> String {
        let first = try load(firstID)
        let start = first.end.addingTimeInterval(gap)
        let id = "20261020-153000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 20, [(0, 8, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 20, [(9, 18, 400)])
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(20), status: .recorded)
        r.meetingID = meetingID
        try r.save(to: dir)
        return id
    }

    func testMergeJoinsMeetingsIntoTheEarliestOne() async throws {
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 600, meetingID: nil)
        await p.process(second)
        let firstNote = try XCTUnwrap(try load(first).markdownPath)
        let secondNote = try XCTUnwrap(try load(second).markdownPath)

        let merged = await p.merge(callIDs: [second, first])

        XCTAssertEqual(merged, first)
        let r = try load(first)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.parts.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(second).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondNote))
        XCTAssertEqual(try audioDuration(paths.callDirectory(first).appendingPathComponent("me.caf")), 50, accuracy: 0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory(first)).path))
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertEqual(r.markdownPath, firstNote)
        XCTAssertTrue(note.contains("Joined with a recording from"), note)
    }

    func testARecordingSplitByARestartContinuesOnItsOwn() async throws {
        let first = try makeRecord(meetingID: "abc-defg-hij")
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 3, meetingID: "abc-defg-hij")
        await p.process(second)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(second).path))
        let r = try load(first)
        XCTAssertEqual(r.parts.count, 2)
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("Recording resumed at"), note)
    }

    func testDifferentMeetingsAreNotJoinedOnTheirOwn() async throws {
        let first = try makeRecord(meetingID: "abc-defg-hij")
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 3, meetingID: "xyz-wxyz-xyz")
        await p.process(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory(second).path))
    }

    func testWritingTheNoteAlsoMakesTheRecording() async throws {
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory(id)).path))
    }

    func testDeleteRemovesTheNoteAndTheAudio() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        let note = try XCTUnwrap(try load(id).markdownPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note))
        let deleted = await p.delete(callID: id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(id).path))
    }

    func testDeleteRefusesACallThatIsStillInProgress() async throws {
        let id = try makeRecord()
        let deleted = await pipeline().delete(callID: id)
        XCTAssertFalse(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory(id).path))
    }

    func testCalendarMatchUsesTheCallsMeetingID() async throws {
        let id = try makeRecord(meetingID: "abc-defg-hij")
        func event(_ title: String, _ code: String) -> CalendarEventInfo {
            CalendarEventInfo(title: title, start: start, end: start.addingTimeInterval(1800), attendees: [],
                              text: "https://meet.google.com/\(code)", isAllDay: false)
        }
        await pipeline(calendar: FakeCalendar(events: [event("Other meeting", "xyz-wxyz-xyz")])).process(id)
        XCTAssertNil(try load(id).calendarTitle)
    }

    func testHappyPathWritesMarkdownAndNotifiesUnknowns() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        let id = try makeRecord()
        let calendar = FakeCalendar(events: [CalendarEventInfo(title: "Weekly Ops Sync", start: start, end: start.addingTimeInterval(1800),
                                                               attendees: ["Alex Rivera", "Amy Lee"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)])
        await pipeline(calendar: calendar).process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.speakerNames["me:A"], "David Webber")
        XCTAssertEqual(r.speakerNames["them:A"], "Alex Rivera")
        XCTAssertEqual(r.unknownSpeakers, ["them:B"])
        XCTAssertEqual(r.calendarTitle, "Weekly Ops Sync")
        XCTAssertEqual(r.summary, "Summary 1")
        XCTAssertEqual(r.actionItems, [ActionItem(owner: "Alex Rivera", task: "send forecast")])
        XCTAssertEqual(r.decisions, ["Decision 1"])
        XCTAssertEqual(r.headline, "Headline 1")
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(md.contains("[00:00:11] Alex Rivera: It leaves Friday."))
        XCTAssertTrue(md.contains("Speaker A: I can book freight."))
        XCTAssertTrue(r.markdownPath!.hasPrefix(paths.meetings.path))
        XCTAssertEqual(notified.map(\.id), [id])
        XCTAssertTrue(summarizer.lastTranscript.contains("Alex Rivera: It leaves Friday."))
    }

    func testNoNotificationWhenAllSpeakersKnown() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        try library.add([0, 0, 0, 1], to: "Amy Lee")
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertEqual(try load(id).status, .written)
        XCTAssertTrue(notified.isEmpty)
    }

    func testTranscriptionFailureKeepsAudioAndRetries() async throws {
        transcriber.error = Boom()
        let id = try makeRecord()
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .recorded)
        XCTAssertEqual(r.attempts, 1)
        XCTAssertNotNil(r.nextAttempt)
        for f in ["me.caf", "them.caf"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory(id).appendingPathComponent(f).path))
        }
        XCTAssertTrue(notified.isEmpty)
    }

    func testSummaryFailureStillWritesTranscript() async throws {
        summarizer.fail = true
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).status, .identified)
        await p.process(id)
        XCTAssertEqual(try load(id).status, .identified)
        await p.process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertNil(r.summary)
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertFalse(md.contains("## Summary"))
        XCTAssertTrue(md.contains("## Transcript"))
    }

    func testRunPendingProcessesDueRecords() async throws {
        let id = try makeRecord()
        await pipeline().runPending()
        XCTAssertEqual(try load(id).status, .written)
    }

    func testApplyNamesRewritesFileAndLearnsVoices() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).unknownSpeakers, ["them:A", "them:B"])
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"])
        let r = try load(id)
        XCTAssertEqual(r.unknownSpeakers, [])
        XCTAssertEqual(r.summary, "Summary 2")
        XCTAssertEqual(r.decisions, ["Decision 2"])
        XCTAssertEqual(r.headline, "Headline 2")
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(md.contains("Amy Lee: I can book freight."))
        XCTAssertEqual(library.bestMatch([0, 0, 0, 1])?.name, "Amy Lee")
        XCTAssertEqual(library.bestMatch([0, 1, 0, 0])?.name, "Alex Rivera")
    }

    func testNamingReplacesSpeakerLettersAtOnceBeforeTheNewSummary() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        let letters = MarkdownWriter.displayNames(r)
        let a = try XCTUnwrap(letters["them:A"]), b = try XCTUnwrap(letters["them:B"])
        r.summary = "\(a) and \(b) agreed. \(a)'s plan stands."
        r.topics = [SummaryTopic(title: "Freight", summary: "\(b) books it.")]
        r.decisions = ["\(a) owns freight"]
        r.actionItems = [ActionItem(owner: a, task: "book freight"), ActionItem(owner: nil, task: "ask \(b) for dates")]
        try r.save(to: paths.callDirectory(id))
        summarizer.delayOnCall[2] = .milliseconds(400)
        let naming = Task { await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"]) }
        try await Task.sleep(for: .milliseconds(150))
        let early = try load(id)
        XCTAssertEqual(early.summary, "Alex Rivera and Amy Lee agreed. Alex Rivera's plan stands.")
        XCTAssertEqual(early.topics.first?.summary, "Amy Lee books it.")
        XCTAssertEqual(early.decisions, ["Alex Rivera owns freight"])
        XCTAssertEqual(early.actionItems.map(\.owner), ["Alex Rivera", nil])
        XCTAssertEqual(early.actionItems.last?.task, "ask Amy Lee for dates")
        await naming.value
        XCTAssertEqual(try load(id).summary, "Summary 2")
    }

    func testApplyNamesStoresEmailsOnTheProfiles() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"],
                           emails: ["them:A": " alex@example.com ", "them:B": ""])
        XCTAssertEqual(library.name(forEmail: "ALEX@example.com"), "Alex Rivera")
        XCTAssertEqual(library.profiles.first { $0.name == "Amy Lee" }?.email, nil)
    }

    func testApplyNamesStoresAnEmailWithoutAVoice() async throws {
        let id = try makeRecord()
        let p = pipeline(voiceFingerprints: false)
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:B": "Amy Lee"], emails: ["them:B": "amy@example.com"])
        XCTAssertEqual(library.name(forEmail: "amy@example.com"), "Amy Lee")
        XCTAssertEqual(try load(id).speakerNames["them:B"], "Amy Lee")
    }

    func testOverlappingNameSavesKeepBothNames() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        summarizer.delayOnCall[2] = .milliseconds(300)
        async let first: Void = p.applyNames(callID: id, names: ["them:A": "Alex Rivera"])
        try await Task.sleep(for: .milliseconds(50))
        await p.applyNames(callID: id, names: ["them:B": "Amy Lee"])
        _ = await first
        let r = try load(id)
        XCTAssertEqual(r.speakerNames["them:A"], "Alex Rivera")
        XCTAssertEqual(r.speakerNames["them:B"], "Amy Lee")
        XCTAssertEqual(r.summary, "Summary 3")
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(md.contains("Alex Rivera: It leaves Friday.") && md.contains("Amy Lee: I can book freight."))
    }

    func testUnreadableTrackIsAFailureNotAnEmptyTrack() async throws {
        let id = try makeRecord()
        try Data(repeating: 7, count: 4096).write(to: paths.callDirectory(id).appendingPathComponent("me.caf"))
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .recorded)
        XCTAssertEqual(r.attempts, 1)
    }

    func testMissingKeyDoesNotUseUpAttempts() async throws {
        transcriber.error = MissingAPIKey(service: "AssemblyAI")
        let id = try makeRecord()
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertEqual(r.attempts, 0)
        // Tried again at the next run (launch or hourly), with no backoff delay.
        XCTAssertEqual(ProcessingQueue(paths: paths).pending(now: start).map(\.id), [id])
    }

    func testConcurrentProcessOfOneCallRunsOnce() async throws {
        transcriber.delay = .milliseconds(200)
        let id = try makeRecord()
        let p = pipeline()
        async let a: Void = p.process(id)
        async let b: Void = p.process(id)
        _ = await (a, b)
        XCTAssertEqual(transcriber.calls.count, 2)
        XCTAssertEqual(notified.count, 1)
    }

    func testCompletedTrackIsNotTranscribedAgain() async throws {
        transcriber.failingTracks = [.me]
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).status, .recorded)
        transcriber.failingTracks = []
        await p.process(id)
        XCTAssertEqual(try load(id).status, .written)
        XCTAssertEqual(transcriber.calls.filter { $0 == .them }.count, 1)
        XCTAssertEqual(transcriber.calls.filter { $0 == .me }.count, 2)
    }

    func testNearEmptyTrackIsNotUploaded() async throws {
        let id = try makeRecord()
        try writeSegments(paths.callDirectory(id).appendingPathComponent("me.caf"), total: 0.5, [])
        await pipeline().process(id)
        XCTAssertEqual(transcriber.calls, [.them])
        XCTAssertEqual(try load(id).status, .written)
    }

    func testGivesUpAfterMaxAttemptsAndRetryResumes() async throws {
        transcriber.error = Boom()
        let id = try makeRecord()
        let p = pipeline()
        for _ in 0..<Pipeline.maxAttempts { await p.process(id) }
        var r = try load(id)
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(r.failedStep, .recorded)
        XCTAssertTrue(ProcessingQueue(paths: paths).pending(now: .distantFuture).isEmpty)
        transcriber.error = nil
        await p.retry(id)
        r = try load(id)
        XCTAssertEqual(r.status, .written)
    }
}
