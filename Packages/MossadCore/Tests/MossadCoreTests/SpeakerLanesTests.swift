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
}
