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
}
