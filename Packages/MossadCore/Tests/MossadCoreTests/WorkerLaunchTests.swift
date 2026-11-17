import XCTest
@testable import MossadCore

final class WorkerLaunchTests: XCTestCase {
    private let main = AppIdentity.mainBundleID
    private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")

    private func registry() -> ProfileRegistry.Loaded {
        var r = ProfileRegistry()
        r.profiles.append(work)
        return .init(registry: r, state: .read)
    }

    func testAWorkerNeedsProfilesAndItsOwnProfile() {
        let ok = ["Mossad", "--profile", "1a2b3c4d", "--worker"]
        XCTAssertNil(WorkerLaunch.refusal(AppIdentity(bundleID: main, arguments: ok, registry: registry()), arguments: ok))
        let bare = ["Mossad", "--worker"]
        XCTAssertEqual(WorkerLaunch.refusal(AppIdentity(bundleID: main, arguments: bare, registry: registry()), arguments: bare),
                       "Mossad: --worker needs --profile <id>; not starting.")
        for id in [AppIdentity(bundleID: AppIdentity.rehearsalBundleID, arguments: ok, registry: registry()),
                   AppIdentity(bundleID: main, arguments: ok, environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: registry()),
                   AppIdentity(bundleID: main, arguments: ok + ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: registry())] {
            XCTAssertEqual(WorkerLaunch.refusal(id, arguments: ok), "Mossad: a worker needs profiles; not starting.")
        }
        let both = ok + ["--mcp"]
        XCTAssertEqual(WorkerLaunch.refusal(AppIdentity(bundleID: main, arguments: both, registry: registry()), arguments: both),
                       "Mossad: --worker cannot run with a command; not starting.")
        XCTAssertTrue(WorkerLaunch.isWorker(ok)); XCTAssertFalse(WorkerLaunch.isWorker(["Mossad", "--profile", "1a2b3c4d"]))
    }

    func testTheFirstProfileMayHaveAWorkerAndAnUnknownOneNot() {
        // When Work is active, the first profile is the other one.
        let first = ["Mossad", "--profile", "default", "--worker"]
        XCTAssertNil(WorkerLaunch.refusal(AppIdentity(bundleID: main, arguments: first, registry: registry()), arguments: first))
        let unknown = ["Mossad", "--profile", "ffffffff", "--worker"]
        XCTAssertEqual(WorkerLaunch.refusal(AppIdentity(bundleID: main, arguments: unknown, registry: registry()), arguments: unknown),
                       "Mossad: no profile with the id ffffffff; not starting.")
    }

    func testTheChildProcessOfAWorker() {
        let p = WorkerLaunch.process(executable: URL(fileURLWithPath: "/tmp/Mossad"), profile: work, environment: ["A": "b"])
        XCTAssertEqual(p.arguments, ["--profile", "1a2b3c4d", "--worker"])
        XCTAssertEqual(WorkerLaunch.arguments(for: work), ["--profile", "1a2b3c4d", "--worker"])
        XCTAssertEqual(p.environment, ["A": "b"])
        XCTAssertEqual(p.qualityOfService, .utility)
        XCTAssertEqual(p.executableURL?.path, "/tmp/Mossad")
        XCTAssertEqual(WorkerLaunch.Exit.refused.rawValue, 2); XCTAssertEqual(WorkerLaunch.Exit.setupNotDone.rawValue, 5)
    }

    func testTheStatusReadHasAName() {
        XCTAssertTrue(["fullAccess", "writeOnly", "denied", "restricted", "notDetermined"].contains(EventKitCalendarSource.permissionName))
    }

