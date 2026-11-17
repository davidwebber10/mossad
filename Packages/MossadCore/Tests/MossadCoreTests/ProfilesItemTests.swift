import Security
import XCTest
@testable import MossadCore

/// The `profiles` item's format and the Mac's rule. No test reads or writes a real Keychain item.
final class ProfilesItemTests: XCTestCase {
    private let work = "1a2b3c4d"
    private let club = "5e6f7a8b"

    private func registry(clubToo: Bool = false) -> ProfileRegistry {
        var r = ProfileRegistry()
        r.profiles[0].server = "f00d"
        r.profiles[0].sync = "icloud"
        var w = Profile(id: work, name: "Work", color: .blue, root: "~/Mossad Work")
        w.server = "abc"
        w.sync = "server"
        r.profiles.append(w)
        if clubToo { r.profiles.append(Profile(id: club, name: "Club", color: .green, root: "~/Mossad Club")) }
        return r
    }

    private func loaded(_ r: ProfileRegistry, _ state: ProfileRegistry.State = .read) -> ProfileRegistry.Loaded {
        ProfileRegistry.Loaded(registry: r, state: state)
    }

    func testTheItemHoldsOnlyTheAllowedFields() throws {
        let item = ProfilesItem.make(from: registry())
        XCTAssertEqual(item.version, ProfilesItem.currentVersion)
        XCTAssertEqual(item.profiles.map(\.id), ["default", work])
        let data = try item.encoded()
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["root", "Mossad Work", #"server":"abc"#, "f00d", "removing", "active"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for entry in object["profiles"] as! [[String: Any]] {
            XCTAssertTrue(Set(entry.keys).isSubset(of: Set(ProfilesItem.fields)), "\(entry.keys)")
            XCTAssertEqual(Set(entry.keys), ["id", "name", "color", "sync"])
        }
        let noSync = try ProfilesItem.make(from: registry(clubToo: true)).encoded()
        let entries = (try JSONSerialization.jsonObject(with: noSync) as! [String: Any])["profiles"] as! [[String: Any]]
        XCTAssertEqual(Set(entries[2].keys), ["id", "name", "color"], "a profile with no sync word has no sync key")
        XCTAssertEqual(ProfilesItem.decode(data), item)
    }

    func testAProfileBeingRemovedIsNotInTheItem() {
        var r = registry()
        r.markRemoving(work)
        XCTAssertEqual(ProfilesItem.make(from: r).profiles.map(\.id), ["default"])
    }

