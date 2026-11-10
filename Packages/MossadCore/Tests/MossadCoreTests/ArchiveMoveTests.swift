import XCTest
@testable import MossadCore

/// A place for recordings in memory, with the faults a real one can have.
final class FakeArchive: ArchiveBackend, @unchecked Sendable {
    let kind: ArchiveKind
    var maxBytes: Int64?
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private(set) var puts: [String] = []
    private(set) var removes: [String] = []
    /// The next uploads fail with these errors, in order.
    var putErrors: [Error] = []
    /// Keeps other bytes than it was sent, as a place that damaged the file.
    var damages = false
    /// Does not answer questions about what it has.
    var silent = false
    var removeFails = false
    var onPut: (() -> Void)?

    init(_ kind: ArchiveKind, maxBytes: Int64? = nil) {
        self.kind = kind
        self.maxBytes = maxBytes
    }

    var objects: [String: Data] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func key(for callID: String) -> String { kind == .server ? "recordings/\(callID)/recording.m4a" : "calls/\(callID)/recording.m4a" }

    func put(_ file: URL, key: String, sha256: String) async throws {
        onPut?()
        let error: Error? = lock.withLock {
            puts.append(key)
            return putErrors.isEmpty ? nil : putErrors.removeFirst()
        }
        if let error { throw error }
        let data = try Data(contentsOf: file)
        lock.withLock { stored[key] = damages ? Data(data.reversed()) : data }
    }

    func presence(_ key: String) async -> ArchivePresence {
        if silent { return .unknown }
        guard let data = objects[key] else { return .absent }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return .present(size: Int64(data.count), sha256: try! FileHash.sha256(of: file))
    }

    func remove(_ key: String) async -> Bool {
        if removeFails { return false }
        lock.withLock { removes.append(key); stored[key] = nil }
        return true
    }

    func playbackURL(_ key: String, expires: Int) -> URL? { URL(string: "https://fake.example.com/\(key)") }
    func check() async -> Bool { !silent }
}

