import AVFoundation
import XCTest
@testable import MossadCore

/// Collects the chunks a feed hands to its writer queue.
final class ChunkList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [AudioFeed.Chunk] = []
    var all: [AudioFeed.Chunk] { lock.withLock { list } }
    func add(_ c: AudioFeed.Chunk) { lock.withLock { list.append(c) } }
    var samples: [Float] { all.flatMap { c in (0..<Int(c.samples.frameLength)).map { c.samples.floatChannelData![0][$0] } } }
}

final class AudioFeedTests: XCTestCase {
    final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
    let clock = Clock()
    let chunks = ChunkList()

    func feed(capacity: Int = AudioFeed.defaultCapacity) -> AudioFeed {
        let clock = clock, chunks = chunks
        return AudioFeed(clock: CaptureClock(now: { clock.now }, fromHost: { Double($0) / 1000 }), capacity: capacity) { chunks.add($0) }
    }

    func ramp(_ range: Range<Int>, rate: Double = 16_000) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, frameCapacity: AVAudioFrameCount(range.count))!
        b.frameLength = AVAudioFrameCount(range.count)
        for (i, v) in range.enumerated() { b.floatChannelData![0][i] = Float(v) }
        return b
    }

    func testTheWriterQueueGetsTheSamplesInOrderWithTheirTimes() {
        let feed = feed()
        feed.beginSegment()
        feed.push(ramp(1..<101), hostTime: 99_500)
        clock.now = 101
        feed.push(ramp(101..<201))
        feed.flush()
        XCTAssertEqual(chunks.samples, (1..<201).map(Float.init))
        let all = chunks.all
        XCTAssertEqual(all.map(\.start), [99.5, nil], "a host time stamp becomes the capture time; none stays unknown")
        XCTAssertEqual(all.map(\.arrival), [100, 101])
        XCTAssertEqual(all.map(\.newSegment), [true, false])
        XCTAssertEqual(all[0].samples.format.sampleRate, 16_000)
        XCTAssertEqual(feed.lastPush, 101)
        feed.close()
    }

    /// A wrong time stamp from a device must not pad minutes of silence or stop the track.
    func testACaptureTimeFarFromTheArrivalIsIgnored() {
        let feed = feed()
        feed.push(ramp(0..<10), hostTime: 99_900)      // 0.1 s before the arrival
        feed.push(ramp(0..<10), hostTime: 4_000_000)   // an hour in the future
        feed.push(ramp(0..<10), hostTime: 1_000)       // long ago
        feed.close()
        XCTAssertEqual(chunks.all.map(\.start), [99.9, nil, nil])
    }

    /// A source that starts while the one it replaces still runs collects audio, and hands it on only when released.
    func testAHeldFeedHandsNothingOnUntilItIsReleased() {
        let clock = clock, chunks = chunks
        let feed = AudioFeed(clock: CaptureClock(now: { clock.now }, fromHost: nil), held: true) { chunks.add($0) }
        feed.beginSegment()
        feed.push(ramp(0..<50))
        feed.flush()
        XCTAssertTrue(chunks.all.isEmpty)
        feed.release()
        XCTAssertEqual(chunks.samples, (0..<50).map(Float.init))
        XCTAssertEqual(chunks.all.map(\.newSegment), [true])
        feed.close()
    }

    /// A held feed whose source failed its try is thrown away: the audio it collected repeats what the working
    /// source already wrote, so it must never reach the writer.
    func testADiscardedHeldFeedHandsNothingOn() {
        let clock = clock, chunks = chunks
        let feed = AudioFeed(clock: CaptureClock(now: { clock.now }, fromHost: nil), held: true) { chunks.add($0) }
        feed.beginSegment()
        feed.push(ramp(0..<50))
        feed.discard()
        feed.push(ramp(50..<60))
        feed.flush()
        XCTAssertTrue(chunks.all.isEmpty)
    }

    /// Buffers that come late in a burst carry true capture times that are some seconds old. They keep them.
    func testAnOldButPossibleCaptureTimeIsKept() {
        let feed = feed()
        feed.push(ramp(0..<10), hostTime: 90_000)   // 10 s before the arrival
        feed.close()
        XCTAssertEqual(chunks.all.map(\.start), [90])
    }

    func testEachSourceStartIsANewSegment() {
        let feed = feed()
        feed.beginSegment()
        feed.push(ramp(0..<10))
        feed.push(ramp(0..<10))
        feed.beginSegment()
        feed.push(ramp(0..<10))
        feed.close()
        XCTAssertEqual(chunks.all.map(\.newSegment), [true, false, true])
    }

    func testStereoIsAveragedAndMoreChannelsUseTheFirst() {
        let feed = feed()
        let stereo = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 4)!
        stereo.frameLength = 4
        for i in 0..<4 {
            stereo.floatChannelData![0][i] = 1
            stereo.floatChannelData![1][i] = 0.5
        }
        feed.push(stereo)
        feed.push(sineBuffer(seconds: 0.001, sampleRate: 16_000, channels: 5, amplitude: 0.5))
        feed.close()
        XCTAssertEqual(Array(chunks.samples.prefix(4)), [0.75, 0.75, 0.75, 0.75])
        XCTAssertEqual(chunks.all[0].samples.format.sampleRate, 48_000)
        XCTAssertEqual(chunks.all[1].samples.frameLength, 16)
    }

    func testAFullRingDropsWholeBuffersAndCountsThem() {
        let feed = feed(capacity: 250)
        feed.push(ramp(0..<100))
        feed.push(ramp(100..<200))
        feed.push(ramp(200..<300))   // does not fit: the writer has not run
        XCTAssertEqual(feed.dropped, 100)
        feed.flush()
        feed.push(ramp(300..<400))   // wraps around the end of the ring
        feed.close()
        XCTAssertEqual(chunks.samples, (Array(0..<200) + Array(300..<400)).map(Float.init))
    }

    func testABufferThatIsNotFloatIsCountedNotWritten() {
        let feed = feed()
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!
        b.frameLength = 10
        feed.push(b)
        feed.reject()
        feed.close()
        XCTAssertEqual(feed.rejected, 2)
        XCTAssertTrue(chunks.all.isEmpty)
        XCTAssertNil(feed.lastPush, "a source that only sends unreadable buffers counts as sending nothing")
    }

    func testOnlyZerosAreNotASignal() {
        let feed = feed()
        feed.push(sineBuffer(seconds: 0.01, sampleRate: 16_000, channels: 1, amplitude: 0))
        XCTAssertFalse(feed.hasHeardSignal)
        feed.push(sineBuffer(seconds: 0.01, sampleRate: 16_000, channels: 1, amplitude: 0.001))
        XCTAssertTrue(feed.hasHeardSignal)
        feed.close()
    }

    /// A USB headset as the output device puts its own mic stream before the tap in the aggregate's input list.
    func testTheTapBuffersAreTakenFromAListThatAlsoHasADeviceInput() {
        let feed = feed()
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { list.unsafeMutablePointer.deallocate() }
        let mic = UnsafeMutablePointer<Float>.allocate(capacity: 4), tap = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { mic.deallocate(); tap.deallocate() }
        for i in 0..<4 { mic[i] = 9 }
        for i in 0..<4 { tap[i * 2] = 0.2; tap[i * 2 + 1] = 0.4 }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: mic)
        list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 32, mData: tap)
        let buffers = TapLayout.tapBuffers(count: 2, channels: { Int(list[$0].mNumberChannels) }, tapChannels: 2, interleaved: true)
        XCTAssertEqual(buffers, 1..<2)
        feed.push(list.unsafePointer, buffers: buffers!, channelsPerBuffer: 2, rate: 48_000, hostTime: nil)
        feed.close()
        XCTAssertEqual(chunks.samples.count, 4)
        for v in chunks.samples { XCTAssertEqual(v, 0.3, accuracy: 0.0001) }
    }

    func testTapLayoutChoosesTheLastBuffersOrRefuses() {
        func pick(_ layout: [Int], _ channels: Int, interleaved: Bool) -> Range<Int>? {
            TapLayout.tapBuffers(count: layout.count, channels: { layout[$0] }, tapChannels: channels, interleaved: interleaved)
        }
        XCTAssertEqual(pick([2], 2, interleaved: true), 0..<1, "the usual case: only the tap")
        XCTAssertEqual(pick([1, 2], 2, interleaved: true), 1..<2, "a headset mic first, the tap last")
        XCTAssertEqual(pick([2, 2], 2, interleaved: true), 1..<2)
        XCTAssertEqual(pick([1, 1, 1], 2, interleaved: false), 1..<3, "one buffer per channel")
        XCTAssertNil(pick([], 2, interleaved: true))
        XCTAssertNil(pick([2, 1], 2, interleaved: true), "the last buffer is not the tap's shape: write nothing, never the wrong stream")
        XCTAssertNil(pick([1], 2, interleaved: false))
        XCTAssertNil(pick([1, 2], 2, interleaved: false))
    }

    func testAMicWithNoInputDeviceIsRefusedBeforeTheTapIsInstalled() {
        XCTAssertThrowsError(try MicCapture.checkInput(sampleRate: 0, channels: 0))
        XCTAssertThrowsError(try MicCapture.checkInput(sampleRate: 48_000, channels: 0))
        XCTAssertNoThrow(try MicCapture.checkInput(sampleRate: 48_000, channels: 1))
    }
}

