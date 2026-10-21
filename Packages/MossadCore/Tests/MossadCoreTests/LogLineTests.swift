import XCTest
@testable import MossadCore

final class LogLineTests: XCTestCase {
    func testParsesTimeLevelAndMessage() {
        let lines = LogLine.parse("2026-10-21T16:51:29Z INFO Wrote note.md\n2026-10-21T16:52:00Z ERROR Summary failed\n")
        XCTAssertEqual(lines, [
            LogLine(date: Date(timeIntervalSince1970: 1_792_601_489), level: .info, message: "Wrote note.md"),
            LogLine(date: Date(timeIntervalSince1970: 1_792_601_520), level: .error, message: "Summary failed"),
        ])
    }

    func testUnknownLevelKeepsTheWordInTheMessage() {
        XCTAssertEqual(LogLine.parse("2026-10-21T16:51:29Z WARN disk low"),
                       [LogLine(date: Date(timeIntervalSince1970: 1_792_601_489), level: .other, message: "WARN disk low")])
        XCTAssertEqual(LogLine.parse("2026-10-21T16:51:29Z DEBUG").first?.level, .debug)
    }

    func testContinuationLinesJoinThePreviousMessage() {
        let text = "2026-10-21T16:51:29Z ERROR Claude HTTP 500: {\n  \"type\": \"error\"\n}\n2026-10-21T16:51:30Z INFO next"
        let lines = LogLine.parse(text)
        XCTAssertEqual(lines.map(\.message), ["Claude HTTP 500: {\n  \"type\": \"error\"\n}", "next"])
    }

    func testTextBeforeAnyTimestampIsItsOwnLine() {
        XCTAssertEqual(LogLine.parse("stray text\n"), [LogLine(date: nil, level: .other, message: "stray text")])
        XCTAssertEqual(LogLine.parse(""), [])
    }
}
