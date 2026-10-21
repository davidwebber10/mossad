import AVFoundation
import XCTest
@testable import MossadCore

func sineBuffer(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount, amplitude: Double = 0.5) -> AVAudioPCMBuffer {
    let format = channels <= 2
        ? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        : AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                        channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float(sin(2 * .pi * 440 * Double(i) / sampleRate) * amplitude) }
    }
    return buffer
}

func audioDuration(_ url: URL) throws -> Double {
    let f = try AVAudioFile(forReading: url)
    return Double(f.length) / f.fileFormat.sampleRate
}

final class TrackWriterTests: XCTestCase {
    var dir: URL!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() { dir = tempDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testConvertsStereo48kToMono16k() throws {
        let url = dir.appendingPathComponent("t.caf")
        let writer = try TrackWriter(url: url, startTime: t0, clock: { self.t0.addingTimeInterval(1) })
        try writer.append(sineBuffer(seconds: 1, sampleRate: 48_000, channels: 2))
        writer.close()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length), 16_000, accuracy: 160)
    }

    func testTakesFirstChannelOfMultichannelInput() throws {
        let url = dir.appendingPathComponent("m.caf")
        let writer = try TrackWriter(url: url, startTime: t0, clock: { self.t0.addingTimeInterval(1) })
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 5))
        writer.close()
        XCTAssertEqual(try audioDuration(url), 1, accuracy: 0.02)
    }

    func testPadsGapToWallClock() throws {
        let url = dir.appendingPathComponent("g.caf")
        var now = t0.addingTimeInterval(1)
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now })
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        now = t0.addingTimeInterval(5)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.close()
        XCTAssertEqual(try audioDuration(url), 5, accuracy: 0.05)
    }

    func testTrimShortensFile() throws {
        let url = dir.appendingPathComponent("trim.caf")
        try writeTestAudio(url, seconds: 10, frequency: 440)
        try trimAudioFile(url, to: 4)
        XCTAssertEqual(try audioDuration(url), 4, accuracy: 0.01)
    }

    func testWritesInt16File() throws {
        let url = dir.appendingPathComponent("i.caf")
        let writer = try TrackWriter(url: url, startTime: t0, clock: { self.t0.addingTimeInterval(1) })
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.close()
        let f = try AVAudioFile(forReading: url)
        XCTAssertEqual(f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(f.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool, false)
    }

    func testLongGapIsPaddedInFullSoTracksStayAligned() throws {
        let url = dir.appendingPathComponent("gap.caf")
        var now = t0.addingTimeInterval(1)
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now })
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        now = t0.addingTimeInterval(1201)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        now = now.addingTimeInterval(1)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.close()
        XCTAssertEqual(try audioDuration(url), 1202, accuracy: 0.05)
    }

    func testStopsWritingAfterAGapLongerThanTheLimit() throws {
        let url = dir.appendingPathComponent("sleep.caf")
        var now = t0.addingTimeInterval(1)
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now })
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        now = t0.addingTimeInterval(1 + TrackWriter.maxGap + 60)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.close()
        XCTAssertEqual(try audioDuration(url), 1, accuracy: 0.05)
    }

    func testRemembersWhenTheTrackLastHadSound() throws {
        let url = dir.appendingPathComponent("loud.caf")
        var now = t0.addingTimeInterval(10)
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now })
        try writer.append(sineBuffer(seconds: 10, sampleRate: 16_000, channels: 1))
        now = t0.addingTimeInterval(20)
        try writer.append(sineBuffer(seconds: 10, sampleRate: 16_000, channels: 1, amplitude: 0))
        XCTAssertEqual(try XCTUnwrap(writer.lastSound), 10, accuracy: 0.05)
    }
}
