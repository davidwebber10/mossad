import XCTest
@testable import MossadCore

/// A chat answer's Markdown as the blocks the chat draws, and the card moment that must stop with its card.
final class ChatBlocksTests: XCTestCase {
    func testHeadingsParagraphsAndSoftBreaks() {
        let blocks = ChatBlocks.parse("## Plan\nFirst line\nsame paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(blocks, [.heading(level: 2, text: "Plan"), .paragraph("First line same paragraph."), .paragraph("Second paragraph.")])
    }

    func testListsGroupTheirItemsWithLevelsAndNumbers() {
        let blocks = ChatBlocks.parse("- one\n- two\n  - inner\n\n1. first\n2. second")
        XCTAssertEqual(blocks, [
            .list(ordered: false, items: [ChatListItem(marker: "•", text: "one", level: 0), ChatListItem(marker: "•", text: "two", level: 0),
                                          ChatListItem(marker: "•", text: "inner", level: 1)]),
            .list(ordered: true, items: [ChatListItem(marker: "1.", text: "first", level: 0), ChatListItem(marker: "2.", text: "second", level: 0)]),
        ])
    }

    func testAFencedCodeBlockKeepsItsLinesAndAnOpenOneRunsToTheEnd() {
        XCTAssertEqual(ChatBlocks.parse("```swift\nlet a = 1\n  let b = 2\n```\nAfter."),
                       [.code(language: "swift", text: "let a = 1\n  let b = 2"), .paragraph("After.")])
        XCTAssertEqual(ChatBlocks.parse("```\nstill streaming"), [.code(language: nil, text: "still streaming")])
    }

    func testATable() {
        let blocks = ChatBlocks.parse("| Who | What |\n|---|:---:|\n| Sam | The deck |\n| Lee | Budget |")
        XCTAssertEqual(blocks, [.table(header: ["Who", "What"], rows: [["Sam", "The deck"], ["Lee", "Budget"]])])
    }

    func testPipesWithoutASeparatorAreAParagraph() {
        XCTAssertEqual(ChatBlocks.parse("| not a table |"), [.paragraph("| not a table |")])
    }

    func testAQuoteFromTheTranscriptHasItsTimeAndSpeaker() {
        let blocks = ChatBlocks.parse("> [12:40](mossad://call/c1?t=760) Sam Carter: \"I can send it Friday.\"")
        XCTAssertEqual(blocks, [.quote(ChatQuote(speaker: "Sam Carter", time: "12:40", link: "mossad://call/c1?t=760", text: "I can send it Friday."))])
    }

    func testAQuoteWithTheSpeakerAndTimeAtTheEnd() {
        let blocks = ChatBlocks.parse("> \u{201C}We ship on the first.\u{201D} \u{2014} Priya, [3:05](mossad://call/c1?t=185)")
        XCTAssertEqual(blocks, [.quote(ChatQuote(speaker: "Priya", time: "3:05", link: "mossad://call/c1?t=185", text: "We ship on the first."))])
    }

    func testAHyphenInTheWordsIsNotTheDashBeforeTheSpeaker() {
        let blocks = ChatBlocks.parse("> \"Send the follow-up today.\" \u{2014} Sam, [1:00](mossad://call/c1?t=60)")
        XCTAssertEqual(blocks, [.quote(ChatQuote(speaker: "Sam", time: "1:00", link: "mossad://call/c1?t=60", text: "Send the follow-up today."))])
    }

    func testAPlainQuoteHasNoSpeaker() {
        XCTAssertEqual(ChatBlocks.parse("> Just a note\n> on two lines"),
                       [.quote(ChatQuote(speaker: nil, time: nil, link: nil, text: "Just a note on two lines"))])
    }

    func testARule() {
        XCTAssertEqual(ChatBlocks.parse("Above\n\n---\n\nBelow"), [.paragraph("Above"), .rule, .paragraph("Below")])
    }

    func testBareTimesBecomeLinksToTheMeeting() {
        XCTAssertEqual(ChatBlocks.linkTimes("At [12:04] and [1:02:03], not [12:04](x).", callID: "c1"),
                       "At [12:04](mossad://call/c1?t=724) and [1:02:03](mossad://call/c1?t=3723), not [12:04](x).")
        XCTAssertEqual(ChatBlocks.linkTimes("At [12:04].", callID: nil), "At [12:04].")
        XCTAssertEqual(ChatBlocks.linkTimes("[99:99] stays", callID: "c1"), "[99:99] stays")
    }

    // MARK: A card's moment

    func testAnAnsweredCardStopsTheMomentItStarted() {
        var p = DeckPlayback()
        p.started("a")
        XCTAssertTrue(p.answered("a"))
        XCTAssertFalse(p.answered("a"), "once")
    }

    func testAnsweringAnotherCardStopsIt_too() {
        var p = DeckPlayback()
        p.started("a")
        XCTAssertTrue(p.answered("b"))
    }

    func testNothingStopsWhenTheDeckDidNotStartTheAudio() {
        var p = DeckPlayback()
        XCTAssertFalse(p.answered("a"))
        XCTAssertFalse(p.topChanged(to: "b"))
        XCTAssertFalse(p.closed())
    }

    func testTheCardLeavingTheTopOrTheDeckClosingStopsIt() {
        var p = DeckPlayback()
        p.started("a")
        XCTAssertFalse(p.topChanged(to: "a"))
        XCTAssertTrue(p.topChanged(to: "b"))
        p.started("b")
        XCTAssertTrue(p.closed())
    }

    func testAPauseForgetsTheCard() {
        var p = DeckPlayback()
        p.started("a")
        p.paused()
        XCTAssertFalse(p.answered("a"), "the second tap paused it")
    }
}
