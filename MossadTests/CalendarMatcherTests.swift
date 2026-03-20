import XCTest
@testable import MossadService

final class CalendarMatcherTests: XCTestCase {
    func testExtractMeetURLFromEventNotes() {
        let notes = "Join: https://meet.google.com/abc-defg-hij\nAgenda: sprint review"
        let urls = CalendarMatcher.extractMeetingURLs(from: notes)
        XCTAssertTrue(urls.contains("https://meet.google.com/abc-defg-hij"))
    }
    func testExtractZoomURLFromEventLocation() {
        let location = "https://zoom.us/j/1234567890?pwd=abcdef"
        let urls = CalendarMatcher.extractMeetingURLs(from: location)
        XCTAssertTrue(urls.contains(location))
    }
    func testExtractTeamsURL() {
        let notes = "Click here: https://teams.microsoft.com/l/meetup-join/abc123"
        let urls = CalendarMatcher.extractMeetingURLs(from: notes)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls.first?.contains("teams.microsoft.com") ?? false)
    }
    func testMatchesMeetURL() {
        let eventURLs = ["https://meet.google.com/abc-defg-hij"]
        XCTAssertTrue(CalendarMatcher.urlMatches(detected: "https://meet.google.com/abc-defg-hij", eventURLs: eventURLs))
    }
    func testMatchesZoomMeetingID() {
        let eventURLs = ["https://zoom.us/j/1234567890?pwd=abc"]
        XCTAssertTrue(CalendarMatcher.urlMatches(detected: "https://zoom.us/j/1234567890", eventURLs: eventURLs))
    }
    func testNoMatchReturnsFalse() {
        let eventURLs = ["https://meet.google.com/abc-defg-hij"]
        XCTAssertFalse(CalendarMatcher.urlMatches(detected: "https://meet.google.com/xyz-uvwx-rst", eventURLs: eventURLs))
    }
}
