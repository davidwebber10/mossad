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

    /// A late script must not run on the main thread after detection stopped waiting for it.
    func testOnMainDoesNotRunWorkAfterItGaveUp() {
        let finished = DispatchSemaphore(value: 0)
        let ran = Box()
        DispatchQueue.global().async {
            _ = onMain(timeout: 0.2) { ran.value = 1; return 1 }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        // The main thread is free again: the queued block runs now, and must do nothing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(ran.value)
    }

    func testTheScriptOutputParses() {
        let output = "https://meet.google.com/abc-defg-hij\tMeet - abc-defg-hij\t1\nhttps://example.com/\tA\ttitle\t0\n"
        XCTAssertEqual(BrowserTabProbe.parse(output), [
            BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true),
            BrowserTab(url: "https://example.com/", title: "A\ttitle", isActive: false),
        ])
        XCTAssertEqual(BrowserTabProbe.parse(""), [])
    }

    /// Arc has no `active tab index`; its script compares tab ids instead.
    func testEachBrowserReadsItsSelectedTabItsOwnWay() {
        XCTAssertTrue(BrowserTabProbe.script(browserBundleID: "com.google.Chrome").contains("active tab index of w"))
        XCTAssertTrue(BrowserTabProbe.script(browserBundleID: "com.apple.Safari").contains("index of current tab of w"))
        let arc = BrowserTabProbe.script(browserBundleID: "company.thebrowser.Browser")
        XCTAssertFalse(arc.contains("active tab index"))
        XCTAssertTrue(arc.contains("id of active tab of w"))
    }

    /// Every script must compile; this runs no Apple event, so it needs no browser and no permission.
    func testEveryBrowserScriptCompiles() {
        for browser in MeetingMatcher.browserBundleIDs {
            let compiled = onMain(timeout: 10) { () -> Bool in
                var error: NSDictionary?
                // Without the browser's dictionary the terms cannot be checked, so only browsers on this Mac count.
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) != nil else { return true }
                let ok = NSAppleScript(source: BrowserTabProbe.script(browserBundleID: browser))?.compileAndReturnError(&error) ?? false
                if !ok { print("\(browser): \(String(describing: error))") }
                return ok
            }
            XCTAssertEqual(compiled, true, browser)
        }
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
