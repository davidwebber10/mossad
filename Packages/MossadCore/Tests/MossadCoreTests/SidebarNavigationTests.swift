import XCTest
@testable import MossadCore

/// The arrow keys in the sidebar move through the rows that show: the items and the pages of the item that is open.
final class SidebarNavigationTests: XCTestCase {
    typealias Nav = SidebarNavigation<String>
    // Meetings: a page of its own with pages under it. Coach: its click opens its first page.
    let items = [Nav.Item(id: "meetings", children: ["bookmarks", "screens", "shares", "tasks"]),
                 Nav.Item(id: "chat"),
                 Nav.Item(id: "coach", children: ["findings", "goals", "weekly"], opensFirstChild: true),
                 Nav.Item(id: "settings")]

    func spot(_ item: String, _ child: String? = nil) -> Nav.Spot { Nav.Spot(item: item, child: child) }

    func testOnlyTheOpenItemShowsItsPagesAndAnItemThatOpensItsFirstPageIsNotARowOfItsOwnWhileOpen() {
        XCTAssertEqual(Nav.rows(items, at: spot("chat")).map(\.label), ["meetings", "chat", "coach", "settings"])
        XCTAssertEqual(Nav.rows(items, at: spot("meetings")).map(\.label),
                       ["meetings", "bookmarks", "screens", "shares", "tasks", "chat", "coach", "settings"])
        XCTAssertEqual(Nav.rows(items, at: spot("coach", "goals")).map(\.label), ["meetings", "chat", "findings", "goals", "weekly", "settings"])
    }

    func testTheArrowsGoThroughThePagesOfTheOpenItem() {
        XCTAssertEqual(Nav.step(items, from: spot("meetings"), by: 1), spot("meetings", "bookmarks"))
        XCTAssertEqual(Nav.step(items, from: spot("meetings", "tasks"), by: 1), spot("chat"))
        XCTAssertEqual(Nav.step(items, from: spot("meetings", "bookmarks"), by: -1), spot("meetings"))
        // Down from Chat opens Coach on its first page, then the next page; up from the first page leaves Coach.
        XCTAssertEqual(Nav.step(items, from: spot("chat"), by: 1), spot("coach", "findings"))
        XCTAssertEqual(Nav.step(items, from: spot("coach", "findings"), by: 1), spot("coach", "goals"))
        XCTAssertEqual(Nav.step(items, from: spot("coach", "findings"), by: -1), spot("chat"))
        // Up from Chat goes to Meetings, not to the pages of Meetings, which are hidden.
        XCTAssertEqual(Nav.step(items, from: spot("chat"), by: -1), spot("meetings"))
        // The ends hold.
        XCTAssertEqual(Nav.step(items, from: spot("meetings"), by: -1), spot("meetings"))
        XCTAssertEqual(Nav.step(items, from: spot("settings"), by: 1), spot("settings"))
    }

    func testAnItemThatOpensItsFirstPageIsThatPageAndTheEndsAreTheFirstAndLastRows() {
        XCTAssertEqual(Nav.open(items, item: "coach"), spot("coach", "findings"))
        XCTAssertEqual(Nav.open(items, item: "meetings"), spot("meetings"))
        XCTAssertEqual(Nav.first(items, at: spot("coach", "goals")), spot("meetings"))
        XCTAssertEqual(Nav.last(items, at: spot("chat")), spot("settings"))
    }

    func testAPlaceThatIsNotARowMovesFromItsItem() {
        XCTAssertEqual(Nav.step(items, from: spot("meetings", "gone"), by: 1), spot("meetings", "bookmarks"))
        XCTAssertEqual(Nav.step(items, from: spot("coach", "gone"), by: 1), spot("coach", "goals"))
        XCTAssertNil(Nav.step(items, from: spot("nowhere"), by: 1))
    }
}

private extension SidebarNavigation.Spot where ID == String {
    var label: String { child ?? item }
}
