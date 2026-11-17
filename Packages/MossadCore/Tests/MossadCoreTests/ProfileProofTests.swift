import XCTest
@testable import MossadCore

private let home = URL(fileURLWithPath: "/Users/someone")
private let main = AppIdentity.mainBundleID
private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")

private func registry(active: String = "1a2b3c4d") -> ProfileRegistry.Loaded {
    var r = ProfileRegistry()
    r.profiles.append(work)
    r.active = active
    return ProfileRegistry.Loaded(registry: r, state: .read)
}

private func id(_ a: [String] = [], _ env: [String: String] = [:], bundle: String? = main,
                registry r: ProfileRegistry.Loaded? = registry()) -> AppIdentity {
    AppIdentity(bundleID: bundle, arguments: ["Mossad"] + a, environment: env, registry: r)
}

final class ProfileProofTests: XCTestCase {
    private var temps: [URL] = []

    override func tearDown() {
        temps.forEach { try? FileManager.default.removeItem(at: $0) }
        temps = []
        super.tearDown()
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temps.append(url)
        return url
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private let twoProfiles = #"{"version":1,"active":"1a2b3c4d","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},{"id":"1a2b3c4d","name":"Work","color":"blue","root":"~/Mossad Work"}]}"#

    func testWithNoRegistryTheProcessIsDefaultAndAsToday() {
        let i = id(registry: nil)
        XCTAssertEqual(i.profile, .default); XCTAssertNil(i.profileRefusal)
        XCTAssertEqual(i.dataRoot(home: home, environment: [:]).path, "/Users/someone/Mossad")
        XCTAssertEqual(i.keychainService, "com.dwebber.mossad"); XCTAssertNil(i.defaultsSuite); XCTAssertNil(i.profileSettings())
        XCTAssertFalse(i.madeUpRegistry); XCTAssertEqual(i.registry, .none)
    }

    func testAProfileHasItsOwnFolderServiceAndSuite() {
        let i = id(["--profile", "1a2b3c4d"])
        XCTAssertEqual(i.dataRoot(home: home, environment: [:]).path, "/Users/someone/Mossad Work")
        XCTAssertEqual(i.keychainService, "com.dwebber.mossad.profile.1a2b3c4d")
        XCTAssertEqual(i.defaultsSuite, "com.dwebber.mossad.profile.1a2b3c4d"); XCTAssertFalse(i.emptiesSettings)
    }

    func testTheWindowAppIsTheActiveProfileAndACommandIsDefault() {
        XCTAssertEqual(id().profile.id, "1a2b3c4d")
        XCTAssertEqual(id(["-psn_0_12345"]).profile.id, "1a2b3c4d")
        for flag in AppIdentity.commands {
            XCTAssertEqual(id([flag]).profile.id, "default", flag)
            XCTAssertEqual(id([flag]).keychainService, "com.dwebber.mossad", flag)
            XCTAssertEqual(id([flag, "--profile", "1a2b3c4d"]).profile.id, "1a2b3c4d", flag)
        }
    }

    func testAnUnknownProfileDoesNotStart() {
        XCTAssertEqual(id(["--profile", "ffffffff"]).refusal(home: home, environment: [:]), "Mossad: no profile with the id ffffffff; not starting.")
        XCTAssertEqual(id(["--profile"]).refusal(home: home, environment: [:]), "Mossad: --profile needs a profile id; not starting.")
        XCTAssertNil(id(["--profile", "default"], registry: nil).refusal(home: home, environment: [:]))
    }

    func testRehearsalAPreviewAndMossadRootIgnoreTheRegistry() {
        let a = ["--profile", "1a2b3c4d"]
        let rehearsal = id(a, bundle: AppIdentity.rehearsalBundleID)
        let preview = id(a + ["--ui-preview"], ["MOSSAD_ROOT": "/tmp/demo"])
        let hand = id(a, ["MOSSAD_ROOT": "/tmp/demo"])
        for i in [rehearsal, preview, hand] { XCTAssertEqual(i.profile, .default); XCTAssertNil(i.profileRefusal) }
        XCTAssertEqual(rehearsal.keychainService, "com.dwebber.mossad.rehearsal")
        XCTAssertEqual(rehearsal.dataRoot(home: home, environment: [:]).path, "/Users/someone/Mossad Rehearsal")
        XCTAssertEqual(preview.keychainService, "com.dwebber.mossad.preview"); XCTAssertTrue(preview.emptiesSettings)
        XCTAssertEqual(preview.defaultsSuite, AppIdentity(bundleID: main, arguments: ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"]).defaultsSuite)
        XCTAssertEqual(hand.keychainService, "com.dwebber.mossad"); XCTAssertNil(hand.defaultsSuite)
        XCTAssertEqual(hand.dataRoot(home: home, environment: ["MOSSAD_ROOT": "/tmp/demo"]).path, "/tmp/demo")
    }

    func testOnlyTheRealMacAppReadsTheRegistryFile() throws {
        XCTAssertTrue(AppIdentity.readsRegistry(bundleID: main, arguments: ["Mossad"], environment: [:]))
        for b in [nil, "com.dwebber.mossad.phone", AppIdentity.rehearsalBundleID, "com.apple.dt.xctest.tool"] as [String?] {
            XCTAssertFalse(AppIdentity.readsRegistry(bundleID: b, arguments: ["Mossad"], environment: [:]))
        }
        XCTAssertFalse(AppIdentity.readsRegistry(bundleID: main, arguments: ["Mossad", "--ui-preview"], environment: [:]))
        XCTAssertFalse(AppIdentity.readsRegistry(bundleID: main, arguments: ["Mossad"], environment: ["MOSSAD_ROOT": "/tmp/demo"]))
        // A temp home with a registry whose active profile is Work:
        let tmp = try tempFolder()
        try write(twoProfiles, to: ProfileRegistry.fileURL(home: tmp))
        let real = AppIdentity.launch(bundleID: main, arguments: ["Mossad"], environment: [:], home: tmp)
        XCTAssertEqual(real.profile.id, "1a2b3c4d"); XCTAssertFalse(real.madeUpRegistry)
        XCTAssertEqual(AppIdentity.launch(bundleID: nil, arguments: ["Mossad"], environment: [:], home: tmp).profile.id, "default")
        // The same file given as MOSSAD_PROFILES, with an empty temp home:
        let empty = try tempFolder()
        let file = empty.appendingPathComponent("made-up.json")
        try write(twoProfiles, to: file)
        let made = AppIdentity.launch(bundleID: main, arguments: ["Mossad"], environment: ["MOSSAD_PROFILES": file.path], home: empty)
        XCTAssertTrue(made.madeUpRegistry); XCTAssertEqual(made.profile.id, "1a2b3c4d")
        let shown = AppIdentity.launch(bundleID: main, arguments: ["Mossad", "--ui-preview"], environment: ["MOSSAD_PROFILES": file.path, "MOSSAD_ROOT": "/tmp/demo"], home: empty)
        XCTAssertEqual(shown.profile, .default); XCTAssertEqual(shown.registry.registry.live.count, 2)
        XCTAssertFalse(shown.madeUpRegistry)
        // No registry file in the home folder: as today, and nothing is made there.
        let none = AppIdentity.launch(bundleID: main, arguments: ["Mossad"], environment: [:], home: empty)
        XCTAssertEqual(none.profile, .default); XCTAssertEqual(none.registry, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.appendingPathComponent("Library").path))
    }

    func testTheRegistryIsReadAndNeverChanged() throws {
        let dir = try tempFolder()
        let missing = ProfileRegistry.load(from: dir.appendingPathComponent("profiles.json"))
        XCTAssertEqual(missing.state, .none); XCTAssertEqual(missing.registry.live, [.default]); XCTAssertTrue(missing.canSave)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profiles.json").path))

        let garbage = dir.appendingPathComponent("garbage.json")
        try write("{ not json", to: garbage)
        let bad = ProfileRegistry.load(from: garbage)
        XCTAssertEqual(bad.state, .unreadable); XCTAssertEqual(bad.registry.live, [.default]); XCTAssertFalse(bad.canSave)
        XCTAssertEqual(try Data(contentsOf: garbage), Data("{ not json".utf8))

        let newerFile = dir.appendingPathComponent("newer.json")
        try write(#"{"version":2,"active":"default","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},{"id":"1a2b3c4d","name":"Work","color":"blue","root":"~/Mossad Work"}]}"#, to: newerFile)
        let newer = ProfileRegistry.load(from: newerFile)
        XCTAssertEqual(newer.state, .newer); XCTAssertFalse(newer.canSave); XCTAssertEqual(newer.registry.live.count, 2)

        let oddFile = dir.appendingPathComponent("odd.json")
        try write(#"{"version":1,"active":"ffffffff","profiles":[{"id":"WORK","name":"Bad","color":"blue","root":"~/Mossad Bad"},{"id":"1a2b3c4d","name":"Work","color":"teal","root":"~/Mossad Work"},{"id":"1a2b3c4d","name":"Twice","color":"blue","root":"~/Mossad Twice"},{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"}]}"#, to: oddFile)
        let odd = ProfileRegistry.load(from: oddFile)
        XCTAssertEqual(odd.state, .partial)
        XCTAssertEqual(odd.registry.live.map(\.id), ["default", "1a2b3c4d"])
        XCTAssertEqual(odd.registry.profile("1a2b3c4d")?.name, "Work")
        XCTAssertEqual(odd.registry.profile("1a2b3c4d")?.color, .graphite)
        XCTAssertEqual(odd.registry.activeProfile, .default)

        let noDefault = dir.appendingPathComponent("nodefault.json")
        try write(#"{"version":1,"active":"1a2b3c4d","profiles":[{"id":"1a2b3c4d","name":"Work","color":"blue","root":"~/Mossad Work"}]}"#, to: noDefault)
        let fixed = ProfileRegistry.load(from: noDefault)
        XCTAssertEqual(fixed.registry.live.map(\.id), ["default", "1a2b3c4d"]); XCTAssertEqual(fixed.registry.activeProfile.id, "1a2b3c4d")
        XCTAssertEqual(fixed.registry.profile("default"), .default)
    }

    func testARootIsReadAgainstTheHomeFolderAndTheFirstProfileIsAlwaysMossad() {
        XCTAssertEqual(work.rootURL(home: home).path, "/Users/someone/Mossad Work")
        XCTAssertEqual(Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "/tmp/made up/Mossad Work").rootURL(home: home).path, "/tmp/made up/Mossad Work")
        XCTAssertEqual(Profile(id: "default", name: "Renamed", color: .pink, root: "/elsewhere").rootURL(home: home).path, "/Users/someone/Mossad")
        XCTAssertTrue(Profile.default.isDefault); XCTAssertFalse(work.isDefault)
    }

    /// A profile id that no real profile can have (not 8 hex characters), so no real profile's settings are touched.
    private func testProfile() -> AppIdentity {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: "zzzzzzzz", name: "Test", color: .blue, root: "~/Mossad Test"))
        return AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "zzzzzzzz"], registry: .init(registry: r, state: .read))
    }

