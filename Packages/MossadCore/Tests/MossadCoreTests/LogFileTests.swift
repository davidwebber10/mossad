import XCTest
@testable import MossadCore

final class LogFileTests: XCTestCase {
    func testAReadOnlyRunWritesNoLinesToTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (before, wrote) = (Log.directory, Log.writesFile)
        defer { Log.directory = before; Log.writesFile = wrote }
        Log.directory = dir
        Log.writesFile = false
        Log.info("Mossad started")
        Log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mossad.log").path))
        Log.writesFile = true
        Log.info("Mossad started")
        Log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mossad.log").path))
    }

    private func withLog(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (before, wrote) = (Log.directory, Log.writesFile)
        defer {
            Log.flush()
            Log.directory = before
            Log.writesFile = wrote
            try? FileManager.default.removeItem(at: dir)
        }
        Log.directory = dir
        Log.writesFile = true
        try body(dir.appendingPathComponent("mossad.log"))
    }

    private func messages(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { String($0.split(separator: " ", maxSplits: 2).last ?? "") }
    }

    func testLinesLandInOrderInOneFile() throws {
        try withLog { url in
            for i in 0..<50 { Log.info("line \(i)") }
            Log.flush()
            XCTAssertEqual(try messages(url), (0..<50).map { "line \($0)" })
        }
    }

    /// The file stays open between lines, so a file that was deleted or moved away must be noticed.
    func testADeletedFileIsMadeAgain() throws {
        try withLog { url in
            Log.info("first")
            Log.flush()
            try FileManager.default.removeItem(at: url)
            Log.info("second")
            Log.flush()
            XCTAssertEqual(try messages(url), ["second"])
        }
    }

    func testAFileThatAnotherProcessRotatedIsNotWrittenToAnyMore() throws {
        try withLog { url in
            Log.info("first")
            Log.flush()
            let rotated = url.deletingLastPathComponent().appendingPathComponent("mossad.1.log")
            try FileManager.default.moveItem(at: url, to: rotated)
            Log.info("second")
            Log.flush()
            XCTAssertEqual(try messages(url), ["second"])
            XCTAssertEqual(try messages(rotated), ["first"])
        }
    }

    func testAnotherWriterToTheSameFileLosesNoLine() throws {
        try withLog { url in
            Log.info("first")
            Log.flush()
            let other = try FileHandle(forWritingTo: url)
            other.seekToEndOfFile()
            other.write(Data("2026-11-09T10:00:00Z INFO from the other process\n".utf8))
            try other.close()
            Log.info("third")
            Log.flush()
            XCTAssertEqual(try messages(url), ["first", "from the other process", "third"])
        }
    }

    func testAFullFileIsRotated() throws {
        try withLog { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 5 * 1024 * 1024 + 1).write(to: url)
            Log.info("after")
            Log.flush()
            XCTAssertEqual(try messages(url), ["after"])
            let rotated = url.deletingLastPathComponent().appendingPathComponent("mossad.1.log")
            XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: rotated.path)[.size] as? Int ?? 0, 5 * 1024 * 1024)
            // And while the file is open: it grows over the limit, and the next line starts a new file.
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(Data(repeating: 0x62, count: 5 * 1024 * 1024 + 1))
            try handle.close()
            Log.info("again")
            Log.flush()
            XCTAssertEqual(try messages(url), ["again"])
        }
    }

    /// The Log page read the whole file (up to 5 MB) every 2 s to show 500 lines.
    func testTheTailStartsAtAWholeLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = (0..<1000).map { "line \($0) caf\u{00E9}" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let tail = try XCTUnwrap(Log.tail(of: url, bytes: 2_000))
        let got = tail.split(separator: "\n").map(String.init)
        XCTAssertEqual(got.last, "line 999 caf\u{00E9}")
        XCTAssertEqual(got, Array(lines.suffix(got.count)), "only whole lines, the newest ones")
        XCTAssertGreaterThan(got.count, 100)
        XCTAssertEqual(Log.tail(of: url, bytes: 10_000_000), lines.joined(separator: "\n") + "\n", "a short file comes whole")
        XCTAssertNil(Log.tail(of: url.appendingPathExtension("none")))
    }
}