/// Recordings in an R2 bucket, and a server that becomes the place for them.
final class ArchiveMoveTests: XCTestCase {
    var paths: Paths!
    var server: FakeArchive!
    var archive: CloudArchive!
    var pipeline: Pipeline!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        FakeS3.objects = [:]
        FakeS3.failPuts = false
        FakeS3.onPut = nil
        FakeS3.puts = 0
        FakeS3.down = false
        FakeS3.deletes = []
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        server = FakeArchive(.server)
        archive = make(target: .server)
        pipeline = Pipeline(paths: paths, transcriber: FakeTranscriber(), library: VoiceLibrary(directory: paths.voices),
                            embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(), summarizer: nil, notify: { _ in })
    }

    func make(target: ArchiveKind?, bucket: Bool = true) -> CloudArchive {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3.self]
        let session = URLSession(configuration: configuration)
        let config = S3Config(endpoint: URL(string: "https://abc.r2.cloudflarestorage.com")!, bucket: "mossad", region: "auto",
                              accessKeyID: "id", secret: "secret", pathStyle: true)
        let places: [any ArchiveBackend] = (bucket ? [BucketArchive(config: config, session: session)] : []) + [server]
        return CloudArchive(target: target, places: places, paths: paths, session: session, retryPause: .zero)
    }

    /// A written call. `inBucket` puts its recording in the bucket and marks the record; `local` keeps the file here.
    @discardableResult
    func call(_ id: String, inBucket: Bool = false, local: Bool = true, endedDaysAgo days: Double = 1) throws -> URL {
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let end = now.addingTimeInterval(-days * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: end.addingTimeInterval(-600), end: end, status: .written)
        let audio = Data("audio-\(id)".utf8)
        if inBucket {
            FakeS3.objects["/mossad/calls/\(id)/recording.m4a"] = audio
            r.cloudKey = "calls/\(id)/recording.m4a"
            r.cloudSize = Int64(audio.count)
        }
        try r.save(to: dir)
        if local { try audio.write(to: Recording.url(in: dir)) }
        return dir
    }

    func record(_ id: String) throws -> CallRecord { try CallRecord.load(from: paths.callDirectory(id)) }

    // MARK: Two places at once

    func testANewRecordingGoesToTheServerAndTheRecordNamesIt() async throws {
        try call("new")
        let report = await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(server.objects["recordings/new/recording.m4a"], Data("audio-new".utf8))
        XCTAssertTrue(FakeS3.objects.isEmpty)
        let r = try record("new")
        XCTAssertEqual(r.cloudKey, "recordings/new/recording.m4a")
        XCTAssertEqual(r.cloudBackend, "server")
        XCTAssertEqual(r.cloudSize, 9)
        XCTAssertEqual(r.archived, ArchivedObject(key: "recordings/new/recording.m4a", kind: .server))
    }

    func testARecordingInTheBucketStaysThereWhenTheServerIsChosen() async throws {
        try call("old", inBucket: true, endedDaysAgo: 40)
        let report = await archive.sync(keepLocalDays: 30, now: now, pipeline: pipeline)
        XCTAssertEqual(report.uploaded, 0)
        XCTAssertTrue(server.puts.isEmpty, "nothing moves by itself")
        let r = try record("old")
        XCTAssertEqual(r.cloudKey, "calls/old/recording.m4a")
        XCTAssertNil(r.cloudBackend)
        XCTAssertEqual(r.archived?.kind, .bucket)
        // The bucket copy is still trusted: the local copy goes after the keep period.
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory("old")).path))
        XCTAssertEqual(archive.playbackURL(for: r)?.host, "abc.r2.cloudflarestorage.com")
    }

    func testEachRecordingPlaysFromItsOwnPlace() throws {
        var onServer = CallRecord(id: "s", platform: .meet, bundleID: "x", start: now, end: now, status: .written)
        onServer.cloudKey = "recordings/s/recording.m4a"
        onServer.cloudBackend = "server"
        XCTAssertEqual(archive.playbackURL(for: onServer)?.host, "fake.example.com")
        // The place is not set up any more: no link, and no crash.
        var inBucket = onServer
        inBucket.cloudKey = "calls/s/recording.m4a"
        inBucket.cloudBackend = nil
        XCTAssertNil(make(target: .server, bucket: false).playbackURL(for: inBucket))
        // A place that a newer build added is not guessed at.
        var future = onServer
        future.cloudBackend = "glacier"
        XCTAssertNil(archive.playbackURL(for: future))
    }

    /// An older build saves a record without the place's name. A key under recordings/ still says "server".
    func testAServerKeyWithoutAPlaceNameIsStillOnTheServer() {
        var r = CallRecord(id: "s", platform: .meet, bundleID: "x", start: now, end: now, status: .written)
        r.cloudKey = "recordings/s/recording.m4a"
        XCTAssertEqual(r.archived?.kind, .server)
        r.cloudKey = "calls/s/recording.m4a"
        XCTAssertEqual(r.archived?.kind, .bucket)
        r.cloudKey = nil
        XCTAssertNil(r.archived)
    }

    func testABucketRecordIsSavedAsBeforeAndAnOlderRecordStillLoads() async throws {
        let dir = try call("one")
        await pipeline.setCloudKey(callID: "one", key: "calls/one/recording.m4a", size: 9)
        let text = try String(contentsOf: dir.appendingPathComponent(CallRecord.fileName), encoding: .utf8)
        XCTAssertFalse(text.contains("cloudBackend"))
        XCTAssertFalse(text.contains("cloudLeftovers"))
        XCTAssertEqual(try record("one").archived, ArchivedObject(key: "calls/one/recording.m4a", kind: .bucket))
    }

    func testARecordingTooLargeForTheServerStaysOnThisMac() async throws {
        server.maxBytes = 5
        let dir = try call("long", endedDaysAgo: 400)
        let report = await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertEqual(report.tooLarge, ["long"])
        XCTAssertEqual(report.uploaded, 0)
        XCTAssertTrue(server.puts.isEmpty, "no upload is tried")
        XCTAssertNil(try record("long").cloudKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path), "the only copy stays")
    }

    func testAnUploadThatFailsForAMomentIsTriedOnceMore() async throws {
        try call("one")
        server.putErrors = [URLError(.networkConnectionLost)]
        let report = await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(server.puts.count, 2)
        // A refusal is not tried again in the same pass, and the local copy stays.
        let dir = try call("two", endedDaysAgo: 90)
        server.putErrors = [ServerError.wrongSecret]
        let second = await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertEqual(second.failed, ["two"])
        XCTAssertEqual(server.puts.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path))
    }

    func testWithNoPlaceChosenNothingIsUploadedOrRemoved() async throws {
        let dir = try call("one", endedDaysAgo: 90)
        let none = make(target: nil)
        let report = await none.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertEqual(report, CloudArchive.Report())
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path))
        XCTAssertFalse(none.hasTarget)
    }

    func testADeletedMeetingLeavesNothingInEitherPlace() async throws {
        try call("one", inBucket: true)
        var r = try record("one")
        // As after a move that has not removed the old copies yet.
        server.objects["recordings/one/recording.m4a"] = Data("audio-one".utf8)
        r.cloudLeftovers = [r.archived!]
        r.cloudKey = "recordings/one/recording.m4a"
        r.cloudBackend = "server"
        await archive.delete(r)
        XCTAssertTrue(server.objects.isEmpty)
        XCTAssertTrue(FakeS3.objects.isEmpty)
    }

    /// A recording that changed after its upload to the bucket goes to the server, and the bucket's old bytes go.
    func testAChangedRecordingGoesToTheNewPlaceAndItsOldCopyIsRemoved() async throws {
        let dir = try call("one", inBucket: true)
        try Data("audio-one-and-part-two".utf8).write(to: Recording.url(in: dir))
        let report = await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(server.objects["recordings/one/recording.m4a"], Data("audio-one-and-part-two".utf8))
        XCTAssertTrue(FakeS3.objects.isEmpty)
        let r = try record("one")
        XCTAssertEqual(r.archived?.kind, .server)
        XCTAssertNil(r.cloudLeftovers)
    }

    /// After a merge the first part's old upload is a leftover. A new upload to the same key replaces its bytes,
    /// and must not be deleted as "the old copy".
    func testAMergedRecordingUploadedToTheSameKeyIsNotDeleted() async throws {
        let bucketOnly = CloudArchive(target: .bucket, places: archive.places.values.filter { $0.kind == .bucket }, paths: paths, retryPause: .zero)
        let dir = try call("one", inBucket: true)
        var r = try record("one")
        let merged = MeetingMerge.combine([r, CallRecord(id: "two", platform: .meet, bundleID: "x", start: r.end.addingTimeInterval(5), end: r.end.addingTimeInterval(60), status: .written)],
                                          durations: ["one": 600, "two": 55])
        XCTAssertNil(merged.cloudKey)
        XCTAssertEqual(merged.cloudLeftovers, [ArchivedObject(key: "calls/one/recording.m4a", kind: .bucket)])
        r = merged
        r.status = .written
        try r.save(to: dir)
        try Data("joined-audio".utf8).write(to: Recording.url(in: dir))
        await bucketOnly.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertEqual(FakeS3.objects["/mossad/calls/one/recording.m4a"], Data("joined-audio".utf8))
        XCTAssertNil(try record("one").cloudLeftovers)
        XCTAssertTrue(FakeS3.deletes.isEmpty)
    }

    /// With the server chosen, the joined recording goes there and the first part's bucket copy is removed.
    func testAMergedRecordingInANewPlaceRemovesTheOldCopyOfItsFirstPart() async throws {
        let dir = try call("one", inBucket: true)
        var r = try record("one")
        r.cloudLeftovers = [r.archived!]
        r.cloudKey = nil
        r.cloudSize = nil
        try r.save(to: dir)
        try Data("joined-audio".utf8).write(to: Recording.url(in: dir))
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertEqual(server.objects["recordings/one/recording.m4a"], Data("joined-audio".utf8))
        XCTAssertTrue(FakeS3.objects.isEmpty)
        XCTAssertNil(try record("one").cloudLeftovers)
    }

    // MARK: The move

    func testAMoveCopiesChecksAndOnlyThenRemovesTheOldCopies() async throws {
        try call("here", inBucket: true)
        try call("away", inBucket: true, local: false)
        try call("never")
        let progress = Progress()
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline) { done, total in progress.note(done, total) }
        XCTAssertEqual(report.total, 2)
        XCTAssertEqual(report.moved, 2)
        XCTAssertEqual(report.removed, 2)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(server.objects["recordings/here/recording.m4a"], Data("audio-here".utf8))
        XCTAssertEqual(server.objects["recordings/away/recording.m4a"], Data("audio-away".utf8), "read from the bucket")
        XCTAssertTrue(FakeS3.objects.isEmpty)
        for id in ["here", "away"] {
            let r = try record(id)
            XCTAssertEqual(r.archived, ArchivedObject(key: "recordings/\(id)/recording.m4a", kind: .server))
            XCTAssertEqual(r.cloudSize, Int64("audio-\(id)".utf8.count))
            XCTAssertNil(r.cloudLeftovers)
        }
        XCTAssertNil(try record("never").cloudKey, "a move copies backups; the next upload pass sends the rest")
        XCTAssertEqual(progress.last?.0, 2)
        XCTAssertEqual(progress.last?.1, 2)
        XCTAssertEqual(report.summary(old: "Cloudflare R2", new: "your server"), "Moved 2 recordings to your server. Removed 2 old copies from Cloudflare R2.")
        XCTAssertEqual(CloudArchive.leftToMove(ProcessingQueue(paths: paths).allRecords(), from: .bucket), 0)
    }

    func testNothingIsRemovedFromTheBucketWhileOneRecordingIsNotCopied() async throws {
        try call("a", inBucket: true)
        try call("b", inBucket: true)
        try call("c", inBucket: true)
        // The upload of the second one is refused; a refusal is not tried again in the same run.
        var uploads = 0
        server.onPut = { [server] in
            uploads += 1
            if uploads == 2 { server!.putErrors = [ServerError.http(403, "")] }
        }
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(report.moved, 2)
        XCTAssertEqual(report.waiting.count, 1)
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(FakeS3.objects.count, 3, "every old copy stays until the whole move is checked")
        XCTAssertTrue(FakeS3.deletes.allSatisfy { $0.contains("mossad-check-") })
        let waiting = try record(report.waiting[0])
        XCTAssertEqual(waiting.archived?.kind, .bucket, "its record still names the bucket")
        XCTAssertEqual(report.summary(old: "Cloudflare R2", new: "your server"),
                       "Moved 2 of 3 recordings to your server. 1 could not be copied yet. Nothing was removed from Cloudflare R2.")
        XCTAssertEqual(CloudArchive.leftToMove(ProcessingQueue(paths: paths).allRecords(), from: .bucket), 3)

        // The next run copies the one that is left, and then removes all three old copies.
        server.onPut = nil
        let again = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(again.total, 1)
        XCTAssertEqual(again.moved, 1)
        XCTAssertEqual(again.removed, 3)
        XCTAssertTrue(again.complete)
        XCTAssertTrue(FakeS3.objects.isEmpty)
        XCTAssertEqual(server.objects.count, 3)
    }

    func testACopyThatTheServerDamagedIsNotTrusted() async throws {
        try call("one", inBucket: true)
        server.damages = true
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(report.waiting, ["one"])
        XCTAssertFalse(report.complete)
        let r = try record("one")
        XCTAssertEqual(r.archived, ArchivedObject(key: "calls/one/recording.m4a", kind: .bucket))
        XCTAssertNil(r.cloudLeftovers)
        XCTAssertNotNil(FakeS3.objects["/mossad/calls/one/recording.m4a"])
    }

    func testARunThatStoppedAfterTheUploadDoesNotSendTheFileAgain() async throws {
        try call("one", inBucket: true, local: false)
        server.objects["recordings/one/recording.m4a"] = Data("audio-one".utf8)
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.moved, 1)
        XCTAssertTrue(server.puts.isEmpty)
    }

    func testARunThatStoppedBeforeTheOldCopiesWereRemovedFinishesTheJob() async throws {
        try call("one", inBucket: true)
        _ = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        // As if the app quit after the record changed and before the old copy went.
        FakeS3.objects["/mossad/calls/one/recording.m4a"] = Data("audio-one".utf8)
        var r = try record("one")
        r.cloudLeftovers = [ArchivedObject(key: "calls/one/recording.m4a", kind: .bucket)]
        try r.save(to: paths.callDirectory("one"))
        XCTAssertEqual(CloudArchive.leftToMove([r], from: .bucket), 1)
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(report.total, 0)
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.complete)
        XCTAssertTrue(FakeS3.objects.isEmpty)
        XCTAssertEqual(report.summary(old: "Amazon S3", new: "your server"), "Every backup is on your server. Removed the old copy from Amazon S3.")
    }

    /// The old copy goes only while the server still says that it has the file.
    func testAnOldCopyStaysWhenTheServerLostTheNewOne() async throws {
        try call("one", inBucket: true, local: false)
        _ = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        FakeS3.objects["/mossad/calls/one/recording.m4a"] = Data("audio-one".utf8)
        var r = try record("one")
        r.cloudLeftovers = [ArchivedObject(key: "calls/one/recording.m4a", kind: .bucket)]
        try r.save(to: paths.callDirectory("one"))
        server.objects = [:]
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.removed, 0)
        XCTAssertNotNil(FakeS3.objects["/mossad/calls/one/recording.m4a"])
    }

    func testABucketThatDoesNotAnswerMovesNothingAndLosesNothing() async throws {
        try call("one", inBucket: true, local: false)
        FakeS3.down = true
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(report.waiting, ["one"])
        XCTAssertTrue(report.missing.isEmpty, "unknown is not absent")
        XCTAssertFalse(report.complete)
        XCTAssertTrue(server.puts.isEmpty)
        XCTAssertEqual(try record("one").archived?.kind, .bucket)
    }

    func testARecordingThatIsInNoPlaceIsNamedAndDoesNotHoldUpTheRest() async throws {
        try call("gone", inBucket: true, local: false)
        try call("fine", inBucket: true)
        FakeS3.objects["/mossad/calls/gone/recording.m4a"] = nil
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(report.missing, ["gone"])
        XCTAssertEqual(report.moved, 1)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(try record("gone").cloudKey, "calls/gone/recording.m4a", "its record is left as it was")
        XCTAssertEqual(report.summary(old: "Cloudflare R2", new: "your server"),
                       "Moved 1 recording to your server. Removed the old copy from Cloudflare R2. 1 was not in Cloudflare R2 and had no copy to move.")
    }

    func testARecordingTooLargeForTheServerStaysInTheBucketAndTheMoveIsNotDone() async throws {
        try call("long", inBucket: true)
        try call("short", inBucket: true)
        FakeS3.objects["/mossad/calls/short/recording.m4a"] = Data("a".utf8)
        var r = try record("short")
        r.cloudSize = 1
        try r.save(to: paths.callDirectory("short"))
        try Data("a".utf8).write(to: Recording.url(in: paths.callDirectory("short")))
        server.maxBytes = 5
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(report.tooLarge, ["long"])
        XCTAssertEqual(report.moved, 1)
        XCTAssertFalse(report.complete)
        XCTAssertEqual(FakeS3.objects.count, 2)
        XCTAssertEqual(try record("long").archived?.kind, .bucket)
    }

    /// The local file is newer than the bucket's copy (a merge): the old bytes are not copied over it.
    func testAChangedRecordingWaitsForItsOwnUpload() async throws {
        let dir = try call("one", inBucket: true)
        try Data("audio-one-joined".utf8).write(to: Recording.url(in: dir))
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(report.waiting, ["one"])
        XCTAssertTrue(server.puts.isEmpty)
        // The upload pass of a move in progress sends the new file and keeps the old copy for the end.
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline, holdLeftovers: true)
        XCTAssertEqual(server.objects["recordings/one/recording.m4a"], Data("audio-one-joined".utf8))
        XCTAssertNotNil(FakeS3.objects["/mossad/calls/one/recording.m4a"])
        let done = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertTrue(done.complete)
        XCTAssertEqual(done.removed, 1)
        XCTAssertTrue(FakeS3.objects.isEmpty)
    }

    /// A record that cannot be read may name a copy in the bucket. Nothing is removed and the move is not done.
    func testARecordThatCannotBeReadHoldsTheOldCopiesInPlace() async throws {
        try call("fine", inBucket: true)
        let damaged = try call("damaged", inBucket: true, local: false)
        try Data("{ not json".utf8).write(to: damaged.appendingPathComponent(CallRecord.fileName))
        // A folder with no record at all is not a meeting, and holds nothing up.
        try FileManager.default.createDirectory(at: paths.callDirectory("empty"), withIntermediateDirectories: true)
        let report = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertEqual(report.moved, 1)
        XCTAssertEqual(report.unreadable, ["damaged"])
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(FakeS3.objects.count, 2, "also the copy of the one that was moved stays until the end")
        XCTAssertEqual(report.summary(old: "Cloudflare R2", new: "your server"),
                       "Moved 1 of 1 recording to your server. 1 meeting on this Mac could not be read, so its backup is not known. Nothing was removed from Cloudflare R2.")
        try FileManager.default.removeItem(at: damaged)
        let again = await archive.move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertTrue(again.complete)
        XCTAssertEqual(again.removed, 1)
    }

    func testAMoveWithNothingInTheBucketIsDoneAtOnce() async throws {
        try call("one")
        let report = await make(target: .server, bucket: false).move(from: .bucket, to: .server, pipeline: pipeline)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.total, 0)
        XCTAssertEqual(report.summary(old: "Cloudflare R2", new: "your server"), "Every backup is on your server. Nothing is left in Cloudflare R2.")
    }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(Int, Int)] = []
    func note(_ done: Int, _ total: Int) { lock.withLock { seen.append((done, total)) } }
    var last: (Int, Int)? { lock.withLock { seen.last } }
}

