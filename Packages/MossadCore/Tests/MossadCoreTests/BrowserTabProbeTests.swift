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
}
