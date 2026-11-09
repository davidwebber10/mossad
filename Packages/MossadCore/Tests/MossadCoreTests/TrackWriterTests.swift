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

    /// AirPods in a call run at 24 kHz while the tap still says 48 kHz: half the samples arrive each second.
    func testAMislabeledRateIsMeasuredSoSpeechKeepsItsSpeed() throws {
        let url = dir.appendingPathComponent("r.caf")
        var now = t0
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now })
        for _ in 0..<200 {
            now = now.addingTimeInterval(0.1)
            let b = sineBuffer(seconds: 0.1, sampleRate: 48_000, channels: 2)
            b.frameLength = 2_400
            try writer.append(b)
        }
        // The AirPods disconnect: the tap is rebuilt, and the real 48 kHz returns.
        now = now.addingTimeInterval(1)
        for _ in 0..<200 {
            now = now.addingTimeInterval(0.1)
            try writer.append(sineBuffer(seconds: 0.1, sampleRate: 48_000, channels: 2))
        }
        writer.close()
        XCTAssertEqual(try audioDuration(url), 41, accuracy: 0.5, "neither part is stretched or squeezed")
        XCTAssertLessThan(try silentShare(url, from: 5, to: 20), 0.05, "no silence padding between fast speech")
        XCTAssertLessThan(try silentShare(url, from: 22, to: 41), 0.05)
    }

    /// Just after AirPods switch, a window measured 22,760 Hz: between 22,050 and 24,000, so the writer waits.
    func testOnlyAClearMeasurementPicksARate() {
        XCTAssertEqual(TrackWriter.standardRate(measured: 47_500, declared: 48_000), 48_000)
        XCTAssertEqual(TrackWriter.standardRate(measured: 23_950, declared: 48_000), 24_000)
        XCTAssertNil(TrackWriter.standardRate(measured: 22_760, declared: 48_000))
        XCTAssertNil(TrackWriter.standardRate(measured: 35_000, declared: 48_000))
    }

    /// The share of 10 ms blocks that are exact digital silence.
    private func silentShare(_ url: URL, from: Double, to: Double) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        f.framePosition = AVAudioFramePosition(from * 16_000)
        let n = AVAudioFrameCount((to - from) * 16_000)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: b, frameCount: n)
        let d = b.floatChannelData![0]
        let blocks = Int(b.frameLength) / 160
        let silent = (0..<blocks).filter { k in (0..<160).allSatisfy { d[k * 160 + $0] == 0 } }.count
        return Double(silent) / Double(max(blocks, 1))
    }

    /// The live stream's times must match the file's, so the live names can cut the right audio.
    func testAShortGapIsAlsoSentToTheLiveStream() throws {
        let url = dir.appendingPathComponent("s.caf")
        var now = t0.addingTimeInterval(1)
        let sink = AudioSink()
        let sent = Counter()
        sink.set { sent.add(Int($0.frameLength)) }
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now }, sink: sink)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        now = t0.addingTimeInterval(4)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        XCTAssertEqual(Double(sent.value) / 16_000, 4, accuracy: 0.05)
        writer.close()
    }

    func chunk(_ seconds: Double, start: TimeInterval?, arrival: TimeInterval, new: Bool = false, rate: Double = 16_000) -> AudioFeed.Chunk {
        AudioFeed.Chunk(samples: sineBuffer(seconds: seconds, sampleRate: rate, channels: 1), start: start, arrival: arrival, newSegment: new)
    }

    /// Where the sound starts and ends in a file, by 10 ms blocks.
    private func soundRange(_ url: URL) throws -> (start: Double, end: Double) {
        let samples = try AudioSamples.read(url, from: 0, to: 10_000)
        let loud = stride(from: 0, to: samples.count - 160, by: 160).filter { i in samples[i..<(i + 160)].contains { abs($0) > 0.01 } }
        return (Double(loud.first ?? 0) / 16_000, Double((loud.last ?? 0) + 160) / 16_000)
    }

    /// A source that starts late kept its offset for the whole call when it was under the tolerance, and the echo
    /// filter then missed the echo. The first buffer of a source goes exactly where its capture time says.
    func testTheFirstBufferOfASourceIsPlacedExactly() throws {
        let base = t0.timeIntervalSinceReferenceDate
        var urls: [URL] = []
        for (name, late) in [("me", 0.1), ("them", 0.45)] {
            let url = dir.appendingPathComponent("\(name).caf")
            let writer = try TrackWriter(url: url, startTime: t0, clock: { self.t0 })
            writer.ingest(chunk(1, start: base + late, arrival: base + late + 1.02, new: true))
            writer.ingest(chunk(1, start: base + late + 1, arrival: base + late + 2.03))
            writer.close()
            urls.append(url)
            XCTAssertEqual(try soundRange(url).start, late, accuracy: 0.011)
            XCTAssertEqual(try audioDuration(url), late + 2, accuracy: 0.011)
        }
    }

    func testJitterBetweenBuffersAddsNoSilence() throws {
        let base = t0.timeIntervalSinceReferenceDate
        let url = dir.appendingPathComponent("j.caf")
        let writer = try TrackWriter(url: url, startTime: t0, clock: { self.t0 })
        writer.ingest(chunk(1, start: base, arrival: base + 1, new: true))
        writer.ingest(chunk(1, start: base + 1.05, arrival: base + 2.1))
        writer.close()
        XCTAssertEqual(try audioDuration(url), 2, accuracy: 0.011)
    }

    func testAGapLongerThanJitterIsPaddedByTheCaptureTime() throws {
        let base = t0.timeIntervalSinceReferenceDate
        let url = dir.appendingPathComponent("p.caf")
        let writer = try TrackWriter(url: url, startTime: t0, clock: { self.t0 })
        writer.ingest(chunk(1, start: base, arrival: base + 1, new: true))
        // The writer queue was busy: the chunk is handed over late, but its capture time says where it belongs.
        writer.ingest(chunk(1, start: base + 1.3, arrival: base + 9))
        writer.close()
        XCTAssertEqual(try audioDuration(url), 2.3, accuracy: 0.011)
    }

    /// A device clock that runs fast must not push the track ahead of the other one.
    func testATrackAheadOfItsCaptureTimesDropsTheExcess() throws {
        let base = t0.timeIntervalSinceReferenceDate
        let url = dir.appendingPathComponent("a.caf")
        let writer = try TrackWriter(url: url, startTime: t0, clock: { self.t0 })
        writer.ingest(chunk(2, start: base, arrival: base + 2, new: true))
        writer.ingest(chunk(1, start: base + 1.5, arrival: base + 2.5))
        writer.close()
        XCTAssertEqual(try audioDuration(url), 2.5, accuracy: 0.011)
    }

    /// Buffers with no capture time that arrive in a burst (a busy main thread) are all kept.
    func testALateBurstWithoutCaptureTimesIsKept() throws {
        let url = dir.appendingPathComponent("b.caf")
        var now = t0.addingTimeInterval(1)
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now })
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        now = t0.addingTimeInterval(1.2)
        try writer.append(sineBuffer(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.close()
        XCTAssertEqual(try audioDuration(url), 2, accuracy: 0.011)
    }

    /// A full disk: every write fails. The writer keeps the first error and the count for the recorder's health check.
    func testFailedWritesAreCountedWithTheFirstError() throws {
        struct DiskFull: LocalizedError { var errorDescription: String? { "No space left on device" } }
        let base = t0.timeIntervalSinceReferenceDate
        let writer = try TrackWriter(url: dir.appendingPathComponent("f.caf"), startTime: t0, clock: { self.t0 })
        writer.ingest(chunk(1, start: base, arrival: base + 1, new: true))
        XCTAssertEqual(writer.writeErrors.count, 0)
        writer.writeFault = DiskFull()
        writer.ingest(chunk(1, start: base + 1, arrival: base + 2))
        writer.ingest(chunk(1, start: base + 2, arrival: base + 3))
        XCTAssertEqual(writer.writeErrors.count, 2)
        XCTAssertEqual(writer.writeErrors.first, "No space left on device")
        XCTAssertEqual(writer.duration, 1, accuracy: 0.01, "a failed write does not move the file position")
        writer.close()
    }

    /// 44.1 kHz delivered as "48 kHz" was inside the old 15 % band and played 9 % too fast, with holes of silence.
    func testANearRateIsCorrectedAfterTwoWindowsThatAgree() throws {
        XCTAssertEqual(TrackWriter.standardRate(measured: 44_100, declared: 48_000), 44_100)
        XCTAssertEqual(TrackWriter.standardRate(measured: 46_500, declared: 48_000), 48_000)
        let url = dir.appendingPathComponent("n.caf")
        var now = t0
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now })
        for _ in 0..<300 {
            now = now.addingTimeInterval(0.1)
            let b = sineBuffer(seconds: 0.1, sampleRate: 48_000, channels: 1)
            b.frameLength = 4_410
            try writer.append(b)
        }
        writer.close()
        XCTAssertEqual(try audioDuration(url), 30, accuracy: 0.3)
        XCTAssertLessThan(try silentShare(url, from: 8, to: 30), 0.01, "after the correction there are no holes")
    }

    /// One late buffer at the edge of a window must not change the rate of a healthy device.
    func testOneOddWindowDoesNotChangeANearRate() throws {
        let url = dir.appendingPathComponent("o.caf")
        var now = t0
        let writer = try TrackWriter(url: url, startTime: t0, clock: { now })
        for i in 0..<200 {
            // The buffer that closes the first window comes 0.25 s late; the next ones catch up.
            now = t0.addingTimeInterval(Double(i + 1) * 0.1 + (i == 30 ? 0.25 : 0))
            try writer.append(sineBuffer(seconds: 0.1, sampleRate: 48_000, channels: 1))
        }
        writer.close()
        XCTAssertEqual(try audioDuration(url), 20, accuracy: 0.3, "nothing was relabeled, so nothing was stretched")
    }

    func testRewriteSilencesSpansAndKeepsTheLength() throws {
        let url = dir.appendingPathComponent("mute.caf")
        try writeTestAudio(url, seconds: 10, frequency: 440)
        try rewriteAudioFile(url, keep: nil, silence: [2...4, 9...30])
        XCTAssertEqual(try audioDuration(url), 10, accuracy: 0.01)
        XCTAssertEqual(try AudioSamples.read(url, from: 2, to: 4).map(abs).max(), 0)
        XCTAssertEqual(try AudioSamples.read(url, from: 9, to: 10).map(abs).max(), 0)
        XCTAssertGreaterThan(try AudioSamples.read(url, from: 1, to: 1.9).map(abs).max() ?? 0, 0.3)
        XCTAssertGreaterThan(try AudioSamples.read(url, from: 4.1, to: 8.9).map(abs).max() ?? 0, 0.3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["mute.caf"])
    }

    func testAFailedRewriteLeavesNoTempFile() throws {
        let url = dir.appendingPathComponent("bad.caf")
        try Data(repeating: 7, count: 4096).write(to: url)
        XCTAssertThrowsError(try trimAudioFile(url, to: 1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["bad.caf"])
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

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var value: Int { lock.withLock { total } }
    func add(_ n: Int) { lock.withLock { total += n } }
}
