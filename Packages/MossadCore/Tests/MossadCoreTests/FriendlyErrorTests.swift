import XCTest
@testable import MossadCore

final class FriendlyErrorTests: XCTestCase {
    /// No codes, domains, JSON, or HTML in what the owner reads.
    private func assertPlain(_ f: FriendlyError, file: StaticString = #filePath, line: UInt = #line) {
        for text in [f.title, f.message] {
            for bad in ["HTTP", "NSURL", "OSStatus", "Domain", "{", "}", "<", ">", "error -", "!"] {
                XCTAssertFalse(text.contains(bad), "\(bad) in \(text)", file: file, line: line)
            }
            XCTAssertNil(text.range(of: #"-?\d{3,}"#, options: .regularExpression), "a code in \(text)", file: file, line: line)
        }
        XCTAssertFalse(f.title.isEmpty, file: file, line: line)
        XCTAssertFalse(f.title.hasSuffix("."), file: file, line: line)
        XCTAssertTrue(f.message.isEmpty || f.message.hasSuffix("."), f.message, file: file, line: line)
    }

    func testCancellationIsNeverShown() {
        for error: Error in [CancellationError(), URLError(.cancelled),
                             NSError(domain: NSURLErrorDomain, code: -999), NSError(domain: "CKErrorDomain", code: 20)] {
            let f = FriendlyError(error, context: .syncing)
            XCTAssertEqual(f.kind, .cancelled)
            XCTAssertEqual(f.visibility, .never)
            XCTAssertFalse(f.shouldShow(failures: 5))
        }
        XCTAssertEqual(FriendlyError(reason: "cancelled", context: .syncing).kind, .cancelled)
    }

    func testTheServerNotAnsweringWhileSyncing() {
        let f = FriendlyError(URLError(.cannotConnectToHost), context: .syncing, service: "your server")
        XCTAssertEqual(f.title, "Your server didn't answer")
        XCTAssertEqual(f.message, "Mossad tries again on its own.")
        XCTAssertTrue(f.canRetry)
        XCTAssertEqual(f.visibility, .whenRepeated)
        XCTAssertFalse(f.shouldShow(failures: 1))
        XCTAssertTrue(f.shouldShow(failures: 2))
        assertPlain(f)
    }

    func testOfflineDependsOnWhoRetries() {
        let auto = FriendlyError(URLError(.notConnectedToInternet), context: .transcribing)
        XCTAssertEqual(auto.title, "You're offline")
        XCTAssertEqual(auto.message, "Mossad tries again when you're back online.")
        let chat = FriendlyError(URLError(.notConnectedToInternet), context: .chatting)
        XCTAssertEqual(chat.message, "Check your connection, then try again.")
        XCTAssertEqual(chat.visibility, .always)
        assertPlain(auto)
        assertPlain(chat)
    }

    func testANextAttemptTimeIsNamed() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let f = FriendlyError(SummaryError.http(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
                              context: .summarizing, nextAttempt: at)
        XCTAssertEqual(f.title, "Anthropic is busy right now")
        XCTAssertTrue(f.message.hasPrefix("Mossad tries again at "), f.message)
    }

    func testAClaudeBadRequestKeepsItsHumaneMessage() {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 215000 tokens > 200000 maximum"}}"#
        let f = FriendlyError(SummaryError.http(400, body), context: .summarizing)
        XCTAssertEqual(f.kind, .rejected)
        XCTAssertEqual(f.title, "Anthropic couldn't take this request")
        XCTAssertFalse(f.canRetry)
        XCTAssertTrue(f.technical.contains("400"))
        assertPlain(f)
        let plain = FriendlyError(SummaryError.http(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"The transcript is too long for this model"}}"#),
                                  context: .summarizing)
        XCTAssertEqual(plain.message, "The transcript is too long for this model.")
    }

    func testAnHTMLGatewayPageIsNeverShown() {
        let html = "<html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center><hr><center>cloudflare</center></body></html>"
        let f = FriendlyError(TranscriptionError.http(502, html), context: .transcribing)
        XCTAssertEqual(f.title, "AssemblyAI is having trouble")
        XCTAssertEqual(f.visibility, .whenRepeated)
        XCTAssertFalse(f.technical.contains("<"))
        XCTAssertTrue(f.technical.contains("502 Bad Gateway"))
        assertPlain(f)
    }

    func testAKeyProblemSaysWhereToFixIt() {
        let bad = FriendlyError(ProviderError.http("Deepgram", 401, #"{"err_msg":"Invalid credentials."}"#), context: .transcribing)
        XCTAssertEqual(bad.title, "Deepgram didn't accept the API key")
        XCTAssertEqual(bad.message, "Check the Deepgram key in Settings › AI.")
        XCTAssertFalse(bad.canRetry)
        XCTAssertEqual(bad.visibility, .always)
        let missing = FriendlyError(MissingAPIKey(service: "AssemblyAI"), context: .transcribing)
        XCTAssertEqual(missing.title, "Mossad needs your AssemblyAI key")
        XCTAssertEqual(missing.message, "Add the key in Settings › AI, then retry.")
        let mail = FriendlyError(MailError.http(403, #"{"message":"API key is invalid"}"#), context: .sendingEmail)
        XCTAssertEqual(mail.message, "Check the Resend key in Settings › Coach.")
        assertPlain(bad); assertPlain(missing); assertPlain(mail)
    }

    func testBillingAndRateLimits() {
        let credit = FriendlyError(SummaryError.http(400, #"{"error":{"message":"Your credit balance is too low to access the Anthropic API."}}"#),
                                   context: .chatting)
        XCTAssertEqual(credit.kind, .billing)
        XCTAssertEqual(credit.title, "Your Anthropic account needs attention")
        let quota = FriendlyError(ProviderError.http("OpenAI", 429, #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#),
                                  context: .summarizing)
        XCTAssertEqual(quota.kind, .billing)
        let slow = FriendlyError(ProviderError.http("OpenAI", 429, "{}"), context: .chatting)
        XCTAssertEqual(slow.kind, .rateLimited)
        XCTAssertEqual(slow.message, "Wait a minute, then try again.")
        assertPlain(credit); assertPlain(quota); assertPlain(slow)
    }

    func testTheRoomRecorderPausedByAnotherApp() {
        let paused = FriendlyError(kind: .interrupted, context: .recording)
        XCTAssertEqual(paused.title, "Recording is paused")
        XCTAssertEqual(paused.message, "Another app used the microphone. Tap Resume to keep recording.")
        XCTAssertTrue(paused.canRetry)
        XCTAssertEqual(paused.visibility, .always)
        XCTAssertTrue(paused.isAboutRecording)
        let resume = FriendlyError(kind: .resumeFailed, context: .recording)
        XCTAssertEqual(resume.title, "Recording couldn't resume")
        XCTAssertTrue(resume.canRetry)
        assertPlain(paused); assertPlain(resume)
    }

    func testTheRoomRecorderOSStatus() {
        let f = FriendlyError(NSError(domain: NSOSStatusErrorDomain, code: -50), context: .recording)
        XCTAssertEqual(f.title, "Recording couldn't start")
        XCTAssertTrue(f.isAboutRecording)
        XCTAssertTrue(f.canRetry)
        XCTAssertTrue(f.technical.contains("-50"))
        assertPlain(f)
        let busy = FriendlyError(NSError(domain: NSOSStatusErrorDomain, code: 561_017_449), context: .recording)
        XCTAssertEqual(busy.kind, .microphoneBusy)
        XCTAssertEqual(busy.title, "Another app is using the microphone")
        assertPlain(busy)
        let wrapped = NSError(domain: "com.apple.coreaudio.avfaudio", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: 561_017_449)])
        XCTAssertEqual(FriendlyError(wrapped, context: .recording).kind, .microphoneBusy)
    }

    func testServerErrors() {
        XCTAssertEqual(FriendlyError(ServerError.wrongSecret, context: .syncing).title, "Your server didn't accept the secret")
        XCTAssertEqual(FriendlyError(ServerError.notMossad, context: .connectingServer).title, "That address isn't a Mossad server")
        let none = FriendlyError(kind: .notConnected, context: .syncing)
        XCTAssertEqual(none.title, "Your server isn't connected")
        XCTAssertEqual(none.visibility, .always)
        let saved = FriendlyError(ServerError.http(0, "The recording did not upload."), context: .uploadingAudio)
        XCTAssertEqual(saved.message, "Mossad tries again on its own.")
        let down = FriendlyError(ServerError.http(503, ""), context: .syncing, service: "your server")
        XCTAssertEqual(down.title, "Your server is having trouble")
        assertPlain(saved); assertPlain(down)
    }

    func testICloudNamesStayAsTheyAre() {
        let f = FriendlyError(NSError(domain: "CKErrorDomain", code: 9), context: .syncing, service: "iCloud")
        XCTAssertEqual(f.title, "You're not signed in to iCloud")
        let down = FriendlyError(NSError(domain: "CKErrorDomain", code: 6), context: .syncing, service: "iCloud")
        XCTAssertEqual(down.title, "iCloud is having trouble")
        let full = FriendlyError(NSError(domain: "CKErrorDomain", code: 25), context: .syncing, service: "iCloud")
        XCTAssertEqual(full.kind, .iCloudFull)
        assertPlain(f); assertPlain(down); assertPlain(full)
    }

    func testOtherErrors() {
        XCTAssertEqual(FriendlyError(SummaryError.refused, context: .summarizing).kind, .refused)
        XCTAssertEqual(FriendlyError(SummaryError.malformed, context: .coaching).title, "The AI service sent a reply Mossad couldn't read")
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertEqual(FriendlyError(decoding, context: .syncing).kind, .unreadable)
        XCTAssertEqual(FriendlyError(ChatError.tooManySteps, context: .chatting).message, "Try a narrower question.")
        XCTAssertEqual(FriendlyError(OrgChart.ParseError.missingColumns, context: .importingOrgChart).kind, .badFile)
        XCTAssertEqual(FriendlyError(NSError(domain: NSCocoaErrorDomain, code: 640), context: .recording).kind, .diskFull)
        XCTAssertEqual(FriendlyError(ProviderError.failed("OpenAI", "the track is over OpenAI's 25 MB limit"), context: .transcribing).kind, .tooLarge)
        let mystery = FriendlyError(NSError(domain: "Weird", code: 3), context: .checkingUpdates)
        XCTAssertEqual(mystery.title, "Mossad couldn't check for updates")
        assertPlain(mystery)
        for context in FriendlyError.Context.allCases {
            assertPlain(FriendlyError(NSError(domain: "Weird", code: 3), context: context))
            assertPlain(FriendlyError(URLError(.timedOut), context: context))
            assertPlain(FriendlyError(ProviderError.http("OpenRouter", 500, "x"), context: context))
        }
    }

    /// A humane LocalizedError, such as the iPhone's note about the shared AI key, reads as it is.
    func testAHumaneLocalizedDescriptionIsKept() {
        struct NoKey: LocalizedError { var errorDescription: String? { "Turn on the shared AI key on your Mac" } }
        XCTAssertEqual(FriendlyError(NoKey(), context: .chatting).message, "Turn on the shared AI key on your Mac.")
    }

    /// The reasons call.json keeps, old and new, read the same as the errors they came from.
    func testStoredReasons() {
        XCTAssertEqual(FriendlyError(reason: "AssemblyAI key missing", context: .transcribing).kind, .missingKey)
        XCTAssertEqual(FriendlyError(reason: "invalid API key", context: .summarizing).kind, .unauthorized)
        let busy = FriendlyError(reason: "Anthropic error 529", context: .summarizing)
        XCTAssertEqual(busy.title, "Anthropic is busy right now")
        XCTAssertEqual(FriendlyError(reason: "no network connection", context: .transcribing).kind, .offline)
        XCTAssertEqual(FriendlyError(reason: "the request timed out", context: .transcribing).kind, .timedOut)
        XCTAssertEqual(FriendlyError(reason: "AssemblyAI HTTP 502: <html><title>502 Bad Gateway</title></html>", context: .transcribing).kind, .serverTrouble)
        XCTAssertEqual(FriendlyError(reason: "Claude HTTP 400: {\"error\":{\"message\":\"Your credit balance is too low\"}}", context: .summarizing).kind, .billing)
        let os = FriendlyError(reason: "Recording could not start: The operation couldn’t be completed. (OSStatus error -50.)", context: .recording)
        XCTAssertEqual(os.kind, .recordingFailed)
        assertPlain(os)
        XCTAssertEqual(FriendlyError(reason: "The operation couldn’t be completed. (NSURLErrorDomain error -1009.)", context: .syncing).kind, .offline)
        XCTAssertEqual(FriendlyError(reason: "Anthropic error 400: The transcript is too long for this model", context: .summarizing).message,
                       "The transcript is too long for this model.")
        let odd = FriendlyError(reason: "unexpected error", context: .identifying)
        XCTAssertEqual(odd.title, "Mossad couldn't name the speakers")
        assertPlain(odd)
    }

    func testTechnicalTextIsTrimmed() {
        let long = String(repeating: "abc ", count: 400)
        let f = FriendlyError(TranscriptionError.http(500, long), context: .transcribing)
        XCTAssertLessThanOrEqual(f.technical.count, 601)
    }

    func testTheProviderMessageInAFailureReason() {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"The transcript is too long for this model"}}"#
        XCTAssertEqual(Pipeline.failureReason(SummaryError.http(400, body)), "Anthropic error 400: The transcript is too long for this model")
    }

    func testACallStillRetryingAndACallThatStopped() {
        var r = CallRecord(id: "x", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 1_800_000_000),
                           end: Date(timeIntervalSince1970: 1_800_001_000), status: .recorded)
        r.failureReason = "AssemblyAI error 502"
        r.attempts = 1
        let retrying = r.friendlyFailure!
        XCTAssertEqual(retrying.context, .transcribing)
        XCTAssertEqual(retrying.message, "Mossad tries again on its own.")
        XCTAssertFalse(retrying.shouldShow(failures: r.attempts))
        r.status = .failed
        r.failedStep = .identified
        let stopped = r.friendlyFailure!
        XCTAssertEqual(stopped.context, .summarizing)
        XCTAssertEqual(stopped.message, "Try again in a few minutes.")
        XCTAssertTrue(stopped.shouldShow(failures: 1))
    }

    /// A reason without a provider name reads as "the API key", never "the the AI service key".
    func testAGenericServiceReadsNaturally() {
        let f = FriendlyError(reason: "invalid API key", context: .summarizing, retries: false)
        XCTAssertEqual(f.title, "The AI service didn't accept the API key")
        XCTAssertEqual(f.message, "Check the API key in Settings › AI.")
        XCTAssertEqual(FriendlyError(kind: .missingKey, context: .chatting).title, "Mossad needs your API key")
        XCTAssertEqual(FriendlyError(kind: .billing, context: .chatting).title, "Your AI account needs attention")
    }
}
