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

    func testASlideThatStaysForMinutesDoesNotEndTheSession() {
        // One new slide each 90 s, all in the capture's session 0; then a pause of the capture; then another window.
        let screens = [
            SharedScreen(offset: 10, file: "a", text: "", presenter: "Sam Carter", window: "w1", session: 0),
            SharedScreen(offset: 100, file: "b", text: "", presenter: "Sam Carter", window: "w1", session: 0),
            SharedScreen(offset: 190, file: "c", text: "", presenter: "Sam Carter", window: "w1", session: 0),
            SharedScreen(offset: 200, file: "d", text: "", window: "w1", session: 1),
            SharedScreen(offset: 210, file: "e", text: "", window: "w2", session: 2),
        ]
        let sessions = ShareSession.group(screens.shuffled())
        XCTAssertEqual(sessions.map(\.count), [3, 1, 1])
        XCTAssertEqual(sessions.map(\.presenter), ["Sam Carter", nil, nil])
        XCTAssertEqual(sessions.map(\.start), [10, 200, 210])
        XCTAssertEqual(sessions.map(\.end), [190, 200, 210])
    }

    func testAPresenterNameIsNeverCarriedToAnotherSession() {
        // The capture gave Dana's frames their own session; and even with one number, another name is another session.
        let numbered = [
            SharedScreen(offset: 10, file: "a", text: "", presenter: "Sam Carter", window: "w", session: 0),
            SharedScreen(offset: 20, file: "b", text: "", presenter: "Dana Lee", window: "w", session: 1),
            SharedScreen(offset: 30, file: "c", text: "", window: "w", session: 2),
        ]
        XCTAssertEqual(ShareSession.group(numbered).map(\.presenter), ["Sam Carter", "Dana Lee", nil])
        let oneNumber = numbered.map { s -> SharedScreen in var s = s; s.session = 0; return s }
        XCTAssertEqual(ShareSession.group(oneNumber).map(\.presenter), ["Sam Carter", "Dana Lee", nil])
    }

    func testRecordsFromBeforeSessionNumbersSplitAtAMinute() {
        let screens = [
            SharedScreen(offset: 10, file: "a", text: "", window: "w1"),
            SharedScreen(offset: 40, file: "b", text: "", window: "w1"),
            SharedScreen(offset: 159, file: "d", text: "", window: "w1"),
            SharedScreen(offset: 170, file: "e", text: "", window: "w2"),
        ]
        XCTAssertEqual(ShareSession.group(screens).map(\.count), [2, 1, 1])
    }

    func testTheFilmstripDrawsFewPicturesHoweverManyFrames() {
        // Three hours with a frame each 15 s: 720 frames on a line of 900 pt.
        let offsets = (0..<720).map { Double($0) * 15 }
        let pictured = FilmstripLayout.pictured(offsets, open: 400, duration: 10_800, span: 900, spacing: 70)
        XCTAssertLessThanOrEqual(pictured.count, 14)
        XCTAssertTrue(pictured.contains(400))
        XCTAssertEqual(pictured, pictured.sorted())
        // No two pictures nearer than the spacing.
        let places = pictured.map { 900 * offsets[$0] / 10_800 }
        XCTAssertTrue(zip(places, places.dropFirst()).allSatisfy { $1 - $0 >= 70 })
        // A few frames far apart all get one.
        XCTAssertEqual(FilmstripLayout.pictured([0, 600, 1200], open: 1, duration: 1800, span: 900, spacing: 70), [0, 1, 2])
        XCTAssertEqual(FilmstripLayout.pictured([], open: 0, duration: 1800, span: 900, spacing: 70), [])
    }

    // MARK: Times of day

    func testTheTimeOfDayAfterAPauseComesFromTheFrame() {
        var r = record(nil)
        // A 10 minute pause before this frame: second 120 of the files was 12 minutes after the start.
        let saved = SharedScreen(offset: 120, file: "f", text: "", time: t0.addingTimeInterval(720))
        XCTAssertEqual(r.date(of: saved), t0.addingTimeInterval(720))
        // A record from before the time was saved falls back to the offset.
        XCTAssertEqual(r.date(of: SharedScreen(offset: 120, file: "f", text: "")), t0.addingTimeInterval(120))
        r.parts = []
        XCTAssertEqual(r.date(atOffset: 30), t0.addingTimeInterval(30))
    }

    func testTheTimeOfDayInAJoinedMeetingCountsFromItsPart() {
        var r = record(nil)
        // 12:00 to 12:30 and 13:30 to 14:00, joined: the second part begins at second 1800 of the audio.
        r.parts = [CallPart(start: t0, end: t0.addingTimeInterval(1800), offset: 0),
                   CallPart(start: t0.addingTimeInterval(5400), end: t0.addingTimeInterval(7200), offset: 1800)]
        XCTAssertEqual(r.date(atOffset: 300), t0.addingTimeInterval(300))
        // 5 minutes into the second part is 13:35, not 12:35.
        XCTAssertEqual(r.date(atOffset: 2100), t0.addingTimeInterval(5700))
        XCTAssertEqual(r.date(of: SharedScreen(offset: 2100, file: "f", text: "")), t0.addingTimeInterval(5700))
    }

    // MARK: Pauses of the capture

    func testAPauseShowsOnlyNextToAShareSession() {
        let screens = [SharedScreen(offset: 600, file: "a", text: "", window: "w", session: 0),
                       SharedScreen(offset: 700, file: "b", text: "", window: "w", session: 0)]
        let gaps = [
            ScreenGap(offset: 100, paused: true), ScreenGap(offset: 130, paused: false),    // nobody shared: not shown
            ScreenGap(offset: 650, paused: true), ScreenGap(offset: 690, paused: false),    // inside the session
            ScreenGap(offset: 750, paused: true), ScreenGap(offset: 2000, paused: false),   // right after it, with its return
            ScreenGap(offset: 2500, paused: true),                                          // long after
        ]
        XCTAssertEqual(ScreenGap.shown(gaps.shuffled(), screens: screens).map(\.offset), [650, 690, 750, 2000])
        XCTAssertEqual(ScreenGap.shown(gaps, screens: []), [])
        var r = record(screens)
        r.screenGaps = ScreenGap.shown(gaps, screens: screens)
        XCTAssertTrue(MarkdownWriter.transcript(r).contains("[00:10:50] (Screen capture paused)\n[00:11:30] (Screen capture resumed)"))
        XCTAssertTrue(r.markers.isEmpty)
    }

    func testTheCoachAndTheCommitmentFinderGetNoScreenLines() {
        var r = record([SharedScreen(offset: 120, file: "f", text: "Budget table")])
        r.screenGaps = [ScreenGap(offset: 130, paused: true)]
        r.markers = [TranscriptMarker(offset: 60, text: "Paused from 10:01 to 10:02 (1 min)")]
        let spoken = MarkdownWriter.transcript(r, screens: false)
        XCTAssertFalse(spoken.contains("Screen"))
        XCTAssertTrue(spoken.contains("(Paused from 10:01"))
        XCTAssertTrue(MarkdownWriter.transcript(r).contains("(Screen: \"Budget table\")"))
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

    func testAPresenterComesOnlyFromAWholeShareLabel() {
        // Lines that people wrote, and titles on a slide: the words are there, the label is not.
        XCTAssertNil(PresenterLabel.name(in: ["Sam is presenting the numbers next week"]))
        XCTAssertNil(PresenterLabel.name(in: ["Today's presentation", "Q3's presentation", "Dana's screen"]))
        XCTAssertNil(PresenterLabel.name(in: ["I think Dana Lee is sharing their screen now, right?"]))
        XCTAssertNil(PresenterLabel.name(in: ["who is presenting", "This is presenting", "the host is presenting", "2 is presenting"]))
        XCTAssertNil(PresenterLabel.name(in: ["Content shared by everyone in the call is recorded"]))
        XCTAssertEqual(PresenterLabel.name(in: ["Sam Carter is presenting."]), "Sam Carter")
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
        one.screens?[0].session = 0
        two.screens?[0].session = 0
        two.screens?[0].time = t0.addingTimeInterval(705)
        two.screenGaps = [ScreenGap(offset: 8, paused: true)]
        let merged = MeetingMerge.combine([two, one], durations: ["one": 600, "two": 200])
        // The offset and the file move; the time of day stays; the two parts' sessions stay apart.
        XCTAssertEqual(merged.screens, [
            SharedScreen(offset: 10, file: "10000.heic", text: "First", session: 0),
            SharedScreen(offset: 605, file: "605000.heic", text: "Second", presenter: "Dana Lee", time: t0.addingTimeInterval(705), session: 1),
        ])
        XCTAssertEqual(merged.screenGaps, [ScreenGap(offset: 608, paused: true)])
        XCTAssertEqual(ShareSession.group(merged.screens ?? []).count, 2)
        // Meetings with no screen capture stay without the field.
        var plain = record(nil), other = record(nil)
        plain.id = "p"
        other.id = "q"
        other.start = t0.addingTimeInterval(700)
        XCTAssertNil(MeetingMerge.combine([plain, other], durations: [:]).screens)
    }

    func testFramesStayAsLongAsTheRecordingAndGoWithIt() throws {
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
        func has(_ dir: URL, _ f: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) }
        let old = try call("old", daysAgo: 31), older = try call("older", daysAgo: 91)
        // The raw tracks go after 30 days; the recording and the frames stay.
        Retention.sweep(audioRoot: paths.audio, now: now)
        XCTAssertFalse(has(old, "me.caf"))
        XCTAssertTrue(has(old, "recording.m4a") && has(old, "frames/10000.heic") && FrameStore.hasFrames(in: old))
        XCTAssertTrue(has(older, "frames/10000.heic"))
        // With "delete recordings" on, the frames go with the recording. The text stays in the record.
        Retention.sweep(audioRoot: paths.audio, recordingsAfterDays: 90, now: now)
        XCTAssertFalse(has(older, "recording.m4a") || has(older, "frames") || FrameStore.hasFrames(in: older))
        XCTAssertEqual(try CallRecord.load(from: older).screens?.first?.text, "Plan")
        XCTAssertTrue(has(old, "frames/10000.heic"))
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
        var r = record([SharedScreen(offset: 120, file: "f", text: "Plan")])
        r.screenGaps = [ScreenGap(offset: 5, paused: true)]
        let payload = SyncPayload(record: r, coach: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sent = try JSONDecoder.callRecord.decode(CallRecord.self, from: payload.record)
        XCTAssertNil(sent.screens)
        XCTAssertNil(sent.screenGaps)
        _ = decoder
    }
}
