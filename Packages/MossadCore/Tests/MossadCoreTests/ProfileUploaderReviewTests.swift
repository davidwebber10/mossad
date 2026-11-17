import AVFoundation
import XCTest
@testable import MossadCore

/// A door a test holds shut: the listing of a folder waits behind it until the test opens it.
final class Door: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var entered = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { c in
            lock.withLock {
                entered = true
                if open { c.resume() } else { waiting.append(c) }
            }
        }
    }

    var reached: Bool { lock.withLock { entered } }

    func letThrough() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiting = [] }
            return waiting
        }
        all.forEach { $0.resume() }
    }
}

/// A store whose next read of the changes fails once; everything else is the made-up store's.
actor FailingPull: RecordStore {
    private let base: MemoryStore
    private var next: Error?
    init(_ base: MemoryStore) { self.base = base }
    func failNext(_ error: Error) { next = error }

    nonisolated var stateFileName: String { base.stateFileName }
    nonisolated var wantsMeetingView: Bool { base.wantsMeetingView }
    func prepare() async throws { try await base.prepare() }
    func save(_ records: [StoredRecord]) async throws -> Set<String> { try await base.save(records) }
    func delete(_ names: [String]) async throws -> Set<String> { try await base.delete(names) }
    func changes(since token: Data?) async throws -> StoreChanges {
        if let error = next {
            next = nil
            throw error
        }
        return try await base.changes(since: token)
    }
    func data(_ record: ChangedRecord, _ key: String) async throws -> Data? { try await base.data(record, key) }
    func discard(_ names: [String]) async { await base.discard(names) }
    func refetch(_ record: ChangedRecord) async throws -> ChangedRecord? { try await base.refetch(record) }
    func saveOne(_ record: StoredRecord) async throws { try await base.saveOne(record) }
}

/// The fixes of the review of profiles part 3, Tasks 5 to 7.
@MainActor
final class ProfileUploaderReviewTests: UploaderTestCase {
    private let work = "1a2b3c4d"

