import XCTest
@testable import MossadCore

final class ProfileSettingsTests: XCTestCase {
    private func registry(_ extra: [Profile], active: String = "default") -> ProfileRegistry {
        var r = ProfileRegistry()
        r.profiles += extra
        r.active = active
        return r
    }
    private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")
    private let client = Profile(id: "9f8e7d6c", name: "Client", color: .green, root: "~/Mossad Client")

    func testWithOneProfileOnlyAddShows() {
        let rows = ProfileSettingsWords.rows(registry([]), active: "default")
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(ProfileSettingsWords.oneTitle, "Profiles")
        XCTAssertEqual(ProfileSettingsWords.oneDetail, "Keep work and personal meetings apart.")
    }

    func testWithOneProfileItsOwnRowShows() {
        let row = ProfileSettingsWords.only(.default)
        XCTAssertEqual(row.name, "Mossad"); XCTAssertEqual(row.folder, "~/Mossad")
        XCTAssertTrue(row.active); XCTAssertFalse(row.mayDelete)
        XCTAssertEqual(ProfileSettingsWords.only(work).folder, "~/Mossad Work")
    }

    func testThePageSaysWhatAProfileKeepsApartAndWhatTheMacShares() {
        XCTAssertEqual(ProfileSettingsWords.apartLabel, "Apart")
        XCTAssertEqual(ProfileSettingsWords.apart, ["Its own folder, shown under its name",
                                                    "Its meetings, people, voices, points, and coach",
                                                    "Its API keys", "Its settings", "Its iCloud sync and its iPhone link"])
        XCTAssertEqual(ProfileSettingsWords.sharedLabel, "Shared on this Mac")
        XCTAssertEqual(ProfileSettingsWords.shared, ["Off, and Open Mossad at login",
                                                     "The do-not-record list: each profile's list stops a recording",
                                                     "Permissions", "Not a call", "Usage statistics",
                                                     "The quick panel's shortcut", "Updates"])
        // Each shared line stands on a Mac-wide key: a key that leaves `MacDefaults` must leave the list too.
        for key in ["offUntil", "didSetLoginItem", "screenCaptureAsked", "notACall", "usageStatsEnabled", "askShortcut"] {
            XCTAssertTrue(MacDefaults.isMacWide(key), key)
        }
        XCTAssertTrue(MacDefaults.isMacWide("SUEnableAutomaticChecks"))
    }

    func testEachProfileIsARowAndOnlyAnotherInactiveOneMayBeDeleted() {
        let rows = ProfileSettingsWords.rows(registry([work, client]), active: "1a2b3c4d")
        XCTAssertEqual(rows.map(\.id), ["default", "1a2b3c4d", "9f8e7d6c"])
        XCTAssertEqual(rows.map(\.active), [false, true, false])
        XCTAssertEqual(rows.map(\.mayDelete), [false, false, true])
        XCTAssertEqual(rows.map(\.folder), ["~/Mossad", "~/Mossad Work", "~/Mossad Client"])
        XCTAssertEqual(rows[1].name, "Work"); XCTAssertEqual(rows[1].color, .blue)
    }

    func testAProfileBeingRemovedIsNoRowAndTheFooterSaysSo() {
        var r = registry([work, client])
        r.markRemoving("9f8e7d6c")
        let loaded = ProfileRegistry.Loaded(registry: r, state: .read)
        XCTAssertEqual(ProfileSettingsWords.rows(r, active: "default").map(\.id), ["default", "1a2b3c4d"])
        XCTAssertEqual(ProfileSettingsWords.footer(loaded, problem: nil), "A deleted profile is still being removed. Mossad tries again at the next launch.")
        XCTAssertEqual(ProfileSettingsWords.footer(loaded, problem: "Another profile has this name."), "Another profile has this name.")
    }

    func testTheFooterOfEachStateOfTheFile() {
        XCTAssertNil(ProfileSettingsWords.footer(.none, problem: nil))
        XCTAssertNil(ProfileSettingsWords.footer(.init(registry: registry([work]), state: .read), problem: nil))
        XCTAssertEqual(ProfileSettingsWords.footer(.init(registry: ProfileRegistry(), state: .unreadable), problem: nil),
                       "The list of profiles could not be read. Mossad runs as the first profile.")
        XCTAssertEqual(ProfileSettingsWords.footer(.init(registry: registry([work]), state: .newer), problem: nil),
                       "A newer Mossad wrote the list of profiles. This one can switch, but changes nothing in it.")
        XCTAssertEqual(ProfileSettingsWords.footer(.init(registry: ProfileRegistry(), state: .partial, leftOut: ["Work"]), problem: nil),
                       "Mossad left out a profile whose folder it cannot use: Work. It did not change the file.")
    }

    func testTheSheetWords() {
        XCTAssertEqual(ProfileSettingsWords.addExplanation,
                       "A profile has its own keys, settings, people, voices, coach, sync, and MCP. Nothing is copied from another profile. Mossad restarts and takes you through setup for the new profile.")
        XCTAssertEqual(ProfileSettingsWords.renameNote, "The folder keeps its name.")
        XCTAssertEqual(ProfileSettingsWords.deleteText(work),
                       "This removes the profile's keys and settings from this Mac and its meetings from iCloud, and moves ~/Mossad Work to the Trash.")
        XCTAssertEqual(ProfileSettingsWords.deleteNotes(work), [ProfileRemoval.bucketNote])
        var served = work; served.server = String(repeating: "0", count: 64)
        XCTAssertEqual(ProfileSettingsWords.deleteNotes(served), [ProfileRemoval.serverNote, ProfileRemoval.bucketNote])
        XCTAssertEqual(ProfileSettingsWords.accessibilityLabel(work), "Profile, Work")
    }
}
