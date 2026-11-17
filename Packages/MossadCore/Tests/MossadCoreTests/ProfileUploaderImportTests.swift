import AVFoundation
import XCTest
@testable import MossadCore

@MainActor
final class ProfileUploaderImportTests: UploaderTestCase {
    private let work = "1a2b3c4d"

    private struct PeopleFile: Codable {
        var version: Int
        var people: [Person]
    }

    /// A 70 second AAC file named as a shared call, in a folder outside every profile.
    private func callFile() throws -> URL {
        let url = temp().appendingPathComponent("Call with Sam Carter.m4a")
        let file = try AVAudioFile(forWriting: url, settings: PhoneRecording.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(70 * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
        try file.write(from: buffer)
        return url
    }

    private func draft(_ url: URL, person: CallImport.Choice? = nil) async -> CallImport.Draft {
        let f = await CallImport.read(url)
        return CallImport.Draft(file: f, title: "", start: Date(timeIntervalSince1970: 1_700_000_000), person: person)
    }

    private func savePeople(_ people: [Person], in paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        try JSONEncoder.callRecord.encode(PeopleFile(version: 1, people: people)).write(to: paths.people.appendingPathComponent(PeopleStore.fileName))
    }

    private var sam: Person { Person(id: PersonID(rawValue: "p-1"), displayName: "Sam Carter", origin: .owner, at: .distantPast) }

    func testAnImportForAProfileThatIsNotShownLandsInItsFolderOutboxAndStore() async throws {
        let world = UploaderWorld()
        let first = uploader(world: world), u = uploader(work, world: world)
        let file = try callFile()
        let result = await u.importCall(await draft(file), from: file)
        let id = try result.get()
        XCTAssertTrue(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: u.recordingsFolder).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.recordingsFolder.appendingPathComponent(Outbox.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.recordingsFolder.appendingPathComponent(ImportMemory.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.recordingsFolder.path))
        await u.sendOutbox()
        let kind = await world.existing("Mossad-1a2b3c4d")?.entries["rec-\(id)"]?.record.fields["kind"]
        XCTAssertEqual(kind, .string("phoneCall"))
        XCTAssertFalse(world.zonesAsked.contains("Mossad"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the caller discards the handed file")
    }

    func testTheSameFileIsADuplicateOnlyInTheProfileThatHasIt() async throws {
        let world = UploaderWorld()
        let first = uploader(world: world), u = uploader(work, world: world)
        let file = try callFile()
        _ = try await u.importCall(await draft(file), from: file).get()
        let refusedInWork = await u.importRefusal(await draft(file), from: file)
        let refusedInFirst = await first.importRefusal(await draft(file), from: file)
        XCTAssertEqual(refusedInWork, .duplicate)
        XCTAssertNil(refusedInFirst)
    }

    func testAPersonIDOfAnotherProfileNeverTravels() async throws {
        let world = UploaderWorld()
        let first = uploader(world: world), u = uploader(work, world: world)
        try savePeople([sam], in: u.paths)
        let file = try callFile()
        let kept = try await u.importCall(await draft(file, person: .init(name: "Sam Carter", personID: "p-1")), from: file).get()
        XCTAssertEqual(u.outbox[kept]?.recording.personID, "p-1")
        XCTAssertEqual(u.outbox[kept]?.recording.person, "Sam Carter")

        var other = await draft(try callFile(), person: .init(name: "Robin Vale", personID: "p-9"))
        other.start = Date(timeIntervalSince1970: 1_700_100_000)
        let otherFile = try callFile()
        try Data(count: 10).append(to: otherFile)
        let dropped = try await u.importCall(other, from: otherFile).get()
        XCTAssertEqual(u.outbox[dropped]?.recording.person, "Robin Vale")
        XCTAssertNil(u.outbox[dropped]?.recording.personID)

        let firstFile = try callFile()
        let inFirst = try await first.importCall(await draft(firstFile, person: .init(name: "Sam Carter", personID: "p-1")), from: firstFile).get()
        XCTAssertEqual(first.outbox[inFirst]?.recording.person, "Sam Carter")
        XCTAssertNil(first.outbox[inFirst]?.recording.personID, "the first profile has no such person")
    }

    func testThePersonChoicesComeFromThisProfileOnly() async throws {
        let world = UploaderWorld()
        let first = uploader(world: world), u = uploader(work, world: world)
        try savePeople([sam], in: u.paths)
        await u.loadPeople()
        await first.loadPeople()
        XCTAssertEqual(u.importChoices("sam", heard: [], owner: ""), [.init(name: "Sam Carter", personID: "p-1")])
        XCTAssertEqual(first.importChoices("sam", heard: [], owner: ""), [])
    }

    func testAnImportWithNoMeetingsInMemoryReadsItsOwnFolder() async throws {
        let world = UploaderWorld()
        let u = uploader(work, world: world)
        let file = try callFile()
        let d = await draft(file)
        let start = CallImport.whole(d.start)
        let dir = u.paths.callDirectory(CallID.make(start) + "-iphone")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try CallRecord(id: CallID.make(start) + "-iphone", platform: .phoneCall, bundleID: PhoneRecording.bundleID, start: start, end: start + 70,
                       status: .written).save(to: dir)
        let refused = await u.importRefusal(d, from: file)
        XCTAssertEqual(refused, .duplicate)
        u.known = { [] }
        let free = await u.importRefusal(d, from: file)
        XCTAssertNil(free)
    }

    func testAnImportIsBusyUntilItsAudioIsThere() async throws {
        let world = UploaderWorld()
        var seen: [Set<String>] = []
        var u: ProfileUploader!
        u = uploader(work, world: world, background: { name in
            if name == "Add the shared recording" { seen.append(u.joining) }
            return {}
        })
        let file = try callFile()
        XCTAssertFalse(u.isImporting)
        let id = try await u.importCall(await draft(file), from: file).get()
        XCTAssertFalse(u.isImporting)
        XCTAssertTrue(u.joining.isEmpty)
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen.first?.contains(id) == true, "the id is held while the audio is added")
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
