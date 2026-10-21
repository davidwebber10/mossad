import XCTest
@testable import MossadCore

final class PathsTests: XCTestCase {
    func testLayoutUnderRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        XCTAssertEqual(paths.meetings, root.appendingPathComponent("Meetings"))
        XCTAssertEqual(paths.audio, root.appendingPathComponent("Audio"))
        XCTAssertEqual(paths.voices, root.appendingPathComponent("Voices"))
        XCTAssertEqual(paths.logs, root.appendingPathComponent("Logs"))
        XCTAssertEqual(paths.callDirectory("abc"), root.appendingPathComponent("Audio/abc"))
        try paths.ensureDirectories()
        for dir in [paths.meetings, paths.audio, paths.voices, paths.logs] {
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        }
    }
}
