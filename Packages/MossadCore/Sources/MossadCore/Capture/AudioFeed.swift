import AVFoundation
import Darwin
import Foundation
import Synchronization

/// The clock that capture times run on, in seconds. In the app it is the host's continuous clock: it does not step
/// with NTP, and unlike `mach_absolute_time` it keeps counting while the Mac sleeps, so a sleep still pads both
/// tracks to the wall clock. Tests follow their injected `Date` clock.
public struct CaptureClock: @unchecked Sendable {
    public let now: () -> TimeInterval
    /// Converts an audio time stamp (`mach_absolute_time` units) to `now`'s seconds; nil when stamps are not used.
    let fromHost: ((UInt64) -> TimeInterval)?

    public static let host: CaptureClock = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1e9
        return CaptureClock(now: { Double(mach_continuous_time()) * scale }, fromHost: { stamp in
            // Stamps are on the absolute clock; the continuous clock is ahead of it by the time spent asleep.
            Double(stamp &+ (mach_continuous_time() &- mach_absolute_time())) * scale
        })
    }()

    public static func following(_ clock: @escaping () -> Date) -> CaptureClock {
        CaptureClock(now: { clock().timeIntervalSinceReferenceDate }, fromHost: nil)
    }
}

/// Carries one track's audio from the audio thread to a writer queue. The audio thread only copies samples (mixed
/// down to mono) into a ring that was allocated up front and returns: no lock, no allocation, no file access. A
/// timer on the writer queue takes the chunks out and hands them on. One producer at a time: a source is stopped
/// before the next one starts.
public final class AudioFeed: @unchecked Sendable {
    /// One buffer as the source sent it, mono, at the rate the source declared.
    public struct Chunk {
        public let samples: AVAudioPCMBuffer
        /// When its first sample was captured, on the capture clock; nil when the source gave no time stamp.
        public let start: TimeInterval?
        /// When it reached the feed, on the capture clock.
        public let arrival: TimeInterval
        /// The first chunk after a source started or restarted.
        public let newSegment: Bool
    }

    private struct Meta {
        var first = 0
        var frames = 0
        var rate: Double = 0
        var arrival: TimeInterval = 0
        var start: TimeInterval = .nan
        var segment = 0
    }

    public static let defaultCapacity = 1 << 20   // about 22 s at 48 kHz
    static let chunkCapacity = 4096
    static let drainInterval: DispatchTimeInterval = .milliseconds(50)
    /// How long before now a buffer's capture time can be.
    static let stampWindow: TimeInterval = 2

