import Security
import XCTest
@testable import MossadCore

/// The fixes of the review of profiles part 3, Tasks 1 to 4.
final class ProfilesPartThreeReviewTests: XCTestCase {
    private let work = "1a2b3c4d"
    private let club = "5e6f7a8b"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let c = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "made-up-secret")

    private func entry(_ id: String, _ name: String, _ color: ProfileColor = .blue, _ sync: String? = "icloud") -> ProfilesItem.Entry {
        ProfilesItem.Entry(id: id, name: name, color: color, sync: sync)
    }

    private var homeAndWork: ProfilesItem.Read {
        .found(ProfilesItem(profiles: [entry("default", "Home", .green), entry(work, "Work", .blue, "server")]))
    }

    private func code(_ id: String, _ name: String, sync: SyncChoice = .icloud) -> ProfileCode {
        ProfileCode.make(profile: Profile(id: id, name: name, color: .pink, root: "~/x"), sync: sync, server: sync == .server ? c : nil)!
    }

    private func codeText(_ json: String) -> String { "mossad-profile:" + Data(json.utf8).base64URL }

    // P1
    func testACodeBringsBackAProfileThatLeftAndItStays() {
        var book = PhoneProfileBook()
        book.take(homeAndWork, now: t0)
        book.take(.none, now: t0 + 60)
        XCTAssertFalse(book.listed.contains { $0.id == work })
        book.add(code(work, "Work"), now: t0 + 120)
        book.take(.none, now: t0 + 180)
        XCTAssertTrue(book.listed.contains { $0.id == work }, "the code keeps it on this iPhone")
        XCTAssertEqual(book.profiles.first { $0.id == work }?.source, .code)
    }

    // P3
    func testANameThatFitsTwoProfilesIsNobody() {
        var book = PhoneProfileBook()
        book.take(.found(ProfilesItem(profiles: [entry("default", "Mossad"), entry(work, "Resume"), entry(club, "resume")])), now: t0)
        XCTAssertNil(book.profile(named: "Resume"), "two that fit is nobody")
        XCTAssertEqual(book.profiles(named: "RESUME").map(\.id), [work, club])
        XCTAssertEqual(PhoneProfileWords.manyNamed("Resume", choices: book.profiles(named: "Resume").map(\.name)),
                       "More than one profile on this iPhone is named “Resume”: Resume, resume. Rename one on your Mac.")
        var accents = PhoneProfileBook()
        accents.take(.found(ProfilesItem(profiles: [entry("default", "Mossad"), entry(work, "Résumé"), entry(club, "Resume")])), now: t0)
        XCTAssertEqual(accents.profile(named: "resume")?.id, club, "accents are not ignored")
        XCTAssertEqual(accents.profile(named: "RÉSUMÉ")?.id, work)
    }

    // P4
    func testTheMacDeletesOnlyItsOwnItem() {
        var one = ProfileRegistry()
        one.writer = "aaaaaaaaaaaaaaaa"
        let loaded = ProfileRegistry.Loaded(registry: one, state: .read)
        var own = ProfilesItem(profiles: [entry("default", "Mossad"), entry(work, "Work")])
        own.writer = "aaaaaaaaaaaaaaaa"
        var others = own
        others.writer = "bbbbbbbbbbbbbbbb"
        var nobody = own
        nobody.writer = nil
        XCTAssertEqual(ProfilesItem.plan(loaded, existing: .found(own)), .delete)
        XCTAssertEqual(ProfilesItem.plan(loaded, existing: .found(others)), .leave, "another Mac's list stays")
        XCTAssertEqual(ProfilesItem.plan(loaded, existing: .found(nobody)), .leave, "a list with no writer stays")
        var none = one
        none.writer = nil
        XCTAssertEqual(ProfilesItem.plan(ProfileRegistry.Loaded(registry: none, state: .read), existing: .found(nobody)), .leave)
    }

    func testTheMacsListCarriesItsWriterMadeOnce() throws {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: work, name: "Work", color: .blue, root: "~/Mossad Work"))
        XCTAssertTrue(r.ensureWriter(random: { "0123456789abcdef" }))
        XCTAssertEqual(r.writer, "0123456789abcdef")
        XCTAssertFalse(r.ensureWriter(random: { "ffffffffffffffff" }), "made once")
        XCTAssertEqual(r.writer, "0123456789abcdef")
        let item = ProfilesItem.make(from: r)
        XCTAssertEqual(item.writer, "0123456789abcdef")
        XCTAssertEqual(ProfilesItem.plan(ProfileRegistry.Loaded(registry: r, state: .read), existing: .none), .write(item))
        XCTAssertEqual(ProfileRegistry.newWriter().count, 16)
        XCTAssertTrue(ProfileRegistry.newWriter().allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(ProfileRegistry.newWriter(), ProfileRegistry.newWriter())
        // Additive in the file: a registry with a writer reads, and one without still reads.
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(ProfileRegistry.self, from: data).writer, "0123456789abcdef")
        XCTAssertTrue(String(decoding: try ProfilesItem.make(from: r).encoded(), as: UTF8.self).contains(#""writer":"0123456789abcdef""#))
    }

    // P2
    func testTwoRequestsInARowNeverLeaveTheOlderState() async throws {
        final class World: @unchecked Sendable {
            let lock = NSLock()
            var current: ProfileRegistry.Loaded
            var item: ProfilesItem.Read = .none
            var writes: [String?] = []
            init(_ loaded: ProfileRegistry.Loaded) { current = loaded }
        }
        var r = ProfileRegistry()
        r.writer = "aaaaaaaaaaaaaaaa"
        var w = Profile(id: work, name: "Work", color: .blue, root: "~/Mossad Work")
        w.sync = "icloud"
        r.profiles.append(w)
        let world = World(ProfileRegistry.Loaded(registry: r, state: .read))
        let writer = ProfilesItemWriter(read: { world.lock.withLock { world.item } }, apply: { plan in
            world.lock.withLock {
                if case .write(let item) = plan {
                    world.item = .found(item)
                    world.writes.append(item.profiles.last?.sync)
                }
            }
        })
        let first = Task { await writer.request { world.lock.withLock { world.current } } }
        world.lock.withLock { world.current.registry.setSync("server", for: self.work) }
        let second = Task { await writer.request { world.lock.withLock { world.current } } }
        await first.value
        await second.value
        let (writes, item) = world.lock.withLock { (world.writes, world.item) }
        XCTAssertEqual(writes.last, "server", "the last write is the newest state")
        XCTAssertFalse(writes.dropFirst(writes.firstIndex(of: "server") ?? writes.count).contains("icloud"))
        if case .found(let found) = item { XCTAssertEqual(found.profiles.last?.sync, "server") } else { XCTFail("written") }
    }

    // P5
    func testAnEntryThisBuildCannotReadIsNotGone() throws {
        var book = PhoneProfileBook()
        book.take(homeAndWork, now: t0)
        let json = #"{"version":1,"profiles":[{"id":"default","name":"Home","color":"green"},{"id":"1a2b3c4d","name":7,"color":"blue"}]}"#
        let item = try XCTUnwrap(ProfilesItem.decode(Data(json.utf8)))
        XCTAssertEqual(item.unread, [work])
        book.take(.found(item), now: t0 + 60)
        XCTAssertTrue(book.listed.contains { $0.id == work }, "unknown is not gone")
        XCTAssertNil(book.profiles.first { $0.id == work }?.gone)
        let noID = try XCTUnwrap(ProfilesItem.decode(Data(#"{"version":1,"profiles":[{"id":"default","name":"Home","color":"green"},{"name":7}]}"#.utf8)))
        XCTAssertEqual(noID.unread, [nil])
        book.take(.found(noID), now: t0 + 120)
        XCTAssertTrue(book.listed.contains { $0.id == work }, "an entry with no readable id could be any profile")
    }

    // P6
    func testABookThatDoesNotDecodeIsNotKnownAndNeverReplaced() throws {
        let made = try MadeUpSuite(self)
        let bytes = Data(#"{"version":1,"profiles":[{"id":"1a2b3c4d","name":"Work","color":"blue","source":"carrier","sync":"server"}],"active":"1a2b3c4d"}"#.utf8)
        made.defaults.set(bytes, forKey: PhoneProfileBook.defaultsKey)
        let book = PhoneProfileBook.load(made.defaults)
        XCTAssertEqual(book.profiles.map(\.id), [work], "an unknown source reads as the item's")
        XCTAssertEqual(book.profiles.first?.source, .item)
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as! [String: Any]
        XCTAssertEqual(((back["profiles"] as? [[String: Any]])?.first?["source"]) as? String, "carrier", "written back as it was read")

        let junk = Data(#"{"version":1,"profiles":[{"id":"1a2b3c4d"}]}"#.utf8)
        made.defaults.set(junk, forKey: PhoneProfileBook.defaultsKey)
        var unknown = PhoneProfileBook.load(made.defaults)
        XCTAssertTrue(unknown.profiles.isEmpty)
        unknown.importTarget = work
        unknown.save(to: made.defaults)
        XCTAssertEqual(made.defaults.data(forKey: PhoneProfileBook.defaultsKey), junk, "a book that does not read is never replaced")
        PhoneProfileBook().save(to: made.defaults)
        made.defaults.set(junk, forKey: PhoneProfileBook.defaultsKey)
        PhoneProfileBook.load(made.defaults).save(to: made.defaults)
        XCTAssertEqual(made.defaults.data(forKey: PhoneProfileBook.defaultsKey), junk, "nor removed")
    }

    // P7
    func testTheFirstProfileAsImportTargetIsNoTarget() throws {
        let made = try MadeUpSuite(self)
        var book = PhoneProfileBook()
        book.importTarget = "default"
        book.active = "default"
        XCTAssertTrue(book.isEmpty)
        book.save(to: made.defaults)
        XCTAssertNil(made.defaults.object(forKey: PhoneProfileBook.defaultsKey))
    }

    // P8
    func testACodedProfileStaysWhenTheItemIsGone() {
        var book = PhoneProfileBook()
        book.add(code(club, "Club"), now: t0)
        book.take(.none, now: t0 + 60)
        XCTAssertTrue(book.listed.contains { $0.id == club })
        XCTAssertTrue(book.leaving.isEmpty)
    }

    func testTheKeychainStatusRule() {
        let item = ProfilesItem(profiles: [entry("default", "Mossad"), entry(work, "Work")])
        let data = try? item.encoded()
        XCTAssertEqual(ProfilesItem.read(status: errSecItemNotFound, data: nil), .none)
        XCTAssertEqual(ProfilesItem.read(status: errSecSuccess, data: data), .found(item))
        XCTAssertEqual(ProfilesItem.read(status: errSecSuccess, data: Data("junk".utf8)), .unknown)
        XCTAssertEqual(ProfilesItem.read(status: errSecSuccess, data: nil), .unknown)
        XCTAssertEqual(ProfilesItem.read(status: errSecInteractionNotAllowed, data: nil), .unknown)
        XCTAssertEqual(ProfilesItem.read(status: errSecAuthFailed, data: data), .unknown)
    }

    func testTheParserRefusesAPlainAddressAndAnEmptySecretAndKnowsTheFirstProfile() {
        XCTAssertEqual(ProfileCode.parse(codeText(#"{"version":1,"id":"1a2b3c4d","name":"Work","color":"blue","sync":"server","address":"http://notes.example.com","secret":"s"}"#)), .damaged)
        XCTAssertEqual(ProfileCode.parse(codeText(#"{"version":1,"id":"1a2b3c4d","name":"Work","color":"blue","sync":"server","address":"https://notes.example.com","secret":""}"#)), .damaged)
        guard case .profile(let first) = ProfileCode.parse(codeText(#"{"version":1,"id":"default","name":"Mossad","color":"orange","sync":"icloud"}"#)) else {
            return XCTFail("the first profile's code parses")
        }
        XCTAssertEqual(first.id, "default")
        guard case .profile(let colored) = ProfileCode.parse(codeText(#"{"version":1,"id":"1a2b3c4d","name":"Work","color":"teal","sync":"icloud"}"#)) else {
            return XCTFail("an unknown color still parses")
        }
        XCTAssertEqual(colored.color, .graphite, "a color this build does not know reads as graphite, as on the Mac")
    }

    func testTheSyncWordIsNotedOnlyInARegistryFileThatReadCleanly() {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: work, name: "Work", color: .blue, root: "~/Mossad Work"))
        XCTAssertNil(ProfileRegistry.Loaded.none.notingSync("server", for: "default"), "no file is made on a Mac with one profile")
        for state in [ProfileRegistry.State.unreadable, .partial, .newer] {
            XCTAssertNil(ProfileRegistry.Loaded(registry: r, state: state).notingSync("server", for: work))
        }
        let read = ProfileRegistry.Loaded(registry: r, state: .read)
        let noted = read.notingSync("server", for: work)
        XCTAssertEqual(noted?.registry.profile(work)?.sync, "server")
        XCTAssertNil(noted?.notingSync("server", for: work), "the same word saves nothing")
    }

    // P9
    func testAServerConnectionNeverPrintsItsSecret() {
        var dumped = ""
        dump(c, to: &dumped)
        for text in ["\(c)", String(describing: c), String(reflecting: c), dumped, "\(ProfileCode.Parsed.server(c))"] {
            XCTAssertFalse(text.contains("made-up-secret"), text)
        }
        XCTAssertTrue("\(c)".contains("notes.example.com"))
        var codeDump = ""
        dump(code(work, "Work", sync: .server), to: &codeDump)
        XCTAssertFalse(codeDump.contains("made-up-secret"), codeDump)
    }

    // P11
    func testTheParserLimitsTheTextAndCleansTheName() {
        let long = "mossad-profile:" + String(repeating: "A", count: 4_100)
        XCTAssertEqual(ProfileCode.parse(long), .damaged)
        guard case .profile(let control) = ProfileCode.parse(codeText(#"{"version":1,"id":"1a2b3c4d","name":"Wo\u0007rk\n","color":"blue","sync":"icloud"}"#)) else {
            return XCTFail("parses")
        }
        XCTAssertEqual(control.name, "Work")
        let spaced = String(repeating: "a", count: 29) + " b"
        guard case .profile(let cut) = ProfileCode.parse(codeText(#"{"version":1,"id":"1a2b3c4d","name":"\#(spaced)","color":"blue","sync":"icloud"}"#)) else {
            return XCTFail("parses")
        }
        XCTAssertEqual(cut.name, String(repeating: "a", count: 29), "cut to 30, then trimmed")
    }

    // P13
    func testAnEmptyRootHookIsTodaysPaths() {
        XCTAssertEqual(PhoneProfileContext.default.root(documents: URL(fileURLWithPath: "/D"), environment: ["MOSSAD_ROOT": ""]).path,
                       URL(fileURLWithPath: "").path)
    }

    // P14
    func testAFolderGoesOnlyAfterAWeekWithNothingWaiting() {
        var gone = PhoneProfile(id: work, name: "Work", color: .blue, sync: .icloud, source: .item)
        gone.gone = t0
        let week = t0 + 7 * 86_400
        let rows: [(PhoneProfile, Int?, Int?, Bool, Date, PhoneProfileBook.Cleanup)] = [
            (gone, 0, 0, false, t0, .waits),
            (gone, 0, 0, false, week - 1, .waits),
            (gone, 0, 0, false, week, .remove),
            (gone, 0, 0, true, week, .waits),
            (gone, 1, 0, false, week, .holds(1)),
            (gone, nil, 0, false, week, .unknown),
            (PhoneProfile(id: work, name: "Work", color: .blue, sync: .icloud, source: .item), 0, 0, false, week, .stays),
            (.default, 0, 0, false, week, .stays),
        ]
        for (profile, outbox, audio, busy, now, expected) in rows {
            XCTAssertEqual(PhoneProfileBook.cleanup(profile, outbox: outbox, audio: audio, busy: busy, now: now), expected,
                           "\(String(describing: outbox)) \(String(describing: audio)) \(busy) \(now)")
        }
    }

    func testANameThatFitsNoProfileIsRefusedWithTheProfilesListed() {
        XCTAssertEqual(PhoneProfileWords.noneNamed("Home", choices: ["Mossad", "Work"]),
                       "Mossad has no profile named “Home” on this iPhone. Its profiles are Mossad, Work.")
    }
}
