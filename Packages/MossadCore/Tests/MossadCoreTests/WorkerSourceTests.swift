import XCTest

/// The worker's code, read as text: it has no way to ask, post, or show, and it reads the calendar only to match.
final class WorkerSourceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func files(in dir: URL) throws -> [(String, String)] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    private let forbidden = ["import AppKit", "UserNotifications", "ServiceManagement", "Sparkle", "requestAccess", "requestFullAccess",
                             "requestAuthorization", "NSApplication", "WeeklyEmail", "Retention.sweep", "GeminiRunner",
                             "CalendarSnapshot.write", "UsageReportPlan", "SharedAIKey", "ServerPairing.share", "ProfilesItem", "notingSync"]

    func testTheWorkersCodeCannotAskPostOrShow() throws {
        let worker = try files(in: root.appendingPathComponent("Sources/MossadCore/Worker"))
        XCTAssertFalse(worker.isEmpty)
        for (name, text) in worker {
            for word in forbidden { XCTAssertFalse(text.contains(word), "\(name) has \(word)") }
        }
        let entry = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/WorkerEntry.swift")
        let text = try String(contentsOf: entry, encoding: .utf8)
        for word in forbidden + ["AppController", "Notifier"] { XCTAssertFalse(text.contains(word), "WorkerEntry has \(word)") }
    }

    func testTheCalendarIsReadOnlyToMatchAnInvite() throws {
        for (name, text) in try files(in: root.appendingPathComponent("Sources/MossadCore/Worker")) where text.contains(".events(from:") {
            XCTAssertEqual(name, "WorkerCalendar.swift")
        }
        let pipeline = try String(contentsOf: root.appendingPathComponent("Sources/MossadCore/Pipeline/Pipeline.swift"), encoding: .utf8)
        let lines = pipeline.components(separatedBy: "\n")
        var function = ""
        var reads: [String] = [], checks: [String] = []
        for line in lines {
            if let r = line.range(of: #"func ([A-Za-z]+)"#, options: .regularExpression), line.contains("func ") {
                function = String(line[r].dropFirst(5))
            }
            if line.contains("calendar.events(") || line.contains("calendar.read(") { reads.append(function) }
            if line.contains("calendar.canRead()") { checks.append(function) }
        }
        // The invite, and the cut by a recording's marks, which reads the calendar of the recording's own time.
        XCTAssertEqual(reads, ["cutIfNeeded", "invite"])
        // The answer of a read decides; `canRead()` only says whether the launch looks at all.
        XCTAssertEqual(Set(checks), ["matchUnknownInvites", "recheckInvites"])
    }
}
