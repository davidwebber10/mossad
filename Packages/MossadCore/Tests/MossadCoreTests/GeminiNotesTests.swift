import Foundation
import XCTest
@testable import MossadCore

/// A made-up "Notes by Gemini" document in the shape of the Docs API with tabs: "Quick notes", "Full notes", and
/// "Transcript" (a HEADING_3 time every minute or two, then "Name: text" lines). No name in it is a real one.
enum GeminiFixture {
    static func paragraph(_ text: String, _ style: String = "NORMAL_TEXT") -> [String: Any] {
        ["paragraph": ["elements": [["textRun": ["content": text + "\n"]]], "paragraphStyle": ["namedStyleType": style]]]
    }

    static func tab(_ title: String, _ content: [[String: Any]], children: [[String: Any]] = []) -> [String: Any] {
        ["tabProperties": ["tabId": "t.\(title.count)", "title": title], "documentTab": ["body": ["content": content]], "childTabs": children]
    }

    static var transcript: [[String: Any]] { [
        paragraph("📖 Transcript", "HEADING_1"),
        paragraph("Nov 10, 2026"),
        paragraph("Weekly design review - Transcript", "HEADING_2"),
        paragraph("00:00:00", "HEADING_3"),
        paragraph("Alex Rivera: Morning, everyone. Let's start with the onboarding flow."),
        paragraph("Sam Carter: Sure. The new screens are in the doc."),
        paragraph("We cut two steps."),
        paragraph("00:01:30", "HEADING_3"),
        paragraph("Jordan Lee: Did the numbers move after the change?"),
        paragraph("Sam Carter: Completion went up by about ten percent."),
        paragraph("Alex Rivera: Good. I will write it up for Friday."),
        paragraph("00:03:00", "HEADING_3"),
        paragraph("Jordan Lee: One more thing: the release date."),
        paragraph("Transcription ended after 00:03:40"),
        paragraph("This editable transcript was computer generated and might contain errors. People can also change the text after it was created."),
    ] }

    static var document: [String: Any] { [
        "documentId": "doc-123",
        "title": "Weekly design review - 2026/11/10 10:00 EST - Notes by Gemini",
        "tabs": [
            tab("Quick notes", [paragraph("Summary", "HEADING_2"), paragraph("The team looked at the onboarding flow.")]),
            tab("Full notes", [paragraph("Details", "HEADING_2"), paragraph("Completion rose after two steps were cut."),
                               paragraph("Suggested next steps", "HEADING_2"), paragraph("Alex Rivera will write it up for Friday.")]),
            tab("Transcript", transcript),
        ],
    ] }
}

final class GeminiNotesTests: XCTestCase {
    private func doc() throws -> GeminiDoc { try GeminiDoc.parse(StubTransport.json(GeminiFixture.document)) }

    func testTheDocumentRequestAsksForTheTabs() {
        let url = GeminiDoc.url(documentID: "doc-123")
        XCTAssertEqual(url.absoluteString, "https://docs.googleapis.com/v1/documents/doc-123?includeTabsContent=true")
    }

    func testTheNotesAttachmentIsFound() throws {
        let gemini = EventAttachment(fileID: "doc-123", title: "Weekly design review - 2026/11/10 10:00 EST - Notes by Gemini",
                                     mimeType: "application/vnd.google-apps.document", url: nil)
        let slides = EventAttachment(fileID: "s-1", title: "Roadmap", mimeType: "application/vnd.google-apps.presentation", url: nil)
        let pdf = EventAttachment(fileID: "p-1", title: "Notes by Gemini.pdf", mimeType: "application/pdf", url: nil)
        var e = CalendarEventInfo(title: "Weekly design review", start: Date(), end: Date(), attendees: [], text: "", isAllDay: false)
        e.attachments = [slides, pdf, gemini]
        XCTAssertEqual(GeminiNotes.attachment(in: e), gemini)
        e.attachments = [slides]
        XCTAssertNil(GeminiNotes.attachment(in: e))
    }

