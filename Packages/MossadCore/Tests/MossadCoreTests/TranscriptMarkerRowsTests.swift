import XCTest
@testable import MossadCore

final class TranscriptMarkerRowsTests: XCTestCase {
    private func block(_ id: Int, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptBlock {
        TranscriptBlock(id: id, speaker: "Sam", speakerKey: "them:A", start: start, end: end, lines: [.init(start: start, text: "Hi")])
    }

    func testMarkersBetweenTurnsGoBeforeTheNextTurn() {
        let blocks = [block(0, 0, 10), block(1, 20, 30), block(2, 40, 50)]
        let markers = [TranscriptMarker(offset: 15, text: "Bookmark", isBookmark: true), TranscriptMarker(offset: 35, text: "Paused"),
                       TranscriptMarker(offset: 60, text: "Stopped")]
        let rows = TranscriptMarkerRows.place(markers, blocks: blocks)
        XCTAssertEqual(rows.before[1]?.map(\.marker.offset), [15])
        XCTAssertEqual(rows.before[2]?.map(\.marker.offset), [35])
        XCTAssertNil(rows.before[0])
        XCTAssertEqual(rows.after.map(\.marker.offset), [60])
    }

    func testMarkersAtOneOffsetHaveIDsOfTheirOwnThatNoTurnHas() {
        let blocks = [block(0, 0, 10), block(1, 20, 30)]
        let markers = [TranscriptMarker(offset: 1, text: "Paused"), TranscriptMarker(offset: 1, text: "Screen capture paused"),
                       TranscriptMarker(offset: 15, text: "Bookmark", isBookmark: true), TranscriptMarker(offset: 15, text: "Bookmark", isBookmark: true),
                       TranscriptMarker(offset: 40, text: "Stopped"), TranscriptMarker(offset: 40, text: "Stopped")]
        let rows = TranscriptMarkerRows.place(markers, blocks: [block(0, 2, 10), blocks[1]])
        let all = rows.before.values.flatMap { $0 } + rows.after
        XCTAssertEqual(all.count, 6)
        let ids = all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let turnIDs = Set((0..<100).map { AnyHashable($0) } + (0..<100).map { AnyHashable(Double($0)) })
        XCTAssertTrue(ids.allSatisfy { !turnIDs.contains(AnyHashable($0)) })
    }

    func testBeforeTheTurnsLoadEveryMarkerIsAfterAndStillUnique() {
        let markers = [TranscriptMarker(offset: 0, text: "A"), TranscriptMarker(offset: 0, text: "B")]
        let rows = TranscriptMarkerRows.place(markers, blocks: [])
        XCTAssertEqual(rows.after.count, 2)
        XCTAssertNotEqual(rows.after[0].id, rows.after[1].id)
    }
}
