import AVFoundation
import XCTest
@testable import MossadCore

/// What a test's `Parts` hands out: one `MemoryStore` per zone or server, each asked-for zone in order, and a secret
/// kept in a box. No Keychain and no iCloud.
final class UploaderWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: MemoryStore] = [:]
    private(set) var asked: [String] = []
    var secret: String?

    func store(_ key: String) -> MemoryStore {
        lock.withLock {
            asked.append(key)
            if let s = stores[key] { return s }
            let s = MemoryStore()
            stores[key] = s
            return s
        }
    }

    func existing(_ key: String) -> MemoryStore? { lock.withLock { stores[key] } }
    var zonesAsked: [String] { lock.withLock { asked } }

    var parts: ProfileUploader.Parts {
        ProfileUploader.Parts(icloud: { self.store($0) }, server: { self.store("server:" + $0.address.absoluteString) },
                              secret: { self.lock.withLock { self.secret } }, setSecret: { s in self.lock.withLock { self.secret = s } },
                              pairedServer: { nil })
    }
}

@MainActor
class UploaderTestCase: XCTestCase {
    var folders: [URL] = []

    override func tearDown() async throws {
        for f in folders { try? FileManager.default.removeItem(at: f) }
        folders = []
    }

    func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uploader-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folders.append(dir)
        return dir
    }

    /// Settings that leave no file in `~/Library/Preferences`.
    func defaults() -> UserDefaults { try! MadeUpSuite(self).defaults }

    func uploader(_ id: String = "default", root: URL? = nil, settings: UserDefaults? = nil, listed: SyncChoice? = .icloud,
                  world: UploaderWorld, background: @escaping @MainActor (String) -> @MainActor () -> Void = { _ in {} }) -> ProfileUploader {
        ProfileUploader(context: PhoneProfileContext(id: id)!, paths: Paths(root: root ?? temp()), settings: settings ?? defaults(),
                        listed: listed, offline: false, parts: world.parts, background: background)
    }

    /// A finished 3 second AAC file and its entry, as an import adds them.
    func addFinished(_ u: ProfileUploader, _ id: String, kind: PhoneRecording.Kind? = nil, seconds: Double = 3) throws {
        try FileManager.default.createDirectory(at: u.recordingsFolder, withIntermediateDirectories: true)
        let url = RoomAudio.finished(id, in: u.recordingsFolder)
        let file = try AVAudioFile(forWriting: url, settings: PhoneRecording.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
        buffer.frameLength = n
        try file.write(from: buffer)
        let start = RoomAudio.start(of: id) ?? Date()
        XCTAssertTrue(u.addImported(PhoneRecording(id: id, start: start, end: start + 3, title: nil, kind: kind)))
    }

    /// A part as the room recorder writes it: 16-bit PCM in CAF.
    func writePart(_ u: ProfileUploader, _ id: String, seconds: Double) throws {
        try FileManager.default.createDirectory(at: u.recordingsFolder, withIntermediateDirectories: true)
        let url = RoomAudio.part(id, 1, in: u.recordingsFolder)
        let file = try AVAudioFile(forWriting: url, settings: RoomAudio.recordingSettings(), commonFormat: .pcmFormatInt16, interleaved: true)
        let n = AVAudioFrameCount(seconds * TrackWriter.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.int16ChannelData![0][i] = Int16(sin(Double(i) * 0.05) * 8000) }
        try file.write(from: buffer)
    }

    /// A meeting the Mac wrote for a recording, in a profile's folder.
    func writeMeeting(_ id: String, in paths: Paths, bundleID: String = PhoneRecording.bundleID, platform: Platform = .inPerson) throws {
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = RoomAudio.start(of: String(id.prefix(15))) ?? Date()
        try CallRecord(id: id, platform: platform, bundleID: bundleID, start: start, end: start + 3, status: .written).save(to: dir)
    }

    /// Waits for the uploader's own tasks (a stop's join and send) to reach a state.
    func until(_ seconds: Double = 10, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if condition() || Date() >= deadline { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func isSent(_ u: ProfileUploader, _ id: String, store: String = "icloud") -> Bool {
        if case .sent(let to, _)? = u.outbox[id]?.state { return to == store }
        return false
    }
}

@MainActor
final class ProfileUploaderTests: UploaderTestCase {
    private let work = "1a2b3c4d"

    func testEachProfileSendsOnItsOwnStore() async throws {
        let world = UploaderWorld()
        let first = uploader(world: world), second = uploader(work, world: world)
        try addFinished(first, "20270115-090000")
        try addFinished(second, "20270115-100000")
        await first.sendOutbox()
        await second.sendOutbox()
        XCTAssertEqual(world.zonesAsked, ["Mossad", "Mossad-1a2b3c4d"])
        let a = await world.existing("Mossad")!.entries.keys.sorted(), b = await world.existing("Mossad-1a2b3c4d")!.entries.keys.sorted()
        XCTAssertEqual(a, ["rec-20270115-090000"])
        XCTAssertEqual(b, ["rec-20270115-100000"])
        XCTAssertTrue(isSent(first, "20270115-090000"))
        XCTAssertTrue(isSent(second, "20270115-100000"))
    }

    func testAProfileWithNoKnownSyncSendsNothing() async throws {
        let world = UploaderWorld()
        let u = uploader(work, listed: nil, world: world)
        XCTAssertNil(u.syncWith)
        XCTAssertNil(u.cloud)
        try addFinished(u, "20270115-090000")
        await u.sendOutbox()
        XCTAssertEqual(u.outbox["20270115-090000"]?.state, .waiting)
        XCTAssertEqual(world.zonesAsked, [])
        u.listed = .icloud
        await u.sendOutbox()
        XCTAssertEqual(world.zonesAsked, ["Mossad-1a2b3c4d"])
        XCTAssertTrue(isSent(u, "20270115-090000"))
    }

    func testTwoSendsAtOnceUploadARecordingOnce() async throws {
        let world = UploaderWorld()
        let u = uploader(world: world)
        try addFinished(u, "20270115-090000")
        async let a: Void = u.sendOutbox()
        async let b: Void = u.sendOutbox()
        _ = await (a, b)
        let seq = await world.existing("Mossad")?.entries["rec-20270115-090000"]?.seq
        XCTAssertEqual(seq, 1)
        XCTAssertEqual(u.outbox["20270115-090000"]?.sends, 1)
    }

    func testAGoneProfileSendsNothingAndKeepsItsAudio() async throws {
        let world = UploaderWorld()
        let u = uploader(work, world: world)
        try addFinished(u, "20270115-090000")
        u.sends = false
        XCTAssertNil(u.cloud)
        await u.sendOutbox()
        await u.pass()
        XCTAssertEqual(world.zonesAsked, [])
        XCTAssertEqual(u.outbox["20270115-090000"]?.state, .waiting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RoomAudio.finished("20270115-090000", in: u.recordingsFolder).path))
    }

    func testASentRecordingSettlesOnlyByItsOwnProfilesMeeting() async throws {
        let world = UploaderWorld()
        let first = uploader(world: world), u = uploader(work, world: world)
        let id = "20270115-090000"
        try addFinished(u, id)
        await u.sendOutbox()
        XCTAssertTrue(isSent(u, id))
        try writeMeeting(id, in: first.paths)
        await u.pass()
        XCTAssertNotNil(u.outbox[id], "a meeting of another profile settles nothing")
        try writeMeeting(id, in: u.paths, bundleID: "")
        await u.pass()
        XCTAssertNotNil(u.outbox[id], "a recording the Mac made itself at that second is no proof")
        try FileManager.default.removeItem(at: u.paths.callDirectory(id))
        try writeMeeting(id, in: u.paths)
        await u.pass()
        XCTAssertNil(u.outbox[id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: u.recordingsFolder).path))
    }

    func testAShownProfilesUploaderLeavesThePullToItsStore() async throws {
        let world = UploaderWorld()
        let u = uploader(work, world: world)
        try addFinished(u, "20270115-090000")
        try addFinished(u, "20270115-100000")
        u.shown = true
        try writeMeeting("20270115-100000", in: u.paths)
        await u.pass()
        XCTAssertEqual(u.outbox.entries.count, 2)
        XCTAssertEqual(world.zonesAsked, [])
        for id in ["20270115-090000", "20270115-100000"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: u.recordingsFolder).path))
        }
    }

    func testAPassAfterALaunchReadsTheOutboxOnDiskAndSends() async throws {
        let world = UploaderWorld()
        let root = temp()
        let before = uploader(work, root: root, world: world)
        try addFinished(before, "20270115-090000")
        // A new launch: a profile that does not show only ever gets a pass.
        let after = uploader(work, root: root, world: world)
        await after.pass()
        XCTAssertTrue(isSent(after, "20270115-090000"), "the outbox on disk is read before the pass")
        XCTAssertEqual(world.zonesAsked, ["Mossad-1a2b3c4d"])
    }

    func testAnIdleUploaderAsksNothing() async {
        let world = UploaderWorld()
        let u = uploader(work, world: world)
        await u.pass()
        XCTAssertEqual(world.zonesAsked, [])
    }

    func testConnectingAServerInOneProfileLeavesTheOthers() {
        let firstWorld = UploaderWorld(), workWorld = UploaderWorld()
        let firstSettings = defaults(), workSettings = defaults()
        let first = uploader(settings: firstSettings, world: firstWorld)
        first.connect(ServerConnection(address: URL(string: "https://first.example.com")!, secret: "first-secret"))
        let u = uploader(work, settings: workSettings, world: workWorld)
        u.connect(ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "made-up-secret"))
        XCTAssertEqual(firstWorld.secret, "first-secret")
        XCTAssertEqual(firstSettings.string(forKey: "serverAddress"), "https://first.example.com")
        XCTAssertEqual(firstSettings.string(forKey: "syncWith"), "server")
        XCTAssertEqual(workWorld.secret, "made-up-secret")
        XCTAssertEqual(workSettings.string(forKey: "serverAddress"), "https://notes.example.com")
        XCTAssertEqual(workSettings.string(forKey: "syncWith"), "server")
        XCTAssertEqual(first.server?.secret, "first-secret")
        XCTAssertEqual(u.server?.secret, "made-up-secret")
        for s in [firstSettings, workSettings] {
            XCTAssertFalse(s.dictionaryRepresentation().values.contains { "\($0)".contains("made-up-secret") || "\($0)".contains("first-secret") })
        }
        u.disconnectServer()
        XCTAssertNil(workWorld.secret)
        XCTAssertEqual(firstWorld.secret, "first-secret", "a disconnect in one profile leaves the other's secret")
    }

    func testOneProfileHasOneUploaderForTheAppsLife() {
        let world = UploaderWorld()
        var made = 0
        let uploaders = ProfileUploaders { profile in
            made += 1
            return self.uploader(profile.id, world: world)
        }
        let a = PhoneProfile(id: work, name: "Work", color: .blue, sync: .icloud, source: .item)
        let b = PhoneProfile(id: work, name: "Client", color: .purple, sync: .server, source: .item)
        XCTAssertTrue(uploaders.uploader(for: a) === uploaders.uploader(for: b))
        XCTAssertEqual(uploaders.all.count, 1)
        XCTAssertEqual(made, 1)
        var tries = 0
        let none = ProfileUploaders { _ in tries += 1; return nil }
        XCTAssertNil(none.uploader(for: a))
        XCTAssertNil(none.uploader(for: a))
        XCTAssertEqual(tries, 2, "a profile that could not open is tried again")
        uploaders.drop(work)
        XCTAssertTrue(uploaders.all.isEmpty)
    }

    func testTheOutboxOfAProfileIsInItsOwnFolder() async {
        let world = UploaderWorld()
        let root = temp(), other = temp()
        let u = uploader(work, root: root, world: world)
        await u.ready()
        u.begin(PhoneRecording(id: "20270115-090000", start: Date(), end: Date(), title: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings/outbox.json").path))
        let again = uploader(work, root: root, world: world)
        await again.ready()
        XCTAssertEqual(again.outbox["20270115-090000"]?.state, .recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("Recordings").path))
    }
}

