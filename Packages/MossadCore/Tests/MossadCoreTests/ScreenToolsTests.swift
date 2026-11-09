import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MossadCore

final class ScreenToolsTests: XCTestCase {
    var paths: Paths!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    /// A plain picture, 2000 x 1000, saved under a frame's name.
    func writePicture(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func makeMeeting(pictures: Bool = true) throws -> CallRecord {
        var r = CallRecord(id: "c1", platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.calendarTitle = "Launch sync"
        r.speakerNames = ["me:A": "Robin Vale", "them:A": "Sam Carter"]
        r.utterances = [
            Utterance(track: .them, speakerLabel: "A", start: 100, end: 125, text: "Here is the forecast."),
            Utterance(track: .me, speakerLabel: "A", start: 130, end: 135, text: "Looks right."),
            Utterance(track: .them, speakerLabel: "A", start: 400, end: 410, text: "Next topic."),
        ]
        r.screens = [
            SharedScreen(offset: 120, file: "120000.heic", text: "Freight forecast\nBy warehouse", presenter: "Sam Carter", window: "w"),
            SharedScreen(offset: 150, file: "150000.heic", text: "Budget table", presenter: "Sam Carter", window: "w"),
            SharedScreen(offset: 400, file: "400000.heic", text: "Roadmap", window: "w"),
        ]
        let dir = paths.callDirectory("c1")
        try FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true)
        try r.save(to: dir)
        if pictures { try writePicture(FrameIndex.folder(in: dir).appendingPathComponent("120000.heic")) }
        return r
    }

    func tools(_ r: CallRecord) -> ChatTools { ChatTools(records: [r], owner: "Robin Vale", paths: paths) }

    func testListScreensGivesSessionsAndFrames() throws {
        let text = tools(try makeMeeting()).run("list_screens", input: ["meeting_id": "c1"])
        XCTAssertEqual(text.components(separatedBy: "\n"), [
            "call_id: c1 | Launch sync | 3 screens",
            "Sam Carter shared 00:02:00–00:02:30 · 2 screens",
            "1. at_seconds: 120 [00:02:00] \"Freight forecast By warehouse\"",
            "2. at_seconds: 150 [00:02:30] \"Budget table\"",
            "Screen shared · 00:06:40 · 1 screen",
            "3. at_seconds: 400 [00:06:40] \"Roadmap\"",
        ])
        XCTAssertEqual(tools(try makeMeeting()).run("list_screens", input: ["meeting_id": "nope"]), "No meeting with that call_id.")
    }

    func testAMeetingWithNoScreensSaysSo() throws {
        var r = try makeMeeting()
        r.screens = nil
        XCTAssertEqual(tools(r).run("list_screens", input: ["meeting_id": "c1"]), "No shared screens were kept for this meeting.")
        XCTAssertTrue(tools(r).run("get_screen", input: ["meeting_id": "c1", "index": 1]).hasPrefix("No shared screen there."))
    }

    func testGetScreenByIndexAndByTimeWithTheLinesAroundIt() throws {
        let t = tools(try makeMeeting())
        let byIndex = t.run("get_screen", input: ["meeting_id": "c1", "index": 1])
        XCTAssertTrue(byIndex.contains("screen 1 of 3 | at_seconds: 120 [00:02:00]"), byIndex)
        XCTAssertTrue(byIndex.contains("Shared by: Sam Carter"))
        XCTAssertTrue(byIndex.contains("Text on the screen:\nFreight forecast\nBy warehouse"))
        XCTAssertTrue(byIndex.contains("Said around it:\n[00:01:40] Sam Carter: Here is the forecast.\n[00:02:10] Robin Vale: Looks right."))
        XCTAssertFalse(byIndex.contains("Next topic."))
        // The nearest frame to a time; a screen with no presenter names who spoke, and says it is not the presenter.
        let byTime = t.run("get_screen", input: ["call_id": "c1", "at_seconds": 380])
        XCTAssertTrue(byTime.contains("screen 3 of 3"))
        XCTAssertTrue(byTime.contains("Shared by: not shown by the call app. Sam Carter spoke most at that time."))
        XCTAssertTrue(t.run("get_screen", input: ["meeting_id": "c1", "index": 9]).hasPrefix("No shared screen there."))
    }

    func testSearchTranscriptsFindsTextOnAScreen() throws {
        let hits = tools(try makeMeeting()).searchTranscripts(query: "warehouse")
        XCTAssertEqual(hits.map(\.at), [120])
        XCTAssertEqual(hits.first?.line, "[00:02:00] (Screen shared by Sam Carter: \"Freight forecast By warehouse\")")
        XCTAssertTrue(tools(try makeMeeting()).readMeeting("c1")?.contains("(Screen: \"Roadmap\")") == true)
    }

    func testTheToolsAreInTheChatAndMCPLists() {
        for name in ["list_screens", "get_screen"] {
            XCTAssertTrue(ChatTools.allDefinitions.contains { $0.name == name })
            XCTAssertTrue(MCPServer.tools.contains { $0.name == name })
        }
    }

    private func call(_ arguments: [String: Any]) throws -> [[String: Any]] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_screen", "arguments": arguments]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let reply = try XCTUnwrap(MCPServer(paths: paths, owner: "Robin Vale").handle(line))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        return (object["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    func testMCPSendsThePictureOnlyWhenAsked() throws {
        _ = try makeMeeting()
        let plain = try call(["meeting_id": "c1", "index": 1])
        XCTAssertEqual(plain.map { $0["type"] as? String }, ["text"])
        let withImage = try call(["meeting_id": "c1", "index": 1, "include_image": true])
        XCTAssertEqual(withImage.map { $0["type"] as? String }, ["text", "image"])
        XCTAssertEqual(withImage[1]["mimeType"] as? String, "image/jpeg")
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(withImage[1]["data"] as? String)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // 2000 x 1000 comes out with a long edge of 1568 at most.
        XCTAssertEqual(max(image.width, image.height), 1568)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testAPictureThatIsGoneGivesTheTextAndSaysSo() throws {
        _ = try makeMeeting()
        let content = try call(["meeting_id": "c1", "index": 2, "include_image": true])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text"])
        XCTAssertTrue((content[0]["text"] as? String)?.contains("The picture is no longer on this Mac") == true)
    }

    func testTheChatTabNeverGetsThePicture() throws {
        // The app's own chat sends text to its AI provider; the tool's result is text there, also with include_image.
        let text = tools(try makeMeeting()).run("get_screen", input: ["meeting_id": "c1", "index": 1, "include_image": true])
        XCTAssertTrue(text.contains("Text on the screen:"))
    }
}