    func testTheTabsAreReadInOrderWithTheirStyles() throws {
        let d = try doc()
        XCTAssertEqual(d.id, "doc-123")
        XCTAssertEqual(d.tabs.map(\.title), ["Quick notes", "Full notes", "Transcript"])
        XCTAssertEqual(d.tabs[2].paragraphs[3], GeminiDoc.Paragraph(style: "HEADING_3", text: "00:00:00"))
        XCTAssertEqual(d.notesText, "Details\nCompletion rose after two steps were cut.\nSuggested next steps\nAlex Rivera will write it up for Friday.")
    }

    func testAChildTabIsReadToo() throws {
        let json: [String: Any] = ["documentId": "d", "title": "t", "tabs": [
            GeminiFixture.tab("Notes", [GeminiFixture.paragraph("Hello")], children: [GeminiFixture.tab("Transcript", GeminiFixture.transcript)]),
        ]]
        let d = try GeminiDoc.parse(StubTransport.json(json))
        XCTAssertEqual(d.tabs.map(\.title), ["Notes", "Transcript"])
        XCTAssertEqual(d.transcript.count, 6)
    }

    func testTheTranscriptHasNamesAndTimesBetweenTheHeadings() throws {
        let lines = try doc().transcript
        XCTAssertEqual(lines.map(\.name), ["Alex Rivera", "Sam Carter", "Jordan Lee", "Sam Carter", "Alex Rivera", "Jordan Lee"])
        XCTAssertEqual(lines[1].text, "Sure. The new screens are in the doc. We cut two steps.", "a line with no name continues the last speaker")
        XCTAssertEqual(lines[5].text, "One more thing: the release date.", "a colon inside the text is not a name")
        XCTAssertEqual(lines[0].start, 0)
        // The block of 00:00:00 to 00:01:30 is shared by words: Alex has 8 words, Sam 12.
        XCTAssertEqual(lines[1].start, 90 * 8 / 20, accuracy: 0.01)
        XCTAssertEqual(lines[0].end, lines[1].start, accuracy: 0.01)
        XCTAssertEqual(lines[2].start, 90)
        XCTAssertEqual(lines[5].start, 180)
        XCTAssertEqual(lines[5].end, 220, "the last block ends where the transcription ended")
        for (a, b) in zip(lines, lines.dropFirst()) { XCTAssertLessThanOrEqual(a.start, b.start) }
    }

    func testTheLastBlockWithNoEndLineIsTimedByItsWords() {
        let lines = GeminiTranscript.parse([.init(style: "HEADING_3", text: "01:02:03"), .init(style: "NORMAL_TEXT", text: "Sam Carter: one two three four five")])
        XCTAssertEqual(lines.first?.start, 3723)
        XCTAssertEqual(lines.first?.end ?? 0, 3723 + 2, accuracy: 0.01, "5 words at 150 a minute")
    }

    func testShortTimesAndOddLinesAreRead() {
        let lines = GeminiTranscript.parse([
            .init(style: "NORMAL_TEXT", text: "Sam Carter: before any time"),
            .init(style: "HEADING_3", text: "12:30"),
            .init(style: "NORMAL_TEXT", text: "https://example.com/a: not a name"),
            .init(style: "NORMAL_TEXT", text: "This lead in runs on for more words than a name has: here"),
            .init(style: "NORMAL_TEXT", text: "   "),
        ])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].start, 0)
        XCTAssertTrue(lines[0].text.hasSuffix("than a name has: here"))
        XCTAssertEqual(GeminiTranscript.seconds("12:30"), 750)
        XCTAssertEqual(GeminiTranscript.seconds("1:02:03"), 3723)
        XCTAssertNil(GeminiTranscript.seconds("Summary"))
    }

    func testANoteWithNoTranscriptTabHasNoLines() throws {
        let json: [String: Any] = ["documentId": "d", "title": "t", "tabs": [GeminiFixture.tab("Notes", [GeminiFixture.paragraph("Only notes.")])]]
        let d = try GeminiDoc.parse(StubTransport.json(json))
        XCTAssertTrue(d.transcript.isEmpty)
        XCTAssertEqual(d.notesText, "Only notes.")
    }
}
