import XCTest
@testable import MossadCore

/// What the coach learned about a person who keeps no read never leaves the Mac (R1), the server's mirror gets every
/// kind its tools read without touching the main sync's notes (R2), and the server's config is sent again until it
/// arrives (R4).
final class CoachPrivacySyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var people: [Person] {
        var dana = Person(id: PersonID(rawValue: "id-dana"), displayName: "Dana Lee", origin: .migration, at: now)
        dana.doNotProfile = true
        return [Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: now),
                Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: now), dana]
    }

    private func mac() throws -> Paths {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        try SharedPayload.people(people).data.write(to: paths.people.appendingPathComponent(PeopleStore.fileName))
        return paths
    }

    private func profile(dana: Bool) -> CoachProfile {
        var p = CoachProfile()
        var sam = CoachPerson(note: "Sam NOTE", calls: 2, lastSeen: now)
        sam.person = "id-sam"
        p.people["Sam Carter"] = sam
        if dana {
            var d = CoachPerson(note: "Dana NOTE", calls: 2, lastSeen: now)
            d.person = "id-dana"
            p.people["Dana Lee"] = d
        }
        return p
    }

    func testTheCoachMemoryThatLeavesTheMacHasNothingOnAPersonWhoKeepsNoRead() async throws {
        let paths = try mac()
        try profile(dana: true).save(to: paths.coach)
        let store = MemoryStore(view: true)
        try await CloudSync(paths: paths, store: store).pushShared(people: true)
        let sent = await store.entries[CloudSync.profileName]?.data["data"]
        let text = String(decoding: try XCTUnwrap(sent), as: UTF8.self)
        XCTAssertTrue(text.contains("Sam NOTE"))
        XCTAssertFalse(text.contains("Dana NOTE"))
    }

    func testAPersonTurnedOffLeavesTheStoresCopyAtTheNextSync() async throws {
        let paths = try mac()
        var p = profile(dana: true)
        p.people["Dana Lee"]?.person = nil
        try p.save(to: paths.coach)
        // Sent while Dana still kept a read: a people file without the flag.
        var before = people
        before[2].doNotProfile = false
        try SharedPayload.people(before).data.write(to: paths.people.appendingPathComponent(PeopleStore.fileName))
        let store = MemoryStore(view: true)
        let sync = CloudSync(paths: paths, store: store)
        try await sync.pushShared(people: true)
        let first = await store.entries[CloudSync.profileName]?.data["data"] ?? Data()
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("Dana NOTE"))
        try SharedPayload.people(people).data.write(to: paths.people.appendingPathComponent(PeopleStore.fileName))
        try await sync.pushShared(people: true)
        let second = await store.entries[CloudSync.profileName]?.data["data"] ?? Data()
        XCTAssertFalse(String(decoding: second, as: UTF8.self).contains("Dana NOTE"), "overwritten without the note, matched by the name")
    }

    func testAPullNeverBringsBackANoteOnAPersonWhoKeepsNoRead() async throws {
        let phone = Paths(root: tempDirectory())
        try phone.ensureDirectories()
        try profile(dana: true).save(to: phone.coach)
        let store = MemoryStore()
        try await CloudSync(paths: phone, store: store).pushShared()
        let paths = try mac()
        try profile(dana: false).save(to: paths.coach)
        try await CloudSync(paths: paths, store: store).pull(includeMeetings: false)
        XCTAssertNil(try CoachProfile.load(from: paths.coach).people["Dana Lee"])
    }

    func testTheCoachWritesNoOlderReadOfAPersonWhoKeepsNoRead() {
        var r = CallRecord(id: "a", platform: .meet, bundleID: "b", start: now, end: now.addingTimeInterval(600), status: .written)
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter", "them:B": "Dana Lee"]
        let records = (0..<3).map { i -> CallRecord in var x = r; x.id = "c\(i)"; return x }
        let due = PersonBriefWriter.due(profile: CoachProfile(), records: records, owner: "Avery Webb", now: now, saved: CoachPeople(people: people))
        XCTAssertTrue(due.contains("Sam Carter"))
        XCTAssertFalse(due.contains("Dana Lee"))
    }

    func testTheMirrorSendsEveryKindAndKeepsTheMainSyncsNotes() async throws {
        let paths = try mac()
        try profile(dana: false).save(to: paths.coach)
        var book = CommitmentBook()
        book.items = [Commitment(text: "Send the deck", to: nil, callID: nil, callTitle: nil, madeAt: now, due: nil)]
        try book.save(to: paths.commitments)
        let chats = ChatStore(directory: paths.chats)
        var chat = Chat(title: "Old")
        chat.messages = [ChatMessage(role: .user, text: "Hi")]
        try chats.save(chat)
        let mirror = MemoryStore(view: true)
        try await CloudSync(paths: paths, store: mirror).pushShared(people: true, personas: SyncedPersonas([]), mirror: true)
        let names = await Set(mirror.entries.keys)
        for name in ["people", "personas", "commitments", CloudSync.profileName, "chat-\(chat.id.uuidString)"] { XCTAssertTrue(names.contains(name), name) }
        chats.delete(chat.id)
        try await CloudSync(paths: paths, store: mirror).pushShared(people: true, personas: SyncedPersonas([]), mirror: true)
        let gone = await mirror.entries["chat-\(chat.id.uuidString)"]?.deleted
        XCTAssertEqual(gone, true)
        XCTAssertTrue(chats.deleted().contains(chat.id), "the main sync still has to send the delete")
    }

    func testTheServerConfigIsSentAgainUntilItArrives() {
        var state = ServerConfigState()
        XCTAssertTrue(state.needsSend("Avery|true"))
        state.sending("Avery|true")
        XCTAssertFalse(state.needsSend("Avery|true"), "one send at a time")
        state.failed()
        XCTAssertTrue(state.needsSend("Avery|true"), "a failed send is tried at the next sync")
        state.sending("Avery|true")
        state.arrived("Avery|true")
        XCTAssertFalse(state.needsSend("Avery|true"))
        XCTAssertTrue(state.needsSend("Avery|false"), "a changed switch is sent")
    }
}
