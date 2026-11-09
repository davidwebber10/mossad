import AVFoundation
import Foundation

/// Writes one track as 16 kHz mono Float32 CAF, converting any input format as it arrives. Runs on the track's
/// writer queue (see `AudioFeed`), never on the audio thread.
/// Each buffer is placed on the timeline by its capture time, so both tracks share one timeline: a gap (for example a
/// tap restart) is filled with silence, and the first buffer after a source starts is placed exactly.
public final class TrackWriter: @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    /// Gaps between buffers shorter than this are ignored (jitter). Smaller than the echo filter's window
    /// (`TranscriptMerger.echoDelay`), so the tracks stay well within it.
    static let gapTolerance: Double = 0.1
    /// A track this far ahead of its own capture times (a device clock that runs fast) drops the excess. Only for
    /// buffers with a real capture time: a late burst of buffers that carry only their arrival time is kept.
    static let aheadTolerance: Double = 0.2
    /// Buffers further apart than this restart the rate measurement (a restart on another device).
    static let rateResetGap: Double = 0.5
    /// A longer gap means the Mac slept through the call; the writer then stops, and the call end trims.
    public static let maxGap: Double = 1800
    /// On disk: 16-bit integer PCM (half the size of Float32, same transcription quality).
    static var fileSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ] }

    /// Held for a whole buffer, file write included: one writer at a time.
    private let ioLock = NSLock()
    /// Held only for a moment, for the values other threads read (the app's main thread reads the duration), so a
    /// slow disk or a long run of silence after a sleep never makes them wait.
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var written: AVAudioFramePosition = 0
    private var lastSoundFrame: AVAudioFramePosition?
    private var stalled = false
    /// Below this RMS level a buffer counts as silence (about -54 dBFS).
    static let soundThreshold: Float = 0.002
    /// Where file second 0 is on the capture clock; moves on by each pause.
    private var timelineStart: TimeInterval
    private let now: () -> TimeInterval
    private let meter: LevelMeter?
    private let sink: AudioSink?
    private var pausedAt: TimeInterval?
    private var muted = false
    private var errors = 0
    private var firstError: String?
    private var lastErrorLog: TimeInterval = -.infinity
    private var lastAheadLog: TimeInterval = -.infinity
    /// For tests: every write fails with this error, as on a full disk.
    var writeFault: Error?
    /// Some devices deliver fewer samples than their format says: AirPods in a call run at 24 kHz while the
    /// process tap still says 48 kHz, so speech came out at double speed. The rate is measured against the
    /// clock and the buffers are relabeled with the nearest standard rate.
    static let standardRates: [Double] = [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
    static let rateWindow: Double = 3
    private var rateCheck: (declared: Double, start: TimeInterval, last: TimeInterval, frames: Double)?
    private var actualRate: Double?
    private var pendingRate: Double?

    /// Follows the call app's mute button for what leaves the writer while the call runs: the meter shows nothing and
    /// the live stream gets silence. The file keeps the real samples; `CallRecorder.end` writes silence over the mute
    /// spans, so a late unmute cannot cost the owner's first words.
    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    public init(url: URL, startTime: Date, clock: @escaping () -> Date = Date.init, captureClock: CaptureClock? = nil,
                meter: LevelMeter? = nil, sink: AudioSink? = nil) throws {
        file = try AVAudioFile(forWriting: url, settings: Self.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let capture = captureClock ?? .following(clock)
        now = capture.now
        timelineStart = capture.now() - clock().timeIntervalSince(startTime)
        self.meter = meter
        self.sink = sink
    }

    /// A paused recording leaves the paused time out: on resume the timeline moves on by the pause, so no
    /// silence is written and a long pause cannot look like a stalled track. Both tracks pause together.
    public func pause() {
        lock.withLock { if pausedAt == nil { pausedAt = now() } }
    }

    public func resume() {
        lock.withLock {
            guard let pausedAt else { return }
            timelineStart += now() - pausedAt
            self.pausedAt = nil
        }
    }

    /// Where the timeline is now, in file seconds: the paused time is left out.
    public var position: TimeInterval {
        lock.withLock { (pausedAt ?? now()) - timelineStart }
    }

    public var duration: TimeInterval {
        lock.withLock { Double(written) / Self.sampleRate }
    }

    /// Seconds into the file where the last non-silent buffer ended, or nil when the track has had no sound.
    public var lastSound: TimeInterval? {
        lock.withLock { lastSoundFrame.map { Double($0) / Self.sampleRate } }
    }

    /// Failed writes (a full disk, a format the converter refuses), and the first error's text.
    public var writeErrors: (count: Int, first: String?) { lock.withLock { (errors, firstError) } }

    /// Writes a buffer that arrived now, with no capture time. For tests and simple callers.
    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0, let mono = Self.downmix(buffer) else { return }
        try ioLock.withLock { try place(mono, start: nil, arrival: now(), newSegment: false) }
    }

    /// Writes a chunk from the feed. Errors are kept for the recorder's health check, never thrown away.
    public func ingest(_ chunk: AudioFeed.Chunk) {
        ioLock.withLock {
            do { try place(chunk.samples, start: chunk.start, arrival: chunk.arrival, newSegment: chunk.newSegment) } catch {
                let count = lock.withLock {
                    errors += 1
                    if firstError == nil { firstError = error.localizedDescription }
                    return errors
                }
                // The first error, then one line a minute, so a full disk does not fill the log.
                let t = now()
                if t - lastErrorLog >= 60 {
                    lastErrorLog = t
                    Log.error("Writing \(file?.url.lastPathComponent ?? "audio") failed (\(count) times): \(error)")
                }
            }
        }
    }

    /// Call with `ioLock` held. `mono` is at the rate its source declared.
    private func place(_ mono: AVAudioPCMBuffer, start: TimeInterval?, arrival: TimeInterval, newSegment: Bool) throws {
        let (paused, timelineStart, muted, written) = lock.withLock { (pausedAt != nil, self.timelineStart, self.muted, self.written) }
        guard file != nil, !stalled, !paused, mono.frameLength > 0 else { return }
        if newSegment { rateCheck = nil }
        let declared = mono.format.sampleRate
        let rate = measureRate(declared: declared, frames: mono.frameLength, now: arrival)
        let input = rate == declared ? mono : Self.relabel(mono, rate: rate)
        var converted = try convert(input)
        guard converted.frameLength > 0 else { return }
        let length = Double(converted.frameLength) / Self.sampleRate
        let bufferStart = (start ?? arrival - length) - timelineStart
        let expected = AVAudioFramePosition(bufferStart * Self.sampleRate)
        let behind = expected - written
        if Double(behind) > Self.maxGap * Self.sampleRate {
            stalled = true
            Log.info("Audio gap longer than \(Int(Self.maxGap)) s; this track stops here")
            return
        }
        // The first buffer of a source is placed exactly; later ones only when the gap is more than jitter.
        let tolerance = newSegment ? 0 : Self.gapTolerance
        if Double(behind) > tolerance * Self.sampleRate {
            try writeSilence(frames: behind, live: Double(behind) <= Self.liveGapLimit * Self.sampleRate)
        } else if start != nil, Double(-behind) > (newSegment ? 0 : Self.aheadTolerance) * Self.sampleRate {
            // A new source that started before the old one stopped sends the overlap a second time: drop exactly that.
            let excess = AVAudioFrameCount(min(-behind, AVAudioFramePosition(converted.frameLength)))
            if !newSegment, arrival - lastAheadLog >= 10 {
                lastAheadLog = arrival
                Log.info("Audio ran \(String(format: "%.2f", Double(-behind) / Self.sampleRate)) s ahead of its clock; dropped the excess")
            }
            guard excess < converted.frameLength else { return }
            converted = Self.dropFirst(converted, frames: excess)
        }
        try write(converted)
        let level = Self.rms(converted)
        meter?.record(muted ? 0 : level)
        sink?.send(muted ? Self.silence(frames: converted.frameLength) : converted)
        if level >= Self.soundThreshold { lock.withLock { lastSoundFrame = self.written } }
    }

    static func relabel(_ buffer: AVAudioPCMBuffer, rate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength)!
        out.frameLength = buffer.frameLength
        out.floatChannelData![0].update(from: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return out
    }

    static func dropFirst(_ buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - frames)!
        out.frameLength = buffer.frameLength - frames
        out.floatChannelData![0].update(from: buffer.floatChannelData![0] + Int(frames), count: Int(out.frameLength))
        return out
    }

    static func silence(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(frames, 1))!
        b.frameLength = frames
        memset(b.floatChannelData![0], 0, Int(frames) * MemoryLayout<Float>.size)
        return b
    }

    /// The rate the buffers really have. A gap (a restart on another device) or a new format starts over.
    private func measureRate(declared: Double, frames: AVAudioFrameCount, now: TimeInterval) -> Double {
        guard var check = rateCheck, check.declared == declared, now - check.last < Self.rateResetGap else {
            rateCheck = (declared, now, now, 0)
            actualRate = nil
            pendingRate = nil
            return declared
        }
        check.frames += Double(frames)
        check.last = now
        let elapsed = now - check.start
        if elapsed >= Self.rateWindow {
            let measured = check.frames / elapsed
            if let rate = Self.standardRate(measured: measured, declared: declared) {
                // A rate close to the declared one (44.1 kHz sent as 48 kHz) can also be one late buffer at the
                // window's edge, so it needs two windows in a row.
                let close = rate != declared && abs(rate / declared - 1) < 0.15
                if close, rate != actualRate, pendingRate != rate {
                    pendingRate = rate
                } else {
                    pendingRate = nil
                    if rate != (actualRate ?? declared) {
                        Log.info("Audio says \(Int(declared)) Hz but delivers \(Int(measured)) Hz; recording it as \(Int(rate)) Hz")
                    }
                    actualRate = rate == declared ? nil : rate
                }
            }
            check = (declared, now, now, 0)
        }
        rateCheck = check
        return actualRate ?? declared
    }

    /// The declared rate when the measurement is within 5 % of it; otherwise a standard rate within 2.5 %, which a
    /// steady device meets. Nil when unclear (a device still settling, or a source that stalls now and then):
    /// the writer keeps the rate it has and measures again. 5 %, so 44.1 kHz sent as "48 kHz" (8 % off) is caught.
    static func standardRate(measured: Double, declared: Double) -> Double? {
        if abs(measured / declared - 1) < 0.05 { return declared }
        let nearest = standardRates.min { abs($0 - measured) < abs($1 - measured) }!
        return abs(measured / nearest - 1) <= 0.025 ? nearest : nil
    }

    public func close() {
        ioLock.withLock {
            if let converter, let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: 4096) {
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    status.pointee = .endOfStream
                    return nil
                }
                try? write(out)
            }
            file?.close()
            file = nil
        }
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        return (sum / Float(n)).squareRoot()
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        if let writeFault { throw writeFault }
        try file?.write(from: buffer)
        lock.withLock { written += AVAudioFramePosition(buffer.frameLength) }
    }

    /// The live stream gets short gaps too, so its times stay the file's times. A longer gap (the Mac slept)
    /// would be a burst of silence the stream does not need.
    static let liveGapLimit: Double = 10

    private func writeSilence(frames: AVAudioFramePosition, live: Bool = false) throws {
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, 16_000))
            let silence = Self.silence(frames: n)
            try write(silence)
            if live { sink?.send(silence) }
            remaining -= AVAudioFramePosition(n)
        }
    }

    private func convert(_ mono: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if mono.format.sampleRate == Self.sampleRate { return mono }
        if converter == nil || converter!.inputFormat.sampleRate != mono.format.sampleRate {
            converter = AVAudioConverter(from: mono.format, to: Self.outputFormat)
        }
        guard let converter else { throw CaptureFormatError(rate: mono.format.sampleRate) }
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * Self.sampleRate / mono.format.sampleRate) + 64
        let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity)!
        var provided = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return mono
        }
        if let error { throw error }
        return out
    }

    /// Float32 input → mono at the input rate, or at `rate` when the input's own label is wrong. Stereo is averaged; more channels use channel 0
    /// (voice processing puts the processed voice on channel 0).
    static func downmix(_ buffer: AVAudioPCMBuffer, rate: Double? = nil) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData else { return nil }
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate ?? format.sampleRate, channels: 1, interleaved: false)!
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)!
        mono.frameLength = buffer.frameLength
        let out = mono.floatChannelData![0]
        let interleaved = format.isInterleaved
        func sample(_ ch: Int, _ i: Int) -> Float { interleaved ? data[0][i * channels + ch] : data[ch][i] }
        for i in 0..<frames {
            out[i] = channels == 2 ? (sample(0, i) + sample(1, i)) * 0.5 : sample(0, i)
        }
        return mono
    }
}

