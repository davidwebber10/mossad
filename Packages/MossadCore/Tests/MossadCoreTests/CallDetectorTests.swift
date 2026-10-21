import XCTest
@testable import MossadCore

final class CallDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func snap(_ seconds: TimeInterval, _ candidates: [MeetingCandidate]) -> DetectionSnapshot {
        DetectionSnapshot(time: t0.addingTimeInterval(seconds), candidates: candidates)
    }

    func meet(mic: Bool, present: Bool?) -> MeetingCandidate {
        MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: mic, meetingPresent: present)
    }

    func zoom(mic: Bool, present: Bool?) -> MeetingCandidate {
        MeetingCandidate(platform: .zoom, bundleID: "us.zoom.xos", micActive: mic, meetingPresent: present)
    }

    func started(_ d: inout CallDetector) {
        XCTAssertEqual(d.process(snap(0, [meet(mic: true, present: true)])),
                       .started(platform: .meet, bundleID: "com.google.Chrome", at: t0))
    }

    func testStartsWhenMicActiveAndMeetingPresent() {
        var d = CallDetector()
        started(&d)
        XCTAssertTrue(d.isInCall)
    }

    func testDoesNotStartWhenMeetingPresentFalse() {
        var d = CallDetector()
        XCTAssertNil(d.process(snap(0, [meet(mic: true, present: false)])))
        XCTAssertFalse(d.isInCall)
    }

    func testDoesNotStartWithoutMic() {
        var d = CallDetector()
        XCTAssertNil(d.process(snap(0, [zoom(mic: false, present: true)])))
    }

    func testStartsWhenMeetingPresentUnknownAndMicActive() {
        var d = CallDetector()
        let teams = MeetingCandidate(platform: .teams, bundleID: "com.microsoft.teams2", micActive: true, meetingPresent: nil)
        XCTAssertEqual(d.process(snap(0, [teams])), .started(platform: .teams, bundleID: "com.microsoft.teams2", at: t0))
    }

    func testMicReleaseWithWindowPresentDoesNotEnd() {
        var d = CallDetector()
        started(&d)
        for s in stride(from: 2.0, through: 170, by: 2) {
            XCTAssertNil(d.process(snap(s, [meet(mic: false, present: true)])), "ended at \(s)")
        }
        XCTAssertTrue(d.isInCall)
    }

    func testEndsAfterTwoGoneTicks() {
        var d = CallDetector()
        started(&d)
        XCTAssertNil(d.process(snap(2, [meet(mic: true, present: false)])))
        XCTAssertEqual(d.process(snap(4, [meet(mic: false, present: false)])), .ended(at: t0.addingTimeInterval(4), trimTo: nil))
        XCTAssertFalse(d.isInCall)
    }

    func testGoneFlickerResets() {
        var d = CallDetector()
        started(&d)
        XCTAssertNil(d.process(snap(2, [meet(mic: true, present: false)])))
        XCTAssertNil(d.process(snap(4, [meet(mic: true, present: true)])))
        XCTAssertNil(d.process(snap(6, [meet(mic: true, present: false)])))
        XCTAssertTrue(d.isInCall)
    }

    func testEndsByMicIdleFallback() {
        var d = CallDetector()
        started(&d)
        XCTAssertNil(d.process(snap(10, [meet(mic: true, present: true)])))
        var event: DetectorEvent?
        var s = 12.0
        while event == nil && s < 400 {
            event = d.process(snap(s, [meet(mic: false, present: nil)]))
            if event == nil { s += 2 }
        }
        XCTAssertEqual(s, 190)
        XCTAssertEqual(event, .ended(at: t0.addingTimeInterval(190), trimTo: t0.addingTimeInterval(10)))
    }

    func testCandidateDisappearsCountsAsGone() {
        var d = CallDetector()
        started(&d)
        XCTAssertNil(d.process(snap(2, [])))
        XCTAssertEqual(d.process(snap(4, [])), .ended(at: t0.addingTimeInterval(4), trimTo: nil))
    }

    func testOnlyOneCallAtATime() {
        var d = CallDetector()
        started(&d)
        XCTAssertNil(d.process(snap(2, [meet(mic: true, present: true), zoom(mic: true, present: true)])))
        XCTAssertEqual(d.currentBundleID, "com.google.Chrome")
    }
}
