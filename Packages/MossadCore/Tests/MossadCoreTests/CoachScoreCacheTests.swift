import XCTest
@testable import MossadCore

final class CoachScoreCacheTests: XCTestCase {
    var root: URL!
    override func setUp() { root = tempDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func review(_ id: String, score: Int?) throws {
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let card = score.map { Scorecard(score: $0, reason: "Clear", dimensions: [], positives: [], negatives: []) }
        try CoachReview(headline: "", overview: "", strengths: [], improvements: [], focusProgress: nil, value: nil, delivery: nil,
                        scorecard: card).save(in: dir)
    }

    /// The iPhone read every review file at each return to the app.
    func testAReviewIsDecodedOnlyWhenItsFileChanged() throws {
        try review("a", score: 4)
        try review("b", score: nil)
        let cache = CoachScoreCache()
        let dir: (String) -> URL = { self.root.appendingPathComponent($0) }
        let first = cache.read(ids: ["a", "b", "c"], directory: dir)
        XCTAssertEqual(first.scores, ["a": 4])
        XCTAssertEqual(cache.decodeCount, 2)
        let second = cache.read(ids: ["c", "b", "a"], directory: dir)
        XCTAssertEqual(second.scores, ["a": 4])
        XCTAssertEqual(second.stamp, first.stamp, "nothing changed")
        XCTAssertEqual(cache.decodeCount, 2, "and nothing was decoded again")

        try review("b", score: 2)
        let third = cache.read(ids: ["a", "b", "c"], directory: dir)
        XCTAssertEqual(third.scores, ["a": 4, "b": 2])
        XCTAssertNotEqual(third.stamp, first.stamp)
        XCTAssertEqual(cache.decodeCount, 3)

        try review("c", score: 5)
        let fourth = cache.read(ids: ["a", "b", "c"], directory: dir)
        XCTAssertEqual(fourth.scores["c"], 5)
        XCTAssertNotEqual(fourth.stamp, third.stamp, "a new review changes the stamp")

        try FileManager.default.removeItem(at: root.appendingPathComponent("a"))
        let fifth = cache.read(ids: ["a", "b", "c"], directory: dir)
        XCTAssertNil(fifth.scores["a"])
        XCTAssertNotEqual(fifth.stamp, fourth.stamp, "a removed review changes it too")
    }
}
