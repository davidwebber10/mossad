import AVFoundation
import Foundation

/// Writes one track as 16 kHz mono Float32 CAF, converting any input format as it arrives.
/// Gaps in the input (for example a tap restart) are filled with silence so tracks stay aligned to wall-clock time.
public final class TrackWriter: @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    /// Gaps shorter than this are ignored (normal buffer jitter).
    static let gapTolerance: Double = 0.5
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
    /// Below this RMS level a buffer counts as silence (about -46 dBFS).
    static let soundThreshold: Float = 0.005
    private let startTime: Date
    private let clock: () -> Date

    public init(url: URL, startTime: Date, clock: @escaping () -> Date = Date.init) throws {
        file = try AVAudioFile(forWriting: url, settings: Self.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.startTime = startTime
        self.clock = clock
    }

    public var duration: TimeInterval {
        lock.withLock { Double(written) / Self.sampleRate }
    }

    /// Seconds into the file where the last non-silent buffer ended, or nil when the track has had no sound.
    public var lastSound: TimeInterval? {
        lock.withLock { lastSoundFrame.map { Double($0) / Self.sampleRate } }
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            guard file != nil, buffer.frameLength > 0, let mono = Self.downmix(buffer) else { return }
            let converted = try convert(mono)
            guard converted.frameLength > 0 else { return }
            let bufferStart = clock().timeIntervalSince(startTime) - Double(converted.frameLength) / Self.sampleRate
            // Pad every gap in full: both tracks must share one timeline. Silence is written in small chunks.
            let expected = AVAudioFramePosition(bufferStart * Self.sampleRate)
            if Double(expected - written) > Self.gapTolerance * Self.sampleRate {
                try writeSilence(frames: expected - written)
            }
            try write(converted)
            if Self.rms(converted) >= Self.soundThreshold { lastSoundFrame = written }
        }
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

    private func writeSilence(frames: AVAudioFramePosition) throws {
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, 16_000))
            let silence = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: n)!
            silence.frameLength = n
            memset(silence.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
            try write(silence)
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

    /// Float32 input → mono at the input rate. Stereo is averaged; more channels use channel 0
    /// (voice processing puts the processed voice on channel 0).
    static func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData else { return nil }
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
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
