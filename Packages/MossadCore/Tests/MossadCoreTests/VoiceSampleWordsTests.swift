import XCTest
@testable import MossadCore

/// The Voice tab's words for where a sample came from.
final class VoiceSampleWordsTests: XCTestCase {
    func testEachOriginHasPlainWords() {
        XCTAssertEqual(VoiceSample.Origin.ownerNamed.words, "You named this voice")
        XCTAssertEqual(VoiceSample.Origin.ownerEnrollment.words, "Your voice on the microphone")
        XCTAssertEqual(VoiceSample.Origin.migrated.words, "From the older voice library")
        XCTAssertEqual(VoiceSample.Origin.autoMatch(0.874).words, "Matched by voice (0.87)")
        XCTAssertEqual(VoiceSample.Origin(kind: "fromANewerBuild").words, "Learned from a call", "a kind from a newer build still reads")
    }

    func testQualityInWords() {
        XCTAssertEqual(VoiceSample.qualityWord(0.9), "Clear")
        XCTAssertEqual(VoiceSample.qualityWord(0.6), "Good")
        XCTAssertEqual(VoiceSample.qualityWord(0.3), "Weak")
        XCTAssertNil(VoiceSample.qualityWord(nil))
    }
}
