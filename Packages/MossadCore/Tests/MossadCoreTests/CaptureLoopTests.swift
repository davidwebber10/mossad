import CoreGraphics
import XCTest
@testable import MossadCore

/// The capture of a meeting window started about 4 times a second for minutes: the search accepted a window that
/// the check of each frame refused at once.
final class CaptureLoopTests: XCTestCase {
    let chrome = "com.google.Chrome"

    func meet(_ title: String = "Meet - abc-defg-hij", width: Double = 2560, height: Double = 1352) -> WindowCandidate {
        WindowCandidate(id: 1213, bundleID: chrome, title: title, width: width, height: height, onScreen: true)
    }

    #if os(macOS)
    /// The check of each frame read the window with a list of CFNumbers, which the window server does not read:
    /// it answered with no window, so each frame said "gone".
    func testTheCheckOfEachFrameFindsAWindowThatTheSearchListed() throws {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] ?? []
        guard let id = list.lazy.compactMap({ $0[kCGWindowNumber] as? CGWindowID }).first else {
            throw XCTSkip("No window server")
        }
        let ids = WindowFrameSource.idList([id])
        XCTAssertEqual(CFArrayGetCount(ids), 1)
        XCTAssertEqual(UInt(bitPattern: CFArrayGetValueAtIndex(ids, 0)), UInt(id))
        XCTAssertNotNil(WindowFrameSource.describe(id), "the window \(id) is in the list but the check of a frame does not find it")
    }
    #endif

    func testTheSameWindowThatTheSearchAcceptsPassesTheCheckOfAFrame() {
        let w = meet()
        XCTAssertEqual(MeetingWindow.kind(of: w, among: [w], platform: .meet, bundleID: chrome), .meeting)
        let size = CGSize(width: w.width, height: w.height)
        XCTAssertNil(MeetingWindow.loss(of: w, size: size, platform: .meet, bundleID: chrome, pageMoved: { false }))
    }

    func testTheCheckOfAFrameSaysWhy() {
        let size = CGSize(width: 2560, height: 1352)
        func loss(_ now: WindowCandidate?, moved: Bool = false) -> MeetingWindow.Loss? {
            MeetingWindow.loss(of: now, size: size, platform: .meet, bundleID: chrome, pageMoved: { moved })
        }
        XCTAssertEqual(loss(nil), .gone)
        XCTAssertEqual(loss(meet("Inbox - Gmail")), .notMeeting)
        XCTAssertEqual(loss(meet(height: 1300)), .resized)
        XCTAssertEqual(loss(meet(), moved: true), .pageMoved)
        // Within the tolerance the size is the same.
        XCTAssertNil(loss(meet(width: 2561)))
        // Accessibility is asked only when the window server's answer holds.
        var asked = false
        _ = MeetingWindow.loss(of: meet("Inbox - Gmail"), size: size, platform: .meet, bundleID: chrome, pageMoved: { asked = true; return false })
        XCTAssertFalse(asked)
        XCTAssertFalse(MeetingWindow.Loss.gone.reason.isEmpty)
    }

    // MARK: Restarts

    func testAStreamLostSoonAfterItBeganRefusesTheWindowForLongerEachTime() {
        var restarts = StreamRestarts()
        var t = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(restarts.allows(1213, at: t))
        restarts.began(1213, at: t)
        t += 0.25
        XCTAssertEqual(restarts.lost(1213, at: t), .refused(30))
        XCTAssertFalse(restarts.allows(1213, at: t + 29))
        // Another window is not refused.
        XCTAssertTrue(restarts.allows(7, at: t))
        t += 30
        XCTAssertTrue(restarts.allows(1213, at: t))
        restarts.began(1213, at: t)
        XCTAssertEqual(restarts.lost(1213, at: t + 1), .refused(120))
        t += 1 + 120
        restarts.began(1213, at: t)
        XCTAssertEqual(restarts.lost(1213, at: t + 9), .refused(600))
        t += 9 + 600
        XCTAssertTrue(restarts.allows(1213, at: t))
        restarts.began(1213, at: t)
        XCTAssertEqual(restarts.lost(1213, at: t + 2), .refusedForTheCall)
        XCTAssertFalse(restarts.allows(1213, at: t + 86_400))
    }

    func testAStreamThatRanAWhileIsLostWithNoRefusal() {
        var restarts = StreamRestarts()
        let t = Date(timeIntervalSince1970: 1_000)
        restarts.began(1213, at: t)
        // The owner chose another tab after a minute.
        XCTAssertEqual(restarts.lost(1213, at: t + 60), StreamRestarts.Outcome.none)
        XCTAssertTrue(restarts.allows(1213, at: t + 60))
        // A loss with no start (the stream of another search) refuses nothing.
        XCTAssertEqual(restarts.lost(99, at: t), StreamRestarts.Outcome.none)
    }

    /// The loop of the owner's call: each start lost by its first frame, a quarter of a second later. Over 25
    /// minutes it gives a handful of starts, not thousands.
    func testALoopOfRestartsEndsAfterAFewStarts() {
        var restarts = StreamRestarts()
        var t = Date(timeIntervalSince1970: 1_000)
        var starts = 0
        for _ in 0..<(25 * 60 * 4) {
            if restarts.allows(1213, at: t) {
                starts += 1
                restarts.began(1213, at: t)
                _ = restarts.lost(1213, at: t + 0.1)
            }
            t += 0.25
        }
        XCTAssertEqual(starts, 4)
    }
}
