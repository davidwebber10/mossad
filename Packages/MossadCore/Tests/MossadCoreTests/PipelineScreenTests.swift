import XCTest
@testable import MossadCore

/// Reads a frame's text from the file itself, so a test writes the text it wants as the "picture".
final class FakeScreenReader: ScreenTextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _read: [String] = []
    var read: [String] { lock.withLock { _read } }

    /// The QoS of the thread each read ran on.
    private var _classes: [qos_class_t] = []
    var classes: [qos_class_t] { lock.withLock { _classes } }
    /// Files that cannot be read, as when Vision fails.
    var unreadable: Set<String> = []

    func read(_ url: URL) -> (text: String, words: [ScreenWord])? {
        lock.withLock {
            _read.append(url.lastPathComponent)
            _classes.append(qos_class_self())
        }
        if unreadable.contains(url.lastPathComponent) { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (text, [ScreenWord(text: text, x: 0.1, y: 0.1, width: 0.5, height: 0.05)])
    }
}

final class PipelineScreenTests: XCTestCase {
    var paths: Paths!
    let transcriber = FakeTranscriber()
    let summarizer = FakeSummarizer()
    let reader = FakeScreenReader()
    var library: VoiceLibrary!
    let start = localDate(2026, 10, 20, 14, 30)
    let slide = "Q3 plan\nRevenue grew 12 percent over the second quarter"
    let faces = "Sam Carter\nDana Lee\nMute"

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        library = VoiceLibrary(directory: paths.voices)
        transcriber.result = [
            .me: [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Where is the shipment?")],
            .them: [Utterance(track: .them, speakerLabel: "A", start: 11, end: 20, text: "It leaves Friday.")],
        ]
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func makeCall(_ id: String, at start: Date, frames: [(TimeInterval, String, String?)]) throws {
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 400)])
        try CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(1800), status: .recorded).save(to: dir)
        guard !frames.isEmpty else { return }
        var index = FrameIndex()
        for (offset, text, presenter) in frames {
            let f = FrameIndex.Frame(offset: offset, file: FrameIndex.fileName(offset: offset), window: "w", presenter: presenter)
            index.insert(f)
            try Data(text.utf8).write(to: index.url(of: f, in: dir))
        }
        try index.save(to: dir)
    }

    func pipeline(isRecording: @escaping @Sendable () -> Bool = { false }, rest: @escaping @Sendable () async -> Void = {},
                  calendar: FakeCalendar = FakeCalendar()) -> Pipeline {
        let later = start.addingTimeInterval(7200)
        return Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                        calendar: calendar, summarizer: summarizer, notify: { _ in }, now: { later }, ownerName: "Robin Vale",
                        screenStep: ScreenStep(reader: reader, isRecording: isRecording, rest: rest))
    }

    func files(_ id: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FrameIndex.folder(in: paths.callDirectory(id)).path)) ?? []).sorted()
    }

    func testFramesWithTextBecomeScreensAndTheRestIsDeleted() async throws {
        try library.add([1, 0, 0], to: "Sam Carter")
        try makeCall("a", at: start, frames: [(12, slide, "sam carter"), (15, faces, nil), (25, slide + " again", nil)])
        await pipeline().process("a")
        let r = try CallRecord.load(from: paths.callDirectory("a"))
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.screens, [
            SharedScreen(offset: 12, file: "12000.heic", text: slide, presenter: "Sam Carter", window: "w"),
            SharedScreen(offset: 25, file: "25000.heic", text: slide + " again", window: "w"),
        ])
        XCTAssertEqual(files("a"), ["12000.heic", "25000.heic"])
        let index = try XCTUnwrap(FrameIndex.load(from: paths.callDirectory("a")))
        XCTAssertEqual(index.frames.map(\.offset), [12, 25])
        XCTAssertEqual(index.frames[0].words?.count, 1)
        // The summary and the note see the screen as a line of the transcript.
        let line = "[00:00:12] (Screen shared by Sam Carter: \"Q3 plan Revenue grew 12 percent over the second quarter\")"
        XCTAssertTrue(summarizer.lastTranscript.contains(line), summarizer.lastTranscript)
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains(line))
        XCTAssertTrue(r.markers.isEmpty)
    }

    func testACallWithNoFramesHasNoScreens() async throws {
        try makeCall("a", at: start, frames: [])
        await pipeline().process("a")
        XCTAssertNil(try CallRecord.load(from: paths.callDirectory("a")).screens)
        XCTAssertEqual(reader.read, [])
    }

    func testASecondRunReadsNothingAgainAndKeepsTheScreens() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil)])
        let p = pipeline()
        await p.process("a")
        XCTAssertEqual(reader.read, ["12000.heic"])
        await p.regenerateSummary("a")
        XCTAssertEqual(reader.read, ["12000.heic"])
        let r = try CallRecord.load(from: paths.callDirectory("a"))
        XCTAssertEqual(r.screens?.count, 1)
        XCTAssertEqual(MarkdownWriter.transcript(r).components(separatedBy: "(Screen").count, 2)
    }

    func testAnInterruptedRunGoesOnWhereItStopped() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil), (25, slide, nil)])
        let dir = paths.callDirectory("a")
        // The first frame was read before the quit.
        var index = try XCTUnwrap(FrameIndex.load(from: dir))
        index.frames[0].text = slide
        try index.save(to: dir)
        await pipeline().process("a")
        XCTAssertEqual(reader.read, ["25000.heic"])
        XCTAssertEqual(try CallRecord.load(from: dir).screens?.count, 2)
    }

    func testTheNoteDoesNotWaitForAnotherCallToEnd() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil), (25, slide + " two", nil), (40, slide + " three", nil)])
        final class Rests: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
        }
        let rests = Rests()
        // Another call records the whole time. The frames are read one at a time, with a rest before each one.
        await pipeline(isRecording: { true }, rest: { rests.lock.withLock { rests.count += 1 } }).process("a")
        let r = try CallRecord.load(from: paths.callDirectory("a"))
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.screens?.count, 3)
        XCTAssertEqual(rests.count, 3)
    }

    func testTheGateForHeavyWorkSlowsTheTextStepAndDoesNotStopIt() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil), (25, slide + " two", nil)])
        final class Rests: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
        }
        let rests = Rests()
        // A call records for as long as the test runs: a step that waited at the gate would never return.
        let gate = HeavyWorkGate(pollInterval: .seconds(3600), isCallRecording: { true })
        let step = ScreenStep(reader: reader, rest: { rests.lock.withLock { rests.count += 1 } }).gated(by: gate)
        let result = await step.run(in: paths.callDirectory("a"), known: [])
        XCTAssertEqual(result?.screens.count, 2)
        XCTAssertEqual(rests.count, 2)
        XCTAssertEqual(reader.classes, [QOS_CLASS_BACKGROUND, QOS_CLASS_BACKGROUND])
    }

    func testScreensSurviveTheCompactRecordAndTheRecordCache() async throws {
        try makeCall("a", at: start, frames: [(12, slide, "Sam Carter")])
        let dir = paths.callDirectory("a")
        var index = try XCTUnwrap(FrameIndex.load(from: dir))
        index.frames[0].session = 0
        index.frames[0].time = start.addingTimeInterval(12)
        index.gaps = [ScreenGap(offset: 20, paused: true)]
        try index.save(to: dir)
        // Read once before the run, so the cache holds the record without screens.
        XCTAssertNil(ProcessingQueue(paths: paths).allRecords().first?.screens)
        await pipeline().process("a")
        let expected = [SharedScreen(offset: 12, file: "12000.heic", text: slide, presenter: "Sam Carter", window: "w",
                                     time: start.addingTimeInterval(12), session: 0)]
        XCTAssertEqual(try CallRecord.load(from: dir).screens, expected)
        let cached = try XCTUnwrap(ProcessingQueue(paths: paths).allRecords().first)
        XCTAssertEqual(cached.screens, expected)
        XCTAssertEqual(cached.screenGaps, [ScreenGap(offset: 20, paused: true)])
        // One line, not pretty-printed, and still the same record.
        let raw = try String(contentsOf: dir.appendingPathComponent(CallRecord.fileName), encoding: .utf8)
        XCTAssertFalse(raw.contains("\n"))
        XCTAssertTrue(raw.contains("\"screens\":["))
        // The screen lines reach the transcript, the search, and the tools from the cached record.
        XCTAssertTrue(MarkdownWriter.transcript(cached).contains("(Screen shared by Sam Carter: \"Q3 plan"))
        XCTAssertEqual(SearchIndex(records: [cached]).moments(in: "a", matching: "revenue").map(\.time), [12])
        let tools = ChatTools(records: [cached], owner: "Robin Vale", paths: paths)
        XCTAssertEqual(tools.searchTranscripts(query: "revenue").map(\.at), [12])
        XCTAssertTrue(tools.run("list_screens", input: ["meeting_id": "a"]).contains("1. at_seconds: 12"))
        XCTAssertTrue(MeetingSearch.matches(cached, "revenue"))
    }

    func testNoRestWhenNoCallRecords() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil), (25, slide + " two", nil)])
        final class Rests: @unchecked Sendable { var count = 0 }
        let rests = Rests()
        await pipeline(rest: { rests.count += 1 }).process("a")
        XCTAssertEqual(rests.count, 0)
    }

    func testTheTextIsReadAtBackgroundPriorityAlsoForAWaitingTaskOfHighPriority() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil)])
        let p = pipeline()
        await Task(priority: .userInitiated) { await p.process("a") }.value
        XCTAssertEqual(reader.classes, [QOS_CLASS_BACKGROUND])
    }

    func testAFrameThatCouldNotBeReadIsKeptForAnotherTry() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil), (25, slide + " two", nil)])
        reader.unreadable = ["25000.heic"]
        let p = pipeline()
        await p.process("a")
        // Not read is not "no text": the picture stays, and the record lists what was read.
        XCTAssertEqual(files("a"), ["12000.heic", "25000.heic"])
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory("a")).screens?.map(\.offset), [12])
        XCTAssertEqual(FrameIndex.load(from: paths.callDirectory("a"))?.frames.map(\.attempts), [nil, 1])
        // The next run reads it.
        reader.unreadable = []
        await p.regenerateSummary("a")
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory("a")).screens?.map(\.offset), [12, 25])
        // One that never reads is given up after three tries.
        try makeCall("b", at: start.addingTimeInterval(4000), frames: [(5, slide, nil)])
        reader.unreadable = ["5000.heic"]
        await p.process("b")
        await p.regenerateSummary("b")
        await p.regenerateSummary("b")
        XCTAssertEqual(files("b"), [])
    }

    func testThePresenterIsMatchedToTheInvitedPeople() async throws {
        try makeCall("a", at: start, frames: [(12, slide, "dana lee")])
        let calendar = FakeCalendar(events: [CalendarEventInfo(title: "Plan review", start: start, end: start.addingTimeInterval(1800),
                                                               attendees: ["Dana Lee"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)])
        await pipeline(calendar: calendar).process("a")
        let r = try CallRecord.load(from: paths.callDirectory("a"))
        XCTAssertEqual(r.attendees, ["Dana Lee"])
        XCTAssertEqual(r.screens?.first?.presenter, "Dana Lee")
    }

    func testPausesNextToAShareReachTheRecordAndOthersDoNot() async throws {
        try makeCall("a", at: start, frames: [(600, slide, nil)])
        let dir = paths.callDirectory("a")
        var index = try XCTUnwrap(FrameIndex.load(from: dir))
        index.gaps = [ScreenGap(offset: 30, paused: true), ScreenGap(offset: 60, paused: false),
                      ScreenGap(offset: 620, paused: true), ScreenGap(offset: 640, paused: false)]
        try index.save(to: dir)
        await pipeline().process("a")
        let r = try CallRecord.load(from: dir)
        XCTAssertEqual(r.screenGaps, [ScreenGap(offset: 620, paused: true), ScreenGap(offset: 640, paused: false)])
        XCTAssertTrue(r.markers.isEmpty)
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("[00:10:20] (Screen capture paused)"))
        XCTAssertFalse(note.contains("[00:00:30] (Screen capture paused)"))
    }

    func testAJoinWithAPartWhosePicturesAreGoneKeepsThatPartsText() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil)])
        try makeCall("b", at: start.addingTimeInterval(2400), frames: [(5, slide + " more", nil)])
        let p = pipeline()
        await p.process("a")
        await p.process("b")
        // The first part's pictures went with its old recording; its text is in the record only.
        FrameStore.remove(in: paths.callDirectory("a"))
        await p.merge(callIDs: ["a", "b"])
        let r = try CallRecord.load(from: paths.callDirectory("a"))
        XCTAssertEqual(r.screens?.map(\.text), [slide, slide + " more"])
        XCTAssertEqual(files("a"), ["35000.heic"])
    }

    func testTheScreensStayWhenTheFramesAreGone() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil)])
        let p = pipeline()
        await p.process("a")
        FrameStore.remove(in: paths.callDirectory("a"))
        await p.regenerateSummary("a")
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory("a")).screens?.map(\.text), [slide])
    }

    func testMergeMovesTheFramesOfTheSecondPart() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil)])
        try makeCall("b", at: start.addingTimeInterval(2400), frames: [(5, slide + " more", nil)])
        let p = pipeline()
        await p.process("a")
        await p.process("b")
        let merged = await p.merge(callIDs: ["a", "b"])
        XCTAssertEqual(merged, "a")
        let r = try CallRecord.load(from: paths.callDirectory("a"))
        // The first part's audio is 30 s long.
        XCTAssertEqual(r.screens?.map(\.offset), [12, 35])
        XCTAssertEqual(r.screens?.map(\.file), ["12000.heic", "35000.heic"])
        XCTAssertEqual(files("a"), ["12000.heic", "35000.heic"])
        XCTAssertEqual(FrameIndex.load(from: paths.callDirectory("a"))?.frames.map(\.text), [slide, slide + " more"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory("b").path))
        // Nothing was read a second time.
        XCTAssertEqual(reader.read.count, 2)
    }

    func testDeletingACallDeletesItsFrames() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil)])
        let p = pipeline()
        await p.process("a")
        let deleted = await p.delete(callID: "a")
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory("a").path))
    }
}
