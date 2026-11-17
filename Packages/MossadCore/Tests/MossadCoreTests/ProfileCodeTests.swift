import XCTest
@testable import MossadCore

final class ProfileCodeTests: XCTestCase {
    private let c = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "made-up-secret")
    private var work: Profile { Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work") }

    /// The text of a code made from any JSON, as a Mac of another build could make it.
    private func codeText(_ json: String) -> String {
        "mossad-profile:" + Data(json.utf8).base64URL
    }

    func testACodeRoundTrips() throws {
        let code = try XCTUnwrap(ProfileCode.make(profile: work, sync: .server, server: c))
        XCTAssertEqual(ProfileCode.parse(code.text), .profile(code))
        XCTAssertTrue(code.holdsSecret)
        XCTAssertEqual(code.connection, c)
        XCTAssertEqual(code.id, "1a2b3c4d")
        XCTAssertEqual(code.color, .blue)
        XCTAssertTrue(code.text.hasPrefix("mossad-profile:"))
        let body = code.text.dropFirst("mossad-profile:".count)
        XCTAssertFalse(body.contains("=") || body.contains("+") || body.contains("/"))
        let cloud = try XCTUnwrap(ProfileCode.make(profile: work, sync: .icloud, server: nil))
        XCTAssertNil(cloud.address)
        XCTAssertNil(cloud.secret)
        XCTAssertFalse(cloud.holdsSecret)
        XCTAssertNil(cloud.connection)
        XCTAssertEqual(ProfileCode.parse(cloud.text), .profile(cloud))
    }

    func testNoCodeWithoutAWayToSync() throws {
        XCTAssertNil(ProfileCode.make(profile: work, sync: .off, server: c))
        XCTAssertNil(ProfileCode.make(profile: work, sync: .server, server: nil))
        let cloud = try XCTUnwrap(ProfileCode.make(profile: work, sync: .icloud, server: c))
        XCTAssertNil(cloud.address)
        XCTAssertNil(cloud.secret)
    }

    func testANewerCodeIsRefusedWithItsOwnWords() {
        let parsed = ProfileCode.parse(codeText(#"{"version":2,"id":"1a2b3c4d","name":"Work","color":"blue","sync":"pigeon"}"#))
        XCTAssertEqual(parsed, .newer)
        XCTAssertEqual(parsed.problem, "This code is from a newer Mossad. Update Mossad on this iPhone, then scan it again.")
    }

    func testADamagedCodeIsRefused() throws {
        let damaged = [
            "mossad-profile:", "mossad-profile:!!!", codeText("{}"),
            codeText(#"{"version":1,"id":"../x","name":"Work","color":"blue","sync":"icloud"}"#),
            codeText(#"{"version":1,"id":"1a2b3c4d","name":"  ","color":"blue","sync":"icloud"}"#),
            codeText(#"{"version":1,"id":"1a2b3c4d","name":"Work","color":"blue","sync":"server","address":"https://notes.example.com"}"#),
            codeText(#"{"version":1,"id":"1a2b3c4d","name":"Work","color":"blue","sync":"server","address":"not a host","secret":"s"}"#),
            codeText(#"{"version":1,"id":"1a2b3c4d","name":"Work","color":"blue","sync":"off"}"#),
        ]
        for text in damaged { XCTAssertEqual(ProfileCode.parse(text), .damaged, text) }
        XCTAssertEqual(ProfileCode.Parsed.damaged.problem, "That code could not be read. Show the code on your Mac again.")
        let long = String(repeating: "a", count: 60)
        guard case .profile(let cut) = ProfileCode.parse(codeText(#"{"version":1,"id":"1a2b3c4d","name":"\#(long)","color":"blue","sync":"icloud"}"#)) else {
            return XCTFail("a long name still parses")
        }
        XCTAssertEqual(cut.name.count, ProfileRules.nameLimit)
        guard case .profile(let dropped) = ProfileCode.parse(codeText(#"{"version":1,"id":"1a2b3c4d","name":"Work","color":"blue","sync":"icloud","address":"https://notes.example.com","secret":"s"}"#)) else {
            return XCTFail("an iCloud code parses")
        }
        XCTAssertNil(dropped.address, "an iCloud code keeps no address")
        XCTAssertNil(dropped.secret, "an iCloud code keeps no secret")
    }

    func testAnOldServerCodeIsForTheFirstProfile() {
        XCTAssertEqual(ProfileCode.parse(ServerPairing.code(for: c)), .server(c))
        XCTAssertEqual(ProfileCode.parse("mossad-server:junk"), .damaged)
        XCTAssertEqual(ProfileCode.parse("https://example.com"), .notMossad)
        XCTAssertEqual(ProfileCode.Parsed.notMossad.problem, "That code isn't from Mossad. Show the code on your Mac again.")
        XCTAssertNil(ProfileCode.Parsed.server(c).problem)
        XCTAssertTrue(ProfileCode.isCode("mossad-profile:x"))
        XCTAssertTrue(ProfileCode.isCode("mossad-server:x"))
        XCTAssertFalse(ProfileCode.isCode("mossad-profiles:x"))
        XCTAssertFalse(ProfileCode.isCode(""))
    }

    func testWhatACodePutsInSettingsNeverHoldsTheSecret() throws {
        let server = try XCTUnwrap(ProfileCode.make(profile: work, sync: .server, server: c))
        XCTAssertEqual(server.settings, ["syncWith": "server", "serverAddress": "https://notes.example.com"])
        let cloud = try XCTUnwrap(ProfileCode.make(profile: work, sync: .icloud, server: nil))
        XCTAssertEqual(cloud.settings, ["syncWith": "icloud"])
        for text in ["\(server)", String(describing: server), String(reflecting: server)] {
            XCTAssertFalse(text.contains("made-up-secret"), text)
        }
        XCTAssertEqual("\(server)", "ProfileCode(1a2b3c4d)")
    }

    func testThePairingCodeOfTheFirstProfileIsTodaysAndAnothersIsAProfileCode() {
        // Today's code: the old scheme and what it holds. Its JSON has no fixed key order, so two calls differ as text.
        let first = ProfileCode.pairingText(profile: .default, connection: c)
        XCTAssertTrue(first.hasPrefix("mossad-server:"))
        XCTAssertEqual(ServerPairing.connection(fromCode: first), c)
        XCTAssertEqual(ProfileCode.parse(first), .server(c))
        let text = ProfileCode.pairingText(profile: work, connection: c)
        XCTAssertTrue(text.hasPrefix("mossad-profile:"))
        guard case .profile(let code) = ProfileCode.parse(text) else { return XCTFail("a profile code") }
        XCTAssertEqual(code.id, "1a2b3c4d")
        XCTAssertEqual(code.connection, c)
    }

    func testTheCodeSheetsWords() {
        XCTAssertEqual(ProfileSettingsWords.codeButton, "Show code for iPhone…")
        XCTAssertEqual(ProfileSettingsWords.codeTitle("Work"), "Add “Work” to your iPhone")
        XCTAssertEqual(ProfileSettingsWords.codeSteps, ["Open Mossad on your iPhone.", "Tap the gear on the Meetings screen.",
                                                        "Tap Profile, then Add a profile. With no Profile row, tap Your server, then Scan code."])
        XCTAssertEqual(ProfileSettingsWords.codeSecretNote(seconds: 59), "The code holds this profile's server secret, so it hides again in 0:59.")
        XCTAssertTrue(ProfileSettingsWords.codeSecretNote(seconds: 5).hasSuffix("0:05."))
        XCTAssertEqual(ProfileSettingsWords.codeICloudNote, "This profile syncs through iCloud. Your iPhone needs the same iCloud account as this Mac.")
        XCTAssertEqual(ProfileSettingsWords.codeNoSync, "This profile does not sync. Choose iCloud or your server in Settings › Storage & Sync first.")
        XCTAssertEqual(ProfileSettingsWords.codeNoServer, "Finish this profile's server in Settings › Storage & Sync first.")
    }
}