    func testAWorkerNeverRunsWithoutItsFolderLock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        for d in [dir, other] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        }
        guard case .held(let first) = InstanceLock.acquire(root: dir) else { return XCTFail("no lock") }
        XCTAssertEqual(WorkerLaunch.afterLock(InstanceLock.acquire(root: dir)), .lockNotHeld)
        XCTAssertEqual(WorkerLaunch.afterLock(.failed(EACCES)), .lockNotHeld)
        withExtendedLifetime(first) {}
        XCTAssertNil(WorkerLaunch.afterLock(InstanceLock.acquire(root: other)))
    }

    func testAProfileThatWouldOpenSetupGetsNoWorker() {
        XCTAssertFalse(WorkerLaunch.setupDone(finished: false, hasMeetings: false))
        XCTAssertTrue(WorkerLaunch.setupDone(finished: true, hasMeetings: false))
        XCTAssertTrue(WorkerLaunch.setupDone(finished: false, hasMeetings: true))
    }

    private func three() -> ProfileRegistry.Loaded {
        var r = ProfileRegistry()
        r.profiles.append(work)
        var gone = Profile(id: "9f8e7d6c", name: "Old", color: .green, root: "~/Mossad Old")
        gone.removing = true
        r.profiles.append(gone)
        return .init(registry: r, state: .read)
    }

    func testEachOtherProfileGetsAWorkerAndOnlyFromTheForegroundApp() {
        func ids(_ identity: AppIdentity, _ mode: RunMode, proof: Bool = false) -> [String] {
            WorkerLaunch.profiles(identity, mode: mode, proof: proof).map(\.id)
        }
        XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "default"], registry: three()), .full), ["1a2b3c4d"])
        XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: three()), .full), ["default"])
        XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "default"], registry: three()), .inert), [])
        XCTAssertEqual(ids(AppIdentity(bundleID: main), .full), [])
        XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: three(), madeUpRegistry: true), .full), [])
        XCTAssertEqual(ids(AppIdentity(bundleID: AppIdentity.rehearsalBundleID, registry: three()), .full), [])
        XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "default"], registry: three()), .worker), [])
    }

    func testOnlyAProofOnAMadeUpRegistryLiftsTheRuleAndNeverForTheFirstProfile() {
        var r = ProfileRegistry()
        r.profiles.append(work)
        r.profiles.append(Profile(id: "0b1c2d3e", name: "Other", color: .green, root: "/tmp/made up/Mossad Other"))
        let made = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: .init(registry: r, state: .read), madeUpRegistry: true)
        XCTAssertEqual(WorkerLaunch.profiles(made, mode: .inert, proof: true).map(\.id), ["0b1c2d3e"], "never `default`: on a made-up registry it is the real folder")
        XCTAssertEqual(WorkerLaunch.profiles(made, mode: .inert, proof: false).map(\.id), [])
        // The hook does nothing on the real registry.
        let real = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "default"], registry: three())
        XCTAssertEqual(WorkerLaunch.profiles(real, mode: .inert, proof: true).map(\.id), [])
    }

    func testOneProfileStartsNothingAndWritesNoFile() {
        let one = AppIdentity(bundleID: main)
        XCTAssertTrue(WorkerLaunch.profiles(one, mode: .full).isEmpty)
        XCTAssertFalse(WorkerLaunch.writesForegroundFile(profiles: []))
        XCTAssertTrue(WorkerLaunch.writesForegroundFile(profiles: [work]))
    }

    func testAStoppedWorkerIsNotStartedAgain() {
        for code: Int32 in [0, 3, 4, 9, 11] { XCTAssertEqual(WorkerLaunch.restart(exit: code, failures: 0, stopping: true), .never) }
        XCTAssertEqual(WorkerLaunch.restart(exit: 5, failures: 0, stopping: false), .never)
        XCTAssertEqual(WorkerLaunch.restart(exit: 2, failures: 0, stopping: false), .never)
    }

    func testAWorkerThatKeepsFailingIsGivenUp() {
        XCTAssertEqual([0, 1, 2, 3, 7].map { WorkerLaunch.restart(exit: 4, failures: $0, stopping: false) },
                       [.after(5), .after(30), .after(120), .gaveUp, .gaveUp])
        XCTAssertEqual(WorkerLaunch.restart(exit: 11, failures: 0, stopping: false), .after(5))
        XCTAssertEqual(WorkerLaunch.failures(after: 3, ranSeconds: 600), 0, "a worker that ran 10 minutes starts the count again")
        XCTAssertEqual(WorkerLaunch.failures(after: 1, ranSeconds: 30), 1)
    }
}