final class BackupSettingsTests: XCTestCase {
    func testTheServerIsOfferedOnlyWhenOneIsConnected() {
        XCTAssertEqual(BackupChoice.offered(serverConnected: false, current: .none), [.none, .r2, .s3])
        XCTAssertEqual(BackupChoice.offered(serverConnected: true, current: .r2), [.none, .server, .r2, .s3])
        XCTAssertEqual(BackupChoice.offered(serverConnected: false, current: .server), [.none, .server, .r2, .s3], "the choice in use always shows")
    }

    func testTheSavedWordsAreTheOnesFromBeforeTheServer() {
        XCTAssertEqual(BackupChoice(rawValue: "local"), BackupChoice.none)
        XCTAssertEqual(BackupChoice(rawValue: "r2"), .r2)
        XCTAssertEqual(BackupChoice(rawValue: "s3"), .s3)
        XCTAssertEqual(BackupSettings(choice: "nonsense").choice, BackupChoice.none)
        XCTAssertNil(BackupChoice.none.target)
        XCTAssertEqual(BackupChoice.server.target, .server)
        XCTAssertEqual(BackupChoice.r2.target, .bucket)
    }

    func testTheBucketStaysReadableAfterTheOwnerChoosesTheServer() throws {
        let r2 = BackupSettings(choice: "server", bucketKind: "r2", endpoint: " https://abc.r2.cloudflarestorage.com ", bucket: "mossad", region: "us-east-1", accessKeyID: "id")
        let config = try XCTUnwrap(r2.bucketConfig(secret: "s"))
        XCTAssertEqual(config.region, "auto")
        XCTAssertTrue(config.pathStyle)
        XCTAssertEqual(config.endpoint.host, "abc.r2.cloudflarestorage.com")
        let s3 = BackupSettings(choice: "local", bucketKind: "s3", endpoint: "https://s3.eu-west-1.amazonaws.com", bucket: "mossad", region: "eu-west-1", accessKeyID: "id")
        XCTAssertEqual(s3.bucketConfig(secret: "s")?.region, "eu-west-1")
        XCTAssertEqual(s3.bucketConfig(secret: "s")?.pathStyle, false)
        // Nothing remembered: the address says which one it is.
        XCTAssertEqual(BackupSettings(choice: "server", endpoint: "https://abc.r2.cloudflarestorage.com", bucket: "b", accessKeyID: "id").bucketFlavor, .r2)
        XCTAssertEqual(BackupSettings(choice: "server", endpoint: "https://s3.us-east-1.amazonaws.com", bucket: "b", accessKeyID: "id").bucketFlavor, .s3)
        XCTAssertEqual(BackupSettings(choice: "s3", bucketKind: "r2", endpoint: "https://abc.r2.cloudflarestorage.com", bucket: "b", accessKeyID: "id").bucketFlavor, .s3)
    }

