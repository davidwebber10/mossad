import XCTest
@testable import MossadService

final class ProcessMonitorTests: XCTestCase {
    func testIdentifyZoomProcess() {
        let result = ProcessMonitor.identifyPlatform(bundleIdentifier: "us.zoom.xos", processName: "zoom.us")
        XCTAssertEqual(result, .zoom)
    }
    func testIdentifyTeamsProcess() {
        let result = ProcessMonitor.identifyPlatform(bundleIdentifier: "com.microsoft.teams2", processName: "Microsoft Teams")
        XCTAssertEqual(result, .teams)
    }
    func testIdentifyUnknownProcess() {
        let result = ProcessMonitor.identifyPlatform(bundleIdentifier: "com.apple.Safari", processName: "Safari")
        XCTAssertNil(result)
    }
    func testExtractMeetURLFromBrowserTitle() {
        let url = ProcessMonitor.extractMeetingURL(from: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(url, "https://meet.google.com/abc-defg-hij")
    }
    func testExtractZoomMeetingID() {
        let meetingId = ProcessMonitor.extractZoomMeetingId(from: "https://zoom.us/j/1234567890?pwd=abc")
        XCTAssertEqual(meetingId, "1234567890")
    }
}
