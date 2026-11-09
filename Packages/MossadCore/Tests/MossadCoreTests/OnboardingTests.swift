import XCTest
@testable import MossadCore

final class OnboardingTests: XCTestCase {
    private var everythingSet: OnboardingFacts {
        OnboardingFacts(ownerName: "Alex Rivera", granted: [.microphone, .systemAudio, .calendars, .accessibility, .notifications],
                        transcriptionKeySet: true, aiKeySet: true, chosenCalendars: 2, micHeard: true, systemAudioHeard: true)
    }

    func testTheStepsComeInTheSpecOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .you, .permissions, .ai, .calendars, .check, .sync, .done])
        XCTAssertEqual(OnboardingStep.allCases.map(\.number), Array(1...8))
        XCTAssertEqual(OnboardingStep.sync.title, "iPhone and sync")
    }

    func testOnlyYouCannotBeSkipped() {
        XCTAssertFalse(OnboardingStep.you.isSkippable)
        for step in OnboardingStep.allCases where step != .you { XCTAssertTrue(step.isSkippable, "\(step)") }
    }

    func testANewProgressStartsAtWelcomeWithEveryStepAhead() {
        let p = OnboardingProgress()
        XCTAssertEqual(p.current, .welcome)
        XCTAssertFalse(p.completed)
        for step in OnboardingStep.allCases where step != .welcome {
            XCTAssertEqual(p.state(of: step, facts: OnboardingFacts()), .upcoming, "\(step)")
        }
    }

    func testContinueMarksTheStepSeenAndMovesOn() {
        var p = OnboardingProgress()
        p.advance()
        XCTAssertEqual(p.current, .you)
        XCTAssertEqual(p.state(of: .welcome, facts: OnboardingFacts()), .done)
    }

    func testYouNeedsANameBeforeContinue() {
        var p = OnboardingProgress(current: .you)
        XCTAssertFalse(p.canContinue(facts: OnboardingFacts(ownerName: "  ")))
        XCTAssertTrue(p.canContinue(facts: OnboardingFacts(ownerName: "Alex")))
        XCTAssertFalse(p.skip(), "You cannot be skipped")
        XCTAssertEqual(p.current, .you)
    }

    func testSkipMarksTheStepSkippedUntilItIsDone() {
        var p = OnboardingProgress(current: .ai)
        XCTAssertTrue(p.skip())
        XCTAssertEqual(p.current, .calendars)
        XCTAssertEqual(p.state(of: .ai, facts: OnboardingFacts()), .skipped)
        // Setting the keys later turns it done.
        XCTAssertEqual(p.state(of: .ai, facts: everythingSet), .done)
    }

    func testAStepSeenButNotSatisfiedNeedsYou() {
        var p = OnboardingProgress(current: .permissions)
        p.advance()
        XCTAssertEqual(p.state(of: .permissions, facts: OnboardingFacts(granted: [.microphone])), .needsYou)
        XCTAssertEqual(p.state(of: .permissions, facts: OnboardingFacts(granted: [.microphone, .systemAudio])), .done)
    }

    func testTheCurrentStepIsCurrentUnlessDone() {
        let p = OnboardingProgress(current: .ai)
        XCTAssertEqual(p.state(of: .ai, facts: OnboardingFacts()), .current)
        XCTAssertEqual(p.state(of: .ai, facts: everythingSet), .done)
    }

    func testBackAndJump() {
        var p = OnboardingProgress(current: .calendars)
        p.back()
        XCTAssertEqual(p.current, .ai)
        p.jump(to: .check)
        XCTAssertEqual(p.current, .check)
        var first = OnboardingProgress()
        first.back()
        XCTAssertEqual(first.current, .welcome)
    }

    func testEachStepSaysWhenItIsSatisfied() {
        let none = OnboardingFacts()
        let all = everythingSet
        XCTAssertFalse(OnboardingStep.ai.isSatisfied(by: none))
        XCTAssertTrue(OnboardingStep.ai.isSatisfied(by: all))
        // The local transcription model needs no key.
        XCTAssertTrue(OnboardingStep.ai.isSatisfied(by: OnboardingFacts(transcriptionKeySet: nil, aiKeySet: true)))
        XCTAssertFalse(OnboardingStep.calendars.isSatisfied(by: OnboardingFacts(chosenCalendars: 2)), "Calendars needs the permission too")
        XCTAssertTrue(OnboardingStep.calendars.isSatisfied(by: OnboardingFacts(granted: [.calendars], chosenCalendars: 1)))
        XCTAssertFalse(OnboardingStep.check.isSatisfied(by: OnboardingFacts(micHeard: true, systemAudioHeard: nil)))
        XCTAssertTrue(OnboardingStep.check.isSatisfied(by: OnboardingFacts(micHeard: true, systemAudioHeard: true)))
    }

    func testFinishCompletesAndRestartForgetsEverything() {
        var p = OnboardingProgress(current: .done)
        p.finish()
        XCTAssertTrue(p.completed)
        XCTAssertEqual(p.state(of: .done, facts: OnboardingFacts()), .done)
        p.restart()
        XCTAssertEqual(p, OnboardingProgress())
    }

    func testProgressResumesFromItsSavedForm() throws {
        var p = OnboardingProgress()
        p.advance()
        p.advance()
        _ = p.skip()
        let saved = try XCTUnwrap(p.encoded())
        let resumed = OnboardingProgress.resume(from: saved)
        XCTAssertEqual(resumed, p)
        XCTAssertEqual(resumed.current, .ai)
    }

    func testUnreadableSavedProgressStartsOver() {
        XCTAssertEqual(OnboardingProgress.resume(from: Data("nonsense".utf8)), OnboardingProgress())
        XCTAssertEqual(OnboardingProgress.resume(from: nil), OnboardingProgress())
    }

    // MARK: Permissions

    func testMicrophoneAndSystemAudioAreRequired() {
        XCTAssertTrue(OnboardingPermissions.isRequired(.microphone))
        XCTAssertTrue(OnboardingPermissions.isRequired(.systemAudio))
        for kind: PermissionKind in [.calendars, .accessibility, .notifications, .automation("com.google.Chrome")] {
            XCTAssertFalse(OnboardingPermissions.isRequired(kind), "\(kind)")
        }
    }

    func testPermissionsSortInImportanceOrderWithBrowsersLast() {
        let mixed: [PermissionKind] = [.automation("com.google.Chrome"), .notifications, .accessibility, .calendars, .systemAudio, .microphone,
                                       .automation("com.apple.Safari")]
        XCTAssertEqual(OnboardingPermissions.ordered(mixed),
                       [.microphone, .systemAudio, .calendars, .accessibility, .notifications, .automation("com.google.Chrome"), .automation("com.apple.Safari")])
    }

    func testWhatWillNotWorkNamesEachMissingPermission() {
        XCTAssertTrue(OnboardingPermissions.whatWillNotWork(missing: []).isEmpty)
        let lines = OnboardingPermissions.whatWillNotWork(missing: [.systemAudio, .calendars])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("other people"), lines[0])
        XCTAssertTrue(lines[1].contains("invite"), lines[1])
        // Several browsers say it once.
        XCTAssertEqual(OnboardingPermissions.whatWillNotWork(missing: [.automation("a"), .automation("b")]).count, 1)
    }

    // MARK: When it opens

    func testOnlyANewInstallSeesItInTheRealApp() {
        XCTAssertTrue(Onboarding.opensAtLaunch(finished: false, hasMeetings: false, preview: false, forced: false, rehearsal: false))
        XCTAssertFalse(Onboarding.opensAtLaunch(finished: true, hasMeetings: false, preview: false, forced: false, rehearsal: false))
        XCTAssertFalse(Onboarding.opensAtLaunch(finished: false, hasMeetings: true, preview: false, forced: false, rehearsal: false))
        XCTAssertFalse(Onboarding.opensAtLaunch(finished: false, hasMeetings: false, preview: true, forced: false, rehearsal: false))
        XCTAssertTrue(Onboarding.opensAtLaunch(finished: true, hasMeetings: true, preview: false, forced: true, rehearsal: false))
    }

    func testRehearsalAlwaysOpensIntoIt() {
        XCTAssertTrue(Onboarding.opensAtLaunch(finished: true, hasMeetings: true, preview: false, forced: false, rehearsal: true))
    }

    // MARK: Cost

    func testAnHourOfMeetingsCostsBothTracksAndOneSummary() {
        let cost = Pricing.hourEstimate(transcription: .assemblyai, ai: .anthropic, model: "")
        // Two tracks at $0.23 an hour, and a summary of about 15,000 tokens in and 2,500 out on the default model.
        XCTAssertEqual(cost, 0.46 + 0.06 + 0.05, accuracy: 0.005)
        XCTAssertEqual(Pricing.hourEstimate(transcription: .local, ai: .anthropic, model: "claude-haiku-5-5"), 0.0028, accuracy: 0.0005)
        XCTAssertTrue(Onboarding.costLine(perHour: 0.57).contains("$0.57"))
    }
}

final class RehearsalFeedbackTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-11-09T15:04:05Z")!

    func testAnEntryIsAHeadingWithTheStepAndTimeThenTheText() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RehearsalFeedback.entry(step: "Permissions", text: "  The rows feel tall.\n", at: date, timeZone: utc),
                       "## Permissions · 2026-11-09T15:04:05Z\nThe rows feel tall.\n")
    }

    func testAppendStartsTheFileOnceThenAddsEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("feedback.md")
        let utc = TimeZone(identifier: "UTC")!
        try RehearsalFeedback.append(step: "Welcome", text: "Good start", at: date, to: file, timeZone: utc)
        try RehearsalFeedback.append(step: "AI", text: "Key check is slow", at: date.addingTimeInterval(60), to: file, timeZone: utc)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, """
            # Mossad Rehearsal feedback

            ## Welcome · 2026-11-09T15:04:05Z
            Good start

            ## AI · 2026-11-09T15:05:05Z
            Key check is slow

            """)
    }

    func testAnEmptyNoteIsNotSaved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try RehearsalFeedback.append(step: "You", text: "   ", at: date, to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
