import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Setup's check that recording will work: the mic hears the owner, and the system audio tap hears a short tone
/// Mossad plays itself. Nothing is written to disk.
public enum AudioCheck {
    static let toneFrequency: Float = 660
    static let toneAmplitude: Float = 0.25
    /// A buffer this loud carries the tone; speech is about this loud on a raw mic.
    static let toneLevel: Float = 0.01
    static let voiceLevel: Float = 0.015

    /// A sine with 50 ms fades, so it starts and ends without a click.
    public static func tone(seconds: Double, sampleRate: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        let fade = Float(sampleRate * 0.05)
        return (0..<count).map { i in
            let t = Float(i)
            let envelope = min(1, t / fade, Float(count - 1 - i) / fade)
            return toneAmplitude * max(0, envelope) * sin(2 * .pi * toneFrequency * t / Float(sampleRate))
        }
    }

    /// The tap heard the tone when several buffers carried sound, not just one click.
    public static func heardTone(_ levels: [Float]) -> Bool {
        levels.filter { $0 >= toneLevel }.count >= 3
    }

    public static func heardVoice(_ levels: [Float]) -> Bool {
        levels.contains { $0 >= voiceLevel }
    }

    /// 0...1 on a 60 dB scale, so quiet speech still moves the meter.
    public static func meterFraction(_ level: Float) -> Double {
        guard level > 0 else { return 0 }
        return Double(min(1, max(0, (20 * log10(level) + 60) / 60)))
    }

    public static func level(_ buffer: AVAudioPCMBuffer) -> Float { TrackWriter.rms(buffer) }
}

#if os(macOS)
extension AudioCheck {
    public enum ToneResult: Equatable, Sendable {
        case heard
        case silent
        /// The tap could not start; the text is for the Log.
        case failed(String)
    }

    /// Plays the tone through Mossad's own output and listens with a process tap on Mossad itself, the same tap a
    /// call uses. Slow (about 2 s): call it off the main thread.
    public static func runToneCheck() async -> ToneResult {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
            b.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            return b
        }
        do {
            try engine.start()
        } catch {
            return .failed("The tone could not play: \(error)")
        }
        // Silence first, so macOS lists Mossad as a process that plays audio before the tap looks for it.
        player.scheduleBuffer(buffer([Float](repeating: 0, count: 9_600)), completionHandler: nil)
        player.play()
        try? await Task.sleep(for: .milliseconds(300))
        guard let me = ownProcessObject() else {
            engine.stop()
            return .failed("Mossad's audio process was not found")
        }
        let meter = LevelMeter(capacity: 400)
        let tap = ProcessTap(processObjectIDs: [me])
        do {
            try tap.start { meter.record(level($0)) }
        } catch {
            engine.stop()
            return .failed("The tap could not start: \(error)")
        }
        player.scheduleBuffer(buffer(tone(seconds: 1.2, sampleRate: 48_000)), completionHandler: nil)
        try? await Task.sleep(for: .milliseconds(1_600))
        tap.stop()
        player.stop()
        engine.stop()
        return heardTone(meter.history) ? .heard : .silent
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// The live mic level for setup's check: the raw mic, as calls record it, into a meter. Start and stop it on
/// `CaptureQueue.queue`.
public final class MicLevelCheck: @unchecked Sendable {
    public let meter = LevelMeter(capacity: 120)
    private var mic: MicCapture?

    public init() {}

    public func start() throws {
        let capture = MicCapture(voiceProcessing: false)
        let meter = meter
        try capture.start { meter.record(AudioCheck.level($0)) }
        mic = capture
    }

    public func stop() {
        mic?.stop()
        mic = nil
    }
}
#endif
