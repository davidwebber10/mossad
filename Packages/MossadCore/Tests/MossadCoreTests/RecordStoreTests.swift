import XCTest
@testable import MossadCore

/// A store in memory, so the sync rules can be tested without iCloud or a server.
actor MemoryStore: RecordStore {
    struct Entry { var record: StoredRecord; var data: [String: Data]; var seq: Int; var deleted: Bool }
    private(set) var entries: [String: Entry] = [:]
    private var seq = 0
    nonisolated let view: Bool

    init(view: Bool = false) { self.view = view }

    nonisolated var stateFileName: String { view ? "state-server.json" : "state.json" }
    nonisolated var wantsMeetingView: Bool { view }

    func prepare() async throws {}

    /// A record the store does not take, as a server that answers one upload with an error.
    private var refused: String?
    func refuse(_ name: String?) { refused = name }

    func save(_ records: [StoredRecord]) async throws -> Set<String> {
        for r in records where r.name != refused {
            seq += 1
            entries[r.name] = Entry(record: r, data: r.files.mapValues { (try? Data(contentsOf: $0)) ?? Data() }, seq: seq, deleted: false)
        }
        return Set(records.map(\.name).filter { $0 != refused })
    }

    func delete(_ names: [String]) async throws -> Set<String> {
        deletes += names
        for n in names where entries[n] != nil { seq += 1; entries[n]!.deleted = true; entries[n]!.seq = seq }
        return Set(names)
    }

    func changes(since token: Data?) async throws -> StoreChanges {
        let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let after = entries.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
        return StoreChanges(
            modified: after.filter { !$0.deleted && unsendable[$0.record.name] == nil }.map { ChangedRecord(name: $0.record.name, type: $0.record.type, fields: $0.record.fields, assetKeys: Array($0.data.keys)) },
            deleted: after.filter(\.deleted).map { (name: $0.record.name, type: $0.record.type) },
            token: Data(String(after.last?.seq ?? since).utf8), more: false,
            failed: after.filter { !$0.deleted }.compactMap { e in unsendable[e.record.name].map { (name: e.record.name, error: $0) } })
    }

    /// Record names whose assets fail to download, with the error.
    private var failing: [String: Error] = [:]
    func fail(_ name: String, with error: Error?) { failing[name] = error }
    private(set) var deletes: [String] = []
    /// Records the store itself cannot send, as iCloud reports one record of a page.
    private var unsendable: [String: Error] = [:]
    func cannotSend(_ name: String, _ error: Error?) { unsendable[name] = error }

    func data(_ record: ChangedRecord, _ key: String) async throws -> Data? {
        if let error = failing[record.name] { throw error }
        return entries[record.name]?.data[key]
    }

    func discard(_ names: [String]) async { _ = try? await delete(names) }

    func asset(_ name: String, _ key: String) -> Data? { entries[name]?.data[key] }
}

final class RecordStoreTests: XCTestCase {
    private func temp() -> Paths {
        Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mossad-store-\(UUID().uuidString)"))
    }

