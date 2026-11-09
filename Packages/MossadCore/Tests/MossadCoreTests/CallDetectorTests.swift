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

    func testAnUnknownTickDoesNotResetTheGoneCount() {
        var d = CallDetector()
        started(&d)
        XCTAssertNil(d.process(snap(2, [meet(mic: true, present: false)])))
        XCTAssertNil(d.process(snap(4, [meet(mic: true, present: nil)])))
        XCTAssertEqual(d.process(snap(6, [meet(mic: false, present: false)])), .ended(at: t0.addingTimeInterval(6), trimTo: nil))
    }

    /// Chrome once answered with no Meet tab for a few seconds at a time while the call went on, and each answer
    /// ended the call; the pieces under a minute were discarded. With the mic still in use, a missing tab must
    /// last before it ends the call.
    func testAMissingTabWhileTheMicIsInUseDoesNotEndTheCallAtOnce() {
        var d = CallDetector()
        started(&d)
        for s in stride(from: 2.0, through: 30, by: 2) {
            XCTAssertNil(d.process(snap(s, [meet(mic: true, present: false)])), "ended at \(s)")
        }
        XCTAssertEqual(d.process(snap(32, [meet(mic: true, present: false)])), .ended(at: t0.addingTimeInterval(32), trimTo: nil))
    }

    func testATabThatComesBackKeepsTheCall() {
        var d = CallDetector()
        started(&d)
        for s in stride(from: 2.0, through: 20, by: 2) { XCTAssertNil(d.process(snap(s, [meet(mic: true, present: false)]))) }
        XCTAssertNil(d.process(snap(22, [meet(mic: true, present: true)])))
        for s in stride(from: 24.0, through: 50, by: 2) {
            XCTAssertNil(d.process(snap(s, [meet(mic: true, present: false)])), "ended at \(s)")
        }
        XCTAssertTrue(d.isInCall)
    }

    func testDoesNotStartWithoutMic() {
        var d = CallDetector()
        XCTAssertNil(d.process(snap(0, [zoom(mic: false, present: true)])))
    }

    func sureZoom(mic: Bool, present: Bool?) -> MeetingCandidate {
        MeetingCandidate(platform: .zoom, bundleID: "us.zoom.xos", micActive: mic, meetingPresent: present, presenceIsSure: true)
    }

    /// The owner joins a Zoom meeting muted, and Zoom does not open the mic: the meeting window alone starts it.
    func testASurePresenceStartsACallWithoutTheMic() {
        var d = CallDetector()
        XCTAssertEqual(d.process(snap(0, [sureZoom(mic: false, present: true)])), .started(platform: .zoom, bundleID: "us.zoom.xos", at: t0))
    }

    /// Zoom and Teams release the mic while the owner is muted. With the meeting window still open, the call
    /// once ended at 180 s and did not start again until the owner unmuted.
    func testAMutedZoomCallWithItsWindowOpenNeverEndsByTheMicRule() {
        var d = CallDetector()
        XCTAssertNotNil(d.process(snap(0, [sureZoom(mic: true, present: true)])))
        for s in stride(from: 2.0, through: 1200, by: 2) {
            XCTAssertNil(d.process(snap(s, [sureZoom(mic: false, present: true)])), "ended at \(s)")
        }
        XCTAssertTrue(d.isInCall)
        // The window closes: the call ends without a trim.
        XCTAssertNil(d.process(snap(1202, [sureZoom(mic: false, present: false)])))
        XCTAssertEqual(d.process(snap(1204, [sureZoom(mic: false, present: false)])), .ended(at: t0.addingTimeInterval(1204), trimTo: nil))
    }

    /// The mic rule counts from the last sure sign, so a brief unknown window after a long muted stretch neither
    /// ends the call at once nor trims away the muted part.
    func testTheMicRuleCountsFromTheLastSureSign() {
        var d = CallDetector()
        XCTAssertNotNil(d.process(snap(0, [sureZoom(mic: true, present: true)])))
        for s in stride(from: 2.0, through: 600, by: 2) { XCTAssertNil(d.process(snap(s, [sureZoom(mic: false, present: true)]))) }
        XCTAssertNil(d.process(snap(602, [sureZoom(mic: false, present: nil)])))
        XCTAssertNil(d.process(snap(700, [sureZoom(mic: false, present: nil)])))
        XCTAssertEqual(d.process(snap(780, [sureZoom(mic: false, present: nil)])), .ended(at: t0.addingTimeInterval(780), trimTo: t0.addingTimeInterval(600)))
    }

    /// Two "gone" answers ten minutes apart, with unknown answers between them, are not 30 s of absence.
    func testGoneReadingsFarApartDoNotAddUp() {
        var d = CallDetector()
        started(&d)
        XCTAssertNil(d.process(snap(2, [meet(mic: true, present: false)])))
        for s in stride(from: 4.0, through: 600, by: 2) { XCTAssertNil(d.process(snap(s, [meet(mic: true, present: nil)]))) }
        XCTAssertNil(d.process(snap(602, [meet(mic: true, present: false)])), "a stray answer must not end the call")
        XCTAssertTrue(d.isInCall)
    }

    func testStartsWhenMeetingPresentUnknownAndMicActive() {
        var d = CallDetector()
        let teams = MeetingCandidate(platform: .teams, bundleID: "com.microsoft.teams2", micActive: true, meetingPresent: nil)
        XCTAssertEqual(d.process(snap(0, [teams])), .started(platform: .teams, bundleID: "com.microsoft.teams2", at: t0))
    }

    func testZoomMicReleaseWithWindowPresentDoesNotEnd() {
        // Zoom can release the mic while muted, so a short mic gap must not end its call.
        var d = CallDetector()
        XCTAssertNotNil(d.process(snap(0, [zoom(mic: true, present: true)])))
        for s in stride(from: 2.0, through: 170, by: 2) {
            XCTAssertNil(d.process(snap(s, [zoom(mic: false, present: true)])), "ended at \(s)")
        }
        XCTAssertTrue(d.isInCall)
    }

    func testMeetEndsSoonAfterTheMicStopsEvenWithTheTabOpen() {
        // Meet keeps the mic open while muted and keeps its title on the page shown after you leave.
        var d = CallDetector()
        started(&d)
        XCTAssertNil(d.process(snap(10, [meet(mic: true, present: true)])))
        var event: DetectorEvent?
        var s = 12.0
        while event == nil && s < 400 {
            event = d.process(snap(s, [meet(mic: false, present: true)]))
            if event == nil { s += 2 }
        }
        XCTAssertEqual(s, 16)
        XCTAssertEqual(event, .ended(at: t0.addingTimeInterval(16), trimTo: t0.addingTimeInterval(10)))
    }

    func testMeetShortMicGapDoesNotEnd() {
        // An audio device change stops the mic for a moment.
        var d = CallDetector()
        started(&d)
        for s in stride(from: 2.0, through: 4, by: 2) {
            XCTAssertNil(d.process(snap(s, [meet(mic: false, present: true)])))
        }
        XCTAssertNil(d.process(snap(6, [meet(mic: true, present: true)])))
        XCTAssertNil(d.process(snap(10, [meet(mic: false, present: true)])))
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
        XCTAssertNotNil(d.process(snap(0, [zoom(mic: true, present: true)])))
        XCTAssertNil(d.process(snap(10, [zoom(mic: true, present: true)])))
        var event: DetectorEvent?
        var s = 12.0
        while event == nil && s < 400 {
            event = d.process(snap(s, [zoom(mic: false, present: nil)]))
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

final class CallDetectorForceTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 4_000_000)

    /// The owner pressed Record on the warning: the call starts at once, and only the mic can end it, because the
    /// meeting itself was never seen.
    func testAForcedCallEndsOnlyWhenTheMicStops() {
        var d = CallDetector()
        XCTAssertEqual(d.force(platform: .meet, bundleID: "com.google.Chrome", at: t0),
                       .started(platform: .meet, bundleID: "com.google.Chrome", at: t0))
        let gone = MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: true, meetingPresent: false)
        for i in 1...30 { XCTAssertNil(d.process(DetectionSnapshot(time: t0.addingTimeInterval(Double(i) * 2), candidates: [gone]))) }
        let quiet = MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: false, meetingPresent: nil)
        XCTAssertNil(d.process(DetectionSnapshot(time: t0.addingTimeInterval(62), candidates: [quiet])))
        XCTAssertNil(d.process(DetectionSnapshot(time: t0.addingTimeInterval(80), candidates: [quiet])))
        XCTAssertEqual(d.process(DetectionSnapshot(time: t0.addingTimeInterval(90), candidates: [quiet])),
                       .ended(at: t0.addingTimeInterval(90), trimTo: t0.addingTimeInterval(60)))
    }

    /// A forced browser call is guessed as Meet; a Zoom or Teams web call muted for a few seconds must not end.
    func testAForcedCallDoesNotUseTheShortMeetRule() {
        var d = CallDetector()
        _ = d.force(platform: .meet, bundleID: "com.google.Chrome", at: t0)
        let quiet = MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: false, meetingPresent: nil)
        for s in stride(from: 2.0, through: 28, by: 2) {
            XCTAssertNil(d.process(DetectionSnapshot(time: t0.addingTimeInterval(s), candidates: [quiet])), "ended at \(s)")
        }
    }

    /// A forced call ignores the presence signs, also a sure one.
    func testAForcedCallEndsByTheMicEvenWithASureSign() {
        var d = CallDetector()
        _ = d.force(platform: .zoom, bundleID: "us.zoom.xos", at: t0)
        let sure = MeetingCandidate(platform: .zoom, bundleID: "us.zoom.xos", micActive: false, meetingPresent: true, presenceIsSure: true)
        XCTAssertNotNil(d.process(DetectionSnapshot(time: t0.addingTimeInterval(180), candidates: [sure])))
    }

    func testForceDoesNothingDuringACall() {
        var d = CallDetector()
        _ = d.force(platform: .meet, bundleID: "com.google.Chrome", at: t0)
        XCTAssertNil(d.force(platform: .zoom, bundleID: "us.zoom.xos", at: t0))
    }
}
