import XCTest
@testable import MossadCore

final class ProfileRulesTests: XCTestCase {
    private var two: ProfileRegistry {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work"))
        return r
    }
    private var read: ProfileRegistry.Loaded { .init(registry: two, state: .read) }
    private var newer: ProfileRegistry.Loaded { .init(registry: two, state: .newer) }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAFolderNameIsMadeUnique() {
        XCTAssertEqual(ProfileRules.folderName(for: "Work", taken: []), "Mossad Work")
        XCTAssertEqual(ProfileRules.folderName(for: "Work", taken: ["mossad work"]), "Mossad Work 2")
        XCTAssertEqual(ProfileRules.folderName(for: "work", taken: ["mossad work", "mossad work 2"]), "Mossad work 3")
        XCTAssertEqual(ProfileRules.folderName(for: "Rehearsal", taken: []), "Mossad Rehearsal 2")
        XCTAssertEqual(ProfileRules.folderName(for: "A/B: #1", taken: []), "Mossad AB 1")
        XCTAssertEqual(ProfileRules.folderName(for: "🙂", taken: []), "Mossad Profile")
        XCTAssertEqual(ProfileRules.folderName(for: String(repeating: "a", count: 60), taken: []), "Mossad " + String(repeating: "a", count: 40))
    }

    func testANewIDIs8HexCharactersAndNotTaken() {
        var answers = ["1a2b3c4d", "1a2b3c4d", "9f8e7d6c"]
        XCTAssertEqual(ProfileRules.newID(taken: ["1a2b3c4d"]) { answers.removeFirst() }, "9f8e7d6c")
        XCTAssertNotNil(ProfileRules.randomID().wholeMatch(of: /[0-9a-f]{8}/))
    }

