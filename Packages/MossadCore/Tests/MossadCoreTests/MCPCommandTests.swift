import XCTest
@testable import MossadCore

final class MCPCommandTests: XCTestCase {
    private let bin = "/Applications/Mossad.app/Contents/MacOS/Mossad"

    private func profile(_ id: String, _ name: String) -> Profile {
        Profile(id: id, name: name, color: .blue, root: "~/Mossad \(name)")
    }

    func testTheDefaultCommandIsTodaysText() {
        let c = MCPCommand(profile: .default, among: [.default])
        XCTAssertEqual(c.serverName, "mossad"); XCTAssertEqual(c.arguments, ["--mcp"])
        XCTAssertEqual(c.claudeCode(binary: bin), "claude mcp add --scope user mossad -- \"\(bin)\" --mcp")
        XCTAssertEqual(c.desktop(binary: bin), "\"mossad\": { \"command\": \"\(bin)\", \"args\": [\"--mcp\"] }")
        var renamed = Profile.default; renamed.name = "Work"
        XCTAssertEqual(MCPCommand(profile: renamed, among: [renamed]).serverName, "mossad")
        XCTAssertEqual(MCPCommand(profile: .default, among: [.default, profile("1a2b3c4d", "Work")]).arguments, ["--mcp"])
    }

    func testAProfilesCommandNamesItAndPassesItsID() {
        let p = profile("1a2b3c4d", "Personal")
        let c = MCPCommand(profile: p, among: [.default, p])
        XCTAssertEqual(c.serverName, "mossad-personal"); XCTAssertEqual(c.arguments, ["--mcp", "--profile", "1a2b3c4d"])
        XCTAssertEqual(c.claudeCode(binary: bin), "claude mcp add --scope user mossad-personal -- \"\(bin)\" --mcp --profile 1a2b3c4d")
        XCTAssertEqual(c.desktop(binary: bin), "\"mossad-personal\": { \"command\": \"\(bin)\", \"args\": [\"--mcp\", \"--profile\", \"1a2b3c4d\"] }")
    }

    func testTheServerNameIsLettersAndDigits() {
        func name(_ n: String) -> String { let p = profile("1a2b3c4d", n); return MCPCommand(profile: p, among: [.default, p]).serverName }
        XCTAssertEqual(name("Client A"), "mossad-clienta")
        XCTAssertEqual(name("Café 2"), "mossad-cafe2")
        XCTAssertEqual(name("!!"), "mossad-1a2b3c4d")
        let a = profile("1a2b3c4d", "Client A"), b = profile("9f8e7d6c", "ClientA")
        XCTAssertEqual(MCPCommand(profile: a, among: [.default, a, b]).serverName, "mossad-clienta-1a2b3c4d")
        XCTAssertEqual(MCPCommand(profile: b, among: [.default, a, b]).serverName, "mossad-clienta-9f8e7d6c")
    }

    func testTheFillSaysWhichCopyToClose() {
        XCTAssertEqual(PersonaFill.openMessage(.default), "Quit Mossad first: the fill writes the files that the app keeps.")
        XCTAssertEqual(PersonaFill.openMessage(profile("1a2b3c4d", "Work")),
                       "Mossad has this profile open. Switch to another profile or quit Mossad first: the fill writes the files that the app keeps.")
    }

    func testServerInfoSaysTheProfilesName() throws {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-name-\(UUID().uuidString)"))
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        for (server, expected) in [(MCPServer(paths: paths, owner: "Sam Carter", name: "mossad-personal"), "mossad-personal"),
                                   (MCPServer(paths: paths, owner: "Sam Carter", name: "mossad-work", settings: { ToolSettings() }), "mossad-work"),
                                   (MCPServer(paths: paths, owner: "Sam Carter"), "mossad")] {
            let reply = try XCTUnwrap(server.handle(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            let info = try XCTUnwrap((json["result"] as? [String: Any])?["serverInfo"] as? [String: Any])
            XCTAssertEqual(info["name"] as? String, expected)
        }
    }
}
