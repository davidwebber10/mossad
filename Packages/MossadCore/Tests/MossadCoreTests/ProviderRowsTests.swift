import XCTest
@testable import MossadCore

/// The words and numbers that setup's AI step and Settings › AI both show.
final class ProviderRowsTests: XCTestCase {
    // MARK: The two jobs

    func testEachJobHasOneNameAndOneLineOnWhatItDoes() {
        XCTAssertEqual(ProviderJob.transcription.title, "Transcription")
        XCTAssertEqual(ProviderJob.notes.title, "Notes")
        XCTAssertTrue(ProviderJob.transcription.detail.contains("transcript"))
        XCTAssertTrue(ProviderJob.notes.detail.contains("summary"))
        XCTAssertTrue(ProviderJob.notes.detail.contains("Chat"))
    }

    // MARK: Cost of an hour

    func testAnHourSplitsIntoBothTracksAndOneSummary() throws {
        let cost = Pricing.hourCost(transcription: .assemblyai, ai: .anthropic, model: "")
        XCTAssertEqual(cost.transcription, 0.46, accuracy: 0.005)
        XCTAssertEqual(try XCTUnwrap(cost.notes), 0.11, accuracy: 0.005)
        XCTAssertEqual(cost.total, Pricing.hourEstimate(transcription: .assemblyai, ai: .anthropic, model: ""), accuracy: 0.000_001)
        XCTAssertEqual(cost.headline, "About $0.57")
        XCTAssertEqual(cost.parts, "Transcription: $0.46 for both tracks. Notes: $0.11.")
    }

    func testLocalProvidersAreFree() {
        let cost = Pricing.hourCost(transcription: .local, ai: .apple, model: "")
        XCTAssertEqual(cost, HourCost(transcription: 0, notes: 0))
        XCTAssertEqual(cost.headline, "Free")
        XCTAssertEqual(cost.parts, "Transcription: free on this Mac. Notes: free.")
    }

    func testAModelWithNoListPriceIsNotCountedAsFree() {
        let router = Pricing.hourCost(transcription: .assemblyai, ai: .openrouter, model: "meta/llama")
        XCTAssertNil(router.notes)
        XCTAssertEqual(router.headline, "At least $0.46")
        XCTAssertEqual(router.parts, "Transcription: $0.46 for both tracks. Notes: no list price for this model.")
        XCTAssertNil(Pricing.hourCost(transcription: .local, ai: .openai, model: "gpt-unknown").notes)
        XCTAssertEqual(Pricing.hourCost(transcription: .local, ai: .openrouter, model: "").headline, "Not known")
        // The total stays what setup shows: an unknown price adds nothing.
        XCTAssertEqual(router.total, Pricing.hourEstimate(transcription: .assemblyai, ai: .openrouter, model: "meta/llama"), accuracy: 0.000_001)
    }

    func testACostUnderOneCentDoesNotReadAsFree() {
        let cost = Pricing.hourCost(transcription: .local, ai: .anthropic, model: "claude-haiku-5-5")
        XCTAssertEqual(cost.headline, "Less than $0.01")
        XCTAssertEqual(cost.parts, "Transcription: free on this Mac. Notes: less than $0.01.")
    }

    func testTheLiveTranscriptLineCarriesTheStreamingPrice() {
        let hour = UsageEvent(date: Date(), callID: nil, service: .assemblyai, purpose: .live, model: nil, audioSeconds: 3600)
        XCTAssertEqual(Pricing.liveHourCost, Pricing.cost(hour), accuracy: 0.000_001)
        XCTAssertTrue(Pricing.liveTranscriptNote.contains("$0.15"), Pricing.liveTranscriptNote)
    }

    // MARK: The coach's voices

    func testEachCoachVoiceSaysHowItSounds() {
        XCTAssertEqual(Set(CoachVoice.allCases.map(\.detail)).count, CoachVoice.allCases.count)
        XCTAssertTrue(CoachVoice.direct.detail.contains("peer"))
        XCTAssertTrue(CoachVoice.warm.detail.contains("Encouraging"))
        XCTAssertTrue(CoachVoice.data.detail.contains("numbers"))
    }

    // MARK: Key status

    func testAKeyIsMissingSavedOrKnownToWork() {
        XCTAssertEqual(KeyCheck.Status(saved: false, passed: false), .missing)
        XCTAssertEqual(KeyCheck.Status(saved: true, passed: false), .saved)
        XCTAssertEqual(KeyCheck.Status(saved: true, passed: true), .works)
        // A check that passed for a key that is gone says nothing about the next key.
        XCTAssertEqual(KeyCheck.Status(saved: false, passed: true), .missing)
        XCTAssertEqual(KeyCheck.Status.missing.label, "No key")
        XCTAssertEqual(KeyCheck.Status.saved.label, "Key saved")
        XCTAssertEqual(KeyCheck.Status.works.label, "Key works")
    }

    func testEveryMailProviderHasAPageToMakeAKey() {
        for provider in MailProvider.allCases {
            XCTAssertEqual(provider.keysPage.scheme, "https", "\(provider)")
            XCTAssertNotNil(provider.keysPage.host, "\(provider)")
        }
        XCTAssertEqual(MailProvider.resend.keysPage.host, "resend.com")
        XCTAssertEqual(Set(MailProvider.allCases.map(\.keysPage)).count, MailProvider.allCases.count)
    }
}
