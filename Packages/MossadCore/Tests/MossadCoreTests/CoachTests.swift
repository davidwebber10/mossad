import XCTest
@testable import MossadCore

final class CoachTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func record(_ id: String, start: Date, ownerSeconds: TimeInterval = 120, status: CallStatus = .written,
                        others: [String: String] = ["them:A": "Mitch Haus"]) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: status)
        r.speakerNames = ["me:A": "David Webber"].merging(others) { a, _ in a }
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: ownerSeconds, text: "Let me walk through the plan.")]
        for (i, key) in others.keys.sorted().enumerated() {
            r.utterances.append(Utterance(track: .them, speakerLabel: String(key.dropFirst(5)), start: ownerSeconds + Double(i), end: ownerSeconds + Double(i) + 30, text: "Sounds good."))
        }
        return r
    }

    private func review(headline: String = "Clear plan, rushed close") -> CoachReview {
        CoachReview(headline: headline, overview: "You led well.",
                    strengths: [CoachPoint(title: "Framed the goal", observation: "You opened with the goal.", quote: "Let me walk through the plan.", at: 0, principle: "Bottom line up front", tryInstead: nil)],
                    improvements: [CoachPoint(title: "Confirm next steps", observation: "The call ended with no owner.", quote: "OK, cool.", at: 1700, principle: "Close the loop", tryInstead: "So you own the draft by Friday, right?")],
                    focusProgress: nil)
    }

    // MARK: Profile

    func testApplyingAnUpdateMergesPatternsByNameAndKeepsTheirHistory() {
        var profile = CoachProfile()
        profile.patterns = [CoachPattern(name: "Interrupts", kind: .growth, note: "Cuts in early.", seen: 2, firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0), trend: .steady)]
        let at = Date(timeIntervalSince1970: 10 * day)
        let update = CoachProfileUpdate(summary: "A direct communicator.", focus: "Close every call with owners and dates.",
                                        patterns: [CoachPatternUpdate(name: "interrupts", kind: .growth, note: "Fewer cut-ins this time.", trend: .improving),
                                                   CoachPatternUpdate(name: "Frames the goal", kind: .strength, note: "Opens with the goal.", trend: .steady)],
                                        people: [CoachPersonUpdate(name: "Mitch Haus", note: "Wants the decision first, then detail.")])
        profile.apply(update, review: review(), callID: "c1", title: "Mitch / David", at: at)

        XCTAssertEqual(profile.summary, "A direct communicator.")
        XCTAssertEqual(profile.focus, "Close every call with owners and dates.")
        XCTAssertEqual(profile.patterns.count, 2)
        let interrupts = profile.patterns.first { $0.name == "Interrupts" }
        XCTAssertEqual(interrupts?.seen, 3)
        XCTAssertEqual(interrupts?.trend, .improving)
        XCTAssertEqual(interrupts?.note, "Fewer cut-ins this time.")
        XCTAssertEqual(interrupts?.firstSeen, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(interrupts?.lastSeen, at)
        XCTAssertEqual(profile.patterns.first { $0.name == "Frames the goal" }?.seen, 1)
        XCTAssertEqual(profile.people["Mitch Haus"]?.note, "Wants the decision first, then detail.")
        XCTAssertEqual(profile.people["Mitch Haus"]?.calls, 1)
        XCTAssertEqual(profile.history.map(\.callID), ["c1"])
        XCTAssertEqual(profile.history.first?.headline, "Clear plan, rushed close")
    }

    func testAnEmptyFocusOrSummaryKeepsTheOldOne() {
        var profile = CoachProfile()
        profile.summary = "Old"
        profile.focus = "Old focus"
        profile.apply(CoachProfileUpdate(summary: " ", focus: "", patterns: [], people: []), review: review(), callID: "c", title: "T", at: Date())
        XCTAssertEqual(profile.summary, "Old")
        XCTAssertEqual(profile.focus, "Old focus")
    }

    func testHistoryKeepsOnlyTheLatestEntries() {
        var profile = CoachProfile()
        for i in 0..<(CoachProfile.historyLimit + 5) {
            profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "c\(i)", title: "T", at: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(profile.history.count, CoachProfile.historyLimit)
        XCTAssertEqual(profile.history.last?.callID, "c\(CoachProfile.historyLimit + 4)")
    }

    func testProfileAndReviewRoundTripOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var profile = CoachProfile()
        profile.apply(CoachProfileUpdate(summary: "S", focus: "F", patterns: [], people: [CoachPersonUpdate(name: "Ed Ng", note: "Quiet")]),
                      review: review(), callID: "c", title: "T", at: Date(timeIntervalSince1970: 5))
        try profile.save(to: dir)
        XCTAssertEqual(try CoachProfile.load(from: dir), profile)
        XCTAssertEqual(try CoachProfile.load(from: dir.appendingPathComponent("missing")), CoachProfile())
        try review().save(in: dir)
        XCTAssertEqual(CoachReview.load(in: dir), review())
    }

    // MARK: Delivery

    func testDeliveryMeasuresPaceFillersTurnsQuestionsAndInterruptions() {
        var r = CallRecord(id: "d", platform: .meet, bundleID: "", start: Date(), end: Date(), status: .written)
        r.speakerNames = ["me:A": "David Webber", "them:A": "Mitch Haus"]
        let ten = Array(repeating: "word", count: 10).joined(separator: " ")
        r.utterances = [
            // 20 words in 10 s: 120 wpm, with two fillers.
            Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Um so \(ten) uh eight more words here to count ok"),
            // Mitch talks from 12 to 30; David cuts in at 20.
            Utterance(track: .them, speakerLabel: "A", start: 12, end: 30, text: "Long reply"),
            // 30 words in 5 s: 360 wpm, a question.
            Utterance(track: .me, speakerLabel: "A", start: 20, end: 25, text: "\(ten) \(ten) \(ten) right?"),
            // Mitch cuts in on David at 40.
            Utterance(track: .me, speakerLabel: "A", start: 35, end: 50, text: "\(ten)"),
            Utterance(track: .them, speakerLabel: "A", start: 40, end: 45, text: "Wait"),
        ]
        let d = DeliveryStats(record: r, owner: "David Webber")
        XCTAssertEqual(d.talkSeconds, 30)
        XCTAssertEqual(d.talkShare, 30.0 / 53.0, accuracy: 0.001)
        XCTAssertEqual(d.fillers, 2)
        XCTAssertEqual(d.fastestWordsPerMinute, 372, accuracy: 1)
        XCTAssertEqual(d.longestTurnSeconds, 15)
        XCTAssertEqual(d.questions, 1)
        XCTAssertEqual(d.interruptions, 1)
        XCTAssertEqual(d.interrupted, 1)
        XCTAssertGreaterThan(d.wordsPerMinute, 100)
    }

    func testDeliveryNumbersIncludeTheToneWhenMeasured() {
        var d = DeliveryStats(record: record("c", start: Date()), owner: "David Webber")
        XCTAssertFalse(CoachPrompt.numbers(d).contains("pitch"))
        d.tone = VoiceTone(medianPitch: 118, pitchVariation: 1.6, level: -24, loudnessRange: 9, endDrop: 4.2)
        let text = CoachPrompt.numbers(d)
        XCTAssertTrue(text.contains("pitch 118 Hz"), text)
        XCTAssertTrue(text.contains("pitch variation 1.6 semitones"), text)
        XCTAssertTrue(text.contains("turn ends 4.2 dB quieter"), text)
    }

    // MARK: Prompt

    func testPromptCarriesTheProfileOnlyTheseAttendeesNotesAndTheTranscript() {
        var profile = CoachProfile()
        profile.focus = "Close with owners and dates."
        profile.people = ["Mitch Haus": CoachPerson(note: "Wants the decision first.", calls: 3, lastSeen: Date()),
                          "Someone Else": CoachPerson(note: "Not on this call.", calls: 1, lastSeen: Date())]
        let r = record("c", start: Date())
        let text = CoachPrompt.user(record: r, owner: "David Webber", profile: profile)
        XCTAssertTrue(text.contains("Close with owners and dates."))
        XCTAssertTrue(text.contains("Wants the decision first."))
        XCTAssertFalse(text.contains("Not on this call."))
        XCTAssertTrue(text.contains("David Webber: Let me walk through the plan."))
        XCTAssertTrue(CoachPrompt.system(owner: "David Webber").contains("David Webber"))
    }

    func testPromptGivesTheFactsForRatingTheMeetingsValue() {
        var profile = CoachProfile()
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "x", title: "Weekly Sync", at: Date())
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "y", title: "weekly sync", at: Date())
        var r = record("c", start: Date())
        r.calendarTitle = "Weekly Sync"
        r.actionItems = [ActionItem(owner: "David Webber", task: "a"), ActionItem(owner: "Mitch Haus", task: "b")]
        r.decisions = ["d"]
        let text = CoachPrompt.user(record: r, owner: "David Webber", profile: profile)
        XCTAssertTrue(text.contains("Action items for David Webber: 1 of 2"), text)
        XCTAssertTrue(text.contains("Decisions: 1"))
        XCTAssertTrue(text.contains("People who spoke: 2"))
        XCTAssertTrue(text.contains("Earlier coached meetings with this title: 2"))
    }

    // MARK: Which calls

    func testPendingCallsAreWrittenSinceTheStartWithEnoughOwnerSpeechAndNoReviewOldestFirst() {
        let since = Date(timeIntervalSince1970: 100 * day)
        let calls = [
            record("new", start: since.addingTimeInterval(2 * day)),
            record("old", start: since.addingTimeInterval(day)),
            record("before", start: since.addingTimeInterval(-day)),
            record("quiet", start: since.addingTimeInterval(day), ownerSeconds: 20),
            record("processing", start: since.addingTimeInterval(day), status: .summarized),
            record("reviewed", start: since.addingTimeInterval(day)),
        ]
        let pending = CoachRunner.pending(calls, owner: "David Webber", since: since, reviewed: ["reviewed"])
        XCTAssertEqual(pending.map(\.id), ["old", "new"])
    }

    // MARK: Weekly email

    func testTheWeeklyEmailIsDueOnceAfterMondayMorning() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        func date(_ d: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }
        // Monday Oct 19 2026.
        XCTAssertFalse(WeeklySchedule.isDue(lastSent: date(12, 9), now: date(19, 7), calendar: cal))
        XCTAssertTrue(WeeklySchedule.isDue(lastSent: date(12, 9), now: date(19, 8), calendar: cal))
        XCTAssertTrue(WeeklySchedule.isDue(lastSent: date(12, 9), now: date(21, 15), calendar: cal))
        XCTAssertFalse(WeeklySchedule.isDue(lastSent: date(19, 8), now: date(21, 15), calendar: cal))
        XCTAssertTrue(WeeklySchedule.isDue(lastSent: nil, now: date(21, 15), calendar: cal))
        XCTAssertEqual(WeeklySchedule.weekStart(before: date(21, 15), calendar: cal), date(12, 8))
    }

    func testResendRequestCarriesTheKeyAndTheMessage() throws {
        let request = try ResendMailer(apiKey: "re_key", from: "Mossad <coach@example.com>")
            .request(to: "me@example.com", subject: "Your week", html: "<p>Hi</p>", text: "Hi")
        XCTAssertEqual(request.url?.absoluteString, "https://api.resend.com/emails")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer re_key")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        XCTAssertEqual(body["from"] as? String, "Mossad <coach@example.com>")
        XCTAssertEqual(body["to"] as? [String], ["me@example.com"])
        XCTAssertEqual(body["subject"] as? String, "Your week")
        XCTAssertEqual(body["html"] as? String, "<p>Hi</p>")
        XCTAssertEqual(body["text"] as? String, "Hi")
    }

    func testResendErrorThrows() async {
        StubURLProtocol.handler = { _ in (403, Data(#"{"message":"bad key"}"#.utf8)) }
        let mailer = ResendMailer(apiKey: "k", from: "a@b.c", session: StubURLProtocol.session())
        do {
            try await mailer.send(to: "me@example.com", subject: "S", html: "H", text: "T")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("403"))
        }
    }

    func testDigestHTMLEscapesTextAndKeepsTheSections() {
        let digest = WeeklyDigest(subject: "Week of Oct 12", intro: "A good week <really>.",
                                  improved: ["Closed calls with owners."], toWork: ["Long openings."], focus: "Ask one question first.")
        let html = digest.html
        XCTAssertTrue(html.contains("A good week &lt;really&gt;."))
        XCTAssertTrue(html.contains("Closed calls with owners."))
        XCTAssertTrue(html.contains("Ask one question first."))
        XCTAssertTrue(digest.text.contains("- Long openings."))
    }

    // MARK: Claude

    private func reply(_ text: String) -> Data {
        json(["stop_reason": "end_turn", "content": [["type": "text", "text": text]]])
    }

    func testCoachSendsTheSchemaAndParsesTheReviewAndUpdate() async throws {
        let output: [String: Any] = [
            "headline": "Clear plan", "overview": "Good.",
            "strengths": [["title": "Goal first", "observation": "O", "quote": "Q", "at_seconds": 3, "principle": "P", "try_instead": NSNull()]],
            "improvements": [["title": "Close", "observation": "O2", "quote": "Q2", "at_seconds": 90, "principle": "P2", "try_instead": "Say X"]],
            "focus_progress": "Better than last week.",
            "meeting_value": ["rating": "low", "reason": "Status only; you said nothing.", "action": "async", "suggestion": "Ask for a written update."],
            "profile": ["summary": "S", "focus": "F",
                        "patterns": [["name": "Interrupts", "kind": "growth", "note": "N", "trend": "improving"]],
                        "people": [["name": "Mitch Haus", "note": "Likes data"]]],
        ]
        let text = String(decoding: json(output), as: UTF8.self)
        StubURLProtocol.handler = { _ in (200, self.reply(text)) }
        let coach = LLMCoach(apiKey: "ant", session: StubURLProtocol.session(), ownerName: "David Webber")
        let result = try await coach.review(record: record("c", start: Date()), profile: CoachProfile(), tone: nil)
        XCTAssertEqual(result.review.headline, "Clear plan")
        XCTAssertEqual(result.review.improvements.first?.tryInstead, "Say X")
        XCTAssertEqual(result.review.improvements.first?.at, 90)
        XCTAssertNil(result.review.strengths.first?.tryInstead)
        XCTAssertEqual(result.review.focusProgress, "Better than last week.")
        XCTAssertEqual(result.update.patterns.first?.trend, .improving)
        XCTAssertEqual(result.update.people.first?.name, "Mitch Haus")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.requests.first).body) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        let schema = ((body["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as? [String: Any]
        XCTAssertEqual(Set(schema?["required"] as? [String] ?? []),
                       ["headline", "overview", "strengths", "improvements", "focus_progress", "meeting_value", "profile"])
        XCTAssertEqual(result.review.value, MeetingValue(rating: .low, reason: "Status only; you said nothing.", action: .async, suggestion: "Ask for a written update."))
    }

    func testCoachMalformedReplyThrows() async {
        StubURLProtocol.handler = { _ in (200, self.reply("nope")) }
        let coach = LLMCoach(apiKey: "ant", session: StubURLProtocol.session(), ownerName: "David Webber")
        do {
            _ = try await coach.review(record: record("c", start: Date()), profile: CoachProfile(), tone: nil)
            XCTFail("expected an error")
        } catch {}
    }

    // MARK: Runner and weekly send

    private final class FakeCoach: Coaching, @unchecked Sendable {
        var seen: [(id: String, focus: String)] = []
        var failOn: String?
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult {
            seen.append((record.id, profile.focus))
            if record.id == failOn { throw SummaryError.malformed }
            return CoachResult(review: CoachReview(headline: "H \(record.id)", overview: "O", strengths: [], improvements: [], focusProgress: nil),
                               update: CoachProfileUpdate(summary: "S", focus: "after \(record.id)", patterns: [], people: []))
        }
    }

    private func tempPaths(_ records: [CallRecord]) throws -> Paths {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.ensureDirectories()
        for r in records {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        return paths
    }

    func testRunnerReviewsOldestFirstAndCarriesTheProfileForward() async throws {
        let since = Date(timeIntervalSince1970: 0)
        let paths = try tempPaths([record("b", start: Date(timeIntervalSince1970: 200)), record("a", start: Date(timeIntervalSince1970: 100))])
        let coach = FakeCoach()
        let done = await CoachRunner(paths: paths, coach: coach, owner: "David Webber", since: since).run()
        XCTAssertEqual(done, 2)
        XCTAssertEqual(coach.seen.map(\.id), ["a", "b"])
        XCTAssertEqual(coach.seen.map(\.focus), ["", "after a"])
        XCTAssertEqual(CoachReview.load(in: paths.callDirectory("b"))?.headline, "H b")
        XCTAssertEqual(try CoachProfile.load(from: paths.coach).history.map(\.callID), ["a", "b"])
        // A second run has nothing left to do.
        let again = await CoachRunner(paths: paths, coach: coach, owner: "David Webber", since: since).run()
        XCTAssertEqual(again, 0)
    }

    func testRunnerStopsAtAFailureSoTheOrderHolds() async throws {
        let paths = try tempPaths([record("a", start: Date(timeIntervalSince1970: 100)), record("b", start: Date(timeIntervalSince1970: 200))])
        let coach = FakeCoach()
        coach.failOn = "a"
        let done = await CoachRunner(paths: paths, coach: coach, owner: "David Webber", since: .distantPast).run()
        XCTAssertEqual(done, 0)
        XCTAssertEqual(coach.seen.map(\.id), ["a"])
        XCTAssertNil(CoachReview.load(in: paths.callDirectory("b")))
    }

    private final class FakeMail: Mailing, DigestWriting, @unchecked Sendable {
        var sent: [String] = []
        var reviewed: [String] = []
        func send(to: String, subject: String, html: String, text: String) async throws { sent.append(subject) }
        func digest(owner: String, reviews: [(title: String, date: Date, review: CoachReview)], profile: CoachProfile) async throws -> WeeklyDigest {
            reviewed = reviews.map(\.review.headline)
            return WeeklyDigest(subject: "Week", intro: "I", improved: [], toWork: [], focus: "F")
        }
    }

    func testWeeklyEmailCoversOnlyLastWeeksCoachedCalls() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func date(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }
        let paths = try tempPaths([record("in", start: date(14)), record("late", start: date(20)), record("early", start: date(5))])
        for id in ["in", "late", "early"] {
            try CoachReview(headline: id, overview: "", strengths: [], improvements: [], focusProgress: nil).save(in: paths.callDirectory(id))
        }
        let fake = FakeMail()
        let sent = await WeeklyEmail.sendIfDue(paths: paths, owner: "David Webber", to: "me@example.com", lastSent: date(12),
                                               now: date(21), writer: fake, mailer: fake, calendar: cal)
        XCTAssertEqual(sent, date(21))
        XCTAssertEqual(fake.reviewed, ["in"])
        XCTAssertEqual(fake.sent, ["Week"])
        let notDue = await WeeklyEmail.sendIfDue(paths: paths, owner: "David Webber", to: "me@example.com", lastSent: date(20),
                                                 now: date(21), writer: fake, mailer: fake, calendar: cal)
        XCTAssertNil(notDue)
    }

    func testTheEmailOnlyEverGoesToOneOwnAddress() async throws {
        XCTAssertTrue(WeeklyEmail.isSingleAddress("me@example.com"))
        XCTAssertTrue(WeeklyEmail.isSingleAddress(" me@example.com "))
        for bad in ["", "me", "a@b.com, c@d.com", "a@b.com;c@d.com", "a@b.com c@d.com", "Me <a@b.com>, c@d.com", "a@@b.com"] {
            XCTAssertFalse(WeeklyEmail.isSingleAddress(bad), bad)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let paths = try tempPaths([record("in", start: start)])
        try CoachReview(headline: "in", overview: "", strengths: [], improvements: [], focusProgress: nil).save(in: paths.callDirectory("in"))
        let fake = FakeMail()
        let sent = await WeeklyEmail.sendIfDue(paths: paths, owner: "David Webber", to: "me@example.com, boss@example.com", lastSent: nil,
                                               now: cal.date(from: DateComponents(year: 2026, month: 10, day: 21))!, writer: fake, mailer: fake, calendar: cal)
        XCTAssertNil(sent)
        XCTAssertTrue(fake.sent.isEmpty)
    }
}
