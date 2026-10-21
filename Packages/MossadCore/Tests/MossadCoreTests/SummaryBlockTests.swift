import XCTest
@testable import MossadCore

final class SummaryBlockTests: XCTestCase {
    func testPlainSummaryIsOneParagraph() {
        XCTAssertEqual(SummaryBlock.parse("The team met. Cushions ship Friday."), [.paragraph("The team met. Cushions ship Friday.")])
    }

    func testBlankLinesSplitParagraphsAndWrappedLinesJoin() {
        XCTAssertEqual(SummaryBlock.parse("First line\nsame paragraph.\n\nSecond."),
                       [.paragraph("First line same paragraph."), .paragraph("Second.")])
    }

    func testHeadingsBulletsAndBoldStayInline() {
        let md = """
        Lead with **$1.2M** in orders.

        ### Freight
        - Ships **Friday**
        * Two trucks
        Carrier is booked.
        ### Next
        """
        XCTAssertEqual(SummaryBlock.parse(md), [
            .paragraph("Lead with **$1.2M** in orders."),
            .heading("Freight"),
            .bullets(["Ships **Friday**", "Two trucks"]),
            .paragraph("Carrier is booked."),
            .heading("Next"),
        ])
    }

    func testEmptyInputHasNoBlocks() {
        XCTAssertEqual(SummaryBlock.parse("  \n\n"), [])
    }
}
