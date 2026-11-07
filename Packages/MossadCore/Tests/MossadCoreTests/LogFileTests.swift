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
}
