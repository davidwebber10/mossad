import XCTest
@testable import MossadCore

/// A worker's run with fakes: no provider, no store, no calendar of this Mac.
final class ProfileWorkerTests: XCTestCase {
    private var paths: Paths!
    private let transcriber = FakeTranscriber()
    private let summarizer = FakeSummarizer()
    private let start = localDate(2026, 10, 20, 14, 30)

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        transcriber.result = [
            .me: [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Where is the shipment?")],
            .them: [Utterance(track: .them, speakerLabel: "A", start: 11, end: 20, text: "It leaves Friday.")],
        ]
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    @discardableResult
    private func recorded(status: CallStatus = .recorded) throws -> String {
        let id = "20261020-143000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 400)])
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(1800), status: status)
        if status == .identified {
            r.utterances = transcriber.result.values.flatMap { $0 }
            r.speakerNames = ["me:A": "Avery Lane"]
        }
        try r.save(to: dir)
        return id
    }

    /// A calendar that counts its reads.
    final class CountingCalendar: CalendarSource, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func events(from: Date, to: Date) async -> [CalendarEventInfo] { lock.withLock { n += 1 }; return [] }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ v: Bool) { value = v }
        var get: Bool { lock.withLock { value } }
    }

    private func worker(madeUp: Bool = false, calling: Bool = false, key: String? = "k", transcriber t: Transcribing? = nil,
                        store: MemoryStore = MemoryStore(), calendar: CalendarSource = FakeCalendar(), coach: Bool = false) throws -> ProfileWorker {
        let made = try MadeUpSuite(self)
        if coach { made.defaults.set(true, forKey: "coachEnabled") }
        let settings = ServiceSettings.read(made.defaults, fullUserName: "Avery Lane")
        let flag = Flag(calling)
        let setup = ProfileWorker.Setup(paths: paths, settings: settings, key: { _ in key }, google: Keychain(service: "com.dwebber.mossad.test-none"),
                                        remember: { _, _ in }, hasICloud: false, madeUpRegistry: madeUp,
                                        macCalendarAuthorized: { false }, callRecords: { flag.get }, now: { [start] in start.addingTimeInterval(7200) })
        let services = ProfileWorker.Services(transcriber: t ?? transcriber, summarizer: summarizer, embeddings: ToneEmbeddingProvider(),
                                              calendar: calendar, llm: nil, main: CloudSync(paths: paths, store: store), mirror: nil, archive: nil)
        return ProfileWorker(setup, services: services)
    }

    func testAPassMovesARecordedCallToWrittenAndWritesTheStatus() async throws {
        let id = try recorded()
        let store = MemoryStore()
        let w = try worker(store: store)
        let started = await w.start()
        XCTAssertTrue(started.isSuperset(of: [.recover, .people, .statusFile]))
        let pass = await w.pass([.queue, .sync])
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).status, .written)
        XCTAssertTrue(pass.ran.isSuperset(of: [.queue, .sync, .statusFile]), "\(pass.ran)")
        let status = try XCTUnwrap(WorkerStatus.peek(root: paths.root))
        XCTAssertEqual(status.inWork, 0); XCTAssertNil(status.failure)
        let types = Set(await store.entries.values.map(\.record.type))
        XCTAssertTrue(types.contains("Meeting"), "\(types)")
    }

    func testWithNoKeyTheCallStaysAndTheStatusNamesTheKind() async throws {
        let id = try recorded()
        let w = try worker(key: nil, transcriber: MissingKeyTranscriber(service: "AssemblyAI"))
        _ = await w.start()
        _ = await w.pass([.queue])
        let r = try CallRecord.load(from: paths.callDirectory(id))
        XCTAssertEqual(r.status, .recorded)
        XCTAssertEqual(r.attempts, 0)
        XCTAssertEqual(WorkerStatus.peek(root: paths.root), WorkerStatus(written: start.addingTimeInterval(7200), inWork: 1,
                                                                           failure: .init(kind: .key, count: 1)))
    }

    func testWhileACallRecordsTheWorkerDoesNotSyncOrEncode() async throws {
        let id = try recorded(status: .identified)
        let store = MemoryStore()
        let w = try worker(calling: true, store: store)
        _ = await w.start()
        let pass = await w.pass([.queue, .sync])
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).status, .written)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(id).appendingPathComponent(Recording.fileName).path))
        XCTAssertFalse(pass.ran.contains(.sync)); XCTAssertFalse(pass.ran.contains(.backup))
        let count = await store.entries.count
        XCTAssertEqual(count, 0)
    }

    func testOnAMadeUpRegistryNothingLeavesTheFolder() async throws {
        try recorded()
        let store = MemoryStore()
        let calendar = CountingCalendar()
        let w = try worker(madeUp: true, store: store, calendar: calendar, coach: true)
        let started = await w.start()
        let pass = await w.pass([.queue, .sync])
        let allowed: Set<Duty> = [.recover, .people, .queue, .statusFile]
        XCTAssertTrue(started.isSubset(of: allowed), "\(started)")
        XCTAssertTrue(pass.ran.isSubset(of: allowed), "\(pass.ran)")
        let count = await store.entries.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(calendar.count, 0)
    }

    func testAWorkerDoesOnlyWhatTheTableSays() async throws {
        try recorded()
        let w = try worker(coach: true)
        let started = await w.start()
        let pass = await w.pass([.queue, .sync])
        for duty in started.union(pass.ran) { XCTAssertTrue(RunMode.worker.does(duty), "\(duty)") }
    }
}
