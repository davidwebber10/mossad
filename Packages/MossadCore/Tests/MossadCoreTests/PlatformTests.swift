import XCTest
@testable import MossadCore

final class PlatformTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testThePhoneCallsWords() {
        XCTAssertEqual(Platform.phoneCall.displayName, "Phone call")
        XCTAssertEqual(Platform.phoneCall.filterName, "Phone call")
        XCTAssertEqual(Platform.phoneCall.untitled, "Phone call")
        XCTAssertEqual(Platform.inPerson.untitled, "In person call")
        XCTAssertEqual(Platform.zoom.untitled, "Zoom call")
        XCTAssertEqual(Platform.unknown.untitled, "Call")
        XCTAssertEqual(Platform.unknown.displayName, "Not known")
        XCTAssertEqual(Platform.allCases.filter(\.isOneTrack), [.inPerson, .phoneCall])
        XCTAssertFalse(Platform.unknown.isOneTrack)
        XCTAssertEqual([Platform.zoom, .inPerson, .phoneCall].map(\.micTrackName), ["your mic", "the room audio", "the call recording"])
    }

    func testAPlatformThisBuildDoesNotKnowStillReads() throws {
        XCTAssertEqual(try JSONDecoder().decode([Platform].self, from: Data(#"["zoom","fax","phoneCall"]"#.utf8)), [.zoom, .unknown, .phoneCall])
        XCTAssertEqual(Platform.allCases, [.zoom, .meet, .teams, .inPerson, .phoneCall])
        XCTAssertFalse(Platform.callApps.contains(.phoneCall))
    }

    func testAMeetingWithAnUnknownPlatformIsNotLeftOut() throws {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let dir = paths.callDirectory("20270115-090000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try CallRecord(id: "20270115-090000", platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + 600, status: .written).save(to: dir)
        let file = dir.appendingPathComponent(CallRecord.fileName)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(#""platform":"meet""#) || text.contains(#""platform" : "meet""#), text)
        try text.replacingOccurrences(of: #""meet""#, with: #""fax""#).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try CallRecord.load(from: dir).platform, .unknown)
        XCTAssertEqual(try CallRecord.load(from: dir).title, "Call")
        let scan = try ProcessingQueue(paths: paths).scan()
        XCTAssertEqual(scan.unreadable, [])
        XCTAssertEqual(scan.records.map(\.id), ["20270115-090000"])
    }

    func testAnUntitledPhoneCallIsNamedOnce() {
        XCTAssertEqual(CallRecord(id: "a", platform: .phoneCall, bundleID: "iphone", start: t0, end: t0, status: .recorded).title, "Phone call")
        XCTAssertEqual(CallRecord(id: "a", platform: .inPerson, bundleID: "", start: t0, end: t0, status: .recorded).title, "In person call")
    }

    func testAPhoneCallIsOneTrackInTheProgressAndTheSpeakerCount() {
        var p = ProcessingProgress(step: .transcribing, started: t0)
        p.tracks = [.me: .uploading(0.42)]
        XCTAssertEqual(p.trackLine(.me, service: "AssemblyAI", platform: .phoneCall), "Uploading the call recording · 42%")
        XCTAssertEqual(p.trackLine(.me, service: "AssemblyAI", platform: .inPerson), "Uploading the room audio · 42%")
        XCTAssertEqual(p.trackLine(.me, service: "AssemblyAI", platform: .zoom), "Uploading your mic · 42%")
        var r = CallRecord(id: "a", platform: .phoneCall, bundleID: "iphone", start: t0, end: t0, status: .recorded)
        r.speakersExpected = 2
        XCTAssertEqual(Pipeline.speakerHints(r), [.me: 2])
    }

    func testAPhoneCallsNoteSaysPhoneCall() {
        var r = CallRecord(id: "20270115-090000", platform: .phoneCall, bundleID: "iphone", start: t0, end: t0 + 600, status: .summarized)
        r.customTitle = "Renewal terms"
        XCTAssertTrue(MarkdownWriter.render(r).contains("\nplatform: Phone call\n"))
    }

    func testAPhoneCallTakesNoCalendarEventByTheGeneralRule() {
        let e = CalendarEventInfo(title: "Lunch", start: t0, end: t0 + 3600, attendees: [], text: "", isAllDay: false)
        XCTAssertNotNil(CalendarMatcher.bestEvent(for: .inPerson, meetingID: nil, start: t0, end: t0 + 600, in: [e]))
        XCTAssertNil(CalendarMatcher.bestEvent(for: .phoneCall, meetingID: nil, start: t0, end: t0 + 600, in: [e]))
        XCTAssertNil(CalendarMatcher.bestEvent(for: .unknown, meetingID: nil, start: t0, end: t0 + 600, in: [e]))
    }

    func testAPlatformThisBuildDoesNotKnowIsWrittenBackAsItWasRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try CallRecord(id: "20270115-090000", platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + 600, status: .written).save(to: dir)
        let file = dir.appendingPathComponent(CallRecord.fileName)
        try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: #""meet""#, with: #""fax""#).write(to: file, atomically: true, encoding: .utf8)

        var r = try CallRecord.load(from: dir)
        XCTAssertEqual(r.platform, .unknown)
        r.summary = "Saved by this build."
        try r.save(to: dir)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(#""platform":"fax""#), text)
        XCTAssertEqual(try CallRecord.load(from: dir).platform, .unknown)

        // A platform this build sets is written as itself.
        r.platform = .phoneCall
        try r.save(to: dir)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(#""platform":"phoneCall""#))
    }
}
