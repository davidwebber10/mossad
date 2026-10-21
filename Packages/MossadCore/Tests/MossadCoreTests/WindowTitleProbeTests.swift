import XCTest
@testable import MossadCore

final class WindowTitleProbeTests: XCTestCase {
    func testAFailedReadIsUnknownNotEmpty() {
        XCTAssertNil(WindowTitleProbe.combine([["Zoom Meeting"], nil]))
        XCTAssertEqual(WindowTitleProbe.combine([["Zoom Meeting"], ["Zoom Workplace"]]), ["Zoom Meeting", "Zoom Workplace"])
        XCTAssertEqual(WindowTitleProbe.combine([[]]), [])
    }
}
