import XCTest
@testable import MossadCore

final class LevelMeterTests: XCTestCase {
    func testKeepsTheLatestLevelsOldestFirst() {
        let meter = LevelMeter(capacity: 3)
        for level: Float in [0.1, 0.2, 0.3, 0.4] { meter.record(level) }
        XCTAssertEqual(meter.history, [0.2, 0.3, 0.4])
    }

    func testResetClearsTheHistory() {
        let meter = LevelMeter(capacity: 3)
        meter.record(0.5)
        meter.reset()
        XCTAssertEqual(meter.history, [])
    }

    func testTheWriterFeedsItsMeter() throws {
        let meter = LevelMeter()
        let url = tempDirectory().appendingPathComponent("t.caf")
        let writer = try TrackWriter(url: url, startTime: Date(), clock: { Date() }, meter: meter)
        try writer.append(sineBuffer(seconds: 0.5, sampleRate: 16_000, channels: 1, amplitude: 0.5))
        writer.close()
        XCTAssertGreaterThan(meter.history.last ?? 0, 0.2)
    }
}

final class TrackWriterPauseTests: XCTestCase {
    func testAPauseIsLeftOutOfTheTrack() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var now = t0
        let writer = try TrackWriter(url: tempDirectory().appendingPathComponent("t.caf"), startTime: t0, clock: { now })
        now = t0.addingTimeInterval(1)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.pause()
        now = t0.addingTimeInterval(30)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))  // ignored while paused
        now = t0.addingTimeInterval(61)
        writer.resume()
        now = t0.addingTimeInterval(62)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        XCTAssertEqual(writer.duration, 2, accuracy: 0.05)
    }
}

final class AudioSinkTests: XCTestCase {
    func testTheWriterSendsItsAudioToTheSink() throws {
        let sink = AudioSink()
        let count = Box()
        sink.set { buffer in count.add(Int(buffer.frameLength)) }
        let writer = try TrackWriter(url: tempDirectory().appendingPathComponent("t.caf"), startTime: Date(), clock: { Date() }, sink: sink)
        try writer.append(sineBuffer(seconds: 0.5, sampleRate: 16_000, channels: 1))
        XCTAssertEqual(count.value, 8_000)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func add(_ n: Int) { lock.withLock { total += n } }
        var value: Int { lock.withLock { total } }
    }
}
