import XCTest
@testable import MossadCore

/// Back and forward in the main window, as a browser does: a step pushes, back and forward move, a new step after
/// back clears what was ahead, and a place that is gone is passed over.
final class NavigationHistoryTests: XCTestCase {
    func place(_ section: String, _ item: String? = nil, page: String? = nil, tab: String? = nil, search: String? = nil) -> NavigationPlace {
        NavigationPlace(section: section, page: page, item: item, tab: tab, search: search)
    }

    let keep: (NavigationPlace) -> NavigationPlace? = { $0 }

    func testAVisitPushesAndBackAndForwardMove() {
        var h = NavigationHistory()
        XCTAssertFalse(h.canGoBack)
        h.visit(place("Recurring", "s1"))
        h.visit(place("Meetings", "m1"))
        XCTAssertTrue(h.canGoBack)
        XCTAssertFalse(h.canGoForward)
        XCTAssertEqual(h.goBack(resolve: keep), place("Recurring", "s1"))
        XCTAssertEqual(h.current, place("Recurring", "s1"))
        XCTAssertFalse(h.canGoBack)
        XCTAssertTrue(h.canGoForward)
        XCTAssertEqual(h.goForward(resolve: keep), place("Meetings", "m1"))
        XCTAssertNil(h.goForward(resolve: keep))
        XCTAssertEqual(h.current, place("Meetings", "m1"))
    }

    func testTheSamePlaceIsNoStep() {
        var h = NavigationHistory()
        h.visit(place("People", "p1"))
        h.visit(place("People", "p1"))
        XCTAssertFalse(h.canGoBack)
        h.visit(place("People", "p1"), .refine)
        XCTAssertFalse(h.canGoBack)
    }

    func testAVisitAfterBackClearsForward() {
        var h = NavigationHistory()
        h.visit(place("Meetings", "m1"))
        h.visit(place("People", "p1"))
        h.visit(place("Chat"))
        _ = h.goBack(resolve: keep)
        _ = h.goBack(resolve: keep)
        XCTAssertEqual(h.forwardPlaces.count, 2)
        h.visit(place("Analytics"))
        XCTAssertFalse(h.canGoForward)
        XCTAssertEqual(h.backPlaces, [place("Meetings", "m1")])
    }

    func testARefinementInTheSameViewReplacesTheEntry() {
        var h = NavigationHistory()
        h.visit(place("Chat"))
        h.visit(place("Meetings", "m1", tab: "summary"))
        // Another row of the same list, and a search typed in it: the same entry, now with the latest state.
        h.visit(place("Meetings", "m2", tab: "summary"), .refine)
        h.visit(place("Meetings", "m2", tab: "summary", search: "budget"), .refine)
        XCTAssertEqual(h.current, place("Meetings", "m2", tab: "summary", search: "budget"))
        XCTAssertEqual(h.backPlaces, [place("Chat")])
        // A tab is a step, even as a refinement; so is another section.
        h.visit(place("Meetings", "m2", tab: "transcript", search: "budget"), .refine)
        XCTAssertEqual(h.backPlaces.count, 2)
        h.visit(place("People", "p1"), .refine)
        XCTAssertEqual(h.backPlaces.count, 3)
        // A jump in the same view is a step: a search result or a link to another meeting.
        h.visit(place("People", "p2"))
        XCTAssertEqual(h.backPlaces.count, 4)
    }

    func testARefinementKeepsWhatWasAheadOnlyWhenItReplaces() {
        var h = NavigationHistory()
        h.visit(place("Meetings", "m1"))
        h.visit(place("People", "p1"))
        _ = h.goBack(resolve: keep)
        // Another row after Back: the page that was ahead stays, as in a browser that changes a page's hash in place.
        h.visit(place("Meetings", "m2"), .refine)
        XCTAssertTrue(h.canGoForward)
        XCTAssertEqual(h.current, place("Meetings", "m2"))
    }

