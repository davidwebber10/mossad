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

    func testTheToolsReadTheSwitch() {
        XCTAssertTrue(ToolSettings.read(defaults).geminiPeople)
        defaults.set(false, forKey: GeminiPeople.settingKey)
        XCTAssertFalse(ToolSettings.read(defaults).geminiPeople)
    }
}
