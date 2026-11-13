import XCTest
@testable import MossadCore

/// The series the Recurring page shows, and the list state that Back and Forward keep.
final class SeriesShownTests: XCTestCase {
    let all = ["a", "b", "c"]

    func testTheSelectedSeriesWhileTheListShowsItElseTheFirstOfTheList() {
        XCTAssertEqual(SeriesShown.pick(selected: "b", asked: false, visible: ["a", "b"], all: all), "b")
        XCTAssertEqual(SeriesShown.pick(selected: "c", asked: false, visible: ["a", "b"], all: all), "a")
        XCTAssertEqual(SeriesShown.pick(selected: nil, asked: false, visible: ["b"], all: all), "b")
        XCTAssertNil(SeriesShown.pick(selected: "c", asked: false, visible: [], all: all))
    }

    /// Back, Forward, or a link asked for it: it shows while the list is still answering the search.
    func testASeriesAskedForShowsUntilTheOwnerChangesTheList() {
        XCTAssertEqual(SeriesShown.pick(selected: "c", asked: true, visible: ["a"], all: all), "c")
        // A series that ended is not shown, asked or not.
        XCTAssertEqual(SeriesShown.pick(selected: "gone", asked: true, visible: ["a"], all: all), "a")
    }

    // M1: in Calendar mode a link opens its series' page full-pane; the list mode selects it in the list.
    func testALinkOpensThePageFullPaneInCalendarMode() {
        XCTAssertEqual(SeriesShown.fullPane(calendarMode: true, request: "b", all: all), "b")
        XCTAssertNil(SeriesShown.fullPane(calendarMode: false, request: "b", all: all))
        // A key of the series finds it by its id now.
        XCTAssertEqual(SeriesShown.fullPane(calendarMode: true, request: "call:x", all: all, resolve: { $0 == "call:x" ? "c" : nil }), "c")
        XCTAssertNil(SeriesShown.fullPane(calendarMode: true, request: "gone", all: all))
    }

    func testALinkClearsAListThatHidesItsSeries() {
        XCTAssertTrue(SeriesShown.linkClearsList(to: "c", visible: ["a", "b"]))
        XCTAssertFalse(SeriesShown.linkClearsList(to: "a", visible: ["a", "b"]))
    }

    func testAPlaceKeepsTheRecurringSearchAndFilter() throws {
        var filter = SeriesFilter()
        filter.cadences = [.weekly]
        filter.next = .twoWeeks
        filter.lastMet = .last30
        filter.people = [.init(id: "p1", name: "Sam Carter")]
        let p = NavigationPlace(section: "Recurring", item: "a", search: "budget", seriesFilter: filter)
        XCTAssertEqual(try JSONDecoder().decode(NavigationPlace.self, from: JSONEncoder().encode(p)), p)
        XCTAssertNotEqual(p, NavigationPlace(section: "Recurring", item: "a", search: "budget"))
    }
}
