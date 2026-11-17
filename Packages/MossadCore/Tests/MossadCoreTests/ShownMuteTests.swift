import XCTest
@testable import MossadCore

final class ShownMuteTests: XCTestCase {
    func testTable() {
        let rows: [(ShownMute, ShownMute.Reading, ShownMute)] = [
            (.none, .sure(muted: true), .muted),
            (.none, .sure(muted: false), .none),
            (.none, .unreadable, .none),
            (.muted, .sure(muted: true), .muted),
            (.muted, .sure(muted: false), .none),
            (.muted, .unreadable, .mutedWhenLastSeen),
            (.mutedWhenLastSeen, .unreadable, .mutedWhenLastSeen),
            (.mutedWhenLastSeen, .sure(muted: false), .none),
            (.mutedWhenLastSeen, .sure(muted: true), .muted),
        ]
        for (before, reading, after) in rows {
            XCTAssertEqual(before.after(reading), after, "\(before) + \(reading)")
        }
    }

    func testWords() {
        XCTAssertNil(ShownMute.none.words)
        XCTAssertEqual(ShownMute.muted.words, "muted")
        XCTAssertEqual(ShownMute.mutedWhenLastSeen.words, "muted when last seen")
        XCTAssertEqual(ShownMute.muted.title, "Muted")
        XCTAssertEqual(ShownMute.mutedWhenLastSeen.title, "Muted when last seen")
        XCTAssertFalse(ShownMute.none.shows)
        XCTAssertTrue(ShownMute.mutedWhenLastSeen.shows)
    }

    /// The banner on the live page and in the menu bar panel.
    func testBanner() {
        XCTAssertNil(ShownMute.none.banner(platform: .meet))
        XCTAssertEqual(ShownMute.muted.banner(platform: .meet)?.lead, "Muted in Google Meet.")
        XCTAssertEqual(ShownMute.muted.banner(platform: .meet)?.detail, "Your mic is not recorded while you are muted.")
        XCTAssertEqual(ShownMute.mutedWhenLastSeen.banner(platform: .meet)?.lead, "Muted in Google Meet when last seen.")
        XCTAssertEqual(ShownMute.mutedWhenLastSeen.banner(platform: .meet)?.detail,
                       "Mossad cannot see the mute button now, so it records your mic.")
    }

    /// A preview's value: "1" is muted, "last" is muted when last seen.
    func testPreviewValue() {
        XCTAssertEqual(ShownMute(preview: "1"), .muted)
        XCTAssertEqual(ShownMute(preview: "last"), .mutedWhenLastSeen)
        XCTAssertEqual(ShownMute(preview: nil), .none)
    }
}