    func testAProfilesSettingsAreNeverEmptied() throws {
        let made = try MadeUpSuite(self)
        made.defaults.set("Sam Carter", forKey: "ownerName")
        var asked: String?
        let s = try XCTUnwrap(testProfile().profileSettings(makeSuite: { asked = $0; return made.defaults }))
        XCTAssertEqual(asked, "com.dwebber.mossad.profile.zzzzzzzz")
        XCTAssertEqual(s.persistentDomain(forName: made.name)?["ownerName"] as? String, "Sam Carter")
        XCTAssertEqual(s.string(forKey: "ownerName"), "Sam Carter")
    }

    func testAProfileSuiteNeverReadsTheStandardDomain() throws {
        let key = "profileProof.\(UUID().uuidString)"
        UserDefaults.standard.set("real", forKey: key); defer { UserDefaults.standard.removeObject(forKey: key) }
        let made = try MadeUpSuite(self)
        let s = try XCTUnwrap(testProfile().profileSettings(makeSuite: { _ in made.defaults }))
        XCTAssertNil(s.object(forKey: key))
        s.set("profile", forKey: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "real")
    }

    func testTheSwapHandsTheRealDomainOverOnTheMainThreadOnly() {
        let real = UserDefaults(suiteName: "com.dwebber.mossad.test-real")!, profile = UserDefaults(suiteName: "com.dwebber.mossad.test-profile")!
        let swap = DefaultsSwap(real: real, profile: profile)
        XCTAssertTrue(swap.current(handingOver: false, isMainThread: true) === profile)
        XCTAssertTrue(swap.current(handingOver: true, isMainThread: true) === real)
        XCTAssertTrue(swap.current(handingOver: true, isMainThread: false) === profile)
    }

