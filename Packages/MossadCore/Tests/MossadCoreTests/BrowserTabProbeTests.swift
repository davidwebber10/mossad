import XCTest
@testable import MossadCore

final class BrowserTabProbeTests: XCTestCase {
    /// Inside a browser's tell block, `tab` names the browser's tab class, not the tab character,
    /// so the separators must be made before the block.
    func testSeparatorsAreDefinedOutsideTheTellBlock() {
        for browser in MeetingMatcher.browserBundleIDs {
            let source = BrowserTabProbe.script(browserBundleID: browser)
            let tell = source.range(of: "tell application")!
            let body = source[tell.lowerBound...]
            XCTAssertFalse(body.contains("& tab &"), browser)
            XCTAssertFalse(body.contains("& linefeed"), browser)
            XCTAssertNotNil(source[..<tell.lowerBound].range(of: "set sep to character id 9"), browser)
        }
    }

    func testOnMainGivesUpWhenTheMainThreadIsBusy() {
        let finished = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global().async {
            box.value = onMain(timeout: 0.2) { 1 }
            finished.signal()
        }
        // This blocks the main thread, as a stuck UI would.
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success, "onMain waited for a blocked main thread")
        XCTAssertNil(box.value)
    }

    func testOnMainReturnsTheResultWhenTheMainThreadIsFree() {
        let done = expectation(description: "done")
        let box = Box()
        DispatchQueue.global().async {
            box.value = onMain(timeout: 2) { 7 }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(box.value, 7)
    }
}

private final class Box: @unchecked Sendable { var value: Int? }
