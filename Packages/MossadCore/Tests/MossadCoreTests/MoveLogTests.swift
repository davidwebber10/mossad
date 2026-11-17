import XCTest
@testable import MossadCore

/// A moved meeting leaves no line in the first profile's log: neither its id nor its note's file name.
final class MoveLogTests: XCTestCase {
    private let id = "20261101-100000"
    private let note = "2026-11-01 1000 - Zebra budget.md"

    func testTheFilterTakesOnlyTheLinesOfThatMeeting() {
        let text = """
        2026-11-01T10:00:00Z INFO Wrote 2026-11-01 1000 - Zebra budget.md
        2026-11-01T10:00:01Z INFO Wrote 2026-11-01 1100 - Zebra budget review.md
        2026-11-01T10:00:02Z INFO Coach: reviewed 20261101-100000
        2026-11-01T10:00:03Z INFO Coach: reviewed 20261101-100000-moved
        2026-11-01T10:00:04Z INFO Coach: reviewed 20261101-1000001
        2026-11-01T10:00:05Z INFO Sync: 3 meetings

        """
        let out = Log.withoutLines(text, naming: [id, note])
        XCTAssertEqual(out, """
        2026-11-01T10:00:01Z INFO Wrote 2026-11-01 1100 - Zebra budget review.md
        2026-11-01T10:00:03Z INFO Coach: reviewed 20261101-100000-moved
        2026-11-01T10:00:04Z INFO Coach: reviewed 20261101-1000001
        2026-11-01T10:00:05Z INFO Sync: 3 meetings

        """)
        XCTAssertEqual(Log.withoutLines(out, naming: [id, note]), out, "safe to run again")
        XCTAssertEqual(Log.withoutLines("a line with no end", naming: [""]), "a line with no end", "an empty name takes nothing")
    }

    /// Every file of the rotation is rewritten in place, and this process's own open log goes on working.
    func testEachLogFileIsRewrittenAndTheLogGoesOn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MoveLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let before = Log.directory, writes = Log.writesFile
        Log.directory = dir
        Log.writesFile = true
        defer { Log.directory = before; Log.writesFile = writes; try? FileManager.default.removeItem(at: dir) }
        try Data("old line of \(id)\nkept old line\n".utf8).write(to: dir.appendingPathComponent("mossad.2.log"))
        Log.info("Wrote \(note)")
        Log.info("Wrote 2026-11-01 1100 - Zebra budget review.md")
        Log.flush()
        XCTAssertTrue(Log.forget(naming: [id, note], in: dir))
        Log.info("after the rewrite")
        Log.flush()
        let current = try String(contentsOf: dir.appendingPathComponent("mossad.log"), encoding: .utf8)
        XCTAssertFalse(current.contains("Zebra budget.md"))
        XCTAssertTrue(current.contains("Zebra budget review.md"))
        XCTAssertTrue(current.contains("after the rewrite"), "the open handle follows the new file")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("mossad.2.log"), encoding: .utf8), "kept old line\n")
        XCTAssertTrue(Log.forget(naming: [id, note], in: dir), "again: nothing to change, and true")
    }

    /// The removal's folder step takes the meeting's lines out of the profile's own log, and no other meeting's.
    func testTheRemovalTakesTheMeetingsLinesOutOfTheLog() throws {
        let a = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MoveLogTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: a.root) }
        let r = try writtenCall(in: a)
        let other = try writtenCall(in: a, id: id + "-moved")
        let noteName = (r.markdownPath! as NSString).lastPathComponent
        try FileManager.default.createDirectory(at: a.logs, withIntermediateDirectories: true)
        try Data("x INFO Wrote \(noteName)\nx INFO Coach: \(id)\nx INFO Coach: \(other.id)\nx INFO Sync\n".utf8)
            .write(to: a.logs.appendingPathComponent("mossad.log"))
        XCTAssertTrue(MoveRemoval.removeFolder(id, paths: a))
        XCTAssertEqual(try String(contentsOf: a.logs.appendingPathComponent("mossad.log"), encoding: .utf8),
                       "x INFO Coach: \(other.id)\nx INFO Sync\n")
    }
}
