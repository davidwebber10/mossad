import XCTest
@testable import MossadCore

final class ForegroundWatchTests: XCTestCase {
    private let a = ForegroundState(pid: 10, started: nil, recording: false)
    private let b = ForegroundState(pid: 10, started: nil, recording: true)

    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(ForegroundState.fileName)
    }

    func testAWorkerEndsWhenTheForegroundAppIsGoneOrSaysStop() {
        var asked = 0
        func alive(_ answer: Bool) -> (ForegroundState) -> Bool { { _ in asked += 1; return answer } }
        // 1. A state with `stopping`: told, `alive` not asked.
        var w = ForegroundWatch()
        asked = 0
        XCTAssertEqual(w.next(.state(.init(pid: 10, started: nil, recording: false, stopping: true)), alive: alive(true)), .stop(.told))
        XCTAssertEqual(asked, 0); XCTAssertNil(w.known)
        // 2. A state whose app is gone.
        w = ForegroundWatch()
        XCTAssertEqual(w.next(.state(a), alive: alive(false)), .stop(.foregroundGone)); XCTAssertNil(w.known)
        // 3. A state whose app lives.
        w = ForegroundWatch()
        XCTAssertEqual(w.next(.state(b), alive: alive(true)), .work(callRecords: true)); XCTAssertEqual(w.known, b)
        // 4. Missing with nothing known.
        w = ForegroundWatch(); asked = 0
        XCTAssertEqual(w.next(.missing, alive: alive(true)), .stop(.noForeground)); XCTAssertEqual(asked, 0)
        // 5. Missing after a good read.
        w = ForegroundWatch(); _ = w.next(.state(a), alive: alive(true)); asked = 0
        XCTAssertEqual(w.next(.missing, alive: alive(true)), .stop(.foregroundGone)); XCTAssertEqual(asked, 0)
        // 6. Unreadable with nothing known.
        w = ForegroundWatch(); asked = 0
        XCTAssertEqual(w.next(.unreadable, alive: alive(true)), .stop(.noForeground)); XCTAssertEqual(asked, 0)
        // 7. Unreadable, and the known app is gone.
        w = ForegroundWatch(); _ = w.next(.state(a), alive: alive(true))
        XCTAssertEqual(w.next(.unreadable, alive: alive(false)), .stop(.foregroundGone))
        // 8. Unreadable, and the known app lives: a call records, `known` stays.
        w = ForegroundWatch(); _ = w.next(.state(a), alive: alive(true))
        XCTAssertEqual(w.next(.unreadable, alive: alive(true)), .work(callRecords: true)); XCTAssertEqual(w.known, a)
    }

    func testAFileThatCannotBeReadMeansACallRecords() {
        var w = ForegroundWatch()
        XCTAssertEqual(w.next(.state(a), alive: { _ in true }), .work(callRecords: false))
        XCTAssertEqual(w.next(.unreadable, alive: { _ in true }), .work(callRecords: true))
        XCTAssertEqual(w.next(.unreadable, alive: { _ in true }), .work(callRecords: true))
        XCTAssertEqual(w.next(.state(a), alive: { _ in true }), .work(callRecords: false))
    }

    func testTheFileIsReadAndWritten() throws {
        let file = try temp()
        XCTAssertEqual(ForegroundState.read(file), .missing)
        let state = ForegroundState(pid: 42, started: Date(timeIntervalSince1970: 1_800_000_000), recording: true)
        try state.write(to: file)
        XCTAssertEqual(ForegroundState.read(file), .state(state))
        try Data(#"{"version":1,"pid":12,"recording":true,"stopping":false}"#.utf8).write(to: file)
        XCTAssertEqual(ForegroundState.read(file), .state(.init(pid: 12, started: nil, recording: true)))
        try Data(#"{"version":2,"pid":12,"recording":false,"stopping":false}"#.utf8).write(to: file)
        XCTAssertEqual(ForegroundState.read(file), .unreadable)
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(ForegroundState.read(file), .unreadable)
    }

    func testTheFileIsBesideTheRegistryInUse() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ForegroundState.url(home: home, environment: [:]).path, "/Users/someone/Library/Application Support/Mossad/foreground.json")
        XCTAssertEqual(ForegroundState.url(home: home, environment: ["MOSSAD_PROFILES": "/tmp/x/profiles.json"]).path, "/tmp/x/foreground.json")
    }

    func testAReusedPidIsNotTheForegroundApp() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let started = try XCTUnwrap(ProcessFacts.startTime(of: me))
        XCTAssertTrue(ProcessFacts.isAlive(pid: me, started: started))
        XCTAssertTrue(ProcessFacts.isAlive(pid: me, started: nil))
        XCTAssertFalse(ProcessFacts.isAlive(pid: me, started: started.addingTimeInterval(-60)))
        XCTAssertFalse(ProcessFacts.isAlive(pid: 0x7FFF_FFF0, started: nil))
        XCTAssertFalse(ProcessFacts.isAlive(pid: 0, started: nil))
    }

    func testTheWatcherStopsWhenTheFileSaysSo() throws {
        let file = try temp()
        let me = ProcessInfo.processInfo.processIdentifier
        try ForegroundState(pid: me, started: ProcessFacts.startTime(of: me), recording: false).write(to: file)
        let stops = Counter()
        let told = expectation(description: "told")
        let watcher = ForegroundWatcher(file: file, every: 0.05, signals: false) { why in
            stops.add(why.rawValue)
            told.fulfill()
        }
        XCTAssertEqual(watcher.first(), .work(callRecords: false))
        XCTAssertFalse(watcher.callRecords)
        watcher.start()
        try ForegroundState(pid: me, started: ProcessFacts.startTime(of: me), recording: false, stopping: true).write(to: file)
        wait(for: [told], timeout: 1)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(stops.all, ["told"])
    }

    func testTheWatcherAssumesACallWhileTheFileCannotBeRead() throws {
        let file = try temp()
        let me = ProcessInfo.processInfo.processIdentifier
        try ForegroundState(pid: me, started: ProcessFacts.startTime(of: me), recording: false).write(to: file)
        let stops = Counter()
        let watcher = ForegroundWatcher(file: file, every: 0.05, signals: false) { stops.add($0.rawValue) }
        XCTAssertEqual(watcher.first(), .work(callRecords: false))
        watcher.start()
        try Data("not json, and longer than before".utf8).write(to: file)
        let deadline = Date().addingTimeInterval(1)
        while !watcher.callRecords, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(watcher.callRecords)
        XCTAssertEqual(stops.all, [])
    }

    func testAMissingFileAtStartIsNoForeground() throws {
        let watcher = ForegroundWatcher(file: try temp(), signals: false) { _ in }
        XCTAssertEqual(watcher.first(), .stop(.noForeground))
        XCTAssertTrue(watcher.callRecords)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }
}