    private let clock: CaptureClock
    private let capacity: Int
    private let ring: UnsafeMutablePointer<Float>
    private let meta: UnsafeMutablePointer<Meta>
    private let sampleWrite = Atomic<Int>(0)
    private let sampleRead = Atomic<Int>(0)
    private let chunkWrite = Atomic<Int>(0)
    private let chunkRead = Atomic<Int>(0)
    private let segment = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)
    private let rejectedBuffers = Atomic<Int>(0)
    private let lastPushBits = Atomic<UInt64>(0)
    private let heardSignal = Atomic<Bool>(false)

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private let onChunk: (Chunk) -> Void
    // Writer queue only.
    private var lastSegment = -1
    private var formats: [Double: AVAudioFormat] = [:]
    private var closed = false

    public init(label: String = "audio", clock: CaptureClock = .host, capacity: Int = AudioFeed.defaultCapacity,
                onChunk: @escaping (Chunk) -> Void) {
        self.clock = clock
        self.capacity = capacity
        self.onChunk = onChunk
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
        meta = .allocate(capacity: Self.chunkCapacity)
        meta.initialize(repeating: Meta(), count: Self.chunkCapacity)
        queue = DispatchQueue(label: "com.dwebber.mossad.writer.\(label)", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        ring.deallocate()
        meta.deallocate()
    }

    // MARK: Audio thread

    /// A new source starts: its first chunk is placed exactly on the timeline.
    public func beginSegment() { segment.add(1, ordering: .relaxed) }

    /// Copies a buffer from an `AVAudioEngine` tap. Float32 only; anything else is counted as rejected.
    public func push(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        push(buffer, start: captureTime(hostTime))
    }

    /// The same, with the capture time of the first sample already on the capture clock.
    func push(_ buffer: AVAudioPCMBuffer, start: TimeInterval?) {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData, format.channelCount > 0 else {
            rejectedBuffers.add(1, ordering: .relaxed)
            return
        }
        let channels = Int(format.channelCount)
        // Stereo is averaged; more channels use channel 0.
        if format.isInterleaved {
            let base = data[0]
            write(frames: Int(buffer.frameLength), rate: format.sampleRate, start: start) { i in
                channels == 2 ? (base[i * 2] + base[i * 2 + 1]) * 0.5 : base[i * channels]
            }
        } else if channels == 2 {
            let left = data[0], right = data[1]
            write(frames: Int(buffer.frameLength), rate: format.sampleRate, start: start) { i in (left[i] + right[i]) * 0.5 }
        } else {
            let mono = data[0]
            write(frames: Int(buffer.frameLength), rate: format.sampleRate, start: start) { i in mono[i] }
        }
    }

    /// Copies the tap's part of an aggregate device's input list: `buffers` are the indices that hold the tap,
    /// each with `channelsPerBuffer` interleaved channels.
    public func push(_ list: UnsafePointer<AudioBufferList>, buffers: Range<Int>, channelsPerBuffer: Int, rate: Double, hostTime: UInt64?) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard channelsPerBuffer > 0, let first = buffers.first, buffers.upperBound <= abl.count,
              let left = abl[first].mData?.assumingMemoryBound(to: Float.self) else {
            rejectedBuffers.add(1, ordering: .relaxed)
            return
        }
        let frames = Int(abl[first].mDataByteSize) / (MemoryLayout<Float>.size * channelsPerBuffer)
        let start = captureTime(hostTime)
        if buffers.count >= 2 {
            // One channel per buffer: the second must be as long as the first.
            guard let right = abl[first + 1].mData?.assumingMemoryBound(to: Float.self),
                  abl[first + 1].mDataByteSize >= abl[first].mDataByteSize else {
                rejectedBuffers.add(1, ordering: .relaxed)
                return
            }
            write(frames: frames, rate: rate, start: start) { i in (left[i] + right[i]) * 0.5 }
        } else if channelsPerBuffer == 2 {
            write(frames: frames, rate: rate, start: start) { i in (left[i * 2] + left[i * 2 + 1]) * 0.5 }
        } else {
            let stride = channelsPerBuffer
            write(frames: frames, rate: rate, start: start) { i in left[i * stride] }
        }
    }

    /// A device's time stamp on the capture clock. A capture time is a little before now; one far from it is a bad
    /// stamp and must not move the timeline, so the arrival time places that buffer.
    private func captureTime(_ hostTime: UInt64?) -> TimeInterval? {
        guard let hostTime, hostTime != 0, let time = clock.fromHost?(hostTime) else { return nil }
        let now = clock.now()
        return time > now - Self.stampWindow && time < now + 1 ? time : nil
    }

    /// Counts a buffer the source could not read (an unexpected layout).
    public func reject() { rejectedBuffers.add(1, ordering: .relaxed) }

    private func write(frames: Int, rate: Double, start: TimeInterval?, sample: (Int) -> Float) {
        guard frames > 0, rate > 0 else { return }
        let arrival = clock.now()
        lastPushBits.store(arrival.bitPattern, ordering: .relaxed)
        let w = sampleWrite.load(ordering: .relaxed)
        let c = chunkWrite.load(ordering: .relaxed)
        guard w + frames - sampleRead.load(ordering: .acquiring) <= capacity,
              c - chunkRead.load(ordering: .acquiring) < Self.chunkCapacity else {
            droppedFrames.add(frames, ordering: .relaxed)
            return
        }
        var signal = false
        for i in 0..<frames {
            let v = sample(i)
            if v != 0 { signal = true }
            ring[(w + i) % capacity] = v
        }
        if signal, !heardSignal.load(ordering: .relaxed) { heardSignal.store(true, ordering: .relaxed) }
        meta[c % Self.chunkCapacity] = Meta(first: w, frames: frames, rate: rate, arrival: arrival, start: start ?? .nan,
                                            segment: segment.load(ordering: .relaxed))
        sampleWrite.store(w + frames, ordering: .relaxed)
        chunkWrite.store(c + 1, ordering: .releasing)
    }

    // MARK: State for the recorder (any thread)

    /// Now, on the feed's capture clock.
    public var now: TimeInterval { clock.now() }

    /// When the source last sent a buffer, on the capture clock; nil before the first one.
    public var lastPush: TimeInterval? {
        let bits = lastPushBits.load(ordering: .relaxed)
        return bits == 0 ? nil : Double(bitPattern: bits)
    }
    /// True once a sample that is not exactly zero arrived. A mic without permission sends only zeros.
    public var hasHeardSignal: Bool { heardSignal.load(ordering: .relaxed) }
    /// Frames lost because the writer fell behind and the ring was full.
    public var dropped: Int { droppedFrames.load(ordering: .relaxed) }
    /// Buffers the source could not read.
    public var rejected: Int { rejectedBuffers.load(ordering: .relaxed) }

    // MARK: Writer queue

    /// Hands every waiting chunk to the writer now. Never call it on the feed's own queue.
    public func flush() { queue.sync { drain() } }

    /// Stops the timer after the last chunk is handed on.
    public func close() {
        queue.sync {
            drain()
            closed = true
            timer?.cancel()
            timer = nil
        }
    }

    private func drain() {
        guard !closed else { return }
        let end = chunkWrite.load(ordering: .acquiring)
        var c = chunkRead.load(ordering: .relaxed)
        while c < end {
            let m = meta[c % Self.chunkCapacity]
            let format = formats[m.rate] ?? {
                let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: m.rate, channels: 1, interleaved: false)!
                formats[m.rate] = f
                return f
            }()
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(m.frames))!
            buffer.frameLength = AVAudioFrameCount(m.frames)
            let out = buffer.floatChannelData![0]
            let head = min(m.frames, capacity - m.first % capacity)
            out.update(from: ring + m.first % capacity, count: head)
            if head < m.frames { (out + head).update(from: ring, count: m.frames - head) }
            sampleRead.store(m.first + m.frames, ordering: .releasing)
            c += 1
            chunkRead.store(c, ordering: .releasing)
            let isNew = m.segment != lastSegment
            lastSegment = m.segment
            onChunk(Chunk(samples: buffer, start: m.start.isNaN ? nil : m.start, arrival: m.arrival, newSegment: isNew))
        }
    }
}