    func testABucketWithAMissingPartIsNotSetUp() {
        XCTAssertNil(BackupSettings(choice: "r2", endpoint: "https://abc.r2.cloudflarestorage.com", bucket: "", accessKeyID: "id").bucketConfig(secret: "s"))
        XCTAssertNil(BackupSettings(choice: "r2", endpoint: "not an address", bucket: "b", accessKeyID: "id").bucketConfig(secret: "s"))
        XCTAssertNil(BackupSettings(choice: "r2", endpoint: "https://abc.r2.cloudflarestorage.com", bucket: "b", accessKeyID: "id").bucketConfig(secret: nil))
        XCTAssertNil(BackupSettings(choice: "r2", endpoint: "https://abc.r2.cloudflarestorage.com", bucket: "b", accessKeyID: "id").bucketConfig(secret: ""))
        XCTAssertTrue(BackupSettings(choice: "local", endpoint: "https://abc.r2.cloudflarestorage.com", bucket: "b", accessKeyID: "id").hasBucket)
    }

    func testTheCountsSayWhereTheRecordingsAre() {
        let now = Date()
        func record(_ id: String, key: String? = nil, backend: String? = nil, status: CallStatus = .written) -> CallRecord {
            var r = CallRecord(id: id, platform: .meet, bundleID: "x", start: now, end: now, status: status)
            r.cloudKey = key
            r.cloudBackend = backend
            return r
        }
        var moved = record("d", key: "recordings/d/recording.m4a", backend: "server")
        moved.cloudLeftovers = [ArchivedObject(key: "calls/d/recording.m4a", kind: .bucket)]
        let counts = BackupCounts([record("a", key: "calls/a/recording.m4a"), record("b", key: "recordings/b/recording.m4a", backend: "server"),
                                   record("c"), record("live", status: .recording), moved])
        XCTAssertEqual(counts.inBucket, 1)
        XCTAssertEqual(counts.onServer, 2)
        XCTAssertEqual(counts.notBackedUp, 1)
        XCTAssertEqual(counts.leftovers, 1)
    }
}
