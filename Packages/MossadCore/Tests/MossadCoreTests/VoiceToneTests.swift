import AVFoundation
import XCTest
@testable import MossadCore

final class VoiceToneTests: XCTestCase {
    /// Writes back-to-back sine segments, each with its own pitch and amplitude, at 48 kHz like the mic track.
    private func write(_ url: URL, _ segments: [(seconds: Double, hz: Double, amplitude: Double)]) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for s in segments {
            let frames = AVAudioFrameCount(s.seconds * rate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] = Float(sin(2 * .pi * s.hz * Double(i) / rate) * s.amplitude)
            }
            try file.write(from: buffer)
        }
    }

    private func turn(_ start: Double, _ end: Double, label: String = "A") -> Utterance {
        Utterance(track: .me, speakerLabel: label, start: start, end: end, text: "words")
    }

    func testASteadyToneHasItsPitchNoVariationAndItsLevel() throws {
        let url = tempDirectory().appendingPathComponent("me.caf")
        try write(url, [(4, 150, 0.5)])
        let tone = try XCTUnwrap(VoiceTone.measure(url: url, turns: [turn(0, 4)]))
        XCTAssertEqual(tone.medianPitch, 150, accuracy: 5)
        XCTAssertLessThan(tone.pitchVariation, 0.5)
        // A sine at 0.5 has an RMS of 0.354, which is -9 dBFS.
        XCTAssertEqual(tone.level, -9, accuracy: 1)
        XCTAssertLessThan(tone.loudnessRange, 1)
    }

    func testAVariedVoiceShowsSemitonesOfRange() throws {
        let url = tempDirectory().appendingPathComponent("me.caf")
        // 120 Hz to 240 Hz is one octave, 12 semitones apart.
        try write(url, [(2, 120, 0.5), (2, 240, 0.5)])
        let tone = try XCTUnwrap(VoiceTone.measure(url: url, turns: [turn(0, 4)]))
        XCTAssertGreaterThan(tone.pitchVariation, 4)
    }

    func testQuieterTurnEndsShowAsTrailingOff() throws {
        let url = tempDirectory().appendingPathComponent("me.caf")
        try write(url, [(4, 150, 0.5), (1, 150, 0.1)])
        let tone = try XCTUnwrap(VoiceTone.measure(url: url, turns: [turn(0, 5)]))
        XCTAssertGreaterThan(tone.endDrop, 6)
    }

    func testOnlyTheOwnersTurnsAreMeasuredAndSilenceGivesNothing() throws {
        let url = tempDirectory().appendingPathComponent("me.caf")
        try write(url, [(2, 0, 0), (2, 200, 0.5)])
        XCTAssertNil(try VoiceTone.measure(url: url, turns: [turn(0, 2)]))
        let tone = try XCTUnwrap(VoiceTone.measure(url: url, turns: [turn(2, 4)]))
        XCTAssertEqual(tone.medianPitch, 200, accuracy: 6)
    }
}
