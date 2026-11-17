import XCTest
@testable import MossadCore

final class PhoneProfileBookTests: XCTestCase {
    private let work = "1a2b3c4d"
    private let club = "5e6f7a8b"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var t1: Date { t0 + 60 }
    private var t2: Date { t0 + 120 }

    private func entry(_ id: String, _ name: String, _ color: ProfileColor, _ sync: String?) -> ProfilesItem.Entry {
        ProfilesItem.Entry(id: id, name: name, color: color, sync: sync)
    }

    private func item(_ entries: [ProfilesItem.Entry]) -> ProfilesItem.Read { .found(ProfilesItem(profiles: entries)) }

    private var homeAndWork: ProfilesItem.Read {
        item([entry("default", "Home", .green, "icloud"), entry(work, "Work", .blue, "server")])
    }

    private func clubCode() -> ProfileCode {
        ProfileCode.make(profile: Profile(id: club, name: "Club", color: .pink, root: "~/Mossad Club"), sync: .icloud, server: nil)!
    }

    private func suite() -> UserDefaults { try! MadeUpSuite(self).defaults }

    func testWithNoItemThePhoneListsOnlyTheFirstProfileAndSavesNothing() {
        var book = PhoneProfileBook()
        book.take(.none, now: t0)
        XCTAssertEqual(book.listed, [.default])
        XCTAssertFalse(book.showsProfiles)
        XCTAssertFalse(book.showsProfileRow)
        XCTAssertTrue(book.isEmpty)
        XCTAssertEqual(book.activeProfile, .default)
        let defaults = suite()
        book.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: "phoneProfiles"))
        defaults.set(Data("old".utf8), forKey: "phoneProfiles")
        book.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: "phoneProfiles"), "an empty book removes the key")
        XCTAssertEqual(PhoneProfileBook.defaultsKey, "phoneProfiles")
    }

    func testTheItemFillsTheList() {
        var book = PhoneProfileBook()
        book.take(homeAndWork, now: t0)
        XCTAssertEqual(book.listed.map(\.id), ["default", work])
        XCTAssertEqual(book.listed[0].name, "Home")
        XCTAssertEqual(book.listed[0].color, .green)
        XCTAssertEqual(book.listed[1].sync, .server)
        XCTAssertEqual(book.listed[1].source, .item)
        XCTAssertTrue(book.showsProfiles)
        XCTAssertTrue(book.showsProfileRow)
        let defaults = suite()
        book.save(to: defaults)
        XCTAssertEqual(PhoneProfileBook.load(defaults), book)
    }

    func testARenameKeepsTheIdAndEverythingNamedAfterIt() {
        var book = PhoneProfileBook()
        book.take(homeAndWork, now: t0)
        book.active = work
        book.importTarget = work
        let before = PhoneProfileContext(id: book.listed[1].id)
        book.take(item([entry("default", "Home", .green, "icloud"), entry(work, "Client", .purple, "server")]), now: t1)
        let entries = book.profiles.filter { $0.id == work }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Client")
        XCTAssertEqual(entries[0].color, .purple)
        XCTAssertEqual(PhoneProfileContext(id: entries[0].id), before)
        XCTAssertEqual(book.active, work)
        XCTAssertEqual(book.importTarget, work)
    }

    func testAnItemThatCannotBeReadChangesNothing() {
        var book = PhoneProfileBook()
        book.take(homeAndWork, now: t0)
        book.active = work
        let before = book
        book.take(.unknown, now: t1)
        XCTAssertEqual(book, before)
    }

    func testAProfileTheMacDroppedLeaves() {
        var book = PhoneProfileBook()
        book.take(homeAndWork, now: t0)
        book.active = work
        book.take(item([entry("default", "Home", .green, "icloud")]), now: t1)
        XCTAssertEqual(book.leaving.map(\.id), [work])
        XCTAssertEqual(book.leaving.first?.gone, t1)
        XCTAssertFalse(book.listed.contains { $0.id == work })
        XCTAssertNil(book.active, "the phone goes to the first profile")
        XCTAssertTrue(book.showsProfileRow, "a leaving profile keeps the row")
        book.take(item([entry("default", "Home", .green, "icloud")]), now: t2)
        XCTAssertEqual(book.leaving.first?.gone, t1, "the first date stays")
        book.take(homeAndWork, now: t2)
        XCTAssertTrue(book.leaving.isEmpty)
        XCTAssertTrue(book.listed.contains { $0.id == work })
        book.take(.none, now: t2)
        XCTAssertEqual(book.leaving.map(\.id), [work])
        XCTAssertFalse(book.profiles.contains { $0.id == "default" }, "with no item, the first profile's entry goes")
        XCTAssertEqual(book.listed.map(\.id), ["default"])
    }

    func testTheFirstProfileNeverLeaves() {
        var book = PhoneProfileBook()
        book.take(item([entry(work, "Work", .blue, "server")]), now: t0)
        XCTAssertEqual(book.listed.first?.id, "default")
        book.take(.none, now: t1)
        XCTAssertEqual(book.listed.first?.id, "default")
        XCTAssertFalse(book.leaving.contains { $0.id == "default" })
        let before = book
        book.removeFromPhone("default", now: t2)
        XCTAssertEqual(book, before)
    }

    func testACodedProfileStaysUntilTheItemTookItOver() {
        var book = PhoneProfileBook()
        book.add(clubCode(), now: t0)
        XCTAssertEqual(book.listed.last?.id, club)
        XCTAssertEqual(book.listed.last?.source, .code)
        XCTAssertEqual(book.listed.last?.sync, .icloud)
        book.take(homeAndWork, now: t0)
        XCTAssertEqual(book.listed.map(\.id), ["default", work, club])
        XCTAssertEqual(book.listed.last?.source, .code)
        book.take(item([entry("default", "Home", .green, "icloud"), entry(work, "Work", .blue, "server"), entry(club, "Club", .pink, "icloud")]), now: t1)
        XCTAssertEqual(book.profiles.first { $0.id == club }?.source, .item)
        book.take(homeAndWork, now: t2)
        XCTAssertEqual(book.leaving.map(\.id), [club])
        var coded = PhoneProfileBook()
        coded.add(clubCode(), now: t0)
        coded.removeFromPhone(club, now: t1)
        XCTAssertEqual(coded.leaving.first?.gone, t1)
        coded.forget(club)
        XCTAssertTrue(coded.isEmpty)
    }

    func testTheImportProfileIsTheLastChosenElseTheActiveOne() {
        var book = PhoneProfileBook()
        book.take(homeAndWork, now: t0)
        book.add(clubCode(), now: t0)
        book.active = work
        XCTAssertEqual(book.importDefault.id, work)
        book.importTarget = club
        XCTAssertEqual(book.importDefault.id, club)
        book.removeFromPhone(club, now: t1)
        XCTAssertEqual(book.importDefault.id, work)
        XCTAssertEqual(book.profile(named: " work ")?.id, work)
        XCTAssertEqual(book.profile(named: "Home")?.id, "default")
        XCTAssertNil(book.profile(named: "Garden"))
    }

    func testAGoneProfileKeepsItsFolderWhileARecordingWaits() {
        let here = PhoneProfile(id: work, name: "Work", color: .blue, sync: .server, source: .item)
        var gone = here
        gone.gone = t0
        let later = t0 + 8 * 86_400
        let rows: [(PhoneProfile, Int?, Int?, PhoneProfileBook.Cleanup)] = [
            (here, 0, 0, .stays), (gone, nil, 0, .unknown), (gone, 0, nil, .unknown), (gone, 1, 1, .holds(1)),
            (gone, 0, 2, .holds(2)), (gone, 0, 0, .remove), (.default, 0, 0, .stays), (.default, nil, nil, .stays),
        ]
        for (profile, outbox, audio, expected) in rows {
            XCTAssertEqual(PhoneProfileBook.cleanup(profile, outbox: outbox, audio: audio, busy: false, now: later), expected,
                           "\(profile.id) \(String(describing: outbox)) \(String(describing: audio))")
        }
        var goneDefault = PhoneProfile.default
        goneDefault.gone = t0
        XCTAssertEqual(PhoneProfileBook.cleanup(goneDefault, outbox: 0, audio: 0, busy: false, now: later), .stays)
    }

    func testANewerBookIsReadAndNeverSaved() throws {
        let defaults = suite()
        let bytes = Data(#"{"version":2,"profiles":[{"id":"1a2b3c4d","name":"Work","color":"blue","sync":"server","source":"item"}],"active":"1a2b3c4d","future":true}"#.utf8)
        defaults.set(bytes, forKey: "phoneProfiles")
        var book = PhoneProfileBook.load(defaults)
        XCTAssertEqual(book.version, 2)
        XCTAssertEqual(book.profiles.map(\.id), [work])
        book.importTarget = work
        book.save(to: defaults)
        XCTAssertEqual(defaults.data(forKey: "phoneProfiles"), bytes)
        defaults.set(Data("junk".utf8), forKey: "phoneProfiles")
        XCTAssertEqual(PhoneProfileBook.load(defaults).profiles, [], "a book that does not read is no profiles")
    }

    func testTheSwitchTable() {
        var book = PhoneProfileBook()
        book.take(homeAndWork, now: t0)
        book.add(clubCode(), now: t0)
        book.removeFromPhone(club, now: t1)
        let rows: [(String, String, Bool, Bool, PhoneProfileSwitch.Decision)] = [
            (work, "default", false, false, .go(work)),
            (work, work, true, false, .stay),
            (work, "default", true, false, .refused(PhoneProfileSwitch.recordingRefusal)),
            (work, "default", false, true, .refused(PhoneProfileSwitch.importRefusal)),
            (work, "default", true, true, .refused(PhoneProfileSwitch.recordingRefusal)),
            (club, "default", false, false, .stay),
            ("ffffffff", "default", false, false, .stay),
            ("default", work, false, false, .go("default")),
        ]
        for (to, active, recording, importing, expected) in rows {
            XCTAssertEqual(PhoneProfileSwitch.decide(to: to, book: book, active: active, recording: recording, importing: importing), expected,
                           "\(to) from \(active) \(recording) \(importing)")
        }
        XCTAssertEqual(PhoneProfileSwitch.Step.allCases, [.closeOld, .remember, .buildNew])
        XCTAssertEqual(PhoneProfileSwitch.recordingRefusal, "A room recording is running. Switch when it ends.")
        XCTAssertEqual(PhoneProfileSwitch.importRefusal, "A recording is being added. Switch when it is done.")
    }

    func testAClosedStoreStartsNoWorkButFinishesAnEdit() {
        var life = StoreLife()
        XCTAssertFalse(life.closed)
        for work in StoreLife.Work.allCases { XCTAssertTrue(life.allows(work)) }
        life.close()
        XCTAssertTrue(life.closed)
        for work in StoreLife.Work.allCases { XCTAssertEqual(life.allows(work), work == .finishEdit, "\(work)") }
    }

    func testTheWordsOfTheProfileScreen() {
        XCTAssertEqual(PhoneProfileWords.label("Work"), "Profile, Work")
        XCTAssertEqual(PhoneProfileWords.waiting(1), "1 recording waits to send")
        XCTAssertEqual(PhoneProfileWords.waiting(2), "2 recordings wait to send")
        XCTAssertEqual(PhoneProfileWords.leavingTitle, "No longer on your Mac")
        XCTAssertEqual(PhoneProfileWords.leavingRow(name: "Work", count: 1), "1 recording of “Work” was not sent")
        XCTAssertEqual(PhoneProfileWords.leavingRow(name: "Work", count: 2), "2 recordings of “Work” were not sent")
        XCTAssertEqual(PhoneProfileWords.leavingFooter,
                       "Your Mac no longer has this profile, so Mossad does not send these recordings. Share a recording to keep it, or delete it. When none are left, Mossad removes the profile from this iPhone after 7 days.")
        XCTAssertEqual(PhoneProfileWords.noProfileNamed("Home"), "Mossad has no profile named “Home” on this iPhone.")
        XCTAssertEqual(PhoneProfileWords.connected(name: "Mossad", host: "notes.example.com"), "Connected “Mossad” to notes.example.com.")
        XCTAssertEqual(PhoneProfileWords.added("Work"), "Added “Work”.")
        XCTAssertEqual(PhoneProfileWords.cannotOpen, "This profile could not be opened on this iPhone.")
        XCTAssertEqual(PhoneProfileWords.notInProfile, "That meeting is not in this profile on this iPhone.")

        let unknown = PhoneProfile(id: work, name: "Work", color: .blue, sync: nil, source: .item)
        XCTAssertEqual(PhoneProfileWords.note(for: unknown, hasServer: false),
                       "Open this profile in Mossad on your Mac once. Then this iPhone knows how it syncs.")
        let server = PhoneProfile(id: work, name: "Work", color: .blue, sync: .server, source: .item)
        XCTAssertEqual(PhoneProfileWords.note(for: server, hasServer: false), "Scan this profile's code on your Mac to connect its server.")
        XCTAssertNil(PhoneProfileWords.note(for: server, hasServer: true))
        let off = PhoneProfile(id: work, name: "Work", color: .blue, sync: .off, source: .item)
        XCTAssertEqual(PhoneProfileWords.note(for: off, hasServer: false), "This profile does not sync on your Mac.")
        let codedCloud = PhoneProfile(id: club, name: "Club", color: .pink, sync: .icloud, source: .code)
        XCTAssertEqual(PhoneProfileWords.note(for: codedCloud, hasServer: false),
                       "This profile syncs through iCloud. It reaches your Mac only when this iPhone uses the same iCloud account.")
        XCTAssertNil(PhoneProfileWords.note(for: PhoneProfile(id: club, name: "Club", color: .pink, sync: .icloud, source: .item), hasServer: false))
        XCTAssertNil(PhoneProfileWords.note(for: .default, hasServer: false))
    }
}