    func testTheHandOverFlagIsSetOnlyDuringTheCall() {
        XCTAssertFalse(MacDefaults.handingOver)
        let seen = MacDefaults.handOver { MacDefaults.handingOver }
        XCTAssertTrue(seen); XCTAssertFalse(MacDefaults.handingOver)
    }

    func testTheMacWideKeysAreThisList() {
        XCTAssertEqual(MacDefaults.keys, ["offUntil", "didSetLoginItem", "screenCaptureAsked", "usageStatsEnabled", "usageStatsInstallID",
                                          "usageStatsLastAttempt", "usageStatsEndpoint", "usageStatsInDebug",
                                          "askShortcut", "askPanelOrigin", "notACall"])
        XCTAssertEqual(MacDefaults.prefixes, ["SU", "automationState."])
    }

    func testAMacWideKeyInAProfilesSettingsIsAStray() {
        XCTAssertEqual(MacDefaults.strays(in: ["ownerName": "x", "SUEnableAutomaticChecks": true, "didSetLoginItem": true,
                                                "automationState.com.google.Chrome": "granted", "syncWith": "icloud"]),
                       ["SUEnableAutomaticChecks", "automationState.com.google.Chrome", "didSetLoginItem"])
    }

    func testTheInstallIDIsTheMacsOwn() {
        // With nothing held, MacDefaults.store === UserDefaults.standard, so installID() reads what it reads today.
        XCTAssertTrue(MacDefaults.store === UserDefaults.standard)
    }

