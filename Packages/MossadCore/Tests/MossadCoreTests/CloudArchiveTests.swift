import XCTest
@testable import MossadCore

/// Answers S3 requests in memory, so the archive can be tested without a network.
final class FakeS3: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var objects: [String: Data] = [:]
    nonisolated(unsafe) static var failPuts = false
    /// Runs during each upload, to change things while the archive waits.
    nonisolated(unsafe) static var onPut: (() -> Void)?
    nonisolated(unsafe) static var puts = 0
    /// The bucket does not answer: every call fails.
    nonisolated(unsafe) static var down = false
    nonisolated(unsafe) static var deletes: [String] = []
    /// The keys that were downloaded.
    nonisolated(unsafe) static var gets: [String] = []
    /// An ETag to send with a download, as a bucket does for a one-part upload.
    nonisolated(unsafe) static var etags: [String: String] = [:]
    nonisolated(unsafe) static var failDeletes = false
    /// The bucket refuses a list, as it does for a key that may only read and write objects.
    nonisolated(unsafe) static var failLists = false

    static func reset() {
        objects = [:]; failPuts = false; onPut = nil; puts = 0; down = false; deletes = []; gets = []; etags = [:]; failDeletes = false; failLists = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = url.path
        var status = 200
        var body = Data()
        switch request.httpMethod {
        case "PUT":
            Self.puts += 1
            Self.onPut?()
            if Self.failPuts { status = 500 } else { Self.objects[key] = Self.body(of: request) }
        case "DELETE": if Self.failDeletes { status = 500 } else { Self.objects[key] = nil; Self.deletes.append(key); status = 204 }
        case "HEAD": status = Self.objects[key] == nil ? 404 : 200
        default:
            if url.query?.contains("list-type=2") == true {
                // A list of the bucket: the keys under the prefix, as S3 writes them.
                let prefix = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prefix" }?.value ?? ""
                let keys = Self.objects.keys.map { String($0.dropFirst("/mossad/".count)) }.filter { $0.hasPrefix(prefix) }.sorted()
                if Self.failLists { status = 403 } else {
                    body = Data("<?xml version=\"1.0\"?><ListBucketResult><KeyCount>\(keys.count)</KeyCount>\(keys.map { "<Contents><Key>\($0)</Key></Contents>" }.joined())</ListBucketResult>".utf8)
                }
            } else if let data = Self.objects[key] {
                Self.gets.append(key)
                body = data
            } else {
                status = 404
            }
        }
        if Self.down { status = 503; body = Data() }
        var headers = request.httpMethod == "HEAD" && !Self.down ? Self.objects[key].map { ["Content-Length": "\($0.count)"] } : nil
        if request.httpMethod == "GET", let tag = Self.etags[key] { headers = ["ETag": "\"\(tag)\""] }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class CloudArchiveTests: XCTestCase {
    var paths: Paths!
    var archive: CloudArchive!
    var pipeline: Pipeline!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        FakeS3.reset()
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3.self]
        let config = S3Config(endpoint: URL(string: "https://abc.r2.cloudflarestorage.com")!, bucket: "mossad", region: "auto",
                              accessKeyID: "id", secret: "secret", pathStyle: true)
        archive = CloudArchive(config: config, paths: paths, session: URLSession(configuration: configuration), retryPause: .zero)
        pipeline = Pipeline(paths: paths, transcriber: FakeTranscriber(), library: VoiceLibrary(directory: paths.voices),
                            embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(), summarizer: nil, notify: { _ in })
    }

    func call(_ id: String, endedDaysAgo days: Double, status: CallStatus = .written) throws -> URL {
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let end = now.addingTimeInterval(-days * 86_400)
        try CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: end.addingTimeInterval(-600), end: end, status: status).save(to: dir)
        try Data("audio-\(id)".utf8).write(to: Recording.url(in: dir))
        return dir
    }

    func testUploadsFinishedRecordingsAndMarksThem() async throws {
        let dir = try call("one", endedDaysAgo: 0)
        _ = try call("live", endedDaysAgo: 0, status: .recording)
        let uploaded = await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertEqual(uploaded.uploaded, 1)
        XCTAssertEqual(FakeS3.objects["/mossad/calls/one/recording.m4a"], Data("audio-one".utf8))
        XCTAssertEqual(try CallRecord.load(from: dir).cloudKey, "calls/one/recording.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path), "the local copy stays")
    }

    func testDeletesTheLocalCopyOnlyAfterUploadAndTheKeepPeriod() async throws {
        let old = try call("old", endedDaysAgo: 10)
        let recent = try call("recent", endedDaysAgo: 2)
        await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: old).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: recent).path))
    }

    func testAFailedUploadKeepsTheLocalCopy() async throws {
        FakeS3.failPuts = true
        let old = try call("old", endedDaysAgo: 10)
        let uploaded = await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertEqual(uploaded.uploaded, 0)
        XCTAssertEqual(uploaded.failed, ["old"])
        XCTAssertNil(try CallRecord.load(from: old).cloudKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: old).path))
    }

    /// A title set during a long upload stays: the archive saves only its key, through the pipeline.
    func testAnEditMadeDuringTheUploadStays() async throws {
        let dir = try call("one", endedDaysAgo: 0)
        FakeS3.onPut = {
            var r = try! CallRecord.load(from: dir)
            r.customTitle = "Freight review"
            try! r.save(to: dir)
        }
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        let r = try CallRecord.load(from: dir)
        XCTAssertEqual(r.customTitle, "Freight review")
        XCTAssertEqual(r.cloudKey, "calls/one/recording.m4a")
        XCTAssertEqual(r.cloudSize, 9)
    }

    /// A merge writes a new, longer recording. The old upload is not that file, so it goes up again, and the
    /// local copy stays until it has.
    func testARecordingThatChangedAfterTheUploadGoesUpAgainBeforeTheLocalCopyIsRemoved() async throws {
        let dir = try call("old", endedDaysAgo: 10)
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        try Data("audio-old-and-part-two".utf8).write(to: Recording.url(in: dir))
        FakeS3.failPuts = true
        await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path), "the bucket holds only the old file")
        FakeS3.failPuts = false
        await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertEqual(FakeS3.objects["/mossad/calls/old/recording.m4a"], Data("audio-old-and-part-two".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: dir).path))
    }

    /// Records archived before sizes were kept: the bucket's own size says whether it holds this file.
    func testAnOlderArchiveMarkIsCheckedAgainstTheBucket() async throws {
        let same = try call("same", endedDaysAgo: 10), longer = try call("longer", endedDaysAgo: 10)
        for dir in [same, longer] {
            var r = try CallRecord.load(from: dir)
            r.cloudKey = "calls/\(r.id)/recording.m4a"
            try r.save(to: dir)
        }
        FakeS3.objects["/mossad/calls/same/recording.m4a"] = Data("audio-same".utf8)
        FakeS3.objects["/mossad/calls/longer/recording.m4a"] = Data("part-one".utf8)
        let uploaded = await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertEqual(uploaded.uploaded, 1)
        XCTAssertEqual(FakeS3.objects["/mossad/calls/longer/recording.m4a"], Data("audio-longer".utf8))
        XCTAssertEqual(try CallRecord.load(from: same).cloudSize, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: same).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: longer).path))
    }

    /// The owner deletes a meeting while its recording goes up: nothing of it stays in the bucket.
    func testAMeetingDeletedDuringItsUploadLeavesNothingInTheBucket() async throws {
        let dir = try call("one", endedDaysAgo: 0)
        FakeS3.onPut = { try! FileManager.default.removeItem(at: dir) }
        let uploaded = await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertEqual(uploaded.uploaded, 0)
        XCTAssertNil(FakeS3.objects["/mossad/calls/one/recording.m4a"])
    }

    /// The mark in a record is not the file. Before the only local copy goes, the bucket is asked.
    func testTheLocalCopyStaysWhenTheBucketDoesNotHaveTheFile() async throws {
        let old = try call("old", endedDaysAgo: 10)
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        // As after an emptied bucket, or a bucket name that now names another bucket.
        FakeS3.objects = [:]
        await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: old).path))
        XCTAssertNil(try CallRecord.load(from: old).cloudKey, "the false mark is gone, so the recording is sent again")
        await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertEqual(FakeS3.objects["/mossad/calls/old/recording.m4a"], Data("audio-old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: old).path), "and only then the local copy goes")
    }

    func testTheLocalCopyStaysWhileTheBucketDoesNotAnswer() async throws {
        let old = try call("old", endedDaysAgo: 10)
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        FakeS3.down = true
        await archive.sync(keepLocalDays: 7, now: now, pipeline: pipeline)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: old).path))
        XCTAssertEqual(try CallRecord.load(from: old).cloudKey, "calls/old/recording.m4a", "unknown is not absent: the mark stays")
    }

    /// A delete that fails (no network) is remembered, and a later pass removes the copy.
    func testABackupCopyThatCouldNotBeDeletedIsTriedAgain() async throws {
        let dir = try call("one", endedDaysAgo: 0)
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        let r = try CallRecord.load(from: dir)
        try FileManager.default.removeItem(at: dir)
        FakeS3.failDeletes = true
        await archive.delete(r)
        XCTAssertNotNil(FakeS3.objects["/mossad/calls/one/recording.m4a"])
        XCTAssertEqual(CloudArchive.pendingDeletes(in: archive.deletesFile), [ArchivedObject(key: "calls/one/recording.m4a", kind: .bucket)])
        FakeS3.failDeletes = false
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertNil(FakeS3.objects["/mossad/calls/one/recording.m4a"])
        XCTAssertTrue(CloudArchive.pendingDeletes(in: archive.deletesFile).isEmpty)
        // With no place set up at the time of the delete, the app remembers it the same way.
        FakeS3.objects["/mossad/calls/one/recording.m4a"] = Data([1])
        CloudArchive.rememberDeletes(of: r, paths: paths)
        await archive.sync(keepLocalDays: nil, now: now, pipeline: pipeline)
        XCTAssertNil(FakeS3.objects["/mossad/calls/one/recording.m4a"])
    }

    func testTheBucketCountsItsRecordings() async throws {
        FakeS3.objects = ["/mossad/calls/a/recording.m4a": Data([1]), "/mossad/calls/b/recording.m4a": Data([1]), "/mossad/other/x": Data([1])]
        let bucket = try XCTUnwrap(archive.places[.bucket])
        let count = await bucket.recordingCount()
        XCTAssertEqual(count, 2)
        FakeS3.failLists = true
        let refused = await bucket.recordingCount()
        XCTAssertNil(refused, "a key that may not list gives no answer, not zero")
    }

    func testPlaybackLinkForAnArchivedRecording() throws {
        var r = CallRecord(id: "one", platform: .meet, bundleID: "x", start: now, end: now, status: .written)
        r.cloudKey = "calls/one/recording.m4a"
        let url = try XCTUnwrap(archive.playbackURL(for: r))
        XCTAssertEqual(url.path, "/mossad/calls/one/recording.m4a")
        XCTAssertTrue(url.query?.contains("X-Amz-Signature=") == true)
    }
}
