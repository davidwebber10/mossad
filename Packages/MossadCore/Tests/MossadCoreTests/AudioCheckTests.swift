import XCTest
@testable import MossadCore

final class AudioCheckTests: XCTestCase {
    func testTheToneIsAShortSineThatFadesInAndOut() {
        let tone = AudioCheck.tone(seconds: 1, sampleRate: 48_000)
        XCTAssertEqual(tone.count, 48_000)
        XCTAssertEqual(tone.first ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(tone.last ?? 1, 0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(tone.map(abs).max() ?? 0, AudioCheck.toneAmplitude + 0.0001)
        XCTAssertGreaterThan(tone.map(abs).max() ?? 0, AudioCheck.toneAmplitude * 0.9)
    }

    func testTheTapHeardTheToneOnlyWhenSeveralBuffersCarrySound() {
        XCTAssertFalse(AudioCheck.heardTone([]))
        XCTAssertFalse(AudioCheck.heardTone([0, 0, 0.0001, 0]))
        XCTAssertFalse(AudioCheck.heardTone([0.2, 0, 0, 0]), "one click is not the tone")
        XCTAssertTrue(AudioCheck.heardTone([0, 0.05, 0.06, 0.05, 0.04, 0]))
    }

    func testTheMicHeardTheOwnerWhenALevelPassesSpeech() {
        XCTAssertFalse(AudioCheck.heardVoice([0.001, 0.002, 0.003]))
        XCTAssertTrue(AudioCheck.heardVoice([0.001, 0.03, 0.002]))
    }

    func testTheMeterShowsQuietSoundAndTopsOut() {
        XCTAssertEqual(AudioCheck.meterFraction(0), 0)
        XCTAssertGreaterThan(AudioCheck.meterFraction(0.01), 0.3)
        XCTAssertEqual(AudioCheck.meterFraction(1), 1)
    }
}
