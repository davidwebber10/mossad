import XCTest
@testable import MossadCore

/// The delete of a profile. Every action here is made up: no real zone, Keychain item, setting, or folder is touched.
final class ProfileRemovalTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")

    private var two: ProfileRegistry {
        var r = ProfileRegistry()
        r.profiles.append(work)
        return r
    }

    /// Made-up actions that write what they were asked to a list.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    struct Failure: Error {}

    private func actions(_ log: Log, trashFails: Bool = false, zoneFails: Bool = false) -> ProfileRemoval.Actions {
        ProfileRemoval.Actions(
            sharedItems: { log.add("sharedItems \($0)") },
            keys: { log.add("keys \($0)") },
            settings: { log.add("settings \($0)") },
            trash: { url in log.add("trash \(url.path)"); if trashFails { throw Failure() } },
            zone: { name in log.add("zone \(name)"); if zoneFails { throw Failure() } })
    }

    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheNamesOfWhatADeleteRemoves() {
        XCTAssertEqual(ProfileRemoval.names(of: work, home: home),
                       .init(id: "1a2b3c4d", service: "com.dwebber.mossad.profile.1a2b3c4d", suite: "com.dwebber.mossad.profile.1a2b3c4d",
                             zone: "Mossad-1a2b3c4d", root: URL(fileURLWithPath: "/Users/someone/Mossad Work")))
    }

    func testTheStepsRunInThisOrder() async throws {
        let h = try tempHome()
        try FileManager.default.createDirectory(at: h.appendingPathComponent("Mossad Work"), withIntermediateDirectories: true)
        let log = Log()
        let outcome = await ProfileRemoval.run(work, home: h, others: [.default], done: [], actions: actions(log))
        XCTAssertEqual(log.all, ["sharedItems 1a2b3c4d", "keys com.dwebber.mossad.profile.1a2b3c4d", "settings com.dwebber.mossad.profile.1a2b3c4d",
                                 "trash \(h.appendingPathComponent("Mossad Work").path)", "zone Mossad-1a2b3c4d"])
        XCTAssertTrue(outcome.complete)
        XCTAssertEqual(outcome.done, ProfileRemoval.Step.allCases)
    }

    func testAFailedStepStopsTheRunAndTheRestWaits() async throws {
        let h = try tempHome()
        try FileManager.default.createDirectory(at: h.appendingPathComponent("Mossad Work"), withIntermediateDirectories: true)
        let first = Log()
        let a = await ProfileRemoval.run(work, home: h, others: [], done: [], actions: actions(first, trashFails: true))
        XCTAssertEqual(a.done, [.sharedItems, .keys, .settings]); XCTAssertEqual(a.failed, .folder); XCTAssertFalse(a.complete)
        XCTAssertFalse(first.all.contains { $0.hasPrefix("zone") })
        let second = Log()
        let b = await ProfileRemoval.run(work, home: h, others: [], done: Set(a.done), actions: actions(second, zoneFails: true))
        XCTAssertEqual(b.done, [.sharedItems, .keys, .settings, .folder]); XCTAssertEqual(b.failed, .zone); XCTAssertFalse(b.complete)
        XCTAssertEqual(second.all.count, 2, "only the folder and the zone: what was done is not done again")
        let third = Log()
        let c = await ProfileRemoval.run(work, home: h, others: [], done: Set(b.done), actions: actions(third))
        XCTAssertTrue(c.complete)
        XCTAssertEqual(third.all, ["zone Mossad-1a2b3c4d"])
    }

    func testAStopAfterEachStepResumesAtTheNextStepOnly() async throws {
        let h = try tempHome()
        try FileManager.default.createDirectory(at: h.appendingPathComponent("Mossad Work"), withIntermediateDirectories: true)
        let steps = ProfileRemoval.Step.allCases
        for k in 0...steps.count {
            let log = Log()
            let outcome = await ProfileRemoval.run(work, home: h, others: [], done: Set(steps.prefix(k)), actions: actions(log))
            XCTAssertTrue(outcome.complete)
            XCTAssertEqual(log.all.count, steps.count - k, "after \(k) steps")
        }
    }

    func testEachStepIsRecordedAsItEnds() async throws {
        let h = try tempHome()
        let recorded = Log()
        _ = await ProfileRemoval.run(work, home: h, others: [], done: [], actions: actions(Log()), record: { recorded.add($0.rawValue) })
        XCTAssertEqual(recorded.all, ProfileRemoval.Step.allCases.map(\.rawValue))
    }

    func testTheFirstProfileAndTheActiveOneAreNeverRemoved() async {
        XCTAssertFalse(ProfileRemoval.mayRun(.default, active: "1a2b3c4d"))
        XCTAssertFalse(ProfileRemoval.mayRun(work, active: "1a2b3c4d"))
        XCTAssertTrue(ProfileRemoval.mayRun(work, active: "default"))
        var renamed = Profile.default; renamed.name = "Work"
        for profile in [Profile.default, renamed] {
            let log = Log()
            let outcome = await ProfileRemoval.run(profile, home: home, others: [], done: [], actions: actions(log))
            XCTAssertTrue(log.all.isEmpty); XCTAssertFalse(outcome.complete)
        }
        let log = Log()
        let outcome = await ProfileRemoval.run(work, home: home, others: [], done: [], active: "1a2b3c4d", actions: actions(log))
        XCTAssertTrue(log.all.isEmpty); XCTAssertFalse(outcome.complete)
        XCTAssertEqual(ProfileRules.deleteProblem("default", in: two, active: "1a2b3c4d", typed: "Mossad"), "The first profile cannot be deleted.")
        XCTAssertEqual(ProfileRules.deleteProblem("1a2b3c4d", in: two, active: "1a2b3c4d", typed: "Work"), "Switch to another profile first.")
    }

    func testOnlyAProfilesOwnNamesAreRemoved() async {
        // A hand-edited entry whose id would name the first profile's things is never run.
        let odd = Profile(id: "default", name: "Odd", color: .blue, root: "~/Mossad Odd")
        XCTAssertFalse(ProfileRemoval.namesAreSafe(ProfileRemoval.names(of: odd, home: home)))
        XCTAssertTrue(ProfileRemoval.namesAreSafe(ProfileRemoval.names(of: work, home: home)))
        let unsafe = ProfileRemoval.Names(id: "1a2b3c4d", service: "com.dwebber.mossad", suite: "com.dwebber.mossad.profile.1a2b3c4d",
                                          zone: "Mossad-1a2b3c4d", root: home.appendingPathComponent("Mossad Work"))
        XCTAssertFalse(ProfileRemoval.namesAreSafe(unsafe))
        XCTAssertFalse(ProfileRemoval.namesAreSafe(.init(id: "1a2b3c4d", service: "com.dwebber.mossad.profile.1a2b3c4d",
                                                        suite: "com.dwebber.mossad.profile.1a2b3c4d", zone: "Mossad",
                                                        root: home.appendingPathComponent("Mossad Work"))))
    }

    func testTheZoneMossadIsNeverDeleted() async {
        XCTAssertFalse(CloudKitStore.mayDelete(zone: "Mossad"))
        do { try await CloudKitStore.deleteZone(named: "Mossad"); XCTFail("refused") } catch {}
    }

    func testADeleteNeverTrashesTheFirstProfilesFolderOrAnothers() async throws {
        let h = home
        XCTAssertTrue(ProfileRemoval.mayTrash(h.appendingPathComponent("Mossad Work"), home: h, others: [h.appendingPathComponent("Mossad")]))
        for bad in ["Mossad", "Mossad Rehearsal", "mossad rehearsal", "Documents", "Mossad Work/Audio", "../other/Mossad Work", "MossadWork", "Mossad "] {
            XCTAssertFalse(ProfileRemoval.mayTrash(h.appendingPathComponent(bad), home: h, others: []), bad)
        }
        XCTAssertFalse(ProfileRemoval.mayTrash(URL(fileURLWithPath: "/tmp/Mossad Work"), home: h, others: []))
        XCTAssertFalse(ProfileRemoval.mayTrash(h.appendingPathComponent("Mossad Work"), home: h, others: [h.appendingPathComponent("Mossad Work")]))
        XCTAssertFalse(ProfileRemoval.mayTrash(h.appendingPathComponent("Mossad Work"), home: h, others: [h.appendingPathComponent("mossad work")]))
        // A symbolic link is never followed into the Trash.
        let real = try tempHome()
        let target = real.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = real.appendingPathComponent("Mossad Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(ProfileRemoval.mayTrash(link, home: real, others: []))
        // With mayTrash false, run does not call trash, and the folder step counts as done.
        let linked = Profile(id: "1a2b3c4d", name: "Link", color: .blue, root: "~/Mossad Link")
        let log = Log()
        let outcome = await ProfileRemoval.run(linked, home: real, others: [], done: [], actions: actions(log))
        XCTAssertFalse(log.all.contains { $0.hasPrefix("trash") })
        XCTAssertTrue(outcome.complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        // Another profile's folder is never trashed.
        let shared = Log()
        let sharing = Profile(id: "9f8e7d6c", name: "Other", color: .blue, root: "~/Mossad Work")
        _ = await ProfileRemoval.run(work, home: h, others: [sharing], done: [], actions: actions(shared))
        XCTAssertFalse(shared.all.contains { $0.hasPrefix("trash") })
    }

    func testAMissingFolderCountsAsDone() async throws {
        let log = Log()
        let outcome = await ProfileRemoval.run(work, home: try tempHome(), others: [], done: [], actions: actions(log))
        XCTAssertFalse(log.all.contains { $0.hasPrefix("trash") })
        XCTAssertTrue(outcome.complete)
    }

    func testALockedFolderRefusesTheDelete() throws {
        let h = try tempHome()
        let folder = h.appendingPathComponent("Mossad Work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard case .held(let lock) = InstanceLock.acquire(root: folder) else { return XCTFail("no lock") }
        XCTAssertEqual(ProfileRemoval.start("1a2b3c4d", in: two, active: "default", typed: "Work", home: h),
                       .refused("Mossad has this profile open. Quit that copy first."))
        withExtendedLifetime(lock) {}
    }

    func testAStartChecksTheRuleFirst() throws {
        let h = try tempHome()
        XCTAssertEqual(ProfileRemoval.start("default", in: two, active: "1a2b3c4d", typed: "Mossad", home: h), .refused("The first profile cannot be deleted."))
        XCTAssertEqual(ProfileRemoval.start("1a2b3c4d", in: two, active: "1a2b3c4d", typed: "Work", home: h), .refused("Switch to another profile first."))
        XCTAssertEqual(ProfileRemoval.start("1a2b3c4d", in: two, active: "default", typed: "work", home: h), .refused("Type the profile's name to delete it."))
        guard case .go = ProfileRemoval.start("1a2b3c4d", in: two, active: "default", typed: "Work", home: h) else { return XCTFail("may start") }
    }

    func testTheProgressOfADeleteIsSavedWithTheEntry() throws {
        var r = two
        r.markRemoving("1a2b3c4d")
        r.noteRemoved(.keys, for: "1a2b3c4d")
        r.noteRemoved(.sharedItems, for: "1a2b3c4d")
        r.noteRemoved(.keys, for: "1a2b3c4d")
        XCTAssertEqual(r.removedSteps(of: "1a2b3c4d"), [.sharedItems, .keys])
        let file = try tempHome().appendingPathComponent("profiles.json")
        try ProfileRegistry.Loaded(registry: r, state: .read).save(to: file)
        XCTAssertEqual(ProfileRegistry.load(from: file).registry.removedSteps(of: "1a2b3c4d"), [.sharedItems, .keys])
    }

    func testTheSheetSentences() {
        XCTAssertEqual(ProfileRemoval.serverNote, "This profile used a server. Mossad does not remove it: it is yours to remove.")
        XCTAssertEqual(ProfileRemoval.bucketNote, "Recordings that this profile backed up to a bucket stay in the bucket.")
    }
}
