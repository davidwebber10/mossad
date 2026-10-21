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
    func transcribe(file: URL, track: Track) async throws -> [Utterance] {
        lock.withLock { _calls.append(track) }
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
    func summarize(transcript: String, title: String) async throws -> MeetingSummary {
        calls += 1
        let call = calls
        lastTranscript = transcript
        if let delay = delayOnCall[call] { try await Task.sleep(for: delay) }
        if fail { throw SummaryError.malformed }
        return MeetingSummary(summary: "Summary \(call)", actionItems: ["Alex Rivera: send forecast"])
    }
}

struct FakeCalendar: CalendarSource {
    var events: [CalendarEventInfo] = []
    func events(from: Date, to: Date) async -> [CalendarEventInfo] { events }
}

struct Boom: Error {}

final class Notifications: @unchecked Sendable {
    var records: [CallRecord] = []
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

    func makeRecord() throws -> String {
        let id = "20261020-143000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 400), (21, 28, 800)])
        try CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(1800), status: .recorded)
            .save(to: dir)
        return id
    }

    func pipeline(calendar: FakeCalendar = FakeCalendar()) -> Pipeline {
        let notifications = notifications
        let later = start.addingTimeInterval(3600)
        return Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                        calendar: calendar, summarizer: summarizer, notify: { notifications.records.append($0) },
                        now: { later })
    }

    func load(_ id: String) throws -> CallRecord { try CallRecord.load(from: paths.callDirectory(id)) }

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
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(md.contains("Amy Lee: I can book freight."))
        XCTAssertEqual(library.bestMatch([0, 0, 0, 1])?.name, "Amy Lee")
        XCTAssertEqual(library.bestMatch([0, 1, 0, 0])?.name, "Alex Rivera")
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