final class CaptureHealthTests: XCTestCase {
    let fine = TrackHealth(running: true, heardSignal: true, hasSound: true)

    func problems(elapsed: TimeInterval = 30, mic: Bool = true, system: Bool = true, free: Int64? = nil,
                  me: TrackHealth? = nil, them: TrackHealth?? = nil) -> [CaptureProblem] {
        CaptureHealth.problems(elapsed: elapsed, micAllowed: mic, systemAudioAllowed: system, freeBytes: free,
                               me: me ?? fine, them: them ?? fine)
    }

    func testAHealthyRecordingHasNoProblems() {
        XCTAssertEqual(problems(), [])
        XCTAssertEqual(problems(them: .some(nil)), [], "a room recording has no call audio")
    }

    func testMissingPermissionsAreToldAtOnce() {
        XCTAssertEqual(problems(elapsed: 0, mic: false), [.micDenied])
        XCTAssertEqual(problems(elapsed: 0, system: false, them: TrackHealth()), [.systemAudioDenied])
        XCTAssertEqual(problems(elapsed: 0, system: false, them: .some(nil)), [], "a room recording does not need system audio")
    }

    func testAWriteErrorAndALowDiskAreToldAtOnce() {
        let failing = TrackHealth(running: true, heardSignal: true, writeErrors: 3, firstError: "No space left on device")
        XCTAssertEqual(problems(elapsed: 0, them: failing), [.cannotWrite("No space left on device")])
        XCTAssertEqual(problems(elapsed: 0, free: 500_000_000), [.diskLow])
        XCTAssertEqual(problems(elapsed: 0, free: 50_000_000_000), [])
    }

    func testASourceThatDoesNotRunCountsOnlyAfterTheGrace() {
        let stopped = TrackHealth()
        XCTAssertEqual(problems(elapsed: 5, me: stopped, them: stopped), [])
        XCTAssertEqual(problems(elapsed: 10, me: stopped, them: stopped), [.micNotRecording, .callAudioNotRecording])
    }

    func testASourceRestartedAgainAndAgainIsTold() {
        let stalled = TrackHealth(running: true, stallRestarts: CaptureHealth.stallRestartLimit)
        XCTAssertEqual(problems(me: stalled), [.micNotRecording])
        XCTAssertEqual(problems(them: stalled), [.callAudioNotRecording])
    }

    /// A mic without permission, or a dead device, sends exact zeros while the engine reports a healthy source.
    func testAMicThatSendsOnlyZerosWhileTheCallHasSoundIsTold() {
        let zeros = TrackHealth(running: true, heardSignal: false)
        XCTAssertEqual(problems(me: zeros), [.micSilent])
        XCTAssertEqual(problems(me: zeros, them: TrackHealth(running: true, heardSignal: true, hasSound: false)), [], "nobody spoke yet")
    }
}
