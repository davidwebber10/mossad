import XCTest
@testable import MossadCore

/// What leaves the Mac with person ids: the server's view has them, a share page never does.
final class PeopleSyncSafetyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func record(ids: Bool) -> CallRecord {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(600), status: .written)
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 2, text: "Hi."), Utterance(track: .them, speakerLabel: "A", start: 3, end: 5, text: "Hello.")]
        r.summary = "Short."
        r.actionItems = [ActionItem(owner: "Sam", task: "send it", ownerID: ids ? "id-sam" : nil)]
        r.invitees = [Invitee(name: "Lee, Dana", email: "dana@example.com", personID: ids ? "id-dana" : nil)]
        if ids { r.speakerPeople = ["me:A": "id-owner", "them:A": "id-sam"] }
        return r
    }

    func testTheServersViewHasTheIds() throws {
        let view = MeetingView(record(ids: true))
        XCTAssertEqual(view.persons?.map(\.id), ["id-owner", "id-sam", "id-dana"])
        XCTAssertEqual(view.persons?.map(\.name), ["Avery Webb", "Sam Carter", "Lee, Dana"])
        XCTAssertEqual(view.lines.map(\.speakerId), ["id-owner", "id-sam"])
        XCTAssertEqual(view.actionItems.first?.ownerId, "id-sam")
        XCTAssertEqual(view.people, MeetingView(record(ids: false)).people, "the names stay as they are")
    }

    func testAViewWithNoIdsWritesNoNewKey() throws {
        let text = String(decoding: try MeetingView.encoder.encode(MeetingView(record(ids: false))), as: UTF8.self)
        for key in ["persons", "speakerId", "ownerId"] { XCTAssertFalse(text.contains(key), key) }
    }

    func testASharePageHasNoPersonId() throws {
        let view = MeetingView(record(ids: true))
        let all = ShareOptions(summary: true, transcript: true, recording: true, chat: true, days: nil)
        let text = String(decoding: try SharedMeeting(view, owner: "Avery Webb", options: all, expires: nil, model: nil).encoded(), as: UTF8.self)
        for word in ["persons", "speakerId", "ownerId", "id-sam", "id-owner", "id-dana"] { XCTAssertFalse(text.contains(word), word) }
    }

    func testTheRecordThatSyncsKeepsItsIdsAndNoFingerprint() throws {
        var r = record(ids: true)
        r.speakerEmbeddings = ["them:A": [0.1, 0.2]]
        let synced = try JSONDecoder.callRecord.decode(CallRecord.self, from: SyncPayload(record: r, coach: nil).record)
        XCTAssertEqual(synced.speakerPeople, r.speakerPeople, "the phone reads the ids")
        XCTAssertTrue(synced.speakerEmbeddings.isEmpty)
    }
}

extension PeopleSyncSafetyTests {
    private func temp() -> Paths { Paths(root: tempDirectory()) }

    func testThePeoplePayloadHasOnlyTheAllowedKeys() throws {
        var p = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: t0)
        p.note = "private note"
        p.identities = [SourceIdentity(source: SourceKind(rawValue: "googleChat"), kind: "userID", value: "users/123", state: .verified, at: t0)]
        p.setVerifiedEmail("sam@example.com", at: t0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedPayload.people([p]).data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "people"])
        let person = try XCTUnwrap((json["people"] as? [[String: Any]])?.first)
        XCTAssertTrue(Set(person.keys).isSubset(of: SyncedPeople.allowedKeys), "\(Set(person.keys).subtracting(SyncedPeople.allowedKeys))")
        let text = String(decoding: SharedPayload.people([p]).data, as: UTF8.self)
        for word in ["private note", "users/123", "embedding", "vector", "org"] { XCTAssertFalse(text.contains(word), word) }
        // The phone reads it as its people file.
        XCTAssertEqual(PeopleStore.decode(SharedPayload.people([p]).data)?.first?.displayName, "Sam Carter")
    }

    func testThePeopleGoFromTheMacToThePhoneAndNotBack() async throws {
        let store = MemoryStore()
        let mac = temp(), phone = temp()
        defer { for p in [mac, phone] { try? FileManager.default.removeItem(at: p.root) } }
        let people = PeopleStore(directory: mac.people)
        _ = try people.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        _ = try people.ensure(voiceName: "Avery Webb", isOwner: true, origin: .voiceNaming)
        try await CloudSync(paths: mac, store: store).pushShared(people: true)
        try await CloudSync(paths: phone, store: store).pull(includeMeetings: true)
        let onPhone = try XCTUnwrap(PeopleStore.peek(in: phone.people))
        XCTAssertEqual(Set(onPhone.map(\.displayName)), ["Sam Carter", "Avery Webb"])
        XCTAssertEqual(onPhone.first(where: \.isOwner)?.displayName, "Avery Webb", "the phone reads the owner flag")
        // The phone sends no people of its own, and the Mac keeps its own file.
        let before = try Data(contentsOf: mac.people.appendingPathComponent(PeopleStore.fileName))
        try await CloudSync(paths: phone, store: store).pushShared()
        try await CloudSync(paths: mac, store: store).pull(includeMeetings: false)
        XCTAssertEqual(try Data(contentsOf: mac.people.appendingPathComponent(PeopleStore.fileName)), before)
        let sent = try await CloudSync(paths: mac, store: store).pushShared(people: true)
        XCTAssertEqual(sent, 0, "nothing new to send")
    }
}
