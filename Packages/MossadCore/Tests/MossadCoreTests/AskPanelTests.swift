import XCTest
@testable import MossadCore

/// The quick panel's rules: which state it shows, its quick questions, the peek of the live transcript at a time in
/// an answer, the quick chat it continues, and the line between an earlier part of the chat and a newer one.
final class AskPanelTests: XCTestCase {
    func turn(_ order: Int, _ text: String, speaker: String? = nil, final: Bool = true) -> Data {
        let label = speaker.map { #","speaker_label":"\#($0)""# } ?? ""
        return Data(#"{"type":"Turn","turn_order":\#(order),"end_of_turn":\#(final),"transcript":"\#(text)"\#(label)}"#.utf8)
    }

    /// Dana on the mic, Sam (named) as A, and B with no name yet.
    func call() -> LiveTranscript {
        var live = LiveTranscript()
        live.apply(turn(0, "Morning, everyone."), source: .me, at: 2)
        live.apply(turn(0, "Dana, can you send the deck by Friday?", speaker: "A"), source: .them, at: 65)
        live.apply(turn(1, "The budget is still open.", speaker: "B"), source: .them, at: 130)
        live.names = ["0A": "Sam Carter"]
        return live
    }

    // MARK: The state

    func testACallThatRecordsShowsItsChat() {
        XCTAssertEqual(AskPanelRules.mode(recording: "c1", liveOff: nil, shownCall: nil), .call("c1"))
    }

    func testNoLiveTranscriptShowsTheReason() {
        XCTAssertEqual(AskPanelRules.mode(recording: "c1", liveOff: .setting, shownCall: nil), .noTranscript("c1", .setting))
    }

    func testTheCallThatEndedWhileOpenSaysSo() {
        XCTAssertEqual(AskPanelRules.mode(recording: nil, liveOff: nil, shownCall: "c1"), .ended("c1"))
    }

    func testANewCallReplacesTheOneThatEnded() {
        XCTAssertEqual(AskPanelRules.mode(recording: "c2", liveOff: nil, shownCall: "c1"), .call("c2"))
    }

    func testWithNoCallItIsTheQuickChat() {
        XCTAssertEqual(AskPanelRules.mode(recording: nil, liveOff: nil, shownCall: nil), .quick)
    }

    func testEachReasonOpensItsOwnSettingsOrNone() {
        XCTAssertEqual(LiveOffReason.setting.fix, .recordingSettings)
        XCTAssertEqual(LiveOffReason.noKey.fix, .aiSettings)
        XCTAssertNil(LiveOffReason.lowData.fix)
        XCTAssertEqual(LiveOffReason.setting.text, "Live transcript is off in Settings.")
        XCTAssertTrue(LiveOffReason.setting.panelText.hasSuffix("The recording is safe, and the full notes come after the call."))
    }

    // MARK: The quick questions

    func testThePanelCountsTheQuestionsForTheOwnerInTheAccent() {
        let chips = AskPanelChips.chips(call().entries(owner: "Dana"), owner: "Dana", openQuestions: 2, lastAsked: nil)
        XCTAssertEqual(chips.last?.label, "Questions for me (2)")
        XCTAssertEqual(chips.last?.accent, true)
        XCTAssertEqual(chips.first?.accent, false)
    }

    func testTheSameRulesAsTheChatTab() {
        let entries = call().entries(owner: "Dana")
        XCTAssertEqual(AskPanelChips.chips(entries, owner: "Dana", openQuestions: 0, lastAsked: nil).map(\.question),
                       LiveChips.chips(entries, owner: "Dana", openQuestions: 0).map(\.question))
        XCTAssertEqual(AskPanelChips.chips([], owner: "Dana", openQuestions: 0, lastAsked: nil), [])
    }

    func testTheQuestionJustAskedIsNotOfferedAgain() {
        let entries = call().entries(owner: "Dana")
        let asked = LiveChips.chips(entries, owner: "Dana", openQuestions: 0)[0].question
        let labels = AskPanelChips.chips(entries, owner: "Dana", openQuestions: 0, lastAsked: asked).map(\.label)
        XCTAssertFalse(labels.contains("What did I miss?"))
        XCTAssertTrue(labels.contains("Summarize so far"))
        // Typed as the chip reads.
        XCTAssertFalse(AskPanelChips.chips(entries, owner: "Dana", openQuestions: 0, lastAsked: "Summarize so far").map(\.label)
            .contains("Summarize so far"))
    }

    // MARK: The peek

    func testThePeekMarksTheLineAtTheTimeWithOneLineEachSide() {
        let live = call()
        let peek = LivePeek.lines(live, lines: live.lines, at: 65, owner: "Dana", room: false)
        XCTAssertEqual(peek.map(\.name), ["You", "Sam", "Speaker B"])
        XCTAssertEqual(peek.map(\.marked), [false, true, false])
        XCTAssertEqual(peek[1].text, "Dana, can you send the deck by Friday?")
        XCTAssertEqual(peek[1].clock, "01:05")
    }

    func testThePeekAtTheFirstLineHasNoLineBefore() {
        let live = call()
        let peek = LivePeek.lines(live, lines: live.lines, at: 1, owner: "Dana", room: false)
        XCTAssertEqual(peek.map(\.marked), [true, false])
    }

    func testThePeekAtTheLastLineHasNoLineAfter() {
        let live = call()
        let peek = LivePeek.lines(live, lines: live.lines, at: 200, owner: "Dana", room: false)
        XCTAssertEqual(peek.map(\.marked), [false, true])
        XCTAssertEqual(peek.last?.name, "Speaker B")
    }

    func testNoPeekWithNoLines() {
        XCTAssertEqual(LivePeek.lines(LiveTranscript(), lines: [], at: 30, owner: "Dana", room: false), [])
    }

    func testTheOwnersNamedVoiceInARoomIsYou() {
        var live = LiveTranscript()
        live.apply(turn(0, "Let us start.", speaker: "A"), source: .them, at: 3)
        live.names = ["0A": "Dana"]
        XCTAssertEqual(LivePeek.lines(live, lines: live.lines, at: 3, owner: "Dana", room: true).map(\.name), ["You"])
    }

    func testAnUnknownCallVoiceIsTheCallOrTheRoom() {
        var live = LiveTranscript()
        live.apply(turn(0, "Hello?"), source: .them, at: 3)
        XCTAssertEqual(LivePeek.lines(live, lines: live.lines, at: 3, owner: "Dana", room: false).first?.name, "Call")
        XCTAssertEqual(LivePeek.lines(live, lines: live.lines, at: 3, owner: "Dana", room: true).first?.name, "Room")
    }

    func testTheMomentsOfABlockAreItsLinkedSeconds() {
        let text = ChatBlocks.linkTimes("Priya moved it [19:42] and Tom [21:10].", callID: "c1")
        XCTAssertEqual(ChatBlocks.momentSeconds(in: text), [1182, 1270])
        XCTAssertEqual(ChatBlocks.momentSeconds(in: "No times here."), [])
    }

    // MARK: The quick chat

    func testTheQuickChatContinuesUntilACallStarts() {
        var chat = Chat(title: "Budget")
        chat.updated = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(QuickChatRule.continues(chat, lastCallStart: nil))
        XCTAssertTrue(QuickChatRule.continues(chat, lastCallStart: Date(timeIntervalSince1970: 500)))
        XCTAssertFalse(QuickChatRule.continues(chat, lastCallStart: Date(timeIntervalSince1970: 2000)))
    }

    func testAChatAboutOneMeetingIsNeverTheQuickChat() {
        var chat = Chat(title: "Budget")
        chat.callID = "c1"
        XCTAssertFalse(QuickChatRule.continues(chat, lastCallStart: nil))
    }

    func testAGoneChatIsNotContinued() {
        XCTAssertFalse(QuickChatRule.continues(nil, lastCallStart: nil))
    }

    // MARK: The line between older and newer questions

    func testALongGapGetsTheAgeOfTheEarlierQuestion() {
        let now = Date(timeIntervalSince1970: 10_000)
        var first = ChatMessage(role: .user, text: "What did I miss?")
        first.asked = now.addingTimeInterval(-17 * 60)
        let answer = ChatMessage(role: .assistant, text: "A lot.")
        var second = ChatMessage(role: .user, text: "Did anyone come back to it?")
        second.asked = now.addingTimeInterval(-10)
        let lines = ChatDividers.lines([first, answer, second], now: now)
        XCTAssertEqual(lines, [second.id: "Asked 17 minutes ago"])
    }

    func testAShortGapOrAnOldMessageGetsNoLine() {
        let now = Date(timeIntervalSince1970: 10_000)
        var first = ChatMessage(role: .user, text: "One")
        first.asked = now.addingTimeInterval(-120)
        var second = ChatMessage(role: .user, text: "Two")
        second.asked = now
        XCTAssertEqual(ChatDividers.lines([first, second], now: now), [:])
        let old = ChatMessage(role: .user, text: "Old")
        XCTAssertEqual(ChatDividers.lines([old, second], now: now), [:])
    }

    func testTheAgeIsInHoursFromAnHour() {
        XCTAssertEqual(ChatDividers.age(60), "Asked 1 minute ago")
        XCTAssertEqual(ChatDividers.age(3600 * 2 + 100), "Asked 2 hours ago")
        XCTAssertEqual(ChatDividers.age(3600), "Asked 1 hour ago")
    }

    // MARK: The chip of the question just asked

    func testOnlyAQuestionAskedJustNowHidesItsChip() {
        let now = Date(timeIntervalSince1970: 10_000)
        var q = ChatMessage(role: .user, text: "Summarize the call so far.")
        q.asked = now.addingTimeInterval(-30)
        let a = ChatMessage(role: .assistant, text: "So far…")
        XCTAssertEqual(AskPanelChips.recentQuestion([q, a], now: now), "Summarize the call so far.")
        XCTAssertNil(AskPanelChips.recentQuestion([q, a], now: now.addingTimeInterval(600)))
        XCTAssertNil(AskPanelChips.recentQuestion([ChatMessage(role: .user, text: "Old")], now: now))
        XCTAssertNil(AskPanelChips.recentQuestion([], now: now))
    }

    // MARK: The panel's size

    let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)

    func testThePanelGrowsUpFromTheFieldsEdge() {
        let f = AskPanelSizing.frame(content: 400, minimum: 132, bottomLeft: CGPoint(x: 400, y: 160), visible: screen)
        XCTAssertEqual(f, CGRect(x: 400, y: 160, width: AskPanelSizing.width, height: 400))
    }

    func testNoHeightOrATinyOneIsTheMinimum() {
        XCTAssertEqual(AskPanelSizing.frame(content: nil, minimum: 132, bottomLeft: CGPoint(x: 400, y: 160), visible: screen).height, 132)
        XCTAssertEqual(AskPanelSizing.frame(content: 0, minimum: 132, bottomLeft: CGPoint(x: 400, y: 160), visible: screen).height, 132)
        XCTAssertEqual(AskPanelSizing.frame(content: 100, minimum: 132, bottomLeft: CGPoint(x: 400, y: 160), visible: screen).height, 132)
    }

    func testATallPanelMovesDownOnlyToStayOnScreen() {
        let f = AskPanelSizing.frame(content: 700, minimum: 132, bottomLeft: CGPoint(x: 400, y: 600), visible: screen)
        XCTAssertEqual(f.maxY, screen.maxY)
        XCTAssertEqual(f.height, 700)
    }

    func testAPanelTallerThanTheScreenFitsTheScreen() {
        let f = AskPanelSizing.frame(content: 2000, minimum: 132, bottomLeft: CGPoint(x: 400, y: 600), visible: screen)
        XCTAssertEqual(f.minY, screen.minY)
        XCTAssertEqual(f.height, screen.height)
    }

    // MARK: The points row

    func testThePointsRowTakesItsHeightFromTheThreadSoThePanelKeepsItsLimit() {
        let full = AskPanelSizing.threadMax(points: 0, chips: true)
        XCTAssertEqual(full, AskPanelSizing.threadLimit)
        // The collapsed row and the open checklist each take their height from the thread.
        XCTAssertEqual(AskPanelSizing.threadMax(points: AskPanelSizing.pointsRow, chips: true), full - AskPanelSizing.pointsRow)
        XCTAssertEqual(AskPanelSizing.threadMax(points: 180, chips: true), full - 180)
        // The tallest panel is the same with or without the points.
        for points: CGFloat in [0, AskPanelSizing.pointsRow, 180, AskPanelSizing.pointsMax] {
            let tallest = AskPanelSizing.header + AskPanelSizing.threadMax(points: points, chips: true) + min(points, AskPanelSizing.pointsMax)
                + AskPanelSizing.chips + AskPanelSizing.field + AskPanelSizing.footer
            XCTAssertEqual(tallest, AskPanelSizing.limit, "points \(points)")
        }
    }

    func testAChecklistTallerThanItsCapScrollsAndTheThreadKeepsItsShare() {
        XCTAssertEqual(AskPanelSizing.points(content: 900), AskPanelSizing.pointsMax)
        XCTAssertEqual(AskPanelSizing.points(content: 120), 120)
        XCTAssertEqual(AskPanelSizing.threadMax(points: 900, chips: true), AskPanelSizing.threadMax(points: AskPanelSizing.pointsMax, chips: true))
        XCTAssertGreaterThan(AskPanelSizing.threadMax(points: AskPanelSizing.pointsMax, chips: true), 0)
    }

    func testThePanelOffersMyOpenPointsWhenThereAreSome() {
        XCTAssertEqual(AskPanelChips.chips([], owner: "Dana", openQuestions: 0, openPoints: 2, lastAsked: nil).map(\.label), ["My open points"])
        XCTAssertTrue(AskPanelChips.chips([], owner: "Dana", openQuestions: 0, openPoints: 0, lastAsked: nil).isEmpty)
    }

    func testTheMinimumHasRoomForThePointsRow() {
        XCTAssertEqual(AskPanelSizing.minimum(chips: false, points: AskPanelSizing.pointsRow), AskPanelSizing.minimum(chips: false) + AskPanelSizing.pointsRow)
        // The field's edge stays where it was when the row opens: the panel grows up.
        let closed = AskPanelSizing.frame(content: 300, minimum: 132, bottomLeft: CGPoint(x: 400, y: 160), visible: screen)
        let open = AskPanelSizing.frame(content: 300 + 140, minimum: 132, bottomLeft: CGPoint(x: 400, y: 160), visible: screen)
        XCTAssertEqual(closed.minY, open.minY)
    }

    func testTheMinimumHasRoomForTheChips() {
        XCTAssertEqual(AskPanelSizing.minimum(chips: false), 132)
        XCTAssertGreaterThan(AskPanelSizing.minimum(chips: true), 132)
    }

    // MARK: After an answer

    func testAWaitingQuestionGoesNextOnlyAfterAGoodAnswer() {
        XCTAssertEqual(ChatRunRules.next(queued: "Two", failed: false, stopped: false, callRecords: true), .send("Two"))
        XCTAssertEqual(ChatRunRules.next(queued: "Two", failed: false, stopped: true, callRecords: true), .send("Two"))
        XCTAssertEqual(ChatRunRules.next(queued: nil, failed: false, stopped: false, callRecords: true), .nothing)
    }

    func testAFailedAnswerKeepsItsErrorAndGivesTheWaitingQuestionBack() {
        XCTAssertEqual(ChatRunRules.next(queued: "Two", failed: true, stopped: false, callRecords: true), .toField("Two"))
    }

    func testAWaitingQuestionOfACallThatEndedGoesBackToTheField() {
        XCTAssertEqual(ChatRunRules.next(queued: "Two", failed: false, stopped: false, callRecords: false), .toField("Two"))
    }

    func testAStoppedFirstQuestionLeavesNoChat() {
        XCTAssertTrue(ChatRunRules.removesChat(messagesLeft: 0))
        XCTAssertFalse(ChatRunRules.removesChat(messagesLeft: 2))
    }

    // MARK: The keyboard

    func testOnlyTheOwnersOwnActionGivesThePanelTheKeyboard() {
        for action in [AskPanelKeys.Show.shortcut, .menu] {
            XCTAssertEqual(AskPanelKeys.opened(by: action), .byOwner)
        }
        XCTAssertEqual(AskPanelKeys.opened(by: .preview), .withoutKeyboard)
        XCTAssertTrue(AskPanelKeys.canBecomeKey(.byOwner))
        // A preview's panel never: not on its first open, not on a re-open, not on a click.
        XCTAssertFalse(AskPanelKeys.canBecomeKey(.withoutKeyboard))
        XCTAssertFalse(AskPanelKeys.canBecomeKey(nil))
    }

    func testAProgrammaticChangeKeepsTheOpenItFoundAndNeverFocusesAHiddenOrPreviewField() {
        // A call that starts or ends, the share cover, or a new height: the panel keeps how it was opened.
        for change in [AskPanelKeys.Change.callStarted, .callEnded, .shareCover, .resized] {
            XCTAssertEqual(AskPanelKeys.after(change, opened: .withoutKeyboard), .withoutKeyboard)
            XCTAssertEqual(AskPanelKeys.after(change, opened: .byOwner), .byOwner)
            XCTAssertNil(AskPanelKeys.after(change, opened: nil))
        }
        XCTAssertTrue(AskPanelKeys.focusesField(.byOwner, visible: true))
        XCTAssertFalse(AskPanelKeys.focusesField(.byOwner, visible: false))
        XCTAssertFalse(AskPanelKeys.focusesField(.withoutKeyboard, visible: true))
        XCTAssertFalse(AskPanelKeys.focusesField(nil, visible: true))
    }
}