    private func waitFor(_ door: Door) async {
        let deadline = Date().addingTimeInterval(5)
        while !door.reached, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The live recording starts while the recovery waits for its folder list.
    private func liveStartsDuringTheList(listsAfterThePart: Bool, retry: Bool) async throws {
        let world = UploaderWorld()
        let u = uploader(world: world)
        await u.ready()
        let door = Door()
        u.listAudio = { dir in
            if listsAfterThePart {
                await door.wait()
                return RoomAudio.ids(in: dir)
            }
            let ids = RoomAudio.ids(in: dir)
            await door.wait()
            return ids
        }
        let live = "20270115-120000"
        var recording: String?
        if retry {
            // Another recording that was never saved: the reason a retry runs.
            u.begin(PhoneRecording(id: "20270115-090000", start: Date(), end: Date(), title: nil))
            try writePart(u, "20270115-090000", seconds: 65)
        }
        let task = Task {
            if retry {
                u.retryUnfinished(active: { recording })
                await self.until { u.joining.isEmpty && u.outbox["20270115-090000"]?.state != .recording }
            } else {
                await u.recover(active: { recording })
            }
        }
        await waitFor(door)
        // The owner starts the room recorder now: its entry and its part 1.
        u.begin(PhoneRecording(id: live, start: Date(), end: Date(), title: nil))
        try writePart(u, live, seconds: 2)
        recording = live
        door.letThrough()
        await task.value
        XCTAssertEqual(u.outbox[live]?.state, .recording, "the live recording keeps its entry")
        XCTAssertFalse(RoomAudio.parts(of: live, in: u.recordingsFolder).isEmpty, "and its part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RoomAudio.finished(live, in: u.recordingsFolder).path), "and is not joined")
    }

    // Q1 (C1)
    func testARecordingThatStartsWhileTheRecoveryListsAFolderMadeBeforeItsPartIsUntouched() async throws {
        try await liveStartsDuringTheList(listsAfterThePart: false, retry: false)
    }

    func testARecordingThatStartsWhileTheRecoveryListsAFolderWithItsPartIsUntouched() async throws {
        try await liveStartsDuringTheList(listsAfterThePart: true, retry: false)
    }

    func testARecordingThatStartsDuringARetryIsUntouched() async throws {
        try await liveStartsDuringTheList(listsAfterThePart: true, retry: true)
    }

    // Q2 (I1)
    func testAProfileThatDoesNotShowRecoversItsUnfinishedRecordingOnAPass() async throws {
        let world = UploaderWorld()
        let root = temp()
        let before = uploader(work, root: root, world: world)
        await before.ready()
        before.begin(PhoneRecording(id: "20270115-090000", start: RoomAudio.start(of: "20270115-090000")!, end: Date(), title: nil))
        try writePart(before, "20270115-090000", seconds: 65)
        let after = uploader(work, root: root, world: world)
        await after.pass(active: { nil })
        XCTAssertTrue(isSent(after, "20270115-090000"), "recovered, joined, and sent by the pass")
        XCTAssertTrue(FileManager.default.fileExists(atPath: RoomAudio.finished("20270115-090000", in: after.recordingsFolder).path))
    }

    func testTheCountOfAnOutboxNotReadIsNotKnown() async throws {
        let world = UploaderWorld()
        let root = temp()
        let before = uploader(work, root: root, world: world)
        try addFinished(before, "20270115-090000")
        let after = uploader(work, root: root, world: world)
        XCTAssertNil(after.outboxCount, "never 0 for an outbox not read")
        await after.ready()
        XCTAssertEqual(after.outboxCount, 1)
    }

    // Q3 (I2)
    func testThePeopleOfTheStoreAreThereAtOnce() {
        let world = UploaderWorld()
        let u = uploader(world: world)
        u.take(people: [Person(id: PersonID(rawValue: "p-1"), displayName: "Sam Carter", origin: .owner, at: .distantPast)])
        XCTAssertEqual(u.importChoices("sam", heard: [], owner: ""), [.init(name: "Sam Carter", personID: "p-1")])
    }

    // Q4 (M1)
    func testTheImportMemoryIsCutOnlyAgainstMeetingsThatWereRead() async throws {
        let world = UploaderWorld()
        for (known, keepsOld) in [(nil as [CallImport.Known]?, true), ([], false)] {
            let u = uploader(work, world: world)
            try FileManager.default.createDirectory(at: u.recordingsFolder, withIntermediateDirectories: true)
            var memory = ImportMemory()
            memory.remember(hash: "old-hash", id: "20200101-090000")
            try memory.save(to: u.recordingsFolder.appendingPathComponent(ImportMemory.fileName))
            u.known = { known }
            let file = temp().appendingPathComponent("call.m4a")
            do {
                // Closed at the end of this scope, before the import reads it.
                let f = try AVAudioFile(forWriting: file, settings: PhoneRecording.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 70 * 16_000)!
                b.frameLength = 70 * 16_000
                for i in 0..<Int(b.frameLength) { b.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
                try f.write(from: b)
            }
            let read = await CallImport.read(file)
            _ = try await u.importCall(CallImport.Draft(file: read, title: "", start: Date(timeIntervalSince1970: 1_700_000_000), person: nil), from: file).get()
            let after = ImportMemory.load(from: u.recordingsFolder.appendingPathComponent(ImportMemory.fileName))
            XCTAssertEqual(after.id(of: "old-hash") != nil, keepsOld, "known: \(String(describing: known))")
        }
    }

    // Q7 (M6)
    func testADisconnectInAnotherProfileGivesTheChoiceBackToTheMac() {
        let world = UploaderWorld()
        let settings = defaults()
        let u = uploader(work, settings: settings, listed: .icloud, world: world)
        u.connect(ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "made-up-secret"))
        XCTAssertEqual(u.syncWith, .server)
        u.disconnectServer()
        XCTAssertNil(settings.string(forKey: "syncWith"), "no choice of the phone is left")
        XCTAssertEqual(u.syncWith, .icloud, "what the Mac lists")
        let firstSettings = defaults()
        let first = uploader(settings: firstSettings, listed: .server, world: world)
        first.connect(ServerConnection(address: URL(string: "https://first.example.com")!, secret: "first-secret"))
        first.disconnectServer()
        XCTAssertEqual(firstSettings.string(forKey: "syncWith"), "icloud", "the first profile as today")
    }

    // Q9 (M2)
    func testAPassPullsOnlyWhileASentRecordingWaitsAndSettlesByWhatArrived() async throws {
        let world = UploaderWorld()
        let u = uploader(work, world: world)
        let id = "20270115-090000"
        try addFinished(u, id)
        // The Mac wrote the meeting of this recording and synced it into Work's zone.
        let mac = Paths(root: temp())
        try writeMeeting(id, in: mac)
        let store = world.store("Mossad-1a2b3c4d")
        _ = try await CloudSync(paths: mac, store: store).push()
        await u.pass(active: { nil })
        XCTAssertTrue(isSent(u, id), "unsent: no pull, just the send")
        XCTAssertFalse(FileManager.default.fileExists(atPath: u.paths.callDirectory(id).path), "nothing was pulled for an unsent entry")
        await u.pass(active: { nil })
        XCTAssertNil(u.outbox[id], "the pulled meeting settled it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: u.recordingsFolder).path))
    }

    func testAFailedPullGoesOnToTheSend() async throws {
        let world = UploaderWorld()
        let failing = FailingPull(world.store("Mossad-1a2b3c4d"))
        var parts = world.parts
        parts.icloud = { _ in failing }
        let u = ProfileUploader(context: PhoneProfileContext(id: work)!, paths: Paths(root: temp()), settings: defaults(),
                                listed: .icloud, offline: false, parts: parts, active: { nil })
        try addFinished(u, "20270115-090000")
        await u.sendOutbox()
        try addFinished(u, "20270115-100000")
        await failing.failNext(URLError(.badServerResponse))
        await u.pass(active: { nil })
        XCTAssertTrue(isSent(u, "20270115-100000"), "the send runs after a failed pull")
        XCTAssertNotNil(u.syncStatus.shown, "the failure shows")
    }

    func testAnOfflineUploaderSendsNothing() async throws {
        let world = UploaderWorld()
        let u = ProfileUploader(context: .default, paths: Paths(root: temp()), settings: defaults(), listed: .icloud, offline: true, parts: world.parts, active: { nil })
        try addFinished(u, "20270115-090000")
        XCTAssertNil(u.cloud)
        await u.sendOutbox()
        await u.pass(active: { nil })
        XCTAssertEqual(world.zonesAsked, [])
        XCTAssertFalse(u.waits(active: nil))
    }

    func testAJoinThatFailsKeepsThePartsAndSaysNotSaved() async throws {
        let world = UploaderWorld()
        let root = temp()
        let before = uploader(root: root, world: world)
        await before.ready()
        let id = "20270115-090000"
        before.begin(PhoneRecording(id: id, start: RoomAudio.start(of: id)!, end: Date(), title: nil))
        try writePart(before, id, seconds: 65)
        // A folder that takes no new file: the join cannot write, which is not an unreadable part.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: before.recordingsFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: before.recordingsFolder.path) }
        let after = uploader(root: root, world: world)
        await after.ready()
        await after.recover(active: { nil })
        XCTAssertEqual(after.outbox[id]?.state, .recording)
        XCTAssertEqual(after.outbox[id]?.trouble, .notSaved)
        XCTAssertFalse(RoomAudio.parts(of: id, in: after.recordingsFolder).isEmpty, "every part stays")
    }

    func testAChangeOfTheMacsWordStartsAPass() async throws {
        let world = UploaderWorld()
        let u = uploader(work, listed: nil, world: world)
        try addFinished(u, "20270115-090000")
        u.listed = .icloud
        await until { self.isSent(u, "20270115-090000") }
        XCTAssertTrue(isSent(u, "20270115-090000"), "no call of sendOutbox: the change itself sends")
    }
}

final class ProfilesQReviewTests: XCTestCase {
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Q5 (M4)
    func testAFolderIsRemovedOnlyForAProfileThatIsStillGone() {
        var book = PhoneProfileBook()
        let two = ProfilesItem.Read.found(ProfilesItem(profiles: [.init(id: "default", name: "Mossad", color: .orange, sync: "icloud"),
                                                                   .init(id: work, name: "Work", color: .blue, sync: "icloud")]))
        book.take(two, now: t0)
        book.take(.none, now: t0)
        let week = t0 + 8 * 86_400
        XCTAssertTrue(book.removesFolder(of: work, outbox: 0, audio: 0, busy: false, now: week))
        book.take(two, now: week)
        XCTAssertFalse(book.removesFolder(of: work, outbox: 0, audio: 0, busy: false, now: week), "listed again while the removal waited")
        XCTAssertFalse(book.removesFolder(of: "ffffffff", outbox: 0, audio: 0, busy: false, now: week))
    }

    // Q9 (M2): the order rule under an interleaving.
    func testTheWriterNeverWritesTheOlderStateWhenTheFirstTurnIsHeld() async {
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
        let door = Door()
        let writer = ProfilesItemWriter(read: { world.lock.withLock { world.item } }, apply: { plan in
            world.lock.withLock {
                if case .write(let item) = plan {
                    world.item = .found(item)
                    world.writes.append(item.profiles.last?.sync)
                }
            }
        })
        // The first turn is held before it reads; the registry changes; a second request comes; then the door opens.
        let first = Task { await writer.request { await door.wait(); return world.lock.withLock { world.current } } }
        while !door.reached { try? await Task.sleep(for: .milliseconds(5)) }
        world.lock.withLock { world.current.registry.setSync("server", for: self.work) }
        let second = Task { await writer.request { world.lock.withLock { world.current } } }
        door.letThrough()
        await first.value
        await second.value
        let writes = world.lock.withLock { world.writes }
        XCTAssertFalse(writes.contains("icloud"), "the older state is never written: \(writes)")
        XCTAssertEqual(writes.last, "server")
    }

    // Q10 (M7)
    func testAnItemCleansItsNames() throws {
        let long = String(repeating: "a", count: 29) + " bcd"
        let json = #"{"version":1,"profiles":[{"id":"default","name":"Mo\u0007ssad","color":"orange"},{"id":"1a2b3c4d","name":"\#(long)","color":"blue"},{"id":"5e6f7a8b","name":"  ","color":"green"}]}"#
        let item = try XCTUnwrap(ProfilesItem.decode(Data(json.utf8)))
        XCTAssertEqual(item.profiles.map(\.name), ["Mossad", String(repeating: "a", count: 29)])
        XCTAssertEqual(item.profiles.map(\.id), ["default", "1a2b3c4d"], "an entry with no name is no entry")
    }

    func testTheLeavingFooterSaysTheWeek() {
        XCTAssertTrue(PhoneProfileWords.leavingFooter.contains("7 days"))
    }
}
