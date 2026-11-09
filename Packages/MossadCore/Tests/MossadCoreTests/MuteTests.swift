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
        // The new Teams app (com.microsoft.teams2), read during a call: the button and the participant tiles.
        let tiles = ["Myself video, Dana Lee, Has control of production tools, Unmuted, video is on, Has context menu",
                     "Sam Park, video is on, muted, Context menu is available"]
        XCTAssertEqual(MuteState.from(labels: ["Mute mic", "Mute mic"] + tiles, platform: .teams), false)
        XCTAssertEqual(MuteState.from(labels: ["Unmute mic", "Unmute mic"] + tiles, platform: .teams), true)
    }
}

final class MutedTrackTests: XCTestCase {
    /// The mute state comes late, so the writer never destroys audio on it: the file keeps the real samples (the
    /// recorder silences the muted spans when the call ends), and only the meter and the live stream go quiet.
    func testAMutedWriterKeepsTheSamplesAndQuietsTheMeterAndTheLiveStream() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var now = t0
        let url = tempDirectory().appendingPathComponent("me.caf")
        let meter = LevelMeter()
        let sink = AudioSink()
        let loudest = Loudest()
        sink.set { loudest.take(TrackWriter.rms($0)) }
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now }, meter: meter, sink: sink)
        writer.isMuted = true
        now = t0.addingTimeInterval(1)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.close()
        XCTAssertGreaterThan(try AudioSamples.read(url, from: 0.1, to: 0.9).map(abs).max() ?? 0, 0.3)
        XCTAssertEqual(meter.history.last, 0)
        XCTAssertEqual(loudest.value, 0)
    }
}

final class Loudest: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0
    var value: Float { lock.withLock { level } }
    func take(_ l: Float) { lock.withLock { level = max(level, l) } }
}
