import XCTest
@testable import MossadCore

/// One sync pass, moved out of `AppController.syncNow`: the same calls in the same order.
final class SyncPassTests: XCTestCase {
    private func temp() -> Paths {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-pass-\(UUID().uuidString)"))
        try! paths.ensureDirectories()
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        return paths
    }

    private func meeting(_ id: String, in paths: Paths) throws {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: Date(timeIntervalSince1970: 1_800_000_000),
                           end: Date(timeIntervalSince1970: 1_800_001_800), status: .written)
        r.summary = "We held spend."
        try FileManager.default.createDirectory(at: paths.callDirectory(id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(id))
    }

    /// A store that writes each call to a log, for the order of a pass.
    actor LoggingStore: RecordStore {
        let inner = MemoryStore()
        private(set) var log: [String] = []
        var failChanges = false
        func setFailChanges(_ on: Bool) { failChanges = on }
        /// A server's store has its own state file and takes the views and the digest.
        nonisolated let stateFileName: String
        nonisolated let wantsMeetingView: Bool
        init(stateFileName: String = "state.json", server: Bool = false) {
            self.stateFileName = stateFileName
            wantsMeetingView = server
        }
        func prepare() async throws { log.append("prepare") }
        func save(_ records: [StoredRecord]) async throws -> Set<String> {
            log.append("save " + records.map(\.type).sorted().joined(separator: ","))
            return try await inner.save(records)
        }
        func delete(_ names: [String]) async throws -> Set<String> { log.append("delete"); return try await inner.delete(names) }
        func changes(since token: Data?) async throws -> StoreChanges {
            log.append("changes")
            if failChanges { throw URLError(.notConnectedToInternet) }
            return try await inner.changes(since: token)
        }
        func refetch(_ record: ChangedRecord) async throws -> ChangedRecord? { try await inner.refetch(record) }
        func data(_ record: ChangedRecord, _ key: String) async throws -> Data? { try await inner.data(record, key) }
        func discard(_ names: [String]) async { await inner.discard(names) }
        var savedTypes: Set<String> { get async { Set(await inner.entries.values.map(\.record.type)) } }
    }

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private func inputs(main: CloudSync?, mirror: CloudSync?, serverIsMain: Bool = false, calling: Bool = false,
                        makeDigest: (@Sendable () -> [SharedPayload]?)? = nil) -> SyncPass.Inputs {
        SyncPass.Inputs(main: main, mirror: mirror, serverIsMain: serverIsMain, place: serverIsMain ? "your server" : "iCloud",
                        connection: nil, owner: "Sam Carter", personasInMCP: false, personas: nil, calling: calling,
                        callStarted: { false }, keptDigest: nil, makeDigest: makeDigest)
    }

