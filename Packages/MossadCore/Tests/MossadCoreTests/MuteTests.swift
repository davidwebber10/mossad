import XCTest
@testable import MossadCore

final class MuteStateTests: XCTestCase {
    func testMeetButtonLabels() {
        XCTAssertEqual(MuteState.from(labels: ["Mute tab", "Turn on microphone"], platform: .meet), true)
        XCTAssertEqual(MuteState.from(labels: ["Turn off microphone (⌘ + d)"], platform: .meet), false)
        XCTAssertNil(MuteState.from(labels: ["Mute tab", "Leave call"], platform: .meet))
    }

    func testZoomAndTeamsLabels() {
        XCTAssertEqual(MuteState.from(labels: ["Unmute audio"], platform: .zoom), true)
        XCTAssertEqual(MuteState.from(labels: ["Mute audio"], platform: .zoom), false)
        XCTAssertEqual(MuteState.from(labels: ["Unmute (⌘+Shift+M)"], platform: .teams), true)
        XCTAssertEqual(MuteState.from(labels: ["Mute (⌘+Shift+M)"], platform: .teams), false)
    }
}

final class MutedTrackTests: XCTestCase {
    func testMutedAudioBecomesSilenceOfTheSameLength() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var now = t0
        let url = tempDirectory().appendingPathComponent("me.caf")
        let meter = LevelMeter()
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now }, meter: meter)
        now = t0.addingTimeInterval(1)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.isMuted = true
        now = t0.addingTimeInterval(2)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.close()
        XCTAssertEqual(writer.duration, 2, accuracy: 0.05)
        XCTAssertLessThan(try AudioSamples.read(url, from: 1.1, to: 1.9).map(abs).max() ?? 1, 0.001)
        XCTAssertEqual(meter.history.last, 0)
    }
}