    func testAPageInASectionIsAStep() {
        var h = NavigationHistory()
        h.visit(place("Coach", page: "findings"))
        h.visit(place("Coach", page: "goals"), .refine)
        XCTAssertEqual(h.backPlaces, [place("Coach", page: "findings")])
    }

    func testTheHistoryHoldsAtMost100Places() {
        var h = NavigationHistory()
        for i in 0..<150 { h.visit(place("Meetings", "m\(i)")) }
        XCTAssertEqual(h.backPlaces.count + 1, NavigationHistory.cap)
        XCTAssertEqual(h.backPlaces.last, place("Meetings", "m50"))
        XCTAssertEqual(h.current, place("Meetings", "m149"))
    }

    func testAPlaceThatIsGoneIsPassedOverAndDropped() {
        var h = NavigationHistory()
        h.visit(place("Meetings", "m1"))
        h.visit(place("Meetings", "deleted"))
        h.visit(place("People", "p1"))
        let live: (NavigationPlace) -> NavigationPlace? = { $0.item == "deleted" ? nil : $0 }
        XCTAssertEqual(h.goBack(resolve: live), place("Meetings", "m1"))
        XCTAssertEqual(h.forwardPlaces, [place("People", "p1")])
        XCTAssertEqual(h.goForward(resolve: live), place("People", "p1"))
        XCTAssertEqual(h.backPlaces, [place("Meetings", "m1")])
    }

    func testNothingLiveBehindLeavesTheCurrentPlace() {
        var h = NavigationHistory()
        h.visit(place("Meetings", "deleted"))
        h.visit(place("People", "p1"))
        XCTAssertNil(h.goBack(resolve: { $0.item == "deleted" ? nil : $0 }))
        XCTAssertEqual(h.current, place("People", "p1"))
        XCTAssertFalse(h.canGoBack)
    }

    func testAMergedPersonComesBackAsThePersonOfNow() {
        var h = NavigationHistory()
        h.visit(place("People", "old-id"))
        h.visit(place("Chat"))
        let merged: (NavigationPlace) -> NavigationPlace? = { p in
            var p = p
            if p.item == "old-id" { p.item = "new-id" }
            return p
        }
        XCTAssertEqual(h.goBack(resolve: merged), place("People", "new-id"))
        XCTAssertEqual(h.forwardPlaces, [place("Chat")])
    }

    func testTheMenuJumpsSeveralStepsAtOnce() {
        var h = NavigationHistory()
        for s in ["a", "b", "c", "d"] { h.visit(place(s)) }
        XCTAssertEqual(h.backPlaces, [place("c"), place("b"), place("a")])
        XCTAssertEqual(h.goBack(steps: 2, resolve: keep), place("b"))
        XCTAssertEqual(h.forwardPlaces, [place("c"), place("d")])
        XCTAssertEqual(h.goForward(steps: 2, resolve: keep), place("d"))
        XCTAssertEqual(h.backPlaces, [place("c"), place("b"), place("a")])
    }

    func testCanGoTellsWhetherALivePlaceIsThere() {
        var h = NavigationHistory()
        h.visit(place("Meetings", "deleted"))
        h.visit(place("People", "p1"))
        XCTAssertTrue(h.canGoBack)
        XCTAssertFalse(h.canGoBack(resolve: { $0.item == "deleted" ? nil : $0 }))
    }

    func testAPlaceIsCodableWithTheMeetingsFilter() throws {
        var filter = MeetingFilter()
        filter.people = [.init(id: "p1", name: "Sam Carter")]
        filter.period = .custom(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 86_400))
        filter.lengths = [.to30]
        filter.flags = [.decisions]
        let p = NavigationPlace(section: "Meetings", item: "m1", tab: "transcript", search: "budget", filter: filter, time: 42)
        let back = try JSONDecoder().decode(NavigationPlace.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }
}
