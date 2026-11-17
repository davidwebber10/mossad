import XCTest
@testable import MossadCore

/// The fixes from the final review of profiles, part 1.
final class ProfileFinalFixTests: XCTestCase {
    private let main = AppIdentity.mainBundleID
    private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")
    private let client = Profile(id: "9f8e7d6c", name: "Client", color: .green, root: "~/Mossad Client")

    private func registry(_ extra: [Profile], active: String = "default") -> ProfileRegistry {
        var r = ProfileRegistry()
        r.profiles += extra
        r.active = active
        return r
    }

    // MARK: 0. A hot key that could not be registered is tried again

    func testAHotKeyIsTriedAgainThenLogged() {
        XCTAssertEqual(HotKeyRetry.delay(afterFailure: 1), 2)
        XCTAssertEqual(HotKeyRetry.delay(afterFailure: 2), 5)
        XCTAssertEqual(HotKeyRetry.delay(afterFailure: 3), 15)
        XCTAssertNil(HotKeyRetry.delay(afterFailure: 4))
        XCTAssertNil(HotKeyRetry.delay(afterFailure: 0))
    }

    // MARK: 1. The gate reads the lists of the live profiles other than the active one

    func testTheGateReadsTheOtherLiveProfilesOnly() {
        let identity = AppIdentity(bundleID: main, registry: .init(registry: registry([work, client]), state: .read))
        XCTAssertEqual(identity.otherProfiles(in: registry([work, client])).map(\.id), ["1a2b3c4d", "9f8e7d6c"])
        var removing = registry([work, client])
        removing.markRemoving("9f8e7d6c")
        XCTAssertEqual(identity.otherProfiles(in: removing).map(\.id), ["1a2b3c4d"])
        // A profile added after the launch is read too.
        let one = AppIdentity(bundleID: main, registry: .none)
        XCTAssertEqual(one.otherProfiles(in: registry([work])).map(\.id), ["1a2b3c4d"])
        // Never on a made-up registry, never in a copy with no profiles.
        let made = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: .init(registry: registry([work]), state: .read), madeUpRegistry: true)
        XCTAssertEqual(made.otherProfiles(in: registry([work, client])), [])
        let hand = AppIdentity(bundleID: main, environment: ["MOSSAD_ROOT": "/tmp/demo"])
        XCTAssertEqual(hand.otherProfiles(in: registry([work])), [])
        // Never the copy's own profile.
        let asWork = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: .init(registry: registry([work]), state: .read))
        XCTAssertEqual(asWork.otherProfiles(in: registry([work, client])).map(\.id), ["default", "9f8e7d6c"])
    }

    // MARK: 2. No second change during a switch; the file's active profile is never deleted

    func testNothingChangesDuringASwitch() {
        XCTAssertTrue(ProfileSwitch.mayChange(inert: false, mayChangeRegistry: true, switching: false))
        XCTAssertFalse(ProfileSwitch.mayChange(inert: false, mayChangeRegistry: true, switching: true))
        XCTAssertFalse(ProfileSwitch.mayChange(inert: true, mayChangeRegistry: true, switching: false))
        XCTAssertFalse(ProfileSwitch.mayChange(inert: false, mayChangeRegistry: false, switching: false))
    }

    func testTheFilesActiveProfileIsNeverDeleted() {
        let r = registry([work, client], active: "1a2b3c4d")
        XCTAssertEqual(ProfileRules.deleteProblem("1a2b3c4d", in: r, active: "default", typed: "Work"), "Switch to another profile first.")
        XCTAssertNil(ProfileRules.deleteProblem("9f8e7d6c", in: r, active: "default", typed: "Client"))
    }

    // MARK: 3. The Mac-wide lock is decided by the file of now, and tried again

    func testTheLockFollowsTheFileOfNow() {
        let one = AppIdentity(bundleID: main, registry: .none)
        XCTAssertFalse(ProfileLaunch.takesForegroundLock(one))
        XCTAssertTrue(ProfileLaunch.takesForegroundLock(one, now: .read))
        XCTAssertTrue(ProfileLaunch.takesForegroundLock(one, now: .partial))
        XCTAssertFalse(ProfileLaunch.takesForegroundLock(one, now: .none))
        XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, environment: ["MOSSAD_ROOT": "/tmp/demo"]), now: .read))
        XCTAssertEqual(ProfileSwitch.lockRetries, [0.2, 0.5, 1, 2, 4])
    }

    // MARK: 4. A problem shows where the owner acted, and goes when its cause is gone

    func testAProblemGoesWhenItsCauseIsGone() {
        XCTAssertTrue(ProfileSwitch.problemStays(ProfileSwitch.refusal, recording: true, age: 5))
        XCTAssertFalse(ProfileSwitch.problemStays(ProfileSwitch.refusal, recording: false, age: 5))
        XCTAssertFalse(ProfileSwitch.problemStays(ProfileSwitch.addRefusal, recording: false, age: 5))
        XCTAssertTrue(ProfileSwitch.problemStays("Could not switch. Mossad stays in Work.", recording: false, age: 10))
        XCTAssertFalse(ProfileSwitch.problemStays("Could not switch. Mossad stays in Work.", recording: false, age: 31))
        XCTAssertFalse(ProfileSwitch.problemStays(ProfileSwitch.refusal, recording: true, age: 31))
    }

    // MARK: 5. A name of 30 characters at most

    func testANameHasALimit() {
        let r = registry([work])
        XCTAssertEqual(ProfileRules.nameLimit, 30)
        XCTAssertNil(ProfileRules.nameProblem(String(repeating: "a", count: 30), in: r))
        XCTAssertEqual(ProfileRules.nameProblem(String(repeating: "a", count: 31), in: r), "Use a name of 30 characters or fewer.")
        XCTAssertNil(ProfileRules.nameProblem(String(repeating: "🙂", count: 30), in: r))
        XCTAssertEqual(ProfileRules.nameProblem(String(repeating: "🙂", count: 31), in: r), "Use a name of 30 characters or fewer.")
        // The folder keeps its own limit of 40.
        XCTAssertEqual(ProfileRules.folderName(for: String(repeating: "a", count: 60), taken: []), "Mossad " + String(repeating: "a", count: 40))
    }

    // MARK: 6. Why a change of the list is off

    func testTheWordsWhenTheListCannotBeChanged() {
        XCTAssertNil(ProfileSettingsWords.changeRefusal(.none))
        XCTAssertNil(ProfileSettingsWords.changeRefusal(.init(registry: registry([work]), state: .read)))
        XCTAssertEqual(ProfileSettingsWords.changeRefusal(.init(registry: registry([work]), state: .newer)),
                       "This Mac has a profile list from a newer Mossad. Update Mossad to change profiles.")
        XCTAssertEqual(ProfileSettingsWords.changeRefusal(.init(registry: registry([]), state: .partial, leftOut: ["Work"])),
                       "Mossad left out a profile whose folder it cannot use: Work. It did not change the file.")
        XCTAssertEqual(ProfileSettingsWords.changeRefusal(.init(registry: ProfileRegistry(), state: .unreadable)),
                       "The list of profiles could not be read. Mossad runs as the first profile.")
    }

    // MARK: 7. An MCP server whose profile was deleted stops

    func testAServersProfileMustStillBeThere() {
        let live = ProfileRegistry.Loaded(registry: registry([work]), state: .read)
        XCTAssertTrue(ProfileLaunch.stillServes("1a2b3c4d", registry: live))
        XCTAssertTrue(ProfileLaunch.stillServes("default", registry: .none))
        var removing = registry([work])
        removing.markRemoving("1a2b3c4d")
        XCTAssertFalse(ProfileLaunch.stillServes("1a2b3c4d", registry: .init(registry: removing, state: .read)))
        XCTAssertFalse(ProfileLaunch.stillServes("1a2b3c4d", registry: .none))
        // A file that cannot be read now: unknown is not gone.
        XCTAssertTrue(ProfileLaunch.stillServes("1a2b3c4d", registry: .init(registry: ProfileRegistry(), state: .unreadable)))
    }

    func testAToolCallOfARemovedProfileWritesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("removed-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let server = MCPServer(paths: Paths(root: root), owner: "Sam Carter", stillServes: { false })
        let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"add_next_time_point","arguments":{"text":"Ask about the budget","for":"Sam Carter"}}}"#
        let (reply, ends) = server.respond(call)
        XCTAssertTrue(ends)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(reply).utf8)) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(text, MCPServer.profileRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // initialize still answers, and does not end the server.
        let (hello, helloEnds) = server.respond(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        XCTAssertNotNil(hello); XCTAssertFalse(helloEnds)
    }

    // MARK: 8. The delete never runs on a bad id

    func testADeleteNeverRunsOnABadID() async {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func add() { lock.withLock { n += 1 } }
            var count: Int { lock.withLock { n } }
        }
        for bad in ["", "Default", "1a2b3c4", "../x", "1A2B3C4D", "1a2b3c4d/"] {
            let calls = Calls()
            let actions = ProfileRemoval.Actions(sharedItems: { _ in calls.add() }, keys: { _ in calls.add() }, settings: { _ in calls.add() },
                                                 trash: { _ in calls.add() }, zone: { _ in calls.add() })
            let profile = Profile(id: bad, name: "Odd", color: .blue, root: "~/Mossad Odd")
            let outcome = await ProfileRemoval.run(profile, home: URL(fileURLWithPath: "/Users/someone"), others: [], done: [], actions: actions)
            XCTAssertEqual(calls.count, 0, bad)
            XCTAssertFalse(outcome.complete, bad)
        }
    }
}
