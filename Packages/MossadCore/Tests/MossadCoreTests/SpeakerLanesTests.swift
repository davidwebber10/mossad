import XCTest
@testable import MossadCore

final class SpeakerLanesTests: XCTestCase {
    func record(_ utterances: [(String, TimeInterval, TimeInterval)]) -> CallRecord {
        var r = CallRecord(id: "1", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 0),
                           end: Date(timeIntervalSince1970: 600), status: .written)
        r.utterances = utterances.map { key, s, e in
            let p = key.split(separator: ":")
            return Utterance(track: Track(rawValue: String(p[0]))!, speakerLabel: String(p[1]), start: s, end: e, text: "x")
        }
        return r
    }

    func named(_ r: CallRecord, _ names: [String: String]) -> CallRecord {
        var r = r
        r.speakerNames = names
        return r
    }

    func testOwnerFirstThenByTalkTime() {
        let r = record([("them:A", 0, 30), ("me:A", 30, 40), ("them:B", 40, 50)])
        let names = ["me:A": "Dana Lee", "them:A": "Sam Park", "them:B": "Alex Rivera"]
        let lanes = SpeakerLanes.make(named(r, names), names: names, ownerName: "Dana Lee")
        XCTAssertEqual(lanes.map(\.name), ["Dana Lee", "Sam Park", "Alex Rivera"])
        XCTAssertEqual(lanes[1].seconds, 30)
    }

    func testKeysWithOneNameMergeIntoOneLane() {
        let r = record([("them:A", 0, 10), ("them:B", 20, 30), ("me:A", 10, 20)])
        let names = ["me:A": "Dana Lee", "them:A": "Sam Park", "them:B": "Sam Park"]
        let lanes = SpeakerLanes.make(named(r, names), names: names, ownerName: "Dana Lee")
        XCTAssertEqual(lanes.count, 2)
        XCTAssertEqual(lanes[1].seconds, 20)
        XCTAssertEqual(lanes[1].segments.count, 2)
    }

    func testSegmentsUnderOneSecondApartJoin() {
        let r = record([("me:A", 0, 5), ("me:A", 5.8, 9), ("me:A", 11, 12)])
        let lane = SpeakerLanes.make(r, names: ["me:A": "Dana Lee"], ownerName: "Dana Lee")[0]
        XCTAssertEqual(lane.segments, [0...9, 11...12])
    }

    func testUnsortedOverlappingUtterancesJoin() {
        let r = record([("me:A", 8, 12), ("me:A", 0, 10)])
        let lane = SpeakerLanes.make(r, names: ["me:A": "Dana Lee"], ownerName: "Dana Lee")[0]
        XCTAssertEqual(lane.segments, [0...12])
    }

    func testNoOwnerLaneMeansTalkTimeOrderOnly() {
        let r = record([("them:A", 0, 5), ("them:B", 5, 20)])
        let lanes = SpeakerLanes.make(r, names: ["them:A": "Sam Park", "them:B": "Alex Rivera"], ownerName: "Dana Lee")
        XCTAssertEqual(lanes.map(\.name), ["Alex Rivera", "Sam Park"])
    }

    func testManyKeysAndUtterancesAreFast() {
        let r = record((0..<1000).map { ("them:K\($0 % 137)", TimeInterval($0), TimeInterval($0) + 0.9) })
        measure { _ = SpeakerLanes.make(r, names: MarkdownWriter.displayNames(r), ownerName: "Dana Lee") }
        XCTAssertEqual(SpeakerLanes.make(r, names: MarkdownWriter.displayNames(r), ownerName: "Dana Lee").count, 137)
    }

    // MARK: Blocks

    func testBlocksMergeAcrossGapsNarrowerThanTheGapAtThisWidth() {
        // 1000 s across 1000 pt: 1 pt is 1 s. A 3 s gap merges at a 5 pt merge gap; a 20 s gap does not.
        let blocks = SpeakerLanes.blocks([0...10, 13...20, 40...50], duration: 1000, width: 1000, mergeGap: 5, minWidth: 3)
        XCTAssertEqual(blocks, [0...20, 40...50])
    }

    func testBlocksGetAMinimumWidthAroundTheirCenter() {
        // 1 pt is 10 s. A 2 s turn grows to 3 pt, which is 30 s, centered on the turn.
        let blocks = SpeakerLanes.blocks([100...102], duration: 10_000, width: 1000, mergeGap: 0, minWidth: 3)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].lowerBound, 86, accuracy: 0.001)
        XCTAssertEqual(blocks[0].upperBound, 116, accuracy: 0.001)
    }

    func testBlocksThatTouchAfterWideningMerge() {
        let blocks = SpeakerLanes.blocks([100...101, 110...111], duration: 10_000, width: 1000, mergeGap: 0, minWidth: 3)
        XCTAssertEqual(blocks.count, 1)
    }

    func testWideningStaysInsideTheMeeting() {
        let blocks = SpeakerLanes.blocks([0...1, 999...1000], duration: 1000, width: 100, mergeGap: 0, minWidth: 3)
        XCTAssertEqual(blocks.first?.lowerBound, 0)
        XCTAssertEqual(blocks.last?.upperBound, 1000)
        XCTAssertEqual(blocks.first?.upperBound ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(blocks.last?.lowerBound ?? 0, 970, accuracy: 0.001)
    }

    func testManySliversBecomeFewBlocks() {
        // A turn of 2 s every 10 s for an hour, across 800 pt: about 4.5 s a point, so the gaps all merge.
        let segments = stride(from: 0.0, to: 3600, by: 10).map { $0...($0 + 2) }
        let blocks = SpeakerLanes.blocks(segments, duration: 3600, width: 800, mergeGap: 5, minWidth: 3)
        XCTAssertEqual(blocks.count, 1)
    }

    func testBlocksWithNoWidthReturnTheSegments() {
        XCTAssertEqual(SpeakerLanes.blocks([0...1, 5...6], duration: 10, width: 0, mergeGap: 5, minWidth: 3), [0...1, 5...6])
    }
}
