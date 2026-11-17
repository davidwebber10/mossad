import XCTest
@testable import MossadCore

/// The fixes from the review of profiles, Tasks 1 to 3.
final class ProfileReviewFixTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private let main = AppIdentity.mainBundleID
    private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")

    private func loaded(_ profiles: [Profile], active: String = "default") -> ProfileRegistry.Loaded {
        var r = ProfileRegistry()
        r.profiles += profiles
        r.active = active
        return .init(registry: r, state: .read)
    }

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func registryFile(_ entries: [String], in dir: URL) throws -> URL {
        let file = dir.appendingPathComponent("profiles.json")
        let all = [#"{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"}"#] + entries
        try Data(#"{"version":1,"active":"default","profiles":[\#(all.joined(separator: ","))]}"#.utf8).write(to: file)
        return file
    }

    private func entry(_ id: String, _ root: String) -> String {
        #"{"id":"\#(id)","name":"P\#(id)","color":"blue","root":"\#(root)"}"#
    }

    // MARK: 3. A real registry accepts only a folder of its own under the home folder

    func testARealRegistryLeavesOutEachUnsafeRoot() throws {
        let dir = try temp()
        let linked = dir.appendingPathComponent("Mossad Link")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: dir.appendingPathComponent("elsewhere"))
        let refused = ["~/Mossad", "~/mossad rehearsal", "~/MOSSAD WORK", "~", "~/", "~/../x", "~/..", "~/.", "/tmp/x", "relative",
                       "", "~/a/b", "~/Mossad Link"]
        for root in refused {
            let file = try registryFile([entry("1a2b3c4d", "~/Mossad Work"), entry("9f8e7d6c", root)], in: dir)
            let read = ProfileRegistry.load(from: file, home: dir)
            XCTAssertEqual(read.registry.live.map(\.id), ["default", "1a2b3c4d"], root)
            XCTAssertFalse(read.canSave, root)
        }
        let file = try registryFile([entry("1a2b3c4d", "~/Mossad Work")], in: dir)
        XCTAssertEqual(ProfileRegistry.load(from: file, home: dir), .init(registry: {
            var r = ProfileRegistry(); r.profiles.append(Profile(id: "1a2b3c4d", name: "P1a2b3c4d", color: .blue, root: "~/Mossad Work")); return r
        }(), state: .read))
    }

    func testTheFirstProfilesRootIsAlwaysMossad() throws {
        let dir = try temp()
        let file = dir.appendingPathComponent("profiles.json")
        try Data(#"{"version":1,"active":"default","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"/elsewhere"}]}"#.utf8).write(to: file)
        let read = ProfileRegistry.load(from: file, home: dir)
        XCTAssertEqual(read.registry.profile("default")?.root, "~/Mossad")
        XCTAssertEqual(read.state, .read)
    }

    func testAMadeUpRegistryMayUseAnAbsoluteRoot() throws {
        let dir = try temp()
        let file = try registryFile([entry("1a2b3c4d", "/tmp/made up/Mossad Work")], in: dir)
        XCTAssertEqual(ProfileRegistry.load(from: file).registry.profile("1a2b3c4d")?.root, "/tmp/made up/Mossad Work")
    }

    func testTheRealFileIsReadWithTheStrictRule() throws {
        let tmp = try temp()
        try FileManager.default.createDirectory(at: ProfileRegistry.folder(home: tmp), withIntermediateDirectories: true)
        try Data(#"{"version":1,"active":"1a2b3c4d","profiles":[{"id":"1a2b3c4d","name":"Work","color":"blue","root":"/tmp/Mossad Work"}]}"#.utf8)
            .write(to: ProfileRegistry.fileURL(home: tmp))
        let identity = AppIdentity.launch(bundleID: main, arguments: ["Mossad"], environment: [:], home: tmp)
        XCTAssertEqual(identity.profile, .default)
        XCTAssertFalse(identity.registry.canSave)
    }

    // MARK: 4. On a made-up registry, `default` is the owner's real install: it never starts

    func testAMadeUpRegistryNeverStartsTheFirstProfile() {
        let refusal = "Mossad: a made-up registry needs --profile <id>; not starting."
        func made(_ args: [String], active: String) -> AppIdentity {
            AppIdentity(bundleID: main, arguments: ["Mossad"] + args, registry: loaded([work], active: active), madeUpRegistry: true)
        }
        XCTAssertEqual(made([], active: "default").profileRefusal, refusal)
        XCTAssertEqual(made(["--profile", "default"], active: "1a2b3c4d").profileRefusal, refusal)
        for flag in AppIdentity.commands {
            XCTAssertEqual(made([flag], active: "1a2b3c4d").refusal(home: home, environment: [:]), refusal, flag)
            XCTAssertNil(made([flag, "--profile", "1a2b3c4d"], active: "default").profileRefusal, flag)
        }
        XCTAssertNil(made([], active: "1a2b3c4d").profileRefusal)
        XCTAssertEqual(made([], active: "1a2b3c4d").profile.id, "1a2b3c4d")
    }

    // MARK: 6. A profile whose settings cannot be made does not start

    func testAProfileWhoseSettingsCannotBeMadeDoesNotStart() {
        let identity = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: loaded([work]))
        XCTAssertFalse(identity.isolateDefaults(makeSuite: { _ in nil }))
        XCTAssertTrue(AppIdentity(bundleID: main, arguments: ["Mossad"]).isolateDefaults(makeSuite: { _ in nil }))
    }

    // MARK: 7. A registry with an entry left out is never saved

    func testARegistryWithAnEntryLeftOutIsNeverSaved() throws {
        let dir = try temp()
        for entries in [[entry("WORK1234", "~/Mossad Work")], [entry("1a2b3c4d", "~/Mossad A"), entry("1a2b3c4d", "~/Mossad B")]] {
            let file = try registryFile(entries, in: dir)
            let read = ProfileRegistry.load(from: file)
            XCTAssertFalse(read.canSave)
            let before = try Data(contentsOf: file)
            XCTAssertThrowsError(try read.save(to: file)) { XCTAssertTrue($0 is ProfileRegistry.ReadOnly) }
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    // MARK: 8. A mistyped --profile is refused

    func testAMistypedProfileArgumentIsRefused() {
        for arg in ["--profile=1a2b3c4d", "--profiles", "--profile-id"] {
            let identity = AppIdentity(bundleID: main, arguments: ["Mossad", "--mcp", arg], registry: loaded([work]))
            XCTAssertEqual(identity.refusal(home: home, environment: [:]), "Mossad: \(arg) is not --profile <id>; not starting.")
            XCTAssertEqual(identity.profile, .default)
        }
        XCTAssertNil(AppIdentity(bundleID: main, arguments: ["Mossad", "--mcp", "--profile", "1a2b3c4d"], registry: loaded([work])).profileRefusal)
    }

    // MARK: 10. A folder name compares in lower case itself

    func testAFolderNameIgnoresTheCallersLetterCase() {
        XCTAssertEqual(ProfileRules.folderName(for: "Work", taken: ["Mossad Work"]), "Mossad Work 2")
        XCTAssertEqual(ProfileRules.folderName(for: "Work", taken: ["MOSSAD WORK", "Mossad Work 2"]), "Mossad Work 3")
    }

    // MARK: 11. The tests hold the production lines

    func testTheInstallIDIsReadFromTheHeldMacDomain() throws {
        let held = try MadeUpSuite(self).defaults
        MacDefaults.hold(held)
        defer { MacDefaults.release() }
        let id = UsageReportPlan.installID()
        XCTAssertEqual(held.string(forKey: UsageReportPlan.installIDKey), id.uuidString.lowercased())
        XCTAssertEqual(UsageReportPlan.resetInstallID().uuidString.lowercased(), held.string(forKey: UsageReportPlan.installIDKey))
    }

    /// `UserDefaults.standard` as a thread that is not the main one reads it.
    private static func readOnAnotherThread() -> UserDefaults {
        nonisolated(unsafe) var read: UserDefaults?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { read = UserDefaults.standard; done.signal() }
        thread.start()
        done.wait()
        return read!
    }

    func testAProfilesSwapHandsOverTheRealDomainOnTheMainThreadOnly() throws {
        // An id that no real profile can have, so no real profile's settings are touched.
        let fake = Profile(id: "zzzzzzzz", name: "Test", color: .blue, root: "~/Mossad Test")
        let identity = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "zzzzzzzz"], registry: loaded([fake]))
        let real = UserDefaults.standard
        let made = try MadeUpSuite(self)
        XCTAssertTrue(identity.isolateDefaults(makeSuite: { _ in made.defaults }))
        defer { AppIdentity.undoIsolation() }
        let suite = UserDefaults.standard
        XCTAssertFalse(suite === real)
        XCTAssertTrue(MacDefaults.store === real, "the real domain is held before the swap")
        // During a hand-over, the main thread gets the real domain and another thread still gets the profile's.
        let (onMain, onOther) = MacDefaults.handOver { (UserDefaults.standard, Self.readOnAnotherThread()) }
        XCTAssertTrue(onMain === real)
        XCTAssertTrue(onOther === suite)
        XCTAssertTrue(Self.readOnAnotherThread() === suite)
        AppIdentity.undoIsolation()
        XCTAssertTrue(UserDefaults.standard === real)
        XCTAssertTrue(MacDefaults.store === real)
    }
}

/// Fixes 1, 2, and 5: not recording across profiles.
final class NoRecordAcrossProfilesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let meet = "https://meet.google.com/abc-defg-hij"
    private let chrome = "com.google.Chrome"

    private func event(_ title: String, in minutes: Double, text: String) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 30) * 60),
                          attendees: [], text: text, isAllDay: false)
    }

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("no-record-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func blockingGate(in dir: URL) -> NoRecordGate {
        let e = event("Vendor", in: 0, text: meet)
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: UpcomingMeeting.from([e], now: now.addingTimeInterval(-86_400 * 2), days: 30)[0])
        let gate = NoRecordGate()
        gate.update(book: book)
        gate.update(events: [e])
        gate.persistSession(in: dir)
        return gate
    }

    func testAnAdoptedBlockNeverSavesTheOtherProfilesKey() throws {
        let dirA = temp(), dirB = temp()
        XCTAssertTrue(blockingGate(in: dirA).blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(1)))
        let b = NoRecordGate()
        b.persistSession(in: dirB)
        b.adopt(sessionsIn: [dirA])
        b.update(events: [])
        XCTAssertTrue(b.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(2)))
        b.seen(at: at(10))
        XCTAssertTrue(b.callEnded(at: at(12)))
        let saved = String(decoding: try Data(contentsOf: dirB.appendingPathComponent(NoRecordGate.sessionFileName)), as: UTF8.self).lowercased()
        XCTAssertFalse(saved.contains("vendor"), saved)
        XCTAssertFalse(saved.contains("meet.google.com"), saved)
    }

    func testASessionThatEndedInAnotherProfileDoesNotBlockAfterASwitchBack() {
        let dirA = temp(), dirB = temp()
        XCTAssertTrue(blockingGate(in: dirA).blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(1)))
        // The owner switched to B during the call; B saw it end.
        let b = NoRecordGate()
        b.persistSession(in: dirB)
        b.adopt(sessionsIn: [dirA])
        XCTAssertTrue(b.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(5)))
        XCTAssertTrue(b.callEnded(at: at(30)))
        // Back to A: its own file still says the call goes on.
        let a = NoRecordGate()
        a.persistSession(in: dirA)
        a.adopt(sessionsIn: [dirB])
        a.update(events: [])
        XCTAssertFalse(a.isBlockingCall)
        XCTAssertFalse(a.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(120)))
    }

    func testAnotherProfilesUnreadableListHasItsOwnWords() {
        let damaged = NoRecordBook.forGate(own: NoRecordBook(), others: [NoRecordBook.peek(from: unreadableFolder())])
        XCTAssertTrue(damaged.unreadable)
        let unreadable = NoRecordBook.peek(from: unreadableFolder())
        XCTAssertNil(NoRecordListProblem.find(own: NoRecordBook(), others: [("Work", NoRecordBook())]))
        XCTAssertEqual(NoRecordListProblem.find(own: unreadable, others: [("Work", unreadable)]), .own)
        let other = NoRecordListProblem.find(own: NoRecordBook(), others: [("Personal", NoRecordBook()), ("Work", unreadable)])
        XCTAssertEqual(other, .otherProfile("Work"))
        let sentence = "Mossad cannot read the do-not-record list of the profile Work. Switch to that profile and reset its list."
        XCTAssertEqual(other?.settingsFooter, sentence)
        XCTAssertEqual(other?.notificationBody, sentence + " Press Record to record this call.")
        XCTAssertFalse(other?.notificationBody.contains("Settings") ?? true)
        XCTAssertEqual(NoRecordListProblem.own.settingsFooter,
                       "The do-not-record list could not be read, so calls with an invite are not recorded. Reset the list, or set a choice for any upcoming meeting, to record them again.")
        XCTAssertEqual(NoRecordListProblem.own.notificationBody,
                       "The do-not-record list could not be read. Press Record to record this call. To end this, set a choice for any upcoming meeting, or reset the list in Settings, Recording.")
    }

    private func unreadableFolder() -> URL {
        let dir = temp()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("{".utf8).write(to: dir.appendingPathComponent(NoRecordBook.fileName))
        return dir
    }
}
