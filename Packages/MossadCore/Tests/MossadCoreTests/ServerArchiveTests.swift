import XCTest
@testable import MossadCore

final class ServerArchiveTests: XCTestCase {
    let connection = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "owner-secret")
    var archive: ServerArchive!
    var file: URL!

    override func setUp() {
        archive = ServerArchive(connection, maxBytes: 1000, session: StubURLProtocol.session())
        file = tempDirectory().appendingPathComponent("recording.m4a")
        try! Data("audio-one".utf8).write(to: file)
    }

    func testTheKeyNamesTheCallUnderRecordings() {
        XCTAssertEqual(archive.key(for: "20261105-090000"), "recordings/20261105-090000/recording.m4a")
        XCTAssertEqual(ServerArchive.name(of: "recordings/20261105-090000/recording.m4a"), "20261105-090000")
        XCTAssertNil(ServerArchive.name(of: "calls/one/recording.m4a"))
        XCTAssertNil(ServerArchive.name(of: "recordings/../recording.m4a/recording.m4a"))
        XCTAssertNil(ServerArchive.name(of: "recordings/a b/recording.m4a"))
        XCTAssertNil(ServerArchive.name(of: "recordings/one.m4a"))
    }

    func testAnUploadSendsTheFileItsHashAndTheSecret() async throws {
        StubURLProtocol.handler = { _ in (200, json(["ok": true, "size": 9])) }
        let hash = try FileHash.sha256(of: file)
        try await archive.put(file, key: archive.key(for: "one"), sha256: hash)
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.url.absoluteString, "https://notes.example.com/api/recordings/one")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer owner-secret")
        XCTAssertEqual(sent.headers["X-Recording-SHA256"], hash)
        XCTAssertEqual(sent.headers["Content-Type"], "audio/mp4")
        XCTAssertEqual(sent.body, Data("audio-one".utf8))
    }

    func testAnUploadThatTheServerDidNotKeepWholeFails() async throws {
        StubURLProtocol.handler = { _ in (200, json(["ok": true, "size": 4])) }
        do {
            try await archive.put(file, key: archive.key(for: "one"), sha256: "x")
            XCTFail("a short upload passed")
        } catch { XCTAssertEqual(error as? ArchiveError, .notWhole) }
    }

    func testAServerErrorIsOneThatPassesAndAWrongSecretIsNot() async throws {
        StubURLProtocol.handler = { _ in (503, Data()) }
        do { try await archive.put(file, key: archive.key(for: "one"), sha256: "x"); XCTFail("no error") } catch {
            XCTAssertTrue(TransientRetry.isTransient(error))
        }
        StubURLProtocol.handler = { _ in (401, Data()) }
        do { try await archive.put(file, key: archive.key(for: "one"), sha256: "x"); XCTFail("no error") } catch {
            XCTAssertEqual(error as? ServerError, .wrongSecret)
            XCTAssertFalse(TransientRetry.isTransient(error))
        }
        XCTAssertTrue(TransientRetry.isTransient(ArchiveError.http(502)))
        XCTAssertFalse(TransientRetry.isTransient(ArchiveError.http(403)))
    }

    func testPresenceReadsTheSizeAndTheHashAndKeepsUnknownApartFromAbsent() async {
        StubURLProtocol.handler = { _ in (200, Data()) }
        StubURLProtocol.responseHeaders = { _ in ["X-Recording-Size": "9", "X-Recording-SHA256": "ABCD"] }
        let found = await archive.presence(archive.key(for: "one"))
        XCTAssertEqual(found, .present(size: 9, sha256: "abcd"))
        XCTAssertEqual(StubURLProtocol.requests.first?.method, "HEAD")
        StubURLProtocol.responseHeaders = nil
        StubURLProtocol.handler = { _ in (404, Data()) }
        let none = await archive.presence(archive.key(for: "one"))
        XCTAssertEqual(none, .absent)
        StubURLProtocol.handler = { _ in (500, Data()) }
        let unknown = await archive.presence(archive.key(for: "one"))
        XCTAssertEqual(unknown, .unknown)
    }

    func testRemoveSaysWhetherTheRecordingIsGone() async {
        StubURLProtocol.handler = { _ in (200, json(["ok": true])) }
        let gone = await archive.remove(archive.key(for: "one"))
        XCTAssertTrue(gone)
        XCTAssertEqual(StubURLProtocol.requests.first?.method, "DELETE")
        StubURLProtocol.handler = { _ in (500, Data()) }
        let kept = await archive.remove(archive.key(for: "one"))
        XCTAssertFalse(kept)
    }

    /// The same numbers are in server/test/recordings.test.ts: the two sides must agree.
    func testAPlaybackLinkCarriesASignatureAndNotTheSecret() throws {
        XCTAssertEqual(ServerArchive.signature(secret: "owner-secret", name: "m1", expires: 1_900_000_000),
                       "b1a6528b814eb22cc4554267b696a0c5c588aba87d7ab9dcc506789e45c315ce")
        let url = try XCTUnwrap(ServerArchive.link(connection, name: "m1", expires: Date(timeIntervalSince1970: 1_900_000_000)))
        XCTAssertEqual(url.absoluteString, "https://notes.example.com/api/recordings/m1?expires=1900000000&signature=b1a6528b814eb22cc4554267b696a0c5c588aba87d7ab9dcc506789e45c315ce")
        XCTAssertFalse(url.absoluteString.contains("owner-secret"))
        XCTAssertNotNil(archive.playbackURL(archive.key(for: "m1"), expires: 3600))
        XCTAssertNil(archive.playbackURL("calls/m1/recording.m4a", expires: 3600))
    }

    func testTheCheckUploadsLooksAndRemovesATestFile() async throws {
        let okHash = try FileHash.sha256(of: { let f = tempDirectory().appendingPathComponent("ok"); try Data("ok".utf8).write(to: f); return f }())
        StubURLProtocol.handler = { r in r.method == "PUT" ? (200, json(["ok": true, "size": 2])) : (200, json(["ok": true])) }
        StubURLProtocol.responseHeaders = { r in r.method == "HEAD" ? ["X-Recording-Size": "2", "X-Recording-SHA256": okHash] : [:] }
        let ok = await archive.check()
        XCTAssertTrue(ok)
        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["PUT", "HEAD", "DELETE"])
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.url.path.hasPrefix("/api/recordings/mossad-check-") })
        StubURLProtocol.handler = { _ in (404, Data()) }
        let old = await archive.check()
        XCTAssertFalse(old, "a server from before it kept recordings")
    }

    func testHelloSaysHowLargeARecordingCanBe() async throws {
        StubURLProtocol.handler = { _ in (200, json(["mossad": true, "authorized": true, "chat": false, "recordings": ["maxBytes": 99_614_720]])) }
        let hello = try await ServerClient(connection, session: StubURLProtocol.session()).hello()
        XCTAssertEqual(hello.recordingLimit, 99_614_720)
        StubURLProtocol.handler = { _ in (200, json(["mossad": true, "authorized": true, "chat": false])) }
        let older = try await ServerClient(connection, session: StubURLProtocol.session()).hello()
        XCTAssertNil(older.recordingLimit)
    }

    func testAFileHashIsTheSHA256OfItsBytes() throws {
        let empty = tempDirectory().appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertEqual(try FileHash.sha256(of: empty), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let abc = tempDirectory().appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        XCTAssertEqual(try FileHash.sha256(of: abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
