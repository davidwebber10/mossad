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

    private func amount(_ cost: HourCost, _ kind: HourCost.Part.Kind) -> Double? { cost.parts.first { $0.kind == kind }?.amount }

    func testAnHourCountsBothTracksAndTheNotes() throws {
        let cost = Pricing.hourCost(transcription: .assemblyai, ai: .anthropic, model: "")
        XCTAssertEqual(cost.parts.map(\.kind), [.transcription, .notes])
        XCTAssertEqual(try XCTUnwrap(amount(cost, .transcription)), 0.46, accuracy: 0.005)
        // The summary (15,000 tokens in, 2,500 out) and the read for what the owner promised (14,100 in, 300 out).
        XCTAssertEqual(try XCTUnwrap(amount(cost, .notes)), 0.11 + 0.0624, accuracy: 0.0005)
        XCTAssertEqual(cost.headline, "About $0.63")
        XCTAssertEqual(cost.detail, "Transcription: $0.46 for both tracks. Notes: $0.17.")
        XCTAssertEqual(Pricing.hourEstimate(transcription: .assemblyai, ai: .anthropic, model: ""), 0.46 + 0.1724, accuracy: 0.0005)
    }

    func testTheLiveTranscriptAndTheCoachAreInTheCostWhenTheyAreOn() throws {
        let cost = Pricing.hourCost(transcription: .assemblyai, ai: .anthropic, model: "", liveTranscript: true, coach: true)
        XCTAssertEqual(cost.parts.map(\.kind), [.transcription, .liveTranscript, .notes, .coach])
        // One streaming session for each track.
        XCTAssertEqual(try XCTUnwrap(amount(cost, .liveTranscript)), 0.30, accuracy: 0.0001)
        // One review of the hour: about 20,000 tokens in and 3,000 out.
        XCTAssertEqual(try XCTUnwrap(amount(cost, .coach)), 0.14, accuracy: 0.0005)
        XCTAssertEqual(cost.headline, "About $1.07")
        XCTAssertEqual(cost.detail, "Transcription: $0.46 for both tracks. Live transcript: $0.30. Notes: $0.17. Coach: $0.14.")
        XCTAssertNil(cost.emailDetail)
    }

    func testACoachEmailIsPricedByTheEmail() {
        let on = Pricing.hourCost(transcription: .assemblyai, ai: .anthropic, model: "", coach: true, coachEmail: true)
        XCTAssertEqual(on.emailDetail, "Each coach email: about $0.04.")
        // The coach writes the emails: with the coach off, none is sent.
        XCTAssertNil(Pricing.hourCost(transcription: .assemblyai, ai: .anthropic, model: "", coach: false, coachEmail: true).emailDetail)
        XCTAssertNil(Pricing.hourCost(transcription: .assemblyai, ai: .localServer, model: "m", coach: true, coachEmail: true).emailDetail)
    }

    func testLocalProvidersAreFree() {
        let cost = Pricing.hourCost(transcription: .local, ai: .apple, model: "", coach: true)
        XCTAssertEqual(cost.parts.map(\.amount), [0, 0, 0])
        XCTAssertEqual(cost.headline, "Free")
        XCTAssertEqual(cost.detail, "Transcription: free on this Mac. Notes: free. Coach: free.")
    }

    func testItIsNeverFreeWhileTheLiveTranscriptBills() {
        let cost = Pricing.hourCost(transcription: .local, ai: .localServer, model: "qwen2.5:32b", liveTranscript: true)
        XCTAssertEqual(cost.headline, "About $0.30")
        XCTAssertEqual(cost.detail, "Transcription: free on this Mac. Live transcript: $0.30. Notes: free.")
    }

    func testAModelWithNoListPriceIsNotCountedAsFree() {
        let router = Pricing.hourCost(transcription: .assemblyai, ai: .openrouter, model: "meta/llama", coach: true)
        XCTAssertNil(router.parts.first { $0.kind == .notes }?.amount)
        XCTAssertEqual(router.headline, "At least $0.46")
        XCTAssertEqual(router.detail, "Transcription: $0.46 for both tracks. Notes and coach: no list price for this model.")
        XCTAssertEqual(Pricing.hourCost(transcription: .assemblyai, ai: .openrouter, model: "meta/llama").detail,
                       "Transcription: $0.46 for both tracks. Notes: no list price for this model.")
        XCTAssertEqual(Pricing.hourCost(transcription: .local, ai: .openai, model: "gpt-unknown").headline, "Not known")
        XCTAssertEqual(Pricing.hourCost(transcription: .local, ai: .openrouter, model: "").headline, "Not known")
    }

    func testACostUnderOneCentDoesNotReadAsFree() {
        let cost = Pricing.hourCost(transcription: .local, ai: .anthropic, model: "claude-haiku-5-5")
        XCTAssertEqual(cost.headline, "Less than $0.01")
        XCTAssertEqual(cost.detail, "Transcription: free on this Mac. Notes: less than $0.01.")
    }

    /// Deepgram and Sonnet: $0.516 and $0.086 are $0.60 together, but the parts show as $0.52 and $0.09.
    func testTheHeadlineIsTheSumOfThePartsAsShown() {
        let cost = Pricing.hourCost(transcription: .deepgram, ai: .anthropic, model: "claude-sonnet-5-5")
        XCTAssertEqual(cost.detail, "Transcription: $0.52 for both tracks. Notes: $0.09.")
        XCTAssertEqual(cost.headline, "About $0.61")
    }

    func testSetupAndSettingsSayTheSameAmount() {
        let cost = Pricing.hourCost(transcription: .assemblyai, ai: .anthropic, model: "", liveTranscript: true)
        XCTAssertEqual(Onboarding.costLine(cost), "About $0.93 for each hour of meetings, billed to your own accounts.")
        let unknown = Pricing.hourCost(transcription: .assemblyai, ai: .openrouter, model: "meta/llama")
        XCTAssertEqual(Onboarding.costLine(unknown), "At least $0.46 for each hour of meetings, billed to your own accounts.")
        XCTAssertEqual(Onboarding.costLine(Pricing.hourCost(transcription: .local, ai: .apple, model: "")), "Free: these choices bill nothing.")
        XCTAssertEqual(Onboarding.costLine(Pricing.hourCost(transcription: .local, ai: .openrouter, model: "")),
                       "The cost is not known: the notes model has no list price.")
    }

    func testTheLiveTranscriptLineCarriesThePriceOfACall() {
        // A call has two sessions, one for each track.
        let hour = UsageEvent(date: Date(), callID: nil, service: .assemblyai, purpose: .live, model: nil, audioSeconds: 2 * 3600)
        XCTAssertEqual(Pricing.liveHourCost, Pricing.cost(hour), accuracy: 0.000_001)
        XCTAssertEqual(Pricing.liveHourCost, 0.30, accuracy: 0.000_001)
        XCTAssertTrue(Pricing.liveTranscriptNote.contains("$0.30"), Pricing.liveTranscriptNote)
    }

    // MARK: Calendars in Settings

    func testAnEmptyCalendarListThatWasNotReadIsNotNoCalendars() {
        XCTAssertEqual(CalendarListState(allowed: false, read: false, count: 0), .needsAccess)
        XCTAssertEqual(CalendarListState(allowed: false, read: true, count: 3), .needsAccess)
        XCTAssertEqual(CalendarListState(allowed: true, read: false, count: 0), .notRead)
        XCTAssertEqual(CalendarListState(allowed: true, read: true, count: 0), .none)
        XCTAssertEqual(CalendarListState(allowed: true, read: true, count: 2), .listed)
        // A list that is there is shown, whoever read it.
        XCTAssertEqual(CalendarListState(allowed: true, read: false, count: 2), .listed)
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

    /// OpenAI's 401 repeats the two ends of the key. Nothing of a reply may reach the log or a tooltip.
    func testAFailedCheckKeepsNothingOfTheProvidersReply() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":{"message":"Incorrect API key provided: sk-ab***************wxyz."}}"#.utf8)) }
        do {
            try await KeyCheck.run(.openai, key: "sk-abcdefghijklmnopqrstuvwxyz", session: StubURLProtocol.session())
            XCTFail("expected an error")
        } catch {
            let friendly = FriendlyError(error, context: .checkingSavedKey, service: "OpenAI")
            for text in [String(describing: error), friendly.technical, friendly.title, friendly.message] {
                XCTAssertFalse(text.contains("sk-ab"), text)
                XCTAssertFalse(text.contains("wxyz"), text)
                XCTAssertFalse(text.contains("Incorrect"), text)
            }
            XCTAssertEqual(String(describing: error), "OpenAI HTTP 401: the key was not accepted")
            XCTAssertEqual(friendly.kind, .unauthorized)
        }
    }

    func testACheckNeverTakesACachedAnswer() {
        for service in KeyCheck.Service.allCases {
            XCTAssertEqual(KeyCheck.request(service, key: "k").cachePolicy, .reloadIgnoringLocalCacheData, "\(service)")
        }
    }

    func testARejectedSavedKeyPointsAtChange() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        do {
            try await KeyCheck.run(.anthropic, key: "bad", session: StubURLProtocol.session())
            XCTFail("expected an error")
        } catch {
            let saved = FriendlyError(error, context: .checkingSavedKey)
            XCTAssertEqual(saved.title, "Anthropic didn't accept the API key")
            XCTAssertEqual(saved.message, "Copy the key again from your Anthropic account. Then click Change and paste it.")
            // Setup has the field in the row.
            XCTAssertTrue(FriendlyError(error, context: .checkingKey).message.hasSuffix("then paste it here."))
        }
    }

    /// A restricted key can do its job and still have no permission for the free request of the check.
    func testAKeyWithNoPermissionForTheCheckIsNotCalledRejected() async {
        StubURLProtocol.handler = { _ in (403, Data(#"{"error":"missing scope"}"#.utf8)) }
        do {
            try await KeyCheck.run(.openai, key: "restricted", session: StubURLProtocol.session())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(String(describing: error), "OpenAI HTTP 403: the key has no permission for this request")
            let saved = FriendlyError(error, context: .checkingSavedKey)
            XCTAssertEqual(saved.kind, .keyNotPermitted)
            XCTAssertEqual(saved.title, "OpenAI did not let Mossad check the key")
            XCTAssertFalse(saved.title.contains("accept"))
            XCTAssertEqual(saved.message, "The key has no permission for this check. It can still work for your calls.")
            XCTAssertEqual(FriendlyError(error, context: .checkingKey).message,
                           "The key has no permission for this check. Use a key with full access, then check it again.")
        }
    }

    /// A slow check can end after the owner saved a different key. Its result is for the old key.
    func testALateResultOfAnOlderCheckIsDropped() {
        var tickets = KeyCheck.Tickets()
        let first = tickets.start(.openai)
        XCTAssertTrue(tickets.isCurrent(first, for: .openai))
        // The owner changed the key while the request ran.
        tickets.cancel(.openai)
        XCTAssertFalse(tickets.isCurrent(first, for: .openai))
        let second = tickets.start(.openai)
        XCTAssertTrue(tickets.isCurrent(second, for: .openai))
        XCTAssertFalse(tickets.isCurrent(first, for: .openai))
        // One key's check says nothing about another key.
        let other = tickets.start(.anthropic)
        XCTAssertTrue(tickets.isCurrent(second, for: .openai))
        tickets.cancelAll()
        XCTAssertFalse(tickets.isCurrent(second, for: .openai))
        XCTAssertFalse(tickets.isCurrent(other, for: .anthropic))
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
