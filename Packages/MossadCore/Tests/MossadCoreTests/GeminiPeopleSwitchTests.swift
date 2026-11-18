import XCTest
@testable import MossadCore

/// Settings › Google › "Add people from Gemini notes", and when the step may run.
final class GeminiPeopleSwitchTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "test.gemini-people.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testTheSwitchIsOnUntilTheOwnerTurnsItOff() {
        XCTAssertTrue(GeminiPeople.isOn(defaults))
        defaults.set(false, forKey: GeminiPeople.settingKey)
        XCTAssertFalse(GeminiPeople.isOn(defaults))
        defaults.set(true, forKey: GeminiPeople.settingKey)
        XCTAssertTrue(GeminiPeople.isOn(defaults))
    }

    func testTheStepRunsOnlyInTheWindowAppWithTheDirectoryAndTheSwitchOn() {
        XCTAssertEqual(GeminiPeople.gate(upkeep: true, directory: true, on: true, recording: false), .run)
        XCTAssertEqual(GeminiPeople.gate(upkeep: false, directory: true, on: true, recording: false), .off)
        XCTAssertEqual(GeminiPeople.gate(upkeep: true, directory: false, on: true, recording: false), .off)
        XCTAssertEqual(GeminiPeople.gate(upkeep: true, directory: true, on: false, recording: false), .off)
    }

    func testACallHoldsTheStepUntilItEnds() {
        XCTAssertEqual(GeminiPeople.gate(upkeep: true, directory: true, on: true, recording: true), .afterCall)
    }

    // Off leaves nothing waiting for the end of a call.
    func testOffDuringACallIsOff() {
        XCTAssertEqual(GeminiPeople.gate(upkeep: true, directory: true, on: false, recording: true), .off)
    }

    // The step only adds: with the switch off a run never starts, and nothing it made goes.
    func testOffNeverRemovesAPersonOrAnAddress() throws {
        let paths = Paths(root: tempDirectory())
        let library = VoiceLibrary(directory: paths.voices)
        let people = PeopleStore(directory: paths.people)
        library.identity = VoiceIdentity(people: people, samples: VoiceSampleStore(directory: paths.voices))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var r = CallRecord(id: "20261102-090000-notes", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.source = CallRecord.geminiNotesSource
        r.speakerNames = ["them:A": "Sam Carter"]
        r.invitees = [Invitee(name: nil, email: "sam.carter@example.com")]
        let directory = [GoogleProfile(emails: ["sam.carter@example.com"], name: "Sam Carter", source: .directory)]
        GeminiPeople.link([r], library: library, people: people, directory: directory, paths: paths, domains: .none)
        defaults.set(false, forKey: GeminiPeople.settingKey)
        XCTAssertEqual(GeminiPeople.gate(upkeep: true, directory: true, on: GeminiPeople.isOn(defaults), recording: false), .off)
        XCTAssertEqual(people.people.filter(\.isLive).map(\.displayName), ["Sam Carter"])
        XCTAssertEqual(library.profiles.first?.emails, ["sam.carter@example.com"])
    }

    func testTheToolsReadTheSwitch() {
        XCTAssertTrue(ToolSettings.read(defaults).geminiPeople)
        defaults.set(false, forKey: GeminiPeople.settingKey)
        XCTAssertFalse(ToolSettings.read(defaults).geminiPeople)
    }
}