    func testTheProfilesItemNeverNamesTheOtherAccounts() {
        let q = ProfilesItem.query()
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "profiles")
        XCTAssertEqual(ProfilesItem.account, "profiles")
        XCTAssertEqual(q[kSecAttrService as String] as? String, "com.dwebber.mossad.shared")
        XCTAssertEqual(q[kSecAttrAccessGroup as String] as? String, SharedAIKey.accessGroup)
        XCTAssertEqual(q[kSecAttrAccessGroup as String] as? String, "35VNBDXR6B.com.dwebber.mossad.shared")
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(SharedAIKey.account(profile: "default"), "ai")
        XCTAssertEqual(ServerPairing.account(profile: "default"), "server")
    }

    func testAMacWithOneProfileNeverWritesTheItem() {
        let anItem = ProfilesItem.make(from: registry())
        XCTAssertEqual(ProfilesItem.plan(.none, existing: .found(anItem)), .leave)
        XCTAssertEqual(ProfilesItem.plan(.none, existing: .none), .leave)
        XCTAssertEqual(ProfilesItem.plan(.none, existing: .unknown), .leave)
    }

    func testTheMacsRuleForTheItem() {
        let two = registry()
        var one = ProfileRegistry()
        one.profiles[0].sync = "icloud"
        let item = ProfilesItem.make(from: two)
        var other = item
        other.profiles[1].name = "Client"
        var newer = item
        newer.version = 2
        let rows: [(ProfileRegistry.Loaded, ProfilesItem.Read, ProfilesItem.Plan, String)] = [
            (loaded(two), .none, .write(item), "two, none"),
            (loaded(two), .found(item), .leave, "two, the same"),
            (loaded(two), .found(other), .write(item), "two, another"),
            (loaded(two), .found(newer), .leave, "two, newer"),
            (loaded(two), .unknown, .write(item), "two, unknown"),
            (loaded(one), .found(item), .delete, "one, found"),
            (loaded(one), .none, .leave, "one, none"),
            (loaded(one), .found(newer), .leave, "one, newer"),
            (loaded(two, .unreadable), .found(item), .leave, "unreadable"),
            (loaded(two, .partial), .none, .leave, "partial"),
            (loaded(two, .newer), .none, .leave, "newer registry"),
        ]
        for (registry, existing, plan, label) in rows {
            XCTAssertEqual(ProfilesItem.plan(registry, existing: existing), plan, label)
        }
    }

    func testANewerItemIsReadAsFarAsKnown() throws {
        let json = #"{"version":2,"future":true,"profiles":[{"id":"default","name":"Mossad","color":"orange","sync":"icloud","extra":1},{"id":"1a2b3c4d","name":"Work","color":"teal","sync":"relay"}]}"#
        let item = try XCTUnwrap(ProfilesItem.decode(Data(json.utf8)))
        XCTAssertEqual(item.version, 2)
        XCTAssertEqual(item.profiles.count, 2)
        XCTAssertEqual(item.profiles[1].color, .graphite)
        XCTAssertEqual(item.profiles[1].sync, "relay")
    }

    func testADamagedItemIsNotAnItem() throws {
        XCTAssertNil(ProfilesItem.decode(Data("junk".utf8)))
        XCTAssertNil(ProfilesItem.decode(Data(#"{"profiles":[]}"#.utf8)))
        let json = #"{"version":1,"profiles":[{"id":"1a2b3c4d","name":"Work","color":"blue"},{"id":"../x","name":"Bad","color":"blue"},{"id":"1a2b3c4d","name":"Again","color":"blue"},{"name":"No id","color":"blue"}]}"#
        let item = try XCTUnwrap(ProfilesItem.decode(Data(json.utf8)), "an item with no default entry still decodes")
        XCTAssertEqual(item.profiles.map(\.id), [work])
        XCTAssertEqual(item.profiles.map(\.name), ["Work"])
    }

    func testTheRegistryKeepsEachProfilesSyncAndAnOlderRegistryStillReads() throws {
        var r = registry()
        r.setSync("off", for: work)
        XCTAssertEqual(r.profile(work)?.sync, "off")
        r.setSync(nil, for: work)
        XCTAssertNil(r.profile(work)?.sync)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A registry of the build of before: no sync key.
        try Data(#"{"version":1,"active":"default","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},{"id":"1a2b3c4d","name":"Work","color":"blue","root":"/tmp/w"}]}"#.utf8).write(to: file)
        let old = ProfileRegistry.load(from: file)
        XCTAssertEqual(old.state, .read)
        XCTAssertNil(old.registry.profile(work)?.sync)
        var next = old
        next.registry.setSync("server", for: work)
        try next.save(to: file)
        XCTAssertEqual(ProfileRegistry.load(from: file).registry.profile(work)?.sync, "server")
        XCTAssertEqual(ProfileRegistry.load(from: file).registry.version, 1, "the version does not rise")
    }

    func testWithNoRegistryFileTheKeychainIsNeverRead() {
        var reads = 0
        XCTAssertEqual(ProfilesItem.decide(.none, read: { reads += 1; return .none }), .leave)
        XCTAssertEqual(reads, 0, "a Mac with one profile and no file never reads the item")
        for state in [ProfileRegistry.State.unreadable, .partial, .newer] {
            XCTAssertEqual(ProfilesItem.decide(loaded(registry(), state), read: { reads += 1; return .none }), .leave)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(ProfilesItem.decide(loaded(registry()), read: { reads += 1; return .none }), .write(ProfilesItem.make(from: registry())))
        XCTAssertEqual(reads, 1)
    }
}
