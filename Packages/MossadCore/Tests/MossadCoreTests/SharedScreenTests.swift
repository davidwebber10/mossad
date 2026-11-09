import XCTest
@testable import MossadCore

final class SharedScreenTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ screens: [SharedScreen]?) -> CallRecord {
        var r = CallRecord(id: "c1", platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0.addingTimeInterval(600), status: .written)
        r.utterances = [
            Utterance(track: .me, speakerLabel: "A", start: 5, end: 20, text: "Let me start."),
            Utterance(track: .them, speakerLabel: "A", start: 100, end: 150, text: "Here is the plan."),
            Utterance(track: .me, speakerLabel: "A", start: 151, end: 155, text: "Thanks."),
            Utterance(track: .them, speakerLabel: "B", start: 300, end: 310, text: "One question."),
        ]
        r.speakerNames = ["me:A": "Robin Vale", "them:A": "Sam Carter"]
        r.screens = screens
        return r
    }

    func testOldRecordsDecodeWithNoScreens() throws {
        let json = #"{"id":"a","platform":"zoom","bundleID":"us.zoom.xos","start":"2026-01-01T10:00:00Z","end":"2026-01-01T10:30:00Z","status":"written"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(CallRecord.self, from: Data(json.utf8)).screens)
    }

    func testScreensRoundTripAndABuildWithoutThePresenterKeyDecodes() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = record([SharedScreen(offset: 12, file: "12000.heic", text: "Plan", presenter: "Sam Carter", window: "us.zoom.xos#7")])
        try r.save(to: dir)
        XCTAssertEqual(try CallRecord.load(from: dir).screens, r.screens)
        let old = try JSONDecoder().decode(SharedScreen.self, from: Data(#"{"offset":3,"file":"3000.heic","text":"x"}"#.utf8))
        XCTAssertEqual(old, SharedScreen(offset: 3, file: "3000.heic", text: "x"))
    }

    func testTheTranscriptHasOneLineForEachScreenAndMarkersStayAsTheyWere() {
        var r = record([
            SharedScreen(offset: 120, file: "120000.heic", text: "Q3 plan\nRevenue \"up\" 12%", presenter: "Sam Carter"),
            SharedScreen(offset: 304, file: "304000.heic", text: "Budget table"),
        ])
        r.markers = [TranscriptMarker(offset: 60, text: "Paused from 10:01 to 10:02 (1 min)")]
        let lines = MarkdownWriter.transcript(r).components(separatedBy: "\n")
        XCTAssertEqual(lines, [
            "[00:00:05] Robin Vale: Let me start.",
            "[00:01:00] (Paused from 10:01 to 10:02 (1 min))",
            "[00:01:40] Sam Carter: Here is the plan.",
            "[00:02:00] (Screen shared by Sam Carter: \"Q3 plan Revenue 'up' 12%\")",
            "[00:02:31] Robin Vale: Thanks.",
            "[00:05:00] Speaker A: One question.",
            "[00:05:04] (Screen: \"Budget table\")",
        ])
        // The lines are made from `screens`; a second run cannot double them.
        XCTAssertEqual(r.markers.count, 1)
        XCTAssertEqual(r.recordingMarkers.count, 1)
        XCTAssertEqual(r.transcriptMarkers.count, 3)
    }

    func testALongScreenTextIsCutInTheLine() {
        let r = record([SharedScreen(offset: 1, file: "1000.heic", text: String(repeating: "a", count: 900))])
        XCTAssertEqual(r.screenMarkers[0].text.count, "Screen: \"\"".count + 300)
    }

    func testSessionsSplitAtAMinuteAndAtAChangeOfWindow() {
        let screens = [
            SharedScreen(offset: 10, file: "a", text: "", window: "w1"),
            SharedScreen(offset: 40, file: "b", text: "", presenter: "Sam Carter", window: "w1"),
            SharedScreen(offset: 99, file: "c", text: "", window: "w1"),
            SharedScreen(offset: 159, file: "d", text: "", presenter: "Dana Lee", window: "w1"),
            SharedScreen(offset: 170, file: "e", text: "", window: "w2"),
        ]
        let sessions = ShareSession.group(screens.shuffled())
        XCTAssertEqual(sessions.map(\.count), [3, 1, 1])
        XCTAssertEqual(sessions.map(\.presenter), ["Sam Carter", "Dana Lee", nil])
        XCTAssertEqual(sessions.map(\.start), [10, 159, 170])
        XCTAssertEqual(sessions.map(\.end), [99, 159, 170])
        XCTAssertTrue(ShareSession.startsNew(offset: 5, window: "w", after: nil))
        XCTAssertFalse(ShareSession.startsNew(offset: 64, window: "w", after: (5, "w")))
        XCTAssertTrue(ShareSession.startsNew(offset: 65, window: "w", after: (5, "w")))
        XCTAssertTrue(ShareSession.startsNew(offset: 6, window: "x", after: (5, "w")))
    }

    func testSessionHeadings() {
        let time: (TimeInterval) -> String = { "12:\(String(format: "%02d", Int($0) / 60))" }
        let named = ShareSession(screens: (0..<9).map { SharedScreen(offset: 240 + Double($0) * 112, file: "\($0)", text: "") }, presenter: "Sam Carter")
        XCTAssertEqual(named.heading(time: time), "Sam Carter shared 12:04–12:18 · 9 screens")
        let plain = ShareSession(screens: [SharedScreen(offset: 240, file: "x", text: "")], presenter: nil)
        XCTAssertEqual(plain.heading(time: time), "Screen shared · 12:04 · 1 screen")
    }

    func testTheRowNamesThePresenterOrTheSpeakerOfThatMinute() {
        let r = record(nil)
        XCTAssertEqual(SharedScreen(offset: 120, file: "f", text: "", presenter: "Sam Carter").rowTitle(time: "12:04", speaker: "Dana Lee"),
                       "Screen shared by Sam Carter · 12:04")
        // Sam talks 100 to 150, Robin 151 to 155: around 130 it is Sam.
        XCTAssertEqual(r.mainSpeaker(around: 130), "Sam Carter")
        XCTAssertEqual(SharedScreen(offset: 130, file: "f", text: "").rowTitle(time: "12:04", speaker: r.mainSpeaker(around: 130)),
                       "Screen shared · while Sam Carter was speaking")
        XCTAssertEqual(r.mainSpeaker(around: 305), "Speaker A")
        XCTAssertNil(r.mainSpeaker(around: 500))
        XCTAssertEqual(SharedScreen(offset: 500, file: "f", text: "").rowTitle(time: "12:10", speaker: nil), "Screen shared · 12:10")
    }

    func testLinesAroundAScreen() {
        let lines = record(nil).lines(around: 125)
        XCTAssertEqual(lines.map(\.speaker), ["Sam Carter", "Robin Vale"])
        XCTAssertEqual(lines.map(\.text), ["Here is the plan.", "Thanks."])
    }

    // MARK: Presenter labels

    func testReadsThePresenterFromAppLabels() {
        XCTAssertEqual(PresenterLabel.name(in: ["Mute", "You are viewing Sam Carter's screen", "View Options"]), "Sam Carter")
        XCTAssertEqual(PresenterLabel.name(in: ["Dana Lee is presenting"]), "Dana Lee")
        XCTAssertEqual(PresenterLabel.name(in: ["Dana Lee (Presenting)"]), "Dana Lee")
        XCTAssertEqual(PresenterLabel.name(in: ["Dana Lee (Presentation)"]), "Dana Lee")
        XCTAssertEqual(PresenterLabel.name(in: ["Content shared by Alex Rivera"]), "Alex Rivera")
        XCTAssertEqual(PresenterLabel.name(in: ["Alex Rivera is sharing their screen"]), "Alex Rivera")
    }

    func testNeverGuessesAPresenter() {
        XCTAssertNil(PresenterLabel.name(in: []))
        XCTAssertNil(PresenterLabel.name(in: ["Share Screen", "Stop sharing", "Present now", "Screen sharing meeting controls"]))
        // The owner's own share names nobody.
        XCTAssertNil(PresenterLabel.name(in: ["You are presenting", "You (Presenting)", "Your screen"]))
        XCTAssertNil(PresenterLabel.name(in: ["Someone is presenting"]))
    }

    func testAPresenterNameMapsToAKnownPerson() {
        let known = ["Sam Carter", "Dana Lee", "Dana Lopez"]
        XCTAssertEqual(PresenterLabel.resolve("sam carter", known: known), "Sam Carter")
        XCTAssertEqual(PresenterLabel.resolve("Sam J. Carter", known: known), "Sam Carter")
        XCTAssertEqual(PresenterLabel.resolve("Alex Rivera", known: known), "Alex Rivera")
        XCTAssertEqual(PresenterLabel.resolve("Dana", known: known), "Dana")
    }

    func testScreenRecordingIsAnOptionalPermission() {
        XCTAssertFalse(OnboardingPermissions.isRequired(.screenCapture))
        XCTAssertFalse(OnboardingPermissions.required.contains(.screenCapture))
        XCTAssertTrue(PermissionKind.screenCapture.settingsURL.absoluteString.hasSuffix("Privacy_ScreenCapture"))
    }

    // MARK: Merge, retention, search, sync

    func testMergeMovesScreensWithTheirPart() {
        var one = record([SharedScreen(offset: 10, file: "10000.heic", text: "First")])
        one.id = "one"
        var two = record([SharedScreen(offset: 5, file: "5000.heic", text: "Second", presenter: "Dana Lee")])
        two.id = "two"
        two.start = t0.addingTimeInterval(700)
        two.end = t0.addingTimeInterval(900)
        let merged = MeetingMerge.combine([two, one], durations: ["one": 600, "two": 200])
        XCTAssertEqual(merged.screens, [
            SharedScreen(offset: 10, file: "10000.heic", text: "First"),
            SharedScreen(offset: 605, file: "605000.heic", text: "Second", presenter: "Dana Lee"),
        ])
        // Meetings with no screen capture stay without the field.
        var plain = record(nil), other = record(nil)
        plain.id = "p"
        other.id = "q"
        other.start = t0.addingTimeInterval(700)
        XCTAssertNil(MeetingMerge.combine([plain, other], durations: [:]).screens)
    }

    func testRetentionRemovesFramesWithTheRawTracksAndKeepsTheText() throws {
        let paths = Paths(root: tempDirectory())
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.ensureDirectories()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func call(_ id: String, daysAgo: Double) throws -> URL {
            let dir = paths.callDirectory(id)
            try FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true)
            let end = now.addingTimeInterval(-daysAgo * 86_400)
            var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: end.addingTimeInterval(-600), end: end, status: .written)
            r.screens = [SharedScreen(offset: 10, file: "10000.heic", text: "Plan")]
            try r.save(to: dir)
            for f in ["me.caf", "recording.m4a", "frames/10000.heic"] { try Data([1]).write(to: dir.appendingPathComponent(f)) }
            try FrameIndex(frames: [.init(offset: 10, file: "10000.heic", text: "Plan")]).save(to: dir)
            return dir
        }
        let old = try call("old", daysAgo: 31), recent = try call("recent", daysAgo: 5)
        Retention.sweep(audioRoot: paths.audio, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FrameIndex.folder(in: old).path))
        XCTAssertFalse(FrameStore.hasFrames(in: old))
        XCTAssertEqual(try CallRecord.load(from: old).screens?.first?.text, "Plan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.appendingPathComponent("frames/10000.heic").path))
        XCTAssertTrue(FrameStore.hasFrames(in: recent))
    }

    func testSearchFindsTextOnAScreen() {
        let r = record([SharedScreen(offset: 120, file: "f", text: "Freight forecast by warehouse")])
        XCTAssertTrue(MeetingSearch.matches(r, "warehouse"))
        XCTAssertFalse(MeetingSearch.matches(record(nil), "warehouse"))
        let index = SearchIndex(records: [r])
        let moments = index.moments(in: "c1", matching: "warehouse")
        XCTAssertEqual(moments.map(\.time), [120])
        XCTAssertEqual(moments.first?.speaker, "Screen")
        XCTAssertEqual(index.moments(in: "c1", matching: "plan").map(\.time), [100])
    }

    func testScreensDoNotSync() throws {
        let r = record([SharedScreen(offset: 120, file: "f", text: "Plan")])
        let payload = SyncPayload(record: r, coach: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sent = try JSONDecoder.callRecord.decode(CallRecord.self, from: payload.record)
        XCTAssertNil(sent.screens)
        _ = decoder
    }
}