struct CaptureFormatError: LocalizedError {
    let rate: Double
    var errorDescription: String? { "audio at \(Int(rate)) Hz cannot be converted" }
}

/// Cuts an audio file to its first `duration` seconds.
public func trimAudioFile(_ url: URL, to duration: TimeInterval) throws {
    try rewriteAudioFile(url, keep: duration, silence: [])
}

/// Rewrites a track: keeps its first `keep` seconds (all when nil) and writes silence over each span, in file
/// seconds. Works on a file that was never closed (a crashed recording). The temp file never stays behind.
public func rewriteAudioFile(_ url: URL, keep: TimeInterval?, silence spans: [ClosedRange<TimeInterval>]) throws {
    let source = try AVAudioFile(forReading: url)
    let rate = source.processingFormat.sampleRate
    let frames = keep.map { min(source.length, AVAudioFramePosition($0 * rate)) } ?? source.length
    let quiet = spans.map { AVAudioFramePosition($0.lowerBound * rate)..<AVAudioFramePosition(($0.upperBound * rate).rounded(.up)) }
    let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
    do {
        let dest = try AVAudioFile(forWriting: temp, settings: source.fileFormat.settings,
                                   commonFormat: source.processingFormat.commonFormat, interleaved: source.processingFormat.isInterleaved)
        var position: AVAudioFramePosition = 0
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_000)!
        while position < frames {
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(frames - position, 16_000)))
            if buffer.frameLength == 0 { break }
            let range = position..<(position + AVAudioFramePosition(buffer.frameLength))
            for span in quiet where span.overlaps(range) {
                let from = Int(max(span.lowerBound, range.lowerBound) - position)
                let to = Int(min(span.upperBound, range.upperBound) - position)
                for c in 0..<Int(buffer.format.channelCount) {
                    if let data = buffer.floatChannelData?[c] { (data + from).update(repeating: 0, count: to - from) }
                }
            }
            try dest.write(from: buffer)
            position = range.upperBound
        }
        dest.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    } catch {
        try? FileManager.default.removeItem(at: temp)
        throw error
    }
}

