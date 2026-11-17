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

    func testAnUnreadableFileIsReadAgainAtEachTick() throws {
        let file = try temp()
        let me = ProcessInfo.processInfo.processIdentifier
        let good = try JSONEncoder().encode(ForegroundState(pid: me, started: ProcessFacts.startTime(of: me), recording: false))
        try good.write(to: file)
        let watcher = ForegroundWatcher(file: file, every: 0.05, signals: false) { _ in }
        XCTAssertEqual(watcher.first(), .work(callRecords: false))
        watcher.start()
        // A short failure: as long as the good file, so only a new read can tell them apart.
        try Data(repeating: UInt8(ascii: "x"), count: good.count).write(to: file)
        let stamp = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        var deadline = Date().addingTimeInterval(1)
        while !watcher.callRecords, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(watcher.callRecords)
        try good.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        deadline = Date().addingTimeInterval(1)
        while watcher.callRecords, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(watcher.callRecords, "the same size and time, read again")
    }

    func testTheWatcherEndsWhenTheAppsPidExitsBeforeItsNextCheck() throws {
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["30"]
        try app.run()
        addTeardownBlock { if app.isRunning { app.terminate() } }
        let file = try temp()
        try ForegroundState(pid: app.processIdentifier, started: nil, recording: false).write(to: file)
        let gone = expectation(description: "gone")
        // A check every minute that would think the pid lives: only the exit source can end it in time.
        let watcher = ForegroundWatcher(file: file, every: 60, alive: { _ in true }, signals: false) { why in
            if why == .foregroundGone { gone.fulfill() }
        }
        XCTAssertEqual(watcher.first(), .work(callRecords: false))
        watcher.start()
        Thread.sleep(forTimeInterval: 0.2)
        app.terminate()
        wait(for: [gone], timeout: 3)
    }

    func testASigtermIsAStopWhenTheWatcherHandlesSignals() throws {
        let file = try temp()
        let me = ProcessInfo.processInfo.processIdentifier
        try ForegroundState(pid: me, started: ProcessFacts.startTime(of: me), recording: false).write(to: file)
        let told = expectation(description: "told")
        let watcher = ForegroundWatcher(file: file, every: 60, signals: true) { why in
            if why == .told { told.fulfill() }
        }
        addTeardownBlock { signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL) }
        XCTAssertEqual(watcher.first(), .work(callRecords: false))
        watcher.start()
        Thread.sleep(forTimeInterval: 0.2)
        kill(me, SIGTERM)
        wait(for: [told], timeout: 3)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    func testAnAppWritesTheFileOnlyWhileItIsTheAppInFront() {
        let other = ForegroundState(pid: 700, started: nil, recording: false)
        let mine = ForegroundState(pid: 500, started: nil, recording: true, stopping: true)
        // After a switch the new app owns the file: the old app's quit does not write `stopping` over it.
        XCTAssertFalse(ForegroundState.mayWrite(over: .state(other), pid: 500, alive: { _ in true }))
        // The start of a new app takes the file over, also from an old app that is still quitting after a switch.
        XCTAssertTrue(ForegroundState.mayWrite(over: .state(other), pid: 500, alive: { _ in true }, takeOver: true))
        // A file left by an app that ended, or by this app, is written over; so is a missing or unreadable one.
        XCTAssertTrue(ForegroundState.mayWrite(over: .state(other), pid: 500, alive: { _ in false }))
        XCTAssertTrue(ForegroundState.mayWrite(over: .state(mine), pid: 500, alive: { _ in true }))
        XCTAssertTrue(ForegroundState.mayWrite(over: .missing, pid: 500, alive: { _ in true }))
        XCTAssertTrue(ForegroundState.mayWrite(over: .unreadable, pid: 500, alive: { _ in true }))
    }
}
