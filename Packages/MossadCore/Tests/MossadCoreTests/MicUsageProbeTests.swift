import XCTest
import CoreAudio
@testable import MossadCore

final class FakeAudioSource: AudioProcessSource {
    struct Object {
        var bundleID: String?
        var pid: pid_t? = 1
        var input: Bool? = false
        var output: Bool? = false
    }
    var objects: [AudioObjectID: Object] = [:]
    var order: [AudioObjectID]? = []
    var inputDeviceRunning: Bool? = true
    var reads: [String] = []

    func processObjects() -> [AudioObjectID]? { order }
    func bundleID(of id: AudioObjectID) -> String? { reads.append("bundle \(id)"); return objects[id]?.bundleID }
    func pid(of id: AudioObjectID) -> pid_t? { reads.append("pid \(id)"); return objects[id]?.pid }
    func isRunningInput(_ id: AudioObjectID) -> Bool? { reads.append("input \(id)"); return objects[id]?.input }
    func isRunningOutput(_ id: AudioObjectID) -> Bool? { reads.append("output \(id)"); return objects[id]?.output }
    func anyInputDeviceRunning() -> Bool? { reads.append("gate"); return inputDeviceRunning }
}

final class MicUsageProbeTests: XCTestCase {
    let source = FakeAudioSource()
    lazy var probe = MicUsageProbe(source: source)
    let chrome = "com.google.Chrome.helper"
    let zoom = "us.zoom.xos"

    func testTheBundleIDAndThePIDAreReadOncePerObject() {
        source.objects = [1: .init(bundleID: chrome, pid: 41, input: true, output: true), 2: .init(bundleID: "com.example.player")]
        source.order = [1, 2]
        XCTAssertEqual(probe.scan(callActive: true), [AudioProcess(objectID: 1, pid: 41, bundleID: chrome, isRunningInput: true, isRunningOutput: true)])
        source.reads = []
        _ = probe.scan(callActive: true)
        XCTAssertEqual(source.reads, ["input 1", "output 1"])
    }

    func testAnAppThatIsNotAMeetingAppIsNeverAskedForItsState() {
        source.objects = [2: .init(bundleID: "com.example.player", input: true, output: true)]
        source.order = [2]
        XCTAssertEqual(probe.scan(callActive: true), [])
        XCTAssertFalse(source.reads.contains("input 2"))
        XCTAssertFalse(source.reads.contains("output 2"))
        XCTAssertFalse(source.reads.contains("pid 2"))
    }

    func testAnObjectThatLeftIsForgotten() {
        source.objects = [1: .init(bundleID: chrome)]
        source.order = [1]
        _ = probe.scan(callActive: true)
        source.order = []
        _ = probe.scan(callActive: true)
        source.objects = [1: .init(bundleID: zoom)]
        source.order = [1]
        XCTAssertEqual(probe.scan(callActive: true)?.first?.bundleID, zoom)
    }

    func testAFailedStateReadIsUnknownNotOff() {
        source.objects = [1: .init(bundleID: chrome, input: nil, output: nil)]
        source.order = [1]
        let found = probe.scan(callActive: true)
        XCTAssertEqual(found?.count, 1)
        XCTAssertNil(found?.first?.isRunningInput)
        XCTAssertNil(found?.first?.isRunningOutput)
    }

    func testAFailedListReadIsUnknown() {
        source.order = nil
        XCTAssertNil(probe.scan(callActive: true))
    }

    func testAFailedBundleIDReadIsTriedAgain() {
        source.objects = [1: .init(bundleID: nil)]
        source.order = [1]
        XCTAssertEqual(probe.scan(callActive: true), [])
        source.objects[1]?.bundleID = chrome
        XCTAssertEqual(probe.scan(callActive: true)?.count, 1)
    }

    func testAFailedPIDReadIsTriedAgain() {
        source.objects = [1: .init(bundleID: chrome, pid: nil)]
        source.order = [1]
        XCTAssertEqual(probe.scan(callActive: true)?.first?.pid, -1)
        source.objects[1]?.pid = 77
        XCTAssertEqual(probe.scan(callActive: true)?.first?.pid, 77)
    }