    func testAMadeUpRunNeverReadsAnotherProfilesFolder() {
        let made = AppIdentity(bundleID: main, arguments: ["Mossad"], registry: registry(), madeUpRegistry: true)
        XCTAssertEqual(made.profile.id, "1a2b3c4d")
        XCTAssertEqual(made.otherProfileRoots(home: home), [])
        let real = id()
        XCTAssertEqual(real.otherProfileRoots(home: home).map(\.path), ["/Users/someone/Mossad"])
        XCTAssertEqual(id(registry: nil).otherProfileRoots(home: home), [])
        XCTAssertEqual(id(["--profile", "1a2b3c4d"], ["MOSSAD_ROOT": "/tmp/demo"]).otherProfileRoots(home: home), [])
        XCTAssertEqual(id(["--profile", "default"]).otherProfileRoots(home: home).map(\.path), ["/Users/someone/Mossad Work"])
    }

    func testAMadeUpRegistryRunsInert() {
        XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: false, madeUpRegistry: false), .full)
        XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: false, madeUpRegistry: true), .inert)
        XCTAssertEqual(RunMode.decide(preview: true, rehearsal: false, secondCopy: false, madeUpRegistry: false), .inert)
        XCTAssertEqual(RunMode.decide(preview: false, rehearsal: true, secondCopy: false, madeUpRegistry: false), .inert)
        XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: true, madeUpRegistry: false), .inert)
    }
}
