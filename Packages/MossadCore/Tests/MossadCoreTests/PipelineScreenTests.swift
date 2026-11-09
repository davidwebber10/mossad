import XCTest
@testable import MossadCore

/// Reads a frame's text from the file itself, so a test writes the text it wants as the "picture".
final class FakeScreenReader: ScreenTextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _read: [String] = []
    var read: [String] { lock.withLock { _read } }

    func read(_ url: URL) -> (text: String, words: [ScreenWord])? {
        lock.withLock { _read.append(url.lastPathComponent) }
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

    func pipeline(isRecording: @escaping @Sendable () -> Bool = { false }, wait: @escaping @Sendable () async -> Void = {}) -> Pipeline {
        let later = start.addingTimeInterval(7200)
        return Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                        calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { later }, ownerName: "Robin Vale",
                        screenStep: ScreenStep(reader: reader, isRecording: isRecording, wait: wait))
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

    func testTheTextIsNotReadWhileACallRecords() async throws {
        try makeCall("a", at: start, frames: [(12, slide, nil)])
        let reader = reader
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var waits = 0
            var readsWhileRecording = 0
        }
        let calls = Calls()
        let p = pipeline(isRecording: {
            calls.lock.withLock {
                if calls.waits < 3 { calls.readsWhileRecording += reader.read.count }
                return calls.waits < 3
            }
        }, wait: { calls.lock.withLock { calls.waits += 1 } })
        await p.process("a")
        XCTAssertEqual(calls.waits, 3)
        XCTAssertEqual(calls.readsWhileRecording, 0)
        XCTAssertEqual(reader.read, ["12000.heic"])
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