    /// The audio server can list a process before it knows its name.
    func testAnEmptyBundleIDIsAskedAgain() {
        source.objects = [1: .init(bundleID: "")]
        source.order = [1]
        XCTAssertEqual(probe.scan(callActive: true), [])
        source.objects[1]?.bundleID = chrome
        XCTAssertEqual(probe.scan(callActive: true)?.first?.bundleID, chrome)
    }

    /// After a restart of the audio server the same numbers can name other processes.
    func testAfterAnUnreadableOrEmptyListEveryObjectIsReadAgain() {
        source.objects = [1: .init(bundleID: "com.example.player")]
        source.order = [1]
        XCTAssertEqual(probe.scan(callActive: true), [])
        source.order = nil
        XCTAssertNil(probe.scan(callActive: true))
        source.objects = [1: .init(bundleID: chrome, input: true)]
        source.order = [1]
        XCTAssertEqual(probe.scan(callActive: true)?.first?.bundleID, chrome)
        source.order = []
        XCTAssertEqual(probe.scan(callActive: true), [])
        source.objects = [1: .init(bundleID: zoom)]
        source.order = [1]
        XCTAssertEqual(probe.scan(callActive: true)?.first?.bundleID, zoom)
    }

    func testForgetAndTheRegularRefreshReadEveryObjectAgain() {
        source.objects = [1: .init(bundleID: chrome)]
        source.order = [1]
        _ = probe.scan(callActive: true)
        source.objects = [1: .init(bundleID: zoom)]
        XCTAssertEqual(probe.scan(callActive: true)?.first?.bundleID, chrome, "the name is kept between scans")
        probe.forget()
        XCTAssertEqual(probe.scan(callActive: true)?.first?.bundleID, zoom)
        source.objects = [1: .init(bundleID: chrome)]
        for _ in 0..<MicUsageProbe.scansBeforeRefresh { _ = probe.scan(callActive: true) }
        XCTAssertEqual(probe.scan(callActive: true)?.first?.bundleID, chrome, "and read again after 5 minutes of scans")
    }

    /// With no input device running, no app can use the mic: the mic state is known without a read.
    func testOutsideACallWithNoInputDeviceRunningOnlyZoomAndTeamsAreAskedForSound() {
        source.objects = [1: .init(bundleID: chrome, input: false, output: true), 2: .init(bundleID: zoom, input: false, output: true)]
        source.order = [1, 2]
        _ = probe.scan(callActive: true)
        source.inputDeviceRunning = false
        source.reads = []
        let found = probe.scan(callActive: false)
        XCTAssertEqual(source.reads, ["gate", "output 2"])
        XCTAssertEqual(found, [
            AudioProcess(objectID: 1, pid: 1, bundleID: chrome, isRunningInput: false, isRunningOutput: nil),
            AudioProcess(objectID: 2, pid: 1, bundleID: zoom, isRunningInput: false, isRunningOutput: true),
        ])
    }

    func testOutsideACallWithAnInputDeviceRunningEveryMeetingAppIsAsked() {
        source.objects = [1: .init(bundleID: chrome, input: true, output: true)]
        source.order = [1]
        source.inputDeviceRunning = true
        XCTAssertEqual(probe.scan(callActive: false)?.first?.isRunningInput, true)
    }

    func testAGateThatCannotBeReadIsOpen() {
        source.objects = [1: .init(bundleID: chrome, input: true, output: true)]
        source.order = [1]
        source.inputDeviceRunning = nil
        XCTAssertEqual(probe.scan(callActive: false)?.first?.isRunningInput, true)
    }

    func testDuringACallTheGateIsNotUsed() {
        source.objects = [1: .init(bundleID: chrome, input: true, output: true)]
        source.order = [1]
        source.inputDeviceRunning = false
        XCTAssertEqual(probe.scan(callActive: true)?.first?.isRunningInput, true)
        XCTAssertFalse(source.reads.contains("gate"))
    }

    /// The real audio server answers, and the scan lists only meeting apps.
    func testTheRealScanAnswers() {
        let real = MicUsageProbe()
        let found = real.scan(callActive: false)
        XCTAssertNotNil(found)
        XCTAssertTrue((found ?? []).allSatisfy { MeetingMatcher.appKind(bundleID: $0.bundleID) != nil })
    }
}