/// Writes silence over spans of a PCM track where it lies, with no copy: it needs no free disk space, so it works on
/// a full disk, and it is fast. Silence in PCM is zero bytes. Works on a file that was never closed.
public func silenceAudioFile(_ url: URL, spans: [ClosedRange<TimeInterval>]) throws {
    guard !spans.isEmpty else { return }
    func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(what) failed (\(status))"]) }
    }
    var opened: AudioFileID?
    try check(AudioFileOpenURL(url as CFURL, .readWritePermission, 0, &opened), "open track")
    guard let file = opened else { throw CaptureFormatError(rate: 0) }
    defer { AudioFileClose(file) }
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format), "read format")
    var bytes: Int64 = 0
    size = UInt32(MemoryLayout<Int64>.size)
    try check(AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &size, &bytes), "read length")
    guard format.mFormatID == kAudioFormatLinearPCM, format.mBytesPerPacket > 0, format.mSampleRate > 0 else {
        throw CaptureFormatError(rate: format.mSampleRate)
    }
    let frame = Int64(format.mBytesPerPacket)
    let zeros = [UInt8](repeating: 0, count: 1 << 16)
    for span in spans {
        var offset = max(0, Int64(span.lowerBound * format.mSampleRate)) * frame
        let end = min(bytes, Int64((span.upperBound * format.mSampleRate).rounded(.up)) * frame)
        while offset < end {
            var count = UInt32(min(Int64(zeros.count), end - offset))
            try check(AudioFileWriteBytes(file, false, offset, &count, zeros), "write silence")
            guard count > 0 else { throw CaptureFormatError(rate: format.mSampleRate) }
            offset += Int64(count)
        }
    }
}
