import XCTest
@testable import MossadCore

/// Against a real Worker on this machine: `npx wrangler dev --config test/wrangler.dev.jsonc` in `server/`, then
/// `MOSSAD_DEV_SERVER=http://localhost:8787 MOSSAD_DEV_SERVER_SECRET=dev-secret swift test --filter LiveServerArchiveTests`.
/// Skipped without the address.
final class LiveServerArchiveTests: XCTestCase {
    func testARecordingGoesUpIsCheckedPlaysFromALinkAndIsRemoved() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["MOSSAD_DEV_SERVER"].flatMap(ServerConnection.address(from:)), let secret = env["MOSSAD_DEV_SERVER_SECRET"] else {
            throw XCTSkip("Set MOSSAD_DEV_SERVER and MOSSAD_DEV_SERVER_SECRET to run this test")
        }
        let connection = ServerConnection(address: address, secret: secret)
        let hello = try await ServerClient(connection).hello()
        let limit = try XCTUnwrap(hello.recordingLimit, "the server keeps recordings")
        let id = try XCTUnwrap(hello.id, "the server names itself")
        let again = try await ServerClient(connection).hello()
        XCTAssertEqual(again.id, id, "with the same id each time")
        let archive = ServerArchive(connection, id: id, maxBytes: limit)
        let ok = await archive.check()
        XCTAssertTrue(ok)

        let file = tempDirectory().appendingPathComponent("recording.m4a")
        var bytes = Data(count: 3_000_000)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: file)
        let hash = try FileHash.sha256(of: file)
        let key = archive.key(for: "live-test-\(UUID().uuidString)")
        try await archive.put(file, key: key, sha256: hash)
        let found = await archive.presence(key)
        XCTAssertEqual(found, .present(size: 3_000_000, sha256: hash))

        // A wrong hash is refused, and the first upload stays.
        do {
            try await archive.put(file, key: key, sha256: String(repeating: "a", count: 64))
            XCTFail("a wrong hash passed")
        } catch { XCTAssertEqual(error as? ServerError, .http(422, "The recording did not arrive whole. Send it again.")) }
        let still = await archive.presence(key)
        XCTAssertEqual(still, .present(size: 3_000_000, sha256: hash))

        // The link plays without the secret in a header, and a byte range works for seeking.
        let link = try XCTUnwrap(archive.playbackURL(key, expires: 600))
        var part = URLRequest(url: link)
        part.setValue("bytes=1000-1999", forHTTPHeaderField: "Range")
        let (slice, response) = try await URLSession.shared.data(for: part)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(slice, bytes.subdata(in: 1000..<2000))
        let copy = try await archive.download(key, session: .shared)
        XCTAssertEqual(try FileHash.sha256(of: copy), hash)
        try? FileManager.default.removeItem(at: copy)

        let gone = await archive.remove(key)
        XCTAssertTrue(gone)
        let after = await archive.presence(key)
        XCTAssertEqual(after, .absent)
    }
}
