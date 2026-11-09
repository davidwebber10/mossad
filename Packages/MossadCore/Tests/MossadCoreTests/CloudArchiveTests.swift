import XCTest
@testable import MossadCore

/// Answers S3 requests in memory, so the archive can be tested without a network.
final class FakeS3: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var objects: [String: Data] = [:]
    nonisolated(unsafe) static var failPuts = false
    /// Runs during each upload, to change things while the archive waits.
    nonisolated(unsafe) static var onPut: (() -> Void)?
    nonisolated(unsafe) static var puts = 0

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
        case "DELETE": Self.objects[key] = nil; status = 204
        case "HEAD": status = Self.objects[key] == nil ? 404 : 200
        default: if let data = Self.objects[key] { body = data } else { status = 404 }
        }
        let headers = request.httpMethod == "HEAD" ? Self.objects[key].map { ["Content-Length": "\($0.count)"] } : nil
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
        FakeS3.objects = [:]
        FakeS3.failPuts = false
        FakeS3.onPut = nil
        FakeS3.puts = 0
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3.self]
        let config = S3Config(endpoint: URL(string: "https://abc.r2.cloudflarestorage.com")!, bucket: "mossad", region: "auto",
                              accessKeyID: "id", secret: "secret", pathStyle: true)
        archive = CloudArchive(config: config, paths: paths, session: URLSession(configuration: configuration))
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
        XCTAssertEqual(uploaded, 1)
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
        XCTAssertEqual(uploaded, 0)
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
        XCTAssertEqual(uploaded, 1)
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
        XCTAssertEqual(uploaded, 0)
        XCTAssertNil(FakeS3.objects["/mossad/calls/one/recording.m4a"])
    }

    func testPlaybackLinkForAnArchivedRecording() throws {
        var r = CallRecord(id: "one", platform: .meet, bundleID: "x", start: now, end: now, status: .written)
        r.cloudKey = "calls/one/recording.m4a"
        let url = try XCTUnwrap(archive.playbackURL(for: r))
        XCTAssertEqual(url.path, "/mossad/calls/one/recording.m4a")
        XCTAssertTrue(url.query?.contains("X-Amz-Signature=") == true)
    }
}
