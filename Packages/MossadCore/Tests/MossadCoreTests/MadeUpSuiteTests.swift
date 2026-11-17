import XCTest

final class MadeUpSuiteTests: XCTestCase {
    func testAMadeUpSuiteKeepsItsFileInATemporaryFolder() throws {
        let made = try MadeUpSuite(self)
        made.defaults.set("Sam Carter", forKey: "ownerName")
        XCTAssertTrue(CFPreferencesAppSynchronize(made.name as CFString))
        XCTAssertTrue(made.name.hasPrefix("/"))
        XCTAssertFalse(made.name.contains("Library/Preferences"))
        XCTAssertEqual(made.defaults.string(forKey: "ownerName"), "Sam Carter")
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let names = try FileManager.default.contentsOfDirectory(atPath: preferences.path)
        let unique = ((made.name as NSString).deletingLastPathComponent as NSString).lastPathComponent
        XCTAssertTrue(unique.hasPrefix("suite-"))
        XCTAssertFalse(names.contains { $0.contains(unique) })
    }
}

/// Settings for a test that leave nothing in `~/Library/Preferences`: a suite named by an absolute path keeps its
/// file in a temporary folder, which the test's teardown removes.
struct MadeUpSuite {
    let name: String
    let defaults: UserDefaults

    init(_ test: XCTestCase) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("suite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        name = dir.appendingPathComponent("settings").path
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let suite = name
        test.addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
