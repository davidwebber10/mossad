import XCTest
@testable import MossadCore

/// The check after a meeting, end to end on a made-up folder, with a fake model.
final class SeriesRunnerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func call(_ id: String, daysAgo: Double, lines: [(Int, Double, String)] = [(0, 5, "Hello all"), (1, 20, "Hello")]) -> CallRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.calendarTitle = "Platform TB"
        r.speakerNames = ["me:A": "Dana Lee", "them:1": "Sam Carter"]
        r.utterances = lines.map { s, at, text in Utterance(track: s == 0 ? .me : .them, speakerLabel: s == 0 ? "A" : "\(s)", start: at, end: at + 10, text: text) }
        return r
    }

    func testTheRunnerFindsTheSeriesOfAMeetingWrittenJustNow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        let earlier = [call("a", daysAgo: 21), call("b", daysAgo: 14)]
        let new = call("c", daysAgo: 1, lines: [(1, 60, "About the API sunset next year, the plan is to move everything by March."), (0, 90, "Good.")])
        for r in earlier + [new] {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        // The point was made for the series as it was before the new meeting.
        let before = SeriesCatalog.build(records: earlier, upcoming: [], owner: "Dana Lee", directory: PersonDirectory())
        var book = NextTimeBook()
        book.add("API sunset plan", series: before[0], at: now.addingTimeInterval(-10 * 86_400))
        try book.save(to: paths.nextTime)

        let model = FakeModel(output: ["points": [["point": "P1", "discussed": true, "quote": "the API sunset next year, the plan is to move everything"]]])
        let runner = NextTimeRunner(paths: paths, checker: NextTimeChecker(llm: model), now: { [now] in now })
        // The app's catalog can be old or empty: the runner makes its own from the records on disk.
        await runner.run(upcoming: [], owner: "Dana Lee", directory: PersonDirectory()) { false }
        let after = try NextTimeBook.load(from: paths.nextTime)
        XCTAssertEqual(after.points[0].done?.callID, "c")
        XCTAssertEqual(after.points[0].done?.quote, "the API sunset next year, the plan is to move everything")
        XCTAssertTrue(after.checked.contains("c"))
        // A meeting with nothing to check is not marked as checked.
        XCTAssertFalse(after.checked.contains("a"))
    }

    func testTheRunnerStopsWhileACallRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        for r in [call("a", daysAgo: 21), call("b", daysAgo: 1)] {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        var book = NextTimeBook()
        book.add("Hiring", series: SeriesCatalog.build(records: [call("a", daysAgo: 21), call("b", daysAgo: 1)], upcoming: [], owner: "Dana Lee", directory: PersonDirectory())[0],
                 at: now.addingTimeInterval(-10 * 86_400))
        try book.save(to: paths.nextTime)
        let model = FailingCheckModel()
        await NextTimeRunner(paths: paths, checker: NextTimeChecker(llm: model), now: { [now] in now })
            .run(upcoming: [], owner: "Dana Lee", directory: PersonDirectory()) { true }
        XCTAssertEqual(model.calls, 0)
        XCTAssertTrue(try NextTimeBook.load(from: paths.nextTime).checked.isEmpty)
    }
}