    func testAddMakesAnEntryAndKeepsTheFolderOnARename() {
        var r = ProfileRegistry()
        let p = r.add(name: " Work ", color: .blue, takenFolders: []) { "1a2b3c4d" }
        XCTAssertEqual(p, Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work"))
        XCTAssertEqual(r.active, "default"); XCTAssertEqual(r.live.map(\.id), ["default", "1a2b3c4d"])
        r.rename("1a2b3c4d", name: "Client", color: .green)
        XCTAssertEqual(r.profile("1a2b3c4d")?.root, "~/Mossad Work"); XCTAssertEqual(r.profile("1a2b3c4d")?.name, "Client")
        XCTAssertEqual(r.profile("1a2b3c4d")?.color, .green)
        XCTAssertEqual(ProfileRules.nextColor(in: ProfileRegistry()), .blue)
        XCTAssertEqual(ProfileRules.nextColor(in: r), .blue)
    }

    func testASecondAddWithTheSameNameGetsAnotherFolder() {
        var r = two
        let p = r.add(name: "work", color: .green, takenFolders: []) { "9f8e7d6c" }
        XCTAssertEqual(p.root, "~/Mossad work 2")
    }

    func testANameMustBeThereAndNotTaken() {
        XCTAssertEqual(ProfileRules.nameProblem("", in: two), "Give the profile a name.")
        XCTAssertEqual(ProfileRules.nameProblem("  ", in: two), "Give the profile a name.")
        XCTAssertEqual(ProfileRules.nameProblem("work", in: two), "Another profile has this name.")
        XCTAssertEqual(ProfileRules.nameProblem("mossad", in: two), "Another profile has this name.")
        XCTAssertNil(ProfileRules.nameProblem("work", in: two, renaming: "1a2b3c4d"))
        XCTAssertNil(ProfileRules.nameProblem("Personal", in: two))
    }

    func testANewerOrUnreadableRegistryIsNeverSaved() throws {
        let dir = try tempFolder()
        for state in [ProfileRegistry.State.newer, .unreadable] {
            let file = dir.appendingPathComponent("\(state).json")
            XCTAssertThrowsError(try ProfileRegistry.Loaded(registry: two, state: state).save(to: file)) {
                XCTAssertTrue($0 is ProfileRegistry.ReadOnly)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        let file = dir.appendingPathComponent("Library/Application Support/Mossad/profiles.json")
        try ProfileRegistry.Loaded(registry: two, state: .none).save(to: file)
        XCTAssertEqual(ProfileRegistry.load(from: file), ProfileRegistry.Loaded(registry: two, state: .read))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "profiles", "active"])
        let profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        for p in profiles { XCTAssertEqual(Set(p.keys), ["id", "name", "color", "root"]) }
    }

    func testTheServerHashAndRemovingAreSavedWhenSet() throws {
        var r = two
        r.setServer(String(repeating: "0", count: 64), for: "1a2b3c4d")
        r.markRemoving("1a2b3c4d")
        let file = try tempFolder().appendingPathComponent("profiles.json")
        try ProfileRegistry.Loaded(registry: r, state: .read).save(to: file)
        let back = ProfileRegistry.load(from: file).registry
        XCTAssertEqual(back.removing.first?.server, String(repeating: "0", count: 64))
        XCTAssertEqual(back.removing.map(\.id), ["1a2b3c4d"])
        r.remove("1a2b3c4d")
        XCTAssertEqual(r.profiles.map(\.id), ["default"]); XCTAssertTrue(r.removing.isEmpty)
        r.remove("default")
        XCTAssertEqual(r.profiles.map(\.id), ["default"])
    }

    func testTheDeleteRule() {
        XCTAssertEqual(ProfileRules.deleteProblem("default", in: two, active: "1a2b3c4d", typed: "Mossad"), "The first profile cannot be deleted.")
        XCTAssertEqual(ProfileRules.deleteProblem("1a2b3c4d", in: two, active: "1a2b3c4d", typed: "Work"), "Switch to another profile first.")
        XCTAssertEqual(ProfileRules.deleteProblem("1a2b3c4d", in: two, active: "default", typed: "work"), "Type the profile's name to delete it.")
        XCTAssertNil(ProfileRules.deleteProblem("1a2b3c4d", in: two, active: "default", typed: " Work "))
    }

    func testARemovingProfileCannotStartAndDoesNotShow() {
        var r = two; r.markRemoving("1a2b3c4d")
        XCTAssertNil(r.profile("1a2b3c4d")); XCTAssertEqual(r.live.map(\.id), ["default"]); XCTAssertEqual(r.removing.map(\.id), ["1a2b3c4d"])
        XCTAssertEqual(ProfileLaunch.choice(arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: .init(registry: r, state: .read)),
                       .refused("Mossad: no profile with the id 1a2b3c4d; not starting."))
        XCTAssertNil(ProfileMenu(r, active: "default", recording: false))
    }

    func testASwitchIsRefusedWhileACallRecords() {
        XCTAssertEqual(ProfileSwitch.decide(to: "1a2b3c4d", registry: read, active: "default", recording: true, arguments: ["Mossad"]),
                       .refused("A call is recording. Switch when it ends."))
        XCTAssertEqual(ProfileSwitch.addRefusal, "A call is recording. Add a profile when it ends.")
    }

    func testASwitchDuringProcessingGoes() {
        // The decision does not ask about processing: a meeting in work keeps its state on disk.
        XCTAssertEqual(ProfileSwitch.decide(to: "1a2b3c4d", registry: read, active: "default", recording: false,
                                            arguments: ["Mossad", "--background", "--profile", "default", "-ownerName", "Sam Carter", "--open-window", "Settings"]),
                       .go(save: true, arguments: ["-ownerName", "Sam Carter", "--switched"]))
        XCTAssertEqual(ProfileSwitch.decide(to: "1a2b3c4d", registry: newer, active: "default", recording: false, arguments: ["Mossad"]),
                       .go(save: false, arguments: ["--switched", "--profile", "1a2b3c4d"]))
        XCTAssertEqual(ProfileSwitch.decide(to: "default", registry: read, active: "default", recording: false, arguments: ["Mossad"]), .stay)
        XCTAssertEqual(ProfileSwitch.decide(to: "ffffffff", registry: read, active: "default", recording: false, arguments: ["Mossad"]), .stay)
        XCTAssertEqual(ProfileSwitch.decide(to: "1a2b3c4d", registry: .init(registry: two, state: .unreadable), active: "default",
                                            recording: false, arguments: ["Mossad"]), .stay)
        XCTAssertEqual(ProfileSwitch.waitSeconds(["Mossad", "--switched"]), 10); XCTAssertEqual(ProfileSwitch.waitSeconds(["Mossad"]), 0)
    }

    func testAFailedStartPutsTheActiveProfileBack() {
        XCTAssertEqual(ProfileSwitch.afterStart(started: true, saved: true, was: "default"), .quit)
        XCTAssertEqual(ProfileSwitch.afterStart(started: false, saved: true, was: "default"), .restore(active: "default"))
        XCTAssertEqual(ProfileSwitch.afterStart(started: false, saved: false, was: "default"), .stay)
    }

    func testTheSwitcherShowsOnlyWithTwoProfiles() throws {
        XCTAssertNil(ProfileMenu(ProfileRegistry(), active: "default", recording: false))
        let m = try XCTUnwrap(ProfileMenu(two, active: "1a2b3c4d", recording: false))
        XCTAssertEqual(m.rows, [.init(id: "default", name: "Mossad", color: .orange, active: false), .init(id: "1a2b3c4d", name: "Work", color: .blue, active: true)])
        XCTAssertEqual(m.title, "Work"); XCTAssertEqual(m.color, .blue); XCTAssertNil(m.note)
        XCTAssertEqual(ProfileMenu(two, active: "default", recording: true)?.note, "A call is recording. Switch when it ends.")
        XCTAssertEqual(ProfileMenu.add, "Add profile…"); XCTAssertEqual(ProfileMenu.manage, "Manage profiles…")
    }

    func testAServerBelongsToOneProfile() {
        let a = URL(string: "https://notes.example.com")!
        var r = two; r.setServer(ProfileRules.serverHash(a), for: "default")
        XCTAssertEqual(ProfileRules.serverHash(a).count, 64)
        XCTAssertEqual(ProfileRules.serverHash(URL(string: "https://NOTES.example.com")!), ProfileRules.serverHash(a))
        XCTAssertEqual(ProfileRules.serverOwner(of: a, in: r, except: "1a2b3c4d")?.id, "default")
        XCTAssertNil(ProfileRules.serverOwner(of: a, in: r, except: "default"))
        XCTAssertNil(ProfileRules.serverOwner(of: URL(string: "https://other.example.com")!, in: r, except: "1a2b3c4d"))
        XCTAssertEqual(ProfileRules.serverRefusal(.default), "The profile “Mossad” already uses this server. Each profile needs its own server.")
    }

    // MARK: Task 7: the launch of a switch, and one foreground app

    func testTheNewInstanceWaitsForTheLocks() throws {
        let dir = try tempFolder()
        nonisolated(unsafe) var held: InstanceLock?
        if case .held(let lock) = InstanceLock.acquire(root: dir) { held = lock }
        XCTAssertNotNil(held)
        let gone = expectation(description: "let go")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { held = nil; gone.fulfill() }
        XCTAssertTrue(InstanceLock.waitUntilFree(root: dir, timeout: 2, every: 0.05))
        wait(for: [gone], timeout: 2)
        XCTAssertNil(held)
        guard case .held(let kept) = InstanceLock.acquire(root: dir) else { return XCTFail("no lock") }
        XCTAssertFalse(InstanceLock.waitUntilFree(root: dir, timeout: 0.3, every: 0.05))
        withExtendedLifetime(kept) {}
        let missing = dir.appendingPathComponent("not-there")
        XCTAssertTrue(InstanceLock.waitUntilFree(root: missing, timeout: 0.3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testOnlyOneForegroundAppForTheMac() {
        let main = AppIdentity.mainBundleID
        XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main)))
        XCTAssertTrue(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, registry: read)))
        XCTAssertTrue(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, registry: newer)))
        // A made-up registry has its own Mac-wide lock, beside its file, never the real one.
        XCTAssertTrue(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: read, madeUpRegistry: true)))
        XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, arguments: ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: read)))
        XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: AppIdentity.rehearsalBundleID, registry: read)))
        XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: read)))
    }

    func testTheMacWideLockOfAMadeUpRegistryIsBesideItsFile() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let real = AppIdentity(bundleID: AppIdentity.mainBundleID, registry: read)
        XCTAssertEqual(real.macWideLockFolder(home: home, environment: [:]).path, "/Users/someone/Library/Application Support/Mossad")
        let made = AppIdentity(bundleID: AppIdentity.mainBundleID, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: read, madeUpRegistry: true)
        XCTAssertEqual(made.macWideLockFolder(home: home, environment: ["MOSSAD_PROFILES": "/tmp/proof/profiles.json"]).path, "/tmp/proof")
        // A made-up flag with no file named never falls back to the real folder.
        XCTAssertEqual(made.macWideLockFolder(home: home, environment: [:]).path, FileManager.default.temporaryDirectory.path)
    }

    func testTheSwitcherShowsTheLineOfAnotherProfileOnly() throws {
        let menu = try XCTUnwrap(ProfileMenu(two, active: "default", recording: false, status: ["1a2b3c4d": "2 meetings in work", "default": "x"]))
        XCTAssertNil(menu.rows[0].status)
        XCTAssertEqual(menu.rows[1].status, "2 meetings in work")
        let plain = try XCTUnwrap(ProfileMenu(two, active: "default", recording: false))
        XCTAssertNil(plain.rows[0].status); XCTAssertNil(plain.rows[1].status)
    }
}