    func testAPassSendsAndTakesAndNeverPullsMeetings() async throws {
        let paths = temp()
        try meeting("m1", in: paths)
        let store = LoggingStore()
        let result = await SyncPass.run(inputs(main: CloudSync(paths: paths, store: store), mirror: nil))
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.received, 0)
        let types = await store.savedTypes
        XCTAssertTrue(types.contains(CloudSync.meetingType), "\(types)")
        // The order of `syncNow` today: push, then pull, then the shared records.
        let log = await store.log
        let firstSave = try XCTUnwrap(log.firstIndex { $0.hasPrefix("save") })
        let firstChanges = try XCTUnwrap(log.firstIndex(of: "changes"))
        XCTAssertLessThan(firstSave, firstChanges, "\(log)")
    }

    func testAMirrorAloneOnlyPushes() async throws {
        let paths = temp()
        try meeting("m1", in: paths)
        let store = LoggingStore()
        let result = await SyncPass.run(inputs(main: nil, mirror: CloudSync(paths: paths, store: store)))
        XCTAssertNil(result.failure)
        let log = await store.log
        XCTAssertFalse(log.contains("changes"), "\(log)")
        let types = await store.savedTypes
        XCTAssertTrue(types.contains(CloudSync.meetingType))
    }

    func testAMirrorDuringACallSendsOnlyTheMeetings() async throws {
        let paths = temp()
        try meeting("m1", in: paths)
        let store = LoggingStore()
        let digests = Count()
        _ = await SyncPass.run(inputs(main: nil, mirror: CloudSync(paths: paths, store: store), calling: true,
                                      makeDigest: { digests.add(); return nil }))
        XCTAssertEqual(digests.value, 0)
        let log = await store.log
        XCTAssertEqual(log.filter { $0.hasPrefix("save") }.count, 1, "\(log)")
    }

    func testAStoreThatFailsIsAFailureInTheResult() async throws {
        let paths = temp()
        try meeting("m1", in: paths)
        let store = LoggingStore()
        await store.setFailChanges(true)
        let result = await SyncPass.run(inputs(main: CloudSync(paths: paths, store: store), mirror: nil))
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.failure?.context, .syncing)
    }

    func testNoDigestIsMadeWithoutAServerAsMain() async throws {
        let paths = temp()
        try meeting("m1", in: paths)
        let digests = Count()
        let result = await SyncPass.run(inputs(main: CloudSync(paths: paths, store: LoggingStore()), mirror: nil,
                                               makeDigest: { digests.add(); return [] }))
        XCTAssertEqual(digests.value, 0)
        XCTAssertNil(result.digest)
        XCTAssertFalse(result.digestArrived)
    }

    func testTheDigestIsMadeOnceForAServerAsMainAndChecked() async throws {
        let paths = temp()
        try meeting("m1", in: paths)
        let digests = Count()
        let result = await SyncPass.run(inputs(main: CloudSync(paths: paths, store: LoggingStore()), mirror: nil, serverIsMain: true,
                                               makeDigest: { digests.add(); return [] }))
        XCTAssertEqual(digests.value, 1)
        XCTAssertEqual(result.digest?.count, 0)
    }

    func testAKeptDigestIsCheckedAsItIsAndNotMadeAgain() async throws {
        let paths = temp()
        try meeting("m1", in: paths)
        let digests = Count()
        var i = inputs(main: CloudSync(paths: paths, store: LoggingStore()), mirror: nil, serverIsMain: true,
                       makeDigest: { digests.add(); return nil })
        i.keptDigest = []
        let result = await SyncPass.run(i)
        XCTAssertEqual(digests.value, 0)
        XCTAssertEqual(result.digest?.count, 0)
    }

    private let server = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "s")

    private func configs() -> [StubURLProtocol.Recorded] {
        StubURLProtocol.requests.filter { $0.url.path.hasSuffix("/config") }
    }

    func testAServerAsMainIsToldTheConfigAfterThePass() async throws {
        let paths = temp()
        var i = inputs(main: CloudSync(paths: paths, store: LoggingStore()), mirror: nil, serverIsMain: true)
        i.connection = server
        i.session = StubURLProtocol.session()
        StubURLProtocol.handler = { _ in (200, Data("{}".utf8)) }
        _ = await SyncPass.run(i)
        let sent = configs()
        XCTAssertEqual(sent.count, 1, "\(StubURLProtocol.requests.map(\.url))")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.first).body) as? [String: Any]
        XCTAssertEqual(body?["owner"] as? String, "Sam Carter")
        XCTAssertNotNil(body?["syncedAt"])
    }

    func testTheMirrorTellsTheConfigOnlyWhenNoCallStarted() async throws {
        for started in [true, false] {
            let paths = temp()
            var i = inputs(main: nil, mirror: CloudSync(paths: paths, store: LoggingStore()))
            i.connection = server
            i.callStarted = { started }
            i.session = StubURLProtocol.session()
            StubURLProtocol.handler = { _ in (200, Data("{}".utf8)) }
            _ = await SyncPass.run(i)
            XCTAssertEqual(configs().count, started ? 0 : 1, "call started: \(started)")
        }
    }

    func testThePhonesRecordingNoticesComeWithThePass() async throws {
        let paths = temp()
        let store = LoggingStore()
        let json = #"{"name":"room-1","firstFailure":0,"attempts":3,"next":0,"reason":"","gaveUp":true}"#
        var state = SyncState()
        state.recordings = [try JSONDecoder().decode(PendingRecording.self, from: Data(json.utf8))]
        try state.save(to: paths.sync, fileName: store.stateFileName)
        let result = await SyncPass.run(inputs(main: CloudSync(paths: paths, store: store), mirror: nil))
        XCTAssertEqual(result.waiting.map(\.name), ["room-1"])
    }

    func testThePassNeverTakesInMeetingsFromAnotherDevice() async throws {
        let other = temp()
        try meeting("m1", in: other)
        let store = LoggingStore()
        _ = try await CloudSync(paths: other, store: store).push()
        let paths = temp()
        let result = await SyncPass.run(inputs(main: CloudSync(paths: paths, store: store), mirror: nil))
        XCTAssertNil(result.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory("m1").path))
        XCTAssertEqual(result.received, 0)
    }

    func testTheDigestIsCheckedOnTheStoreItWentTo() async throws {
        let paths = temp()
        try meeting("m1", in: paths)
        let payload = SharedPayload(kind: .digest, key: "digest-series", data: Data("{}".utf8))
        // iCloud main and the server as a mirror: the digest goes to the mirror, so the mirror is asked.
        let result = await SyncPass.run(inputs(main: CloudSync(paths: paths, store: LoggingStore()),
                                               mirror: CloudSync(paths: paths, store: LoggingStore(stateFileName: "server.json", server: true)),
                                               makeDigest: { [payload] }))
        XCTAssertEqual(result.digest?.count, 1)
        XCTAssertTrue(result.digestArrived)
    }
}