    private func written(_ id: String, in paths: Paths) throws -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_001_800), status: .written)
        r.calendarTitle = "Budget review"
        r.speakerNames = ["me:A": "Dana", "them:A": "Jennifer Lee"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 1, end: 2, text: "Morning."),
                        Utterance(track: .them, speakerLabel: "A", start: 65, end: 70, text: "I need the numbers by Friday."),
                        Utterance(track: .them, speakerLabel: "B", start: 80, end: 82, text: "Agreed.")]
        r.summary = "We held spend."
        r.actionItems = [ActionItem(owner: "Jennifer Lee", task: "Send the numbers")]
        r.attendees = ["Ed Ng", "ed@example.com"]
        try FileManager.default.createDirectory(at: paths.callDirectory(id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(id))
        return r
    }

    func testTheSameRulesSyncMeetingsAndChatsThroughAnyStore() async throws {
        let store = MemoryStore()
        let mac = temp(), phone = temp()
        _ = try written("m1", in: mac)
        let macSync = CloudSync(paths: mac, store: store), phoneSync = CloudSync(paths: phone, store: store)

        let pushed = try await macSync.push()
        XCTAssertEqual(pushed, 1)
        let pushedAgain = try await macSync.push()
        XCTAssertEqual(pushedAgain, 0, "nothing changed")
        try await phoneSync.pull(includeMeetings: true)
        XCTAssertEqual(try CallRecord.load(from: phone.callDirectory("m1")).summary, "We held spend.")

        // A chat made on the phone reaches the Mac, and a delete there removes it here.
        let chat = Chat(title: "Budget")
        try ChatStore(directory: phone.chats).save(chat)
        try await phoneSync.pushShared()
        try await macSync.pull(includeMeetings: false)
        XCTAssertEqual(ChatStore(directory: mac.chats).all().map(\.id), [chat.id])
        // The app's order: push, pull, then pushShared, which records the chat as known here.
        try await macSync.pushShared()
        ChatStore(directory: mac.chats).delete(chat.id)
        try await macSync.pushShared()
        try await phoneSync.pull(includeMeetings: true)
        XCTAssertTrue(ChatStore(directory: phone.chats).all().isEmpty)
    }

    func testTheServerStoreAlsoGetsTheViewTheRemoteMCPReads() async throws {
        let icloud = MemoryStore(view: false), server = MemoryStore(view: true)
        let mac = temp()
        _ = try written("m1", in: mac)
        try await CloudSync(paths: mac, store: icloud).push()
        try await CloudSync(paths: mac, store: server).push()
        let noView = await icloud.asset("m1", "view")
        XCTAssertNil(noView)
        let viewData = await server.asset("m1", "view")
        let data = try XCTUnwrap(viewData)
        let view = try JSONDecoder.callRecord.decode(MeetingView.self, from: data)
        XCTAssertEqual(view.people, ["Dana", "Ed Ng", "Jennifer Lee"], "named voices and invited names, no emails")
        XCTAssertEqual(view.lines.map(\.speaker), ["Dana", "Jennifer Lee", "Speaker A"], "the note's display names")
        XCTAssertEqual(view.actionItems.first?.text, "Jennifer Lee: Send the numbers")
        XCTAssertNotNil(view.timeZone)
        // Each store keeps its own state, so a switch starts clean.
        XCTAssertTrue(FileManager.default.fileExists(atPath: mac.sync.appendingPathComponent("state-server.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mac.sync.appendingPathComponent("state.json").path))
    }

    func testAShareHoldsOnlyTheChosenParts() throws {
        let mac = temp()
        let view = MeetingView(try written("m1", in: mac))
        let only = SharedMeeting(view, owner: "Dana", options: ShareOptions(summary: false, transcript: true, recording: false, chat: true, days: nil), expires: nil, model: nil)
        XCTAssertNil(only.summary)
        XCTAssertNil(only.actionItems)
        XCTAssertEqual(only.lines?.count, 3)
        XCTAssertTrue(only.chat)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: only.encoded()) as? [String: Any])
        XCTAssertTrue(json["expires"] is NSNull, "never expires is written as null")
        XCTAssertNil(json["summary"])

        let nothing = SharedMeeting(view, owner: "Dana", options: ShareOptions(summary: false, transcript: false, recording: true, chat: true), expires: nil, model: nil)
        XCTAssertFalse(nothing.chat, "the chat needs something to read")
    }

    func testShareTokensAreLongRandomAndStoredByHash() {
        let a = MeetingLink.newToken(), b = MeetingLink.newToken()
        XCTAssertEqual(a.count, 43)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(MeetingLink.serverID("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAddressesAndPairingCodes() throws {
        XCTAssertEqual(ServerConnection.address(from: " notes.example.com/ ")?.absoluteString, "https://notes.example.com")
        XCTAssertEqual(ServerConnection.address(from: "http://localhost:8787/x")?.absoluteString, "http://localhost:8787")
        XCTAssertNil(ServerConnection.address(from: "not a host"))
        XCTAssertNil(ServerConnection.address(from: "nodot"))
        let c = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: ServerConnection.newSecret())
        XCTAssertEqual(c.secret.count, 43)
        XCTAssertEqual(ServerPairing.connection(fromCode: ServerPairing.code(for: c)), c)
        XCTAssertNil(ServerPairing.connection(fromCode: "https://example.com"))
    }

    func testFieldsKeepTheirTypesThroughJSON() {
        let fields: [String: StoredValue] = ["t": .string("x"), "d": .date(Date(timeIntervalSince1970: 1_800_000_000)), "l": .strings(["a"])]
        let round = ServerStore.fields(ServerStore.json(fields))
        XCTAssertEqual(round, fields)
    }

    /// Against `wrangler dev --config test/wrangler.dev.jsonc` in `server/`: MOSSAD_TEST_SERVER=http://localhost:8787
    func testTheRealServerSyncsAMacToAPhone() async throws {
        guard let address = ProcessInfo.processInfo.environment["MOSSAD_TEST_SERVER"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Set MOSSAD_TEST_SERVER to a local server")
        }
        let connection = ServerConnection(address: address, secret: "dev-secret")
        let mac = temp(), phone = temp()
        let id = "t\(Int(Date().timeIntervalSince1970))"
        _ = try written(id, in: mac)
        let hello = try await ServerClient(connection).hello()
        XCTAssertTrue(hello.authorized)
        XCTAssertEqual(hello.mcp?.absoluteString, "http://127.0.0.1:8787/mossad")
        try await CloudSync(paths: mac, store: ServerStore(connection)).push()
        try await CloudSync(paths: phone, store: ServerStore(connection)).pull(includeMeetings: true)
        XCTAssertEqual(try CallRecord.load(from: phone.callDirectory(id)).summary, "We held spend.")
        let wrong = ServerConnection(address: address, secret: "nope")
        do { try await ServerStore(wrong).prepare(); XCTFail("a wrong secret must fail") } catch ServerError.wrongSecret {}
    }
}
