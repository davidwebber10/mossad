import Accelerate
import Foundation

/// How the owner's voice sounded, measured on this Mac from the mic track within their own turns:
/// pitch and its variation, loudness and its range, and how much turns fade at the end.
public struct VoiceTone: Codable, Equatable, Sendable, Hashable {
    /// Hz; men are often near 85 to 155, women near 165 to 255.
    public var medianPitch: Double
    /// The spread of pitch in semitones (standard deviation). Below about 2 sounds flat.
    public var pitchVariation: Double
    /// dBFS of the voiced frames.
    public var level: Double
    /// dB between the loud (90th percentile) and quiet (10th percentile) voiced frames.
    public var loudnessRange: Double
    /// dB the last fifth of a turn is quieter than the rest, averaged over turns. Positive means trailing off.
    public var endDrop: Double

    static let analysisRate = 8_000.0
    static let frameSeconds = 0.04
    /// Frames quieter than this are silence or room noise.
    static let voicedFloor = -45.0
    static let pitchRange = 70.0...400.0
    /// Normalized autocorrelation needed to call a frame pitched.
    static let periodicity: Float = 0.5

    public static func measure(url: URL, turns: [Utterance]) throws -> VoiceTone? {
        var pitches: [Double] = [], levels: [Double] = [], drops: [Double] = []
        for turn in turns where turn.end > turn.start {
            let samples = downsample(try AudioSamples.read(url, from: turn.start, to: turn.end), from: try sampleRate(url))
            let frame = Int(analysisRate * frameSeconds)
            guard samples.count >= frame else { continue }
            var turnLevels: [Double] = []
            var i = 0
            while i + frame <= samples.count {
                let slice = Array(samples[i..<i + frame])
                let db = decibels(slice)
                turnLevels.append(db)
                if db > voicedFloor {
                    levels.append(db)
                    if let f = pitch(slice) { pitches.append(f) }
                }
                i += frame
            }
            let voiced = turnLevels.filter { $0 > voicedFloor }
            if voiced.count >= 10 {
                let tail = voiced.count / 5
                drops.append(mean(voiced.dropLast(tail)) - mean(voiced.suffix(tail)))
            }
        }
        guard pitches.count >= 5, !levels.isEmpty else { return nil }
        let median = pitches.sorted()[pitches.count / 2]
        let semitones = pitches.map { 12 * log2($0 / median) }
        let m = mean(semitones)
        let variation = sqrt(semitones.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(semitones.count))
        let sorted = levels.sorted()
        return VoiceTone(medianPitch: median, pitchVariation: variation, level: mean(levels),
                         loudnessRange: sorted[sorted.count * 9 / 10] - sorted[sorted.count / 10], endDrop: drops.isEmpty ? 0 : mean(drops))
    }

    private static func sampleRate(_ url: URL) throws -> Double {
        try AudioSamples.sampleRate(url)
    }

    /// Averages blocks of samples down to 8 kHz; enough for voice pitch, and cheap.
    static func downsample(_ samples: [Float], from rate: Double) -> [Float] {
        let factor = max(1, Int((rate / analysisRate).rounded()))
        guard factor > 1 else { return samples }
        return stride(from: 0, to: samples.count - factor + 1, by: factor).map { i in
            samples[i..<i + factor].reduce(0, +) / Float(factor)
        }
    }

    static func decibels(_ x: [Float]) -> Double {
        let rms = sqrt(x.map { $0 * $0 }.reduce(0, +) / Float(max(1, x.count)))
        return 20 * log10(max(Double(rms), 1e-9))
    }

    /// The strongest repeat period in the voice range, by normalized autocorrelation.
    static func pitch(_ x: [Float]) -> Double? {
        let energy = x.map { $0 * $0 }.reduce(0, +)
        guard energy > 0 else { return nil }
        let minLag = Int(analysisRate / pitchRange.upperBound), maxLag = min(Int(analysisRate / pitchRange.lowerBound), x.count - 1)
        var best: (lag: Int, r: Float) = (0, 0)
        for lag in minLag...maxLag {
            var r: Float = 0
            x.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &r, vDSP_Length(x.count - lag)) }
            r /= energy
            if r > best.r { best = (lag, r) }
        }
        return best.r >= periodicity ? analysisRate / Double(best.lag) : nil
    }

    private static func mean<C: Collection>(_ x: C) -> Double where C.Element == Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }
}
