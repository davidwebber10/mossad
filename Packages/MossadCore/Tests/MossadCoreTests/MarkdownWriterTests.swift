import XCTest
@testable import MossadCore

func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

final class MarkdownWriterTests: XCTestCase {
    func fixture() -> CallRecord {
        var r = CallRecord(id: "20261020-143000", platform: .meet, bundleID: "com.google.Chrome",
                           start: localDate(2026, 10, 20, 14, 30), end: localDate(2026, 10, 20, 15, 2), status: .summarized)
        r.calendarTitle = "Weekly Ops Sync"
        r.attendees = ["Alex Rivera", "Amy Lee"]
        r.utterances = [
            Utterance(track: .me, speakerLabel: "A", start: 5, end: 8, text: "Morning, everyone."),
            Utterance(track: .them, speakerLabel: "A", start: 252, end: 260, text: "Cushions ship Friday."),
            Utterance(track: .them, speakerLabel: "C", start: 3725, end: 3730, text: "Who owns freight?"),
        ]
        r.speakerNames = ["me:A": "David Webber", "them:A": "Alex Rivera"]
        r.unknownSpeakers = ["them:C"]
        r.summary = "The team confirmed the Friday cushion shipment."
        r.actionItems = [ActionItem(owner: "Alex Rivera", task: "confirm freight"), ActionItem(owner: nil, task: "book a room")]
        r.decisions = ["Cushions ship Friday."]
        return r
    }

    func testRenderGolden() {
        let expected = """
        ---
        date: 2026-10-20
        start: "14:30"
        end: "15:02"
        duration_minutes: 32
        platform: Google Meet
        title: "Weekly Ops Sync"
        attendees: ["Alex Rivera", "Amy Lee"]
        speakers: ["David Webber", "Alex Rivera", "Speaker A"]
        audio: ~/Mossad/Audio/20261020-143000
        ---
        # Weekly Ops Sync

        ## Summary

        The team confirmed the Friday cushion shipment.

        ## Action items

        - [ ] Alex Rivera: confirm freight
        - [ ] book a room

        ## Decisions

        - Cushions ship Friday.

        ## Transcript

        [00:00:05] David Webber: Morning, everyone.
        [00:04:12] Alex Rivera: Cushions ship Friday.
        [01:02:05] Speaker A: Who owns freight?

        """
        XCTAssertEqual(MarkdownWriter.render(fixture()), expected)
    }

    func testRenderWithoutSummaryOmitsSections() {
        var r = fixture()
        r.summary = nil
        r.actionItems = []
        let md = MarkdownWriter.render(r)
        XCTAssertFalse(md.contains("## Summary"))
        XCTAssertFalse(md.contains("## Action items"))
        XCTAssertTrue(md.contains("## Transcript"))
    }

    func testNoDecisionsSectionWhenEmpty() {
        var r = fixture()
        r.decisions = []
        XCTAssertFalse(MarkdownWriter.render(r).contains("## Decisions"))
    }

    func testFileNameSanitized() {
        var r = fixture()
        r.calendarTitle = "Q4: Plan / Review"
        XCTAssertEqual(MarkdownWriter.fileName(for: r), "2026-10-20 1430 - Q4- Plan - Review.md")
    }

    func testUnknownSpeakersLettered() {
        var r = fixture()
        r.speakerNames = [:]
        r.unknownSpeakers = ["me:A", "them:A", "them:C"]
        XCTAssertEqual(MarkdownWriter.displayNames(r), ["me:A": "Speaker A", "them:A": "Speaker B", "them:C": "Speaker C"])
    }

    func testTitleFallsBackToPlatform() {
        var r = fixture()
        r.calendarTitle = nil
        XCTAssertTrue(MarkdownWriter.render(r).contains("# Google Meet call"))
    }
}
