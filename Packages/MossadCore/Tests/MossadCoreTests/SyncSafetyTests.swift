import AVFoundation
import CloudKit
import XCTest
@testable import MossadCore

/// Sync must not lose what it could not read: a failed download is tried again, and nothing is deleted in the
/// store because it is missing or unreadable here.
final class SyncSafetyTests: XCTestCase {
    private func temp() -> Paths {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mossad-safety-\(UUID().uuidString)"))
        try! paths.ensureDirectories()
        return paths
    }

    @discardableResult
    private func meeting(_ id: String, status: CallStatus = .written, in paths: Paths) throws -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: Date(timeIntervalSince1970: 1_800_000_000),
                           end: Date(timeIntervalSince1970: 1_800_001_800), status: status)
        r.summary = "We held spend."
        try FileManager.default.createDirectory(at: paths.callDirectory(id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(id))
        return r
    }

    private func phoneAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let file = try AVAudioFile(forWriting: url, settings: PhoneRecording.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    func testAMeetingAndAChatWhoseDownloadFailedArriveOnTheNextPull() async throws {
        let store = MemoryStore()
        let mac = temp(), phone = temp()
        try meeting("m1", in: mac)
        try meeting("m2", in: mac)
        let chat = Chat(title: "Budget")
        try ChatStore(directory: mac.chats).save(chat)
        let macSync = CloudSync(paths: mac, store: store), phoneSync = CloudSync(paths: phone, store: store)
        try await macSync.push()
        try await macSync.pushShared()

        await store.fail("m1", with: URLError(.networkConnectionLost))
        await store.fail("chat-\(chat.id.uuidString)", with: URLError(.timedOut))
        do {
            try await phoneSync.pull()
            XCTFail("a pull that missed records must say so")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: phone.callDirectory("m2").path), "what did arrive is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.callDirectory("m1").appendingPathComponent("call.json").path))

        await store.fail("m1", with: nil)
        await store.fail("chat-\(chat.id.uuidString)", with: nil)
        try await phoneSync.pull()
        XCTAssertEqual(try CallRecord.load(from: phone.callDirectory("m1")).summary, "We held spend.")
        XCTAssertEqual(ChatStore(directory: phone.chats).all().map(\.id), [chat.id])
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func upload(_ audio: URL, to store: MemoryStore, id: String = "20270115-090000") async throws {
        try await CloudSync(paths: temp(), store: store).upload(PhoneRecording(id: id, start: t0, end: t0.addingTimeInterval(3), title: "Offsite"), audio: audio)
    }

    /// A recording that fails does not hold back the other changes, and it is tried again after a pause.
    func testAPhoneRecordingThatFailedIsTriedAgainAndDoesNotStopTheOtherChanges() async throws {
        let store = MemoryStore()
        let mac = temp(), phone = temp()
        let clock = TestClock(t0)
        try await upload(try phoneAudio(), to: store)
        let chat = Chat(title: "Budget")
        try ChatStore(directory: phone.chats).save(chat)
        try await CloudSync(paths: phone, store: store).pushShared()
        let macSync = CloudSync(paths: mac, store: store, now: { clock.now })

        await store.fail("rec-20270115-090000", with: URLError(.timedOut))
        try await macSync.pull(includeMeetings: false)
        XCTAssertEqual(ChatStore(directory: mac.chats).all().map(\.id), [chat.id], "the chat behind the recording arrived")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac.callDirectory("20270115-090000").path))
        var kept = await store.deletes
        XCTAssertTrue(kept.isEmpty, "the store keeps a recording the Mac does not have yet")
        XCTAssertEqual(try SyncState.load(from: mac.sync).recordings?.map(\.name), ["rec-20270115-090000"])

        // Too soon: no second try. After the pause: imported, and the store copy goes.
        await store.fail("rec-20270115-090000", with: nil)
        try await macSync.pull(includeMeetings: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac.callDirectory("20270115-090000").path))
        clock.advance(301)
        try await macSync.pull(includeMeetings: false)
        XCTAssertEqual(try CallRecord.load(from: mac.callDirectory("20270115-090000")).status, .recorded)
        XCTAssertEqual(try SyncState.load(from: mac.sync).recordings ?? [], [])
        try await Task.sleep(for: .milliseconds(50))
        kept = await store.deletes
        XCTAssertEqual(kept, ["rec-20270115-090000"])
    }

    /// A cut-off upload does not convert. Mossad keeps trying for 7 days, tells the owner after one day, one time,
    /// and then stops; the store keeps the recording the whole time.
    func testARecordingThatNeverConvertsIsTriedForSevenDaysAndTheOwnerIsToldAfterOne() async throws {
        let store = MemoryStore()
        let mac = temp()
        let clock = TestClock(t0)
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: bad)
        try await upload(bad, to: store)
        let sync = CloudSync(paths: mac, store: store, now: { clock.now })

        try await sync.pull(includeMeetings: false)
        var notices = try await sync.recordingNotices()
        XCTAssertTrue(notices.isEmpty, "not after one failure")
        for _ in 1...5 { clock.advance(6 * 3600); try await sync.pull(includeMeetings: false) }
        notices = try await sync.recordingNotices()
        XCTAssertEqual(notices.map(\.name), ["rec-20270115-090000"])
        XCTAssertEqual(notices.first?.title, "Offsite")
        XCTAssertNotEqual(notices.first?.gaveUp, true)
        notices = try await sync.recordingNotices()
        XCTAssertTrue(notices.isEmpty, "told one time")

        for _ in 1...30 { clock.advance(6 * 3600); try await sync.pull(includeMeetings: false) }
        let state = try SyncState.load(from: mac.sync)
        XCTAssertEqual(state.recordings?.first?.gaveUp, true)
        notices = try await sync.recordingNotices()
        XCTAssertEqual(notices.first?.gaveUp, true, "and told that Mossad stopped")
        let tries = state.recordings?.first?.attempts ?? 0
        clock.advance(86_400)
        try await sync.pull(includeMeetings: false)
        XCTAssertEqual(try SyncState.load(from: mac.sync).recordings?.first?.attempts, tries, "no more tries")
        let deletes = await store.deletes
        XCTAssertTrue(deletes.isEmpty)

        // The phone sends it again, good this time: a fresh start.
        try await upload(try phoneAudio(), to: store)
        try await sync.pull(includeMeetings: false)
        XCTAssertEqual(try CallRecord.load(from: mac.callDirectory("20270115-090000")).status, .recorded)
    }

    /// A full disk on the Mac is not the recording's fault: it never ends the tries.
    func testAFailureCausedOnTheMacNeverEndsTheTries() async throws {
        let store = MemoryStore()
        let mac = temp()
        let clock = TestClock(t0)
        try await upload(try phoneAudio(), to: store)
        let sync = CloudSync(paths: mac, store: store, now: { clock.now })
        await store.fail("rec-20270115-090000", with: CocoaError(.fileWriteOutOfSpace))
        for _ in 1...60 { try await sync.pull(includeMeetings: false); clock.advance(6 * 3600) }
        let p = try XCTUnwrap(try SyncState.load(from: mac.sync).recordings?.first)
        XCTAssertNotEqual(p.gaveUp, true)
        XCTAssertNil(p.countedSince)
        await store.fail("rec-20270115-090000", with: nil)
        try await sync.pull(includeMeetings: false)
        XCTAssertEqual(try CallRecord.load(from: mac.callDirectory("20270115-090000")).status, .recorded)
    }

    func testFailuresAreSortedByWhoseFaultTheyAre() {
        XCTAssertEqual(CloudSync.kind(of: URLError(.timedOut)), .passes)
        XCTAssertEqual(CloudSync.kind(of: URLError(.cannotParseResponse)), .passes)
        XCTAssertEqual(CloudSync.kind(of: ServerError.http(429, "")), .passes)
        XCTAssertEqual(CloudSync.kind(of: ServerError.http(503, "")), .passes)
        XCTAssertEqual(CloudSync.kind(of: ServerError.http(404, "")), .content)
        XCTAssertEqual(CloudSync.kind(of: CocoaError(.fileWriteOutOfSpace)), .local)
        XCTAssertEqual(CloudSync.kind(of: CocoaError(.fileWriteNoPermission)), .local)
        XCTAssertEqual(CloudSync.kind(of: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .local)
        XCTAssertEqual(CloudSync.kind(of: NSError(domain: NSOSStatusErrorDomain, code: -34)), .local)
        XCTAssertEqual(CloudSync.kind(of: PhoneRecording.ConversionFailed(reason: "short")), .content)
        XCTAssertEqual(CloudSync.kind(of: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))), .content)
    }

    /// iCloud can fail to send one record of a page. That record follows the same rule as one that does not decode.
    func testARecordTheStoreCannotSendIsCountedAndDoesNotStopTheSyncForGood() async throws {
        let store = MemoryStore()
        let mac = temp(), phone = temp()
        let chat = Chat(title: "Budget")
        try ChatStore(directory: mac.chats).save(chat)
        try await CloudSync(paths: mac, store: store).pushShared()
        await store.cannotSend("chat-\(chat.id.uuidString)", NSError(domain: "CKErrorDomain", code: 16))
        let sync = CloudSync(paths: phone, store: store)
        for _ in 1..<CloudSync.maxRecordFailures {
            do { try await sync.pull(); XCTFail("the failure must show") } catch {}
        }
        try await sync.pull()
        XCTAssertNotNil(try SyncState.load(from: phone.sync).changeToken)
    }

    // MARK: A file that was set aside

    /// The Mac's coach profile was damaged. It starts empty, but it must not replace the copy in the store: it
    /// sends nothing until one pull merged that copy, coaching fields included.
    func testARecoveredProfileTakesTheStoreCopyBeforeItSendsAnything() async throws {
        let store = MemoryStore()
        let mac = temp(), phone = temp()
        var profile = CoachProfile()
        profile.focus = "Slow down"
        profile.summary = "Clear, sometimes fast."
        try profile.save(to: mac.coach)
        var book = CommitmentBook()
        book.checked = ["call-1"]
        try book.save(to: mac.commitments)
        let macSync = CloudSync(paths: mac, store: store)
        try await macSync.pushShared()
        try await CloudSync(paths: phone, store: store).pull()

        let file = mac.coach.appendingPathComponent(CoachProfile.fileName)
        try Data("{ damaged".utf8).write(to: file)
        try Data("{ damaged".utf8).write(to: mac.commitments.appendingPathComponent(CommitmentBook.fileName))
        // A view reads the profile first, as in the app: the file is set aside and the read gives an empty one.
        XCTAssertNil(try? CoachProfile.load(from: mac.coach))
        XCTAssertNil(try? CommitmentBook.load(from: mac.commitments))
        XCTAssertTrue(StoredFile.awaitsMerge(file))
        // Something saves the empty profile (a rating, a chat's "remember").
        try CoachProfile().save(to: mac.coach)

        try await macSync.pushShared()
        try await CloudSync(paths: phone, store: store).pull()
        XCTAssertEqual(try CoachProfile.load(from: phone.coach).focus, "Slow down", "the empty profile did not reach the phone")

        try await macSync.pull(includeMeetings: false)
        XCTAssertEqual(try CoachProfile.load(from: mac.coach).focus, "Slow down")
        XCTAssertEqual(try CoachProfile.load(from: mac.coach).summary, "Clear, sometimes fast.")
        XCTAssertEqual(try CommitmentBook.load(from: mac.commitments).checked, ["call-1"], "no call is read a second time")
        XCTAssertFalse(StoredFile.awaitsMerge(file))
    }

    func testTheOwnerIsToldOnceWhichFileWasSetAside() throws {
        let paths = temp()
        try FileManager.default.createDirectory(at: paths.voices, withIntermediateDirectories: true)
        try Data("[{".utf8).write(to: paths.voices.appendingPathComponent("voices.json"))
        let library = VoiceLibrary(directory: paths.voices)
        XCTAssertTrue(library.profiles.isEmpty)
        let told = StoredFile.takeUntold(in: [paths.voices, paths.coach])
        XCTAssertEqual(told.map(\.file), ["voices.json"])
        XCTAssertTrue(told[0].kept.hasPrefix("voices.unreadable-"))
        XCTAssertFalse(told[0].awaitsMerge, "voices do not sync")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.voices.appendingPathComponent(told[0].kept).path))
        XCTAssertTrue(StoredFile.takeUntold(in: [paths.voices, paths.coach]).isEmpty)
    }

    /// With no store connected there is no other copy to wait for.
    func testWithoutAStoreARecoveredFileDoesNotWait() throws {
        let paths = temp()
        try FileManager.default.createDirectory(at: paths.coach, withIntermediateDirectories: true)
        let file = paths.coach.appendingPathComponent(CoachProfile.fileName)
        try Data("{".utf8).write(to: file)
        XCTAssertThrowsError(try CoachProfile.load(from: paths.coach))
        XCTAssertTrue(StoredFile.awaitsMerge(file))
        CloudSync.nothingToMerge(paths: paths)
        XCTAssertFalse(StoredFile.awaitsMerge(file))
        XCTAssertEqual(StoredFile.takeUntold(in: [paths.coach]).map(\.file), [CoachProfile.fileName], "still told")
    }

    /// Call IDs are start times on both devices.
    func testAPhoneRecordingFromTheSameSecondAsAMacCallIsNotTakenAsImported() async throws {
        let store = MemoryStore()
        let mac = temp()
        try meeting("20270115-090000", in: mac)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await CloudSync(paths: temp(), store: store).upload(PhoneRecording(id: "20270115-090000", start: start, end: start.addingTimeInterval(3), title: nil), audio: try phoneAudio())
        try await CloudSync(paths: mac, store: store).pull(includeMeetings: false)
        XCTAssertEqual(try CallRecord.load(from: mac.callDirectory("20270115-090000-iphone")).platform, .inPerson)
        XCTAssertEqual(try CallRecord.load(from: mac.callDirectory("20270115-090000")).platform, .meet)
    }

    func testAMeetingThatIsProcessedAgainIsNotDeletedInTheStore() async throws {
        let store = MemoryStore()
        let mac = temp()
        var r = try meeting("m1", in: mac)
        try meeting("m2", in: mac)
        try meeting("m3", in: mac)
        let sync = CloudSync(paths: mac, store: store)
        try await sync.push()

        // "Regenerate summary" in progress, and a record that does not decode.
        r.status = .identified
        try r.save(to: mac.callDirectory("m1"))
        try Data("{".utf8).write(to: mac.callDirectory("m2").appendingPathComponent("call.json"))
        try await sync.push()
        var deletes = await store.deletes
        XCTAssertTrue(deletes.isEmpty)

        // A delete removes the folder: that one goes.
        try FileManager.default.removeItem(at: mac.callDirectory("m3"))
        try await sync.push()
        deletes = await store.deletes
        XCTAssertEqual(deletes, ["m3"])
    }

    func testAPushStopsWhenTheCallFolderCannotBeListed() async throws {
        let store = MemoryStore()
        let mac = temp()
        try meeting("m1", in: mac)
        let sync = CloudSync(paths: mac, store: store)
        try await sync.push()
        try FileManager.default.removeItem(at: mac.audio)
        do { try await sync.push(); XCTFail("unknown is not empty") } catch {}
        let deletes = await store.deletes
        XCTAssertTrue(deletes.isEmpty)
    }

    func testAChatFileThatDoesNotDecodeIsNotDeletedOnTheOtherDevice() async throws {
        let store = MemoryStore()
        let mac = temp(), phone = temp()
        let damaged = Chat(title: "Budget"), removed = Chat(title: "Old")
        let chats = ChatStore(directory: mac.chats)
        try chats.save(damaged)
        try chats.save(removed)
        let macSync = CloudSync(paths: mac, store: store), phoneSync = CloudSync(paths: phone, store: store)
        try await macSync.pushShared()
        try await phoneSync.pull()

        try Data("{".utf8).write(to: mac.chats.appendingPathComponent("\(damaged.id.uuidString).json"))
        chats.delete(removed.id)
        try await macSync.pushShared()
        try await phoneSync.pull()
        XCTAssertEqual(ChatStore(directory: phone.chats).all().map(\.id), [damaged.id], "only the chat deleted on purpose goes")
        XCTAssertTrue(chats.deleted().isEmpty, "the store has the delete")
        let moved = try FileManager.default.contentsOfDirectory(atPath: mac.chats.path).filter { $0.contains(".unreadable-") }
        XCTAssertEqual(moved.count, 1, "the damaged file is kept aside")
    }

    func testAnUnreadableCoachProfileIsNotMergedOverAsIfEmpty() async throws {
        let store = MemoryStore()
        let mac = temp(), phone = temp()
        var profile = CoachProfile()
        profile.focus = "Slow down"
        try profile.save(to: phone.coach)
        try await CloudSync(paths: phone, store: store).pushShared()

        try FileManager.default.createDirectory(at: mac.coach, withIntermediateDirectories: true)
        let file = mac.coach.appendingPathComponent(CoachProfile.fileName)
        try Data("{ damaged".utf8).write(to: file)
        do { try await CloudSync(paths: mac, store: store).pull(includeMeetings: false); XCTFail("the failure must show") } catch {}
        let kept = try FileManager.default.contentsOfDirectory(atPath: mac.coach.path).filter { $0.contains(".unreadable-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try String(contentsOf: mac.coach.appendingPathComponent(kept[0]), encoding: .utf8), "{ damaged")
    }

    func testRecordNamesFromTheStoreCannotLeaveTheirFolder() async throws {
        XCTAssertTrue(CloudSync.isSafeName("rec-20270115-090000"))
        XCTAssertTrue(CloudSync.isSafeName("chat-\(UUID().uuidString)"))
        for bad in ["rec-../../x", "..", ".", ".hidden", "rec-.", "a/b", "", "a b", "notes-..", "é"] { XCTAssertFalse(CloudSync.isSafeName(bad), bad) }

        let store = MemoryStore()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: scratch)
        _ = try await store.save([StoredRecord(name: "../../outside", type: CloudSync.meetingType, files: ["record": scratch])])
        let phone = temp()
        try await CloudSync(paths: phone, store: store).pull()
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.audio.appendingPathComponent("../../outside").standardizedFileURL.path))
    }

    func testEachServerHasItsOwnStateFile() {
        func name(_ address: String) -> String {
            ServerStore(ServerConnection(address: URL(string: address)!, secret: "s")).stateFileName
        }
        XCTAssertEqual(name("https://notes.example.com"), name("https://NOTES.example.com"))
        XCTAssertNotEqual(name("https://notes.example.com"), name("https://other.example.com"))
        XCTAssertTrue(name("https://notes.example.com").hasPrefix("state-server-"))
    }

    func testPlainHTTPIsOnlyForThisMachine() {
        XCTAssertEqual(ServerConnection.address(from: "http://notes.example.com")?.scheme, "https")
        XCTAssertEqual(ServerConnection.address(from: "http://localhost:8787")?.scheme, "http")
        XCTAssertEqual(ServerConnection.address(from: "http://127.0.0.1:8787")?.scheme, "http")
    }

    /// An address typed wrong must not receive the owner's secret.
    func testHelloAsksWithoutTheSecretFirst() async throws {
        StubURLProtocol.handler = { _ in (200, json(["mossad": false])) }
        let client = ServerClient(ServerConnection(address: URL(string: "https://wrong.example.com")!, secret: "owner-secret"), session: StubURLProtocol.session())
        do { _ = try await client.hello(); XCTFail("not a Mossad server") } catch {}
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertNil(StubURLProtocol.requests[0].headers["Authorization"])

        StubURLProtocol.handler = { r in (200, json(["mossad": true, "authorized": r.headers["Authorization"] == "Bearer owner-secret"])) }
        let good = ServerClient(ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "owner-secret"), session: StubURLProtocol.session())
        let hello = try await good.hello()
        XCTAssertTrue(hello.authorized)
    }

    func testNoNetworkInICloudIsTriedAgain() {
        XCTAssertTrue(TransientRetry.isTransient(CKError(.networkUnavailable)))
        XCTAssertTrue(TransientRetry.isTransient(CKError(.serviceUnavailable)))
        XCTAssertFalse(TransientRetry.isTransient(CKError(.notAuthenticated)))
    }

    func testAStateFileThatDoesNotDecodeIsMovedAsideAndTheNextSyncStartsClean() throws {
        let dir = temp().sync
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: dir.appendingPathComponent(SyncState.fileName))
        XCTAssertThrowsError(try SyncState.load(from: dir))
        XCTAssertEqual(try SyncState.load(from: dir), SyncState())
    }
}
