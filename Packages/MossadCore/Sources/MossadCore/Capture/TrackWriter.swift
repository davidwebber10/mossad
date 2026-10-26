import AVFoundation
import Foundation

/// Writes one track as 16 kHz mono Float32 CAF, converting any input format as it arrives.
/// Gaps in the input (for example a tap restart) are filled with silence so tracks stay aligned to wall-clock time.
public final class TrackWriter: @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    /// Gaps shorter than this are ignored (normal buffer jitter).
    static let gapTolerance: Double = 0.5
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

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var written: AVAudioFramePosition = 0
    private var lastSoundFrame: AVAudioFramePosition?
    private var stalled = false
    /// Below this RMS level a buffer counts as silence (about -54 dBFS).
    static let soundThreshold: Float = 0.002
    private var startTime: Date
    private let clock: () -> Date
    private let meter: LevelMeter?
    private let sink: AudioSink?
    private var pausedAt: Date?
    private var muted = false
    /// Some devices deliver fewer samples than their format says: AirPods in a call run at 24 kHz while the
    /// process tap still says 48 kHz, so speech came out at double speed. The rate is measured against the
    /// clock and the buffers are relabeled with the nearest standard rate.
    static let standardRates: [Double] = [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
    static let rateWindow: Double = 3
    private var rateCheck: (declared: Double, start: Date, last: Date, frames: Double)?
    private var actualRate: Double?

    /// While muted in the call app, the mic's sound is replaced with silence of the same length: the timeline
    /// stays true, and what was said off the call (a phone call while muted) is not kept or transcribed.
    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    public init(url: URL, startTime: Date, clock: @escaping () -> Date = Date.init, meter: LevelMeter? = nil, sink: AudioSink? = nil) throws {
        file = try AVAudioFile(forWriting: url, settings: Self.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.startTime = startTime
        self.clock = clock
        self.meter = meter
        self.sink = sink
    }

    /// A paused recording leaves the paused time out: on resume the timeline moves on by the pause, so no
    /// silence is written and a long pause cannot look like a stalled track. Both tracks pause together.
    public func pause() {
        lock.withLock { if pausedAt == nil { pausedAt = clock() } }
    }

    public func resume() {
        lock.withLock {
            guard let pausedAt else { return }
            startTime = startTime.addingTimeInterval(clock().timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }
    }

    /// When the source last sent a buffer, by the writer's clock.
    public var lastInput: Date? { lock.withLock { lastInputAt } }
    private var lastInputAt: Date?

    public var duration: TimeInterval {
        lock.withLock { Double(written) / Self.sampleRate }
    }

    /// Seconds into the file where the last non-silent buffer ended, or nil when the track has had no sound.
    public var lastSound: TimeInterval? {
        lock.withLock { lastSoundFrame.map { Double($0) / Self.sampleRate } }
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            guard file != nil, !stalled, pausedAt == nil, buffer.frameLength > 0 else { return }
            lastInputAt = clock()
            let rate = measureRate(declared: buffer.format.sampleRate, frames: buffer.frameLength, now: clock())
            guard let mono = Self.downmix(buffer, rate: rate) else { return }
            let converted = try convert(mono)
            guard converted.frameLength > 0 else { return }
            if muted { memset(converted.floatChannelData![0], 0, Int(converted.frameLength) * MemoryLayout<Float>.size) }
            let bufferStart = clock().timeIntervalSince(startTime) - Double(converted.frameLength) / Self.sampleRate
            // Pad every gap in full: both tracks must share one timeline. Silence is written in small chunks.
            let expected = AVAudioFramePosition(bufferStart * Self.sampleRate)
            if Double(expected - written) > Self.maxGap * Self.sampleRate {
                stalled = true
                Log.info("Audio gap longer than \(Int(Self.maxGap)) s; this track stops here")
                return
            }
            if Double(expected - written) > Self.gapTolerance * Self.sampleRate {
                try writeSilence(frames: expected - written, live: Double(expected - written) <= Self.liveGapLimit * Self.sampleRate)
            }
            try write(converted)
            let level = Self.rms(converted)
            meter?.record(level)
            if !muted { sink?.send(converted) }
            if level >= Self.soundThreshold { lastSoundFrame = written }
        }
    }

    /// The rate the buffers really have. A gap (a restart on another device) or a new format starts over.
    private func measureRate(declared: Double, frames: AVAudioFrameCount, now: Date) -> Double {
        guard var check = rateCheck, check.declared == declared, now.timeIntervalSince(check.last) < Self.gapTolerance else {
            rateCheck = (declared, now, now, 0)
            actualRate = nil
            return declared
        }
        check.frames += Double(frames)
        check.last = now
        let elapsed = now.timeIntervalSince(check.start)
        if elapsed >= Self.rateWindow {
            let measured = check.frames / elapsed
            if let rate = Self.standardRate(measured: measured, declared: declared) {
                if rate != (actualRate ?? declared) {
                    Log.info("Audio says \(Int(declared)) Hz but delivers \(Int(measured)) Hz; recording it as \(Int(rate)) Hz")
                }
                actualRate = rate == declared ? nil : rate
            }
            check = (declared, now, now, 0)
        }
        rateCheck = check
        return actualRate ?? declared
    }

    /// The declared rate when the measurement is near it; otherwise a standard rate within 2.5 %, which a
    /// steady device meets. Nil when unclear (a device still settling, or a source that stalls now and then):
    /// the writer keeps the rate it has and measures again.
    static func standardRate(measured: Double, declared: Double) -> Double? {
        if abs(measured / declared - 1) < 0.15 { return declared }
        let nearest = standardRates.min { abs($0 - measured) < abs($1 - measured) }!
        return abs(measured / nearest - 1) <= 0.025 ? nearest : nil
    }

    public func close() {
        lock.withLock {
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
        try file?.write(from: buffer)
        written += AVAudioFramePosition(buffer.frameLength)
    }

    /// The live stream gets short gaps too, so its times stay the file's times. A longer gap (the Mac slept)
    /// would be a burst of silence the stream does not need.
    static let liveGapLimit: Double = 10

    private func writeSilence(frames: AVAudioFramePosition, live: Bool = false) throws {
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, 16_000))
            let silence = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: n)!
            silence.frameLength = n
            memset(silence.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
            try write(silence)
            if live, !muted { sink?.send(silence) }
            remaining -= AVAudioFramePosition(n)
        }
    }

    private func convert(_ mono: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if mono.format.sampleRate == Self.sampleRate { return mono }
        if converter == nil || converter!.inputFormat.sampleRate != mono.format.sampleRate {
            converter = AVAudioConverter(from: mono.format, to: Self.outputFormat)
        }
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * Self.sampleRate / mono.format.sampleRate) + 64
        let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity)!
        var provided = false
        var error: NSError?
        converter!.convert(to: out, error: &error) { _, status in
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

/// Cuts an audio file to its first `duration` seconds.
public func trimAudioFile(_ url: URL, to duration: TimeInterval) throws {
    let source = try AVAudioFile(forReading: url)
    let frames = min(source.length, AVAudioFramePosition(duration * source.processingFormat.sampleRate))
    let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
    do {
        let dest = try AVAudioFile(forWriting: temp, settings: source.fileFormat.settings,
                                   commonFormat: source.processingFormat.commonFormat, interleaved: source.processingFormat.isInterleaved)
        var remaining = frames
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_000)!
        while remaining > 0 {
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 16_000)))
            if buffer.frameLength == 0 { break }
            try dest.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        dest.close()
    }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
}
