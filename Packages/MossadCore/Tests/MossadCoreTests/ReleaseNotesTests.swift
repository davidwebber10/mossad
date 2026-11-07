import XCTest
@testable import MossadCore

final class ReleaseNotesTests: XCTestCase {
    func testReadsListItemsAsPlainLines() {
        let html = "<ul><li>Faster sync</li>\n<li>New <b>Log</b> page</li><li>Fix &amp; polish &lt;People&gt;</li></ul>"
        XCTAssertEqual(ReleaseNotes(html: html).lines, ["Faster sync", "New Log page", "Fix & polish <People>"])
    }

    func testSkipsEmptyItemsAndTrimsSpace() {
        let html = "<ul>\n  <li>  One  </li><li></li><LI class=\"x\">Two</LI>\n</ul>"
        XCTAssertEqual(ReleaseNotes(html: html).lines, ["One", "Two"])
    }

    func testFallsBackToTextWhenThereIsNoList() {
        XCTAssertEqual(ReleaseNotes(html: "<p>Bug fixes</p>").lines, ["Bug fixes"])
        XCTAssertEqual(ReleaseNotes(html: nil).lines, [])
        XCTAssertEqual(ReleaseNotes(html: "  ").lines, [])
    }

    func testPreviewShowsFirstThreeAndCountsTheRest() {
        let notes = ReleaseNotes(lines: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(notes.preview.lines, ["a", "b", "c"])
        XCTAssertEqual(notes.preview.more, "and 2 more")
        XCTAssertNil(ReleaseNotes(lines: ["a", "b", "c"]).preview.more)
        XCTAssertEqual(ReleaseNotes(lines: ["a", "b", "c", "d"]).preview.more, "and 1 more")
    }
}