/// Today's room recorder, as `PhoneStore` did it on main, pinned through the uploader's seam: the same files in the
/// same folder, the same order of writes, and no recording deleted before the Mac has it.
@MainActor
final class ProfileUploaderCharacterizationTests: UploaderTestCase {
    func testARoomRecordingIsBegunSavedFromItsFirstSecondJoinedAndSent() async throws {
        let world = UploaderWorld()
        let u = uploader(world: world)
        await u.ready()
        let id = "20270115-090000", start = RoomAudio.start(of: "20270115-090000")!
        u.begin(PhoneRecording(id: id, start: start, end: start, title: nil))
        let file = u.recordingsFolder.appendingPathComponent(Outbox.fileName)
        XCTAssertEqual(try Outbox.load(from: file)[id]?.state, .recording, "the entry is on disk from the first second")
        try writePart(u, id, seconds: 65)
        u.keepTitle(id, "Planning")
        XCTAssertEqual(try Outbox.load(from: file)[id]?.recording.title, "Planning")
        var held: [String] = []
        let v = uploader(root: u.paths.root, settings: u.settings, world: world, background: { name in held.append(name); return {} })
        await v.ready()
        v.finish(id, end: start + 65, counted: 65, title: "Planning", discard: false)
        XCTAssertTrue(v.joining.contains(id), "the stop holds the id while it joins")
        await until { self.isSent(v, id) }
        XCTAssertTrue(isSent(v, id))
        XCTAssertEqual(held, ["Finish the room recording", "Upload the room recording"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: v.recordingsFolder).path))
        XCTAssertEqual(RoomAudio.parts(of: id, in: v.recordingsFolder), [], "the parts go once the file is whole")
        XCTAssertEqual(v.outbox[id]?.recording.title, "Planning")
        XCTAssertEqual(v.outbox[id]?.recording.end, start + 65)
        let stored = await world.existing("Mossad")?.entries["rec-\(id)"]
        XCTAssertNotNil(stored)
        XCTAssertTrue(v.joining.isEmpty)
    }

    func testAShortRoomRecordingGoesWithItsEntryAndADiscardedOneToo() async throws {
        let world = UploaderWorld()
        let u = uploader(world: world)
        await u.ready()
        let id = "20270115-090000", start = RoomAudio.start(of: id)!
        u.begin(PhoneRecording(id: id, start: start, end: start, title: nil))
        try writePart(u, id, seconds: 3)
        u.finish(id, end: start + 3, counted: 3, title: nil, discard: false)
        await until { u.outbox[id] == nil }
        XCTAssertNil(u.outbox[id])
        XCTAssertEqual(RoomAudio.ids(in: u.recordingsFolder), [])
        XCTAssertEqual(world.zonesAsked, [], "nothing was sent")
    }

    func testARecordingIsKeptUntilItsMeetingComesBackFromTheIPhone() async throws {
        let world = UploaderWorld()
        let u = uploader(world: world)
        let id = "20270115-090000"
        try addFinished(u, id)
        await u.sendOutbox()
        let start = RoomAudio.start(of: id)!
        u.settle(arrived: Outbox.arrived([CallRecord(id: id, platform: .zoom, bundleID: PhoneRecording.bundleID, start: start, end: start, status: .written)]))
        u.settle(arrived: Outbox.arrived([CallRecord(id: id, platform: .inPerson, bundleID: "", start: start, end: start, status: .written)]))
        XCTAssertNotNil(u.outbox[id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: u.recordingsFolder).path))
        u.settle(arrived: Outbox.arrived([CallRecord(id: id + "-iphone", platform: .inPerson, bundleID: PhoneRecording.bundleID, start: start, end: start, status: .written)]))
        XCTAssertNil(u.outbox[id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: u.recordingsFolder).path))
        XCTAssertNil(try Outbox.load(from: u.recordingsFolder.appendingPathComponent(Outbox.fileName))[id])
    }

    func testTheLaunchRecoversAnUnfinishedRecordingLooseAudioAndDropsAnEntryWithNoAudio() async throws {
        let world = UploaderWorld()
        let root = temp(), settings = defaults()
        let before = uploader(root: root, settings: settings, world: world)
        await before.ready()
        let unfinished = "20270115-090000", loose = "20270115-100000", empty = "20270115-110000", active = "20270115-120000"
        let shortLoose = "20270115-130000"
        let start = RoomAudio.start(of: unfinished)!
        before.begin(PhoneRecording(id: unfinished, start: start, end: start, title: "Kept"))
        try writePart(before, unfinished, seconds: 65)
        try addFinished(before, empty)
        try FileManager.default.removeItem(at: RoomAudio.finished(empty, in: before.recordingsFolder))
        before.begin(PhoneRecording(id: active, start: start, end: start, title: nil))
        try writePart(before, active, seconds: 2)
        let other = uploader(root: temp(), world: world)
        try addFinished(other, loose, seconds: 65)
        try addFinished(other, shortLoose)
        for id in [loose, shortLoose] {
            try FileManager.default.copyItem(at: RoomAudio.finished(id, in: other.recordingsFolder), to: RoomAudio.finished(id, in: before.recordingsFolder))
        }

        let launch = uploader(root: root, settings: settings, world: world)
        await launch.ready()
        await launch.recover(active: { active })
        XCTAssertEqual(launch.outbox[unfinished]?.state, .waiting)
        XCTAssertEqual(launch.outbox[unfinished]?.recording.title, "Kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: RoomAudio.finished(unfinished, in: launch.recordingsFolder).path))
        XCTAssertNotNil(launch.outbox[loose], "loose audio gets an entry")
        XCTAssertNil(launch.outbox[shortLoose], "loose audio that is surely short goes, as the Mac drops a short call")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RoomAudio.finished(shortLoose, in: launch.recordingsFolder).path))
        XCTAssertNil(launch.outbox[empty], "an entry with no audio goes")
        XCTAssertEqual(launch.outbox[active]?.state, .recording, "the recording in progress is never recovered")
        XCTAssertFalse(RoomAudio.parts(of: active, in: launch.recordingsFolder).isEmpty)
    }

    func testOnlyTheOwnerRemovesARecordingAndNeverTheOneRecordingNow() throws {
        let world = UploaderWorld()
        let u = uploader(world: world)
        try addFinished(u, "20270115-090000")
        u.begin(PhoneRecording(id: "20270115-100000", start: Date(), end: Date(), title: nil))
        XCTAssertFalse(u.canRemove("20270115-100000", active: "20270115-100000"))
        u.remove("20270115-100000", active: "20270115-100000")
        XCTAssertNotNil(u.outbox["20270115-100000"])
        XCTAssertTrue(u.canRemove("20270115-090000", active: "20270115-100000"))
        u.remove("20270115-090000", active: "20270115-100000")
        XCTAssertNil(u.outbox["20270115-090000"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: RoomAudio.finished("20270115-090000", in: u.recordingsFolder).path))
        XCTAssertTrue(u.waits(active: nil))
        XCTAssertFalse(u.waits(active: "20270115-100000"), "the recording in progress is no reason to look")
    }

    func testSendAgainPutsASentRecordingBackInLine() async throws {
        let world = UploaderWorld()
        let u = uploader(world: world)
        try addFinished(u, "20270115-090000")
        await u.sendOutbox()
        u.sendAgain("20270115-090000")
        XCTAssertEqual(u.outbox["20270115-090000"]?.sends, 0)
        await until { self.isSent(u, "20270115-090000") }
        let seq = await world.existing("Mossad")?.entries["rec-20270115-090000"]?.seq
        XCTAssertEqual(seq, 2, "sent once more")
    }

    func testTheFirstProfilesStoreKeysAreTodays() {
        let world = UploaderWorld()
        let settings = defaults()
        let u = uploader(settings: settings, listed: nil, world: world)
        XCTAssertEqual(u.syncWith, .icloud, "the first profile with no choice syncs through iCloud, as today")
        XCTAssertEqual(u.cloud?.key, "icloud")
        XCTAssertEqual(world.zonesAsked, ["Mossad"])
        XCTAssertEqual(u.place, "iCloud")
        u.connect(ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "made-up-secret"))
        XCTAssertEqual(u.cloud?.key, "server:https://notes.example.com")
        XCTAssertEqual(u.place, "your server")
        XCTAssertEqual(u.recordingsFolder, u.paths.root.appendingPathComponent("Recordings"))
    }
}
