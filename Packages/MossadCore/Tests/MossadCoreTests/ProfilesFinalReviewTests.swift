import AVFoundation
import XCTest
@testable import MossadCore

/// A door that opens when `count` callers wait at it: two tasks reach one place before either goes on.
final class MeetingPoint: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrived = 0

    init(_ count: Int) { self.count = count }

    func arrive() async {
        await withCheckedContinuation { c in
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                arrived += 1
                waiting.append(c)
                guard arrived >= count else { return [] }
                defer { waiting = [] }
                return waiting
            }
            all.forEach { $0.resume() }
        }
    }
}

/// The fixes of the final review of profiles part 3.
@MainActor
final class ProfileUploaderFinalReviewTests: UploaderTestCase {
    private let work = "1a2b3c4d"

    private func callFile() throws -> URL {
        let url = temp().appendingPathComponent("Call.m4a")
        do {
            let f = try AVAudioFile(forWriting: url, settings: PhoneRecording.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 70 * 16_000)!
            b.frameLength = 70 * 16_000
            for i in 0..<Int(b.frameLength) { b.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
            try f.write(from: b)
        }
        return url
    }

    // Z2c: the pass that a change of store starts asks the app's recorder.
    func testAChangeOfStoreNeverTouchesTheLiveRecording() async throws {
        let world = UploaderWorld()
        var live: String?
        let u = uploader(work, listed: nil, world: world, active: { live })
        await u.ready()
        let id = "20270115-120000"
        u.begin(PhoneRecording(id: id, start: Date(), end: Date(), title: nil))
        try writePart(u, id, seconds: 2)
        live = id
        u.listed = .icloud
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(u.outbox[id]?.state, .recording, "the live recording keeps its entry")
        XCTAssertFalse(RoomAudio.parts(of: id, in: u.recordingsFolder).isEmpty, "and its part")
    }

    // Z5: the outbox is read after the meetings, so the second of two same imports is refused.
    func testTwoSameImportsAtOneTimeKeepTheFirstEntry() async throws {
        let world = UploaderWorld()
        let u = uploader(work, world: world)
        let both = MeetingPoint(2)
        u.readMeetings = { _ in
            await both.arrive()
            return []
        }
        let one = try callFile(), two = try callFile()
        let draft = CallImport.Draft(file: await CallImport.read(one), title: "", start: Date(timeIntervalSince1970: 1_700_000_000), person: nil)
        async let a = u.importCall(draft, from: one)
        async let b = u.importCall(draft, from: two)
        let results = await [a, b]
        let added = results.compactMap { try? $0.get() }
        XCTAssertEqual(added.count, 1, "one is added, the other is refused: \(results)")
        let id = try XCTUnwrap(added.first)
        XCTAssertNotNil(u.outbox[id], "the first one's entry stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: u.recordingsFolder).path))
    }

    // Z6: a people file that does not read is not known: the person the owner picked stays.
    func testAPersonIDStaysWhenThePeopleCannotBeRead() async throws {
        let world = UploaderWorld()
        let u = uploader(work, world: world)
        try FileManager.default.createDirectory(at: u.paths.people, withIntermediateDirectories: true)
        try Data("not people".utf8).write(to: u.paths.people.appendingPathComponent(PeopleStore.fileName))
        let file = try callFile()
        let draft = CallImport.Draft(file: await CallImport.read(file), title: "", start: Date(timeIntervalSince1970: 1_700_000_000),
                                     person: .init(name: "Robin Vale", personID: "p-9"))
        let id = try await u.importCall(draft, from: file).get()
        XCTAssertEqual(u.outbox[id]?.recording.personID, "p-9", "no list was read: the owner's pick stays")

        // A list read before stays when a later read fails.
        let sam = Person(id: PersonID(rawValue: "p-1"), displayName: "Sam Carter", origin: .owner, at: .distantPast)
        u.take(people: [sam])
        let read = await u.loadPeople()
        XCTAssertFalse(read)
        XCTAssertEqual(u.people.map(\.id.rawValue), ["p-1"])
    }
}

final class ProfilesFinalReviewTests: XCTestCase {
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let c = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "made-up-secret")

    private var two: ProfilesItem.Read {
        .found(ProfilesItem(profiles: [.init(id: "default", name: "Mossad", color: .orange, sync: "icloud"),
                                       .init(id: work, name: "Work", color: .blue, sync: "icloud")]))
    }

    // Z1: with one profile, the words of before.
    func testTheScanWordsOfOneProfileAreTheWordsOfBefore() {
        XCTAssertEqual(PhoneProfileWords.connected(name: "Mossad", host: "notes.example.com", showsProfiles: false), "Connected to notes.example.com")
        XCTAssertEqual(PhoneProfileWords.connected(name: "Mossad", host: "notes.example.com", showsProfiles: true),
                       "Connected “Mossad” to notes.example.com.")
        let before = "That code isn't from Mossad. Show the code on your Mac again."
        XCTAssertEqual(PhoneProfileWords.scanProblem(.damaged, showsProfiles: false), before)
        XCTAssertEqual(PhoneProfileWords.scanProblem(.notMossad, showsProfiles: false), before)
        XCTAssertEqual(PhoneProfileWords.scanProblem(.damaged, showsProfiles: true), "That code could not be read. Show the code on your Mac again.")
        XCTAssertEqual(PhoneProfileWords.scanProblem(.notMossad, showsProfiles: true), before)
        XCTAssertEqual(PhoneProfileWords.scanProblem(.newer, showsProfiles: false), ProfileCode.Parsed.newer.problem)
        XCTAssertNil(PhoneProfileWords.scanProblem(.server(c), showsProfiles: false))
    }

    // Z2a
    func testAClosedStoreStartsNoRecording() {
        var life = StoreLife()
        XCTAssertTrue(life.allows(.record))
        life.close()
        XCTAssertFalse(life.allows(.record))
    }

    // Z2b
    func testASwitchGoesOnAfterTheWaitOnlyToAProfileThatIsStillListed() {
        var book = PhoneProfileBook()
        book.take(two, now: t0)
        XCTAssertEqual(PhoneProfileSwitch.afterClose(next: work, book: book), work)
        book.take(.found(ProfilesItem(profiles: [.init(id: "default", name: "Mossad", color: .orange, sync: "icloud")])), now: t0)
        XCTAssertEqual(PhoneProfileSwitch.afterClose(next: work, book: book), Profile.defaultID, "it left in the wait")
        XCTAssertEqual(PhoneProfileSwitch.afterClose(next: "ffffffff", book: book), Profile.defaultID)
    }

    // Z7: the Profile row for a profile that left only while it holds a recording.
    func testTheProfileRowShowsForAProfileThatLeftOnlyWithARecording() {
        var book = PhoneProfileBook()
        book.take(two, now: t0)
        book.take(.none, now: t0)
        XCTAssertFalse(book.showsProfiles)
        XCTAssertFalse(book.showsProfileRow(holding: []))
        XCTAssertTrue(book.showsProfileRow(holding: [work]))
        XCTAssertFalse(book.showsProfileRow(holding: ["ffffffff"]))
        book.take(two, now: t0)
        XCTAssertTrue(book.showsProfileRow(holding: []))
    }

    // Z11: a profile the owner removed has its own words and goes at once with no recording.
    func testAProfileTheOwnerRemovedIsNotOneThatLeftTheMac() throws {
        var book = PhoneProfileBook()
        let code = try XCTUnwrap(ProfileCode.make(profile: Profile(id: "5e6f7a8b", name: "Club", color: .green, root: "~/Mossad Club"), sync: .icloud, server: nil))
        book.add(code, now: t0)
        book.removeFromPhone("5e6f7a8b", now: t0)
        let removed = try XCTUnwrap(book.leaving.first)
        XCTAssertTrue(removed.removedHere)
        XCTAssertEqual(book.removedHere.map(\.id), ["5e6f7a8b"])
        XCTAssertTrue(book.leftTheMac.isEmpty)
        XCTAssertEqual(PhoneProfileBook.cleanup(removed, outbox: 0, audio: 0, busy: false, now: t0), .remove, "no week to wait")
        XCTAssertEqual(PhoneProfileBook.cleanup(removed, outbox: 1, audio: 1, busy: false, now: t0), .holds(1))
        XCTAssertEqual(PhoneProfileBook.cleanup(removed, outbox: 0, audio: 0, busy: true, now: t0), .waits)
        book.add(code, now: t0)
        XCTAssertFalse(try XCTUnwrap(book.profiles.first { $0.id == "5e6f7a8b" }).removedHere, "a new scan brings it back")

        book.take(two, now: t0)
        book.take(.none, now: t0)
        XCTAssertEqual(book.leftTheMac.map(\.id), [work])
        XCTAssertNotEqual(PhoneProfileWords.removedTitle, PhoneProfileWords.leavingTitle)
        XCTAssertFalse(PhoneProfileWords.removedFooter.contains("Mac no longer"))
    }

    func testTheRemovedMarkIsKeptByTheBook() throws {
        var book = PhoneProfileBook()
        book.add(try XCTUnwrap(ProfileCode.make(profile: Profile(id: "5e6f7a8b", name: "Club", color: .green, root: "~/Mossad Club"), sync: .icloud, server: nil)), now: t0)
        book.removeFromPhone("5e6f7a8b", now: t0)
        let again = try JSONDecoder().decode(PhoneProfileBook.self, from: JSONEncoder().encode(book))
        XCTAssertTrue(try XCTUnwrap(again.profiles.first).removedHere)
    }

    // Z4
    func testTheWordsForAnImportWhoseProfileLeft() {
        XCTAssertEqual(PhoneProfileWords.importTargetLeft("Work"), "“Work” is no longer on this iPhone. Choose another profile, then add the call again.")
    }

    // Z11: "was not sent" only for entries that were not sent.
    func testTheRowOfAProfileThatLeftSaysNotSentOnlyForWhatWasNotSent() {
        XCTAssertEqual(PhoneProfileWords.leavingRow(name: "Work", unsent: 1, sent: 0), "1 recording of “Work” was not sent")
        XCTAssertEqual(PhoneProfileWords.leavingRow(name: "Work", unsent: 2, sent: 1), "2 recordings of “Work” were not sent")
        XCTAssertEqual(PhoneProfileWords.leavingRow(name: "Work", unsent: 0, sent: 1), "1 recording of “Work” is still on this iPhone")
        XCTAssertEqual(PhoneProfileWords.leavingRow(name: "Work", unsent: 0, sent: 2), "2 recordings of “Work” are still on this iPhone")
        XCTAssertEqual(PhoneProfileWords.deleteMessage(sent: false), "The audio is deleted from this iPhone. Your Mac never got it.")
        XCTAssertFalse(PhoneProfileWords.deleteMessage(sent: true).contains("never"))
    }
}
