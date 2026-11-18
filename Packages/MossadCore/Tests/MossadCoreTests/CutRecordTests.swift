import XCTest
@testable import MossadCore

final class CutRecordTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)

    private func json(_ r: CallRecord) throws -> [String: Any] {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(r)) as? [String: Any])
    }

    private func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b)
        default: false
        }
    }

    private var storedFields: Set<String> {
        let blank = CallRecord(id: "x", platform: .zoom, bundleID: "b", start: Date(), end: Date(), status: .written)
        return Set(Mirror(reflecting: blank).children.compactMap { $0.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 } })
    }

    private func recorded(length: TimeInterval = 1800) -> CallRecord {
        CallRecord(id: "20261101-100000", platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + length, status: .recorded)
    }

    func testEveryFieldOfARecordHasARule() throws {
        XCTAssertEqual(storedFields, Set(CutRecord.fields.keys), "a field of CallRecord with no rule, or a rule with no field")
        XCTAssertEqual(CutRecord.fields.count, 66)
    }

    /// One table: each field of a record with every field set, before and after, in both parts.
    func testTheFieldsOfEachPart() throws {
        let full = fullRecord()
        let before = try json(full)
        let parts = CutRecord.parts(of: full, at: [Cut(at: 900, link: "987654321")], ids: ["20261101-100000-2", "20261101-101600"], length: 1800)
        XCTAssertEqual(parts.count, 2)
        guard parts.count == 2 else { return }
        let first = try json(parts[0]), second = try json(parts[1])
        let fresh = try json(CallRecord(id: "x", platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0, status: .recorded))
        for (key, rule) in CutRecord.fields {
            switch rule {
            case .cleared:
                XCTAssertTrue(same(first[key], fresh[key]), "cleared in the first part: \(key)")
                XCTAssertTrue(same(second[key], fresh[key]), "cleared in the second part: \(key)")
            case .same:
                XCTAssertTrue(same(first[key], before[key]), "same in the first part: \(key)")
                XCTAssertTrue(same(second[key], before[key]), "same in the second part: \(key)")
            case .first:
                XCTAssertTrue(same(first[key], before[key]), "the first part's: \(key)")
                XCTAssertTrue(same(second[key], fresh[key]), "not the second part's: \(key)")
            case .divided, .special: break
            }
        }
        let counts = Dictionary(grouping: CutRecord.fields.values, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(counts[.divided], 8)
        XCTAssertEqual(counts[.special], 6)
        XCTAssertEqual(counts[.first], 3)
        XCTAssertEqual(counts[.same], 7)
        XCTAssertEqual(counts[.cleared], 42)

        // The special fields.
        XCTAssertEqual(parts.map(\.id), ["20261101-100000-2", "20261101-101600"])
        XCTAssertEqual(parts.map(\.status), [.recorded, .recorded])
        XCTAssertEqual(parts.map(\.cutFrom), ["20261101-090000", "20261101-090000"], "a part of a part keeps the first original")
        XCTAssertEqual(parts.map(\.meetingID), ["123456789", "987654321"])
        // The pause at 600 s took 60 s of wall time, so the cut at 900 s is at 960 s of the wall clock.
        XCTAssertEqual(parts[0].start, t0)
        XCTAssertEqual(parts[0].end, t0 + 960)
        XCTAssertEqual(parts[1].start, t0 + 960)
        XCTAssertEqual(parts[1].end, t0 + 1800)
        // The divided fields of this record.
        XCTAssertEqual(parts[0].markers, full.markers)
        XCTAssertEqual(parts[1].markers, [])
        XCTAssertEqual(parts[0].muteSpans, full.muteSpans)
        XCTAssertEqual(parts[0].screens, full.screens)
        XCTAssertNil(parts[1].screens)
        XCTAssertEqual(parts[0].screenGaps, full.screenGaps)
        XCTAssertEqual(parts[0].deletedScreens, full.deletedScreens)
        XCTAssertEqual(parts[0].pauses, full.pauses)
        XCTAssertNil(parts[1].pauses)
        XCTAssertNil(parts[0].callMarks)
        XCTAssertNil(parts[1].callMarks, "the mark of its own cut is not the second part's: it is never cut again by it")
    }

    func testOnlyTheOwnersTagsGoToTheFirstPart() {
        var r = recorded()
        r.tags = ["Budget"]
        r.tagsSetByOwner = nil
        let parts = CutRecord.parts(of: r, at: [Cut(at: 900, link: nil)], ids: ["a", "b"], length: 1800)
        XCTAssertEqual(parts.map(\.tags), [[], []], "tags the model gave are made again for each part")
    }

    func testAFirstPartWithNoLinkKeepsNone() {
        let parts = CutRecord.parts(of: recorded(), at: [Cut(at: 900, link: "abc-defg-hij")], ids: ["a", "b"], length: 1800)
        XCTAssertEqual(parts.map(\.meetingID), [nil, "abc-defg-hij"])
    }

    func testABookmarkOnTheCutGoesToTheLaterPart() {
        var r = recorded()
        r.markers = [TranscriptMarker(offset: 100, text: "★", isBookmark: true),
                     TranscriptMarker(offset: 900, text: "★", isBookmark: true, note: "here"),
                     TranscriptMarker(offset: 1000, text: "Paused")]
        let parts = CutRecord.parts(of: r, at: [Cut(at: 900, link: nil)], ids: ["a", "b"], length: 1800)
        XCTAssertEqual(parts[0].markers.map(\.offset), [100])
        XCTAssertEqual(parts[1].markers.map(\.offset), [0, 100])
        XCTAssertEqual(parts[1].markers.first?.note, "here")
    }

    func testScreensMoveWithTheirFiles() {
        var r = recorded()
        r.screens = [SharedScreen(offset: 100, file: "100000.heic", text: "a"), SharedScreen(offset: 950.5, file: "950500.heic", text: "b")]
        r.screenGaps = [ScreenGap(offset: 899, paused: true), ScreenGap(offset: 901, paused: false)]
        r.deletedScreens = ["120000.heic", "960000.heic"]
        let parts = CutRecord.parts(of: r, at: [Cut(at: 900, link: nil)], ids: ["a", "b"], length: 1800)
        XCTAssertEqual(parts[0].screens?.map(\.file), ["100000.heic"])
        XCTAssertEqual(parts[1].screens?.map(\.offset), [50.5])
        XCTAssertEqual(parts[1].screens?.map(\.file), ["50500.heic"], "the name FrameStore.cut gives the picture")
        XCTAssertEqual(parts[0].screenGaps, [ScreenGap(offset: 899, paused: true)])
        XCTAssertEqual(parts[1].screenGaps, [ScreenGap(offset: 1, paused: false)])
        XCTAssertEqual(parts[0].deletedScreens, ["120000.heic"])
        XCTAssertEqual(parts[1].deletedScreens, ["60000.heic"])
    }

    func testAMuteSpanAcrossTheCutBecomesTwo() {
        var r = recorded()
        r.muteSpans = [MuteSpan(start: 800, end: 1000), MuteSpan(start: 1700, end: nil)]
        let parts = CutRecord.parts(of: r, at: [Cut(at: 900, link: nil)], ids: ["a", "b"], length: 1800)
        XCTAssertEqual(parts[0].muteSpans, [MuteSpan(start: 800, end: 900)])
        XCTAssertEqual(parts[1].muteSpans, [MuteSpan(start: 0, end: 100), MuteSpan(start: 800, end: nil)])
    }

    func testAMergedMeetingsParts() {
        var r = recorded(length: 3000)
        // Two recordings of 1000 s with 1000 s between them; the cut falls inside the second.
        r.parts = [CallPart(start: t0, end: t0 + 1000, offset: 0), CallPart(start: t0 + 2000, end: t0 + 3000, offset: 1000)]
        let parts = CutRecord.parts(of: r, at: [Cut(at: 1400, link: nil)], ids: ["a", "b"], length: 2000)
        XCTAssertEqual(parts[0].parts, [CallPart(start: t0, end: t0 + 1000, offset: 0), CallPart(start: t0 + 2000, end: t0 + 2400, offset: 1000)])
        XCTAssertEqual(parts[0].start, t0)
        XCTAssertEqual(parts[0].end, t0 + 2400)
        XCTAssertEqual(parts[1].parts, [], "one recording is no merged meeting")
        XCTAssertEqual(parts[1].start, t0 + 2400)
        XCTAssertEqual(parts[1].end, t0 + 3000)
    }

    func testACutBetweenTheRecordingsOfAMergedMeeting() {
        var r = recorded(length: 3000)
        r.parts = [CallPart(start: t0, end: t0 + 1000, offset: 0), CallPart(start: t0 + 2000, end: t0 + 3000, offset: 1000)]
        let parts = CutRecord.parts(of: r, at: [Cut(at: 1000, link: nil)], ids: ["a", "b"], length: 2000)
        XCTAssertEqual(parts[0].parts, [])
        XCTAssertEqual(parts[0].end, t0 + 1000)
        XCTAssertEqual(parts[1].start, t0 + 2000)
        XCTAssertEqual(parts[1].parts, [])
    }

    func testPausesBeforeAcrossAndAfterTheCut() {
        var r = recorded(length: 2000)
        // 60 s paused at 300 s, a pause exactly at the cut (900 s) of 100 s, and one at 1500 s of 40 s.
        r.pauses = [PauseSpan(at: 300, from: t0 + 300, to: t0 + 360),
                    PauseSpan(at: 900, from: t0 + 960, to: t0 + 1060),
                    PauseSpan(at: 1500, from: t0 + 1660, to: t0 + 1700)]
        r.end = t0 + 2000
        let parts = CutRecord.parts(of: r, at: [Cut(at: 900, link: nil)], ids: ["a", "b"], length: 1800)
        XCTAssertEqual(parts[0].end, t0 + 960, "the first part ends where the pause at the cut begins")
        XCTAssertEqual(parts[1].start, t0 + 1060, "the second part starts where that pause ends")
        XCTAssertEqual(parts[0].pauses, [PauseSpan(at: 300, from: t0 + 300, to: t0 + 360)])
        XCTAssertEqual(parts[1].pauses, [PauseSpan(at: 600, from: t0 + 1660, to: t0 + 1700)])
    }

    func testAnOpenPauseRunsToTheEnd() {
        var r = recorded(length: 2000)
        r.pauses = [PauseSpan(at: 1200, from: t0 + 1200, to: nil)]
        let parts = CutRecord.parts(of: r, at: [Cut(at: 900, link: nil)], ids: ["a", "b"], length: 1200)
        XCTAssertEqual(parts[1].start, t0 + 900)
        XCTAssertEqual(parts[1].end, t0 + 2000)
        XCTAssertEqual(parts[1].pauses, [PauseSpan(at: 300, from: t0 + 1200, to: nil)])
    }

    func testTwoCuts() {
        var r = recorded(length: 3000)
        r.markers = [TranscriptMarker(offset: 500, text: "★", isBookmark: true), TranscriptMarker(offset: 1500, text: "★", isBookmark: true),
                     TranscriptMarker(offset: 2500, text: "★", isBookmark: true)]
        r.callMarks = [CallMark(at: 1000, time: t0 + 1000, link: "bbb", platform: .meet, source: .tabs, sure: true),
                       CallMark(at: 1600, time: t0 + 1600, link: nil, platform: .meet, source: .title, sure: false),
                       CallMark(at: 2000, time: t0 + 2000, link: "ccc", platform: .meet, source: .tabs, sure: true)]
        let parts = CutRecord.parts(of: r, at: [Cut(at: 1000, link: "bbb"), Cut(at: 2000, link: "ccc")], ids: ["a", "b", "c"], length: 3000)
        XCTAssertEqual(parts.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(parts.map(\.meetingID), [nil, "bbb", "ccc"])
        XCTAssertEqual(parts.map { $0.markers.map(\.offset) }, [[500], [500], [500]])
        XCTAssertEqual(parts.map(\.start), [t0, t0 + 1000, t0 + 2000])
        XCTAssertEqual(parts.map(\.end), [t0 + 1000, t0 + 2000, t0 + 3000])
        XCTAssertNil(parts[0].callMarks)
        XCTAssertEqual(parts[1].callMarks?.map(\.at), [600], "a mark inside a part stays, moved back")
        XCTAssertNil(parts[2].callMarks)
    }

    func testTheCutsAreTakenInOrder() {
        let parts = CutRecord.parts(of: recorded(length: 3000), at: [Cut(at: 2000, link: "c"), Cut(at: 1000, link: "b")],
                                    ids: ["a", "b", "c"], length: 3000)
        XCTAssertEqual(parts.map(\.meetingID), [nil, "b", "c"])
        XCTAssertEqual(parts.map(\.start), [t0, t0 + 1000, t0 + 2000])
    }

    func testRefusals() {
        let ok = recorded()
        let cut = [Cut(at: 900, link: nil)]
        XCTAssertNil(CutRecord.refusal(ok, cuts: cut, length: 1800, hasTracks: true))
        var written = ok
        written.status = .written
        XCTAssertNil(CutRecord.refusal(written, cuts: cut, length: 1800, hasTracks: true), "a written meeting can be cut: the repair")
        var r = ok
        r.status = .recording
        XCTAssertNotNil(CutRecord.refusal(r, cuts: cut, length: 1800, hasTracks: true))
        r = ok
        r.source = "geminiNotes"
        XCTAssertNotNil(CutRecord.refusal(r, cuts: cut, length: 1800, hasTracks: true))
        r = ok
        r.platform = .phoneCall
        XCTAssertNotNil(CutRecord.refusal(r, cuts: cut, length: 1800, hasTracks: true))
        r = ok
        r.mutedAudioPending = true
        XCTAssertNotNil(CutRecord.refusal(r, cuts: cut, length: 1800, hasTracks: true))
        XCTAssertNotNil(CutRecord.refusal(ok, cuts: cut, length: 1800, hasTracks: false))
        XCTAssertNotNil(CutRecord.refusal(ok, cuts: [], length: 1800, hasTracks: true))
        XCTAssertNotNil(CutRecord.refusal(ok, cuts: [Cut(at: 1900, link: nil)], length: 1800, hasTracks: true), "past the end")
        XCTAssertNotNil(CutRecord.refusal(ok, cuts: [Cut(at: 0, link: nil)], length: 1800, hasTracks: true))
        XCTAssertNotNil(CutRecord.refusal(ok, cuts: [Cut(at: 30, link: nil)], length: 1800, hasTracks: true), "a part under a minute")
        XCTAssertNotNil(CutRecord.refusal(ok, cuts: [Cut(at: 1770, link: nil)], length: 1800, hasTracks: true))
        XCTAssertNotNil(CutRecord.refusal(ok, cuts: [Cut(at: 900, link: nil), Cut(at: 930, link: nil)], length: 1800, hasTracks: true))
        XCTAssertNotNil(CutRecord.refusal(ok, cuts: [Cut(at: 900, link: nil), Cut(at: 900, link: nil)], length: 1800, hasTracks: true))
        XCTAssertNil(CutRecord.refusal(ok, cuts: [Cut(at: 60, link: nil), Cut(at: 1740, link: nil)], length: 1800, hasTracks: true))
    }

    func testAPartsIDComesFromItsOwnStartAndIsFree() throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let start = t0
        let id = CallRecorder.callID(for: start)
        XCTAssertEqual(CallRecorder.freeID(for: start, in: paths), id)
        try FileManager.default.createDirectory(at: paths.callDirectory(id), withIntermediateDirectories: true)
        XCTAssertEqual(CallRecorder.freeID(for: start, in: paths), "\(id)-2", "the original's id while its folder exists")
        try FileManager.default.createDirectory(at: paths.audio.appendingPathComponent("\(id)-2.cutting"), withIntermediateDirectories: true)
        XCTAssertEqual(CallRecorder.freeID(for: start, in: paths), "\(id)-3", "a part that is being made has its id")
    }
}
