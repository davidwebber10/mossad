import XCTest

/// Each send of a live call asks `MoveAfterCall.allows` in the app's own sources, and each end of a call reads
/// `MoveAfterCall.atEnd` before the pipeline: a new send that does not ask fails here.
final class MoveGateSourceTests: XCTestCase {
    private var app: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
    }

    private func text(_ file: String) throws -> String { try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8) }

    /// The body of a function: from its declaration to the next declaration at the same indent.
    private func body(_ source: String, _ name: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "func \(name)("), "func \(name)")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let other = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<min(end, other)])
    }

    func testEachLiveSendAsksTheGate() throws {
        let controller = try text("AppController.swift")
        XCTAssertTrue(try body(controller, "startLive").contains("MoveAfterCall.allows(.liveTranscript"))
        XCTAssertTrue(try body(controller, "startLiveTitling").contains("MoveAfterCall.allows(.liveTitle"))
        let points = try text("AppController+LivePoints.swift")
        XCTAssertTrue(try body(points, "hearPoints").contains("MoveAfterCall.allows(.livePoints"))
        let chat = try text("AppController+LiveChat.swift")
        XCTAssertTrue(try body(chat, "liveChatAnswer").contains("MoveAfterCall.allows(.liveChat"))
        XCTAssertTrue(try body(chat, "summarizeLiveChats").contains("MoveAfterCall.allows(.chatSummary"))
        // The detector's end and Stop both end in `endOfCall`, which reads the rule.
        XCTAssertGreaterThanOrEqual(controller.components(separatedBy: "self.endOfCall(record)").count - 1, 2, "the detector's end and Stop")
        XCTAssertTrue(try body(controller, "endOfCall").contains("MoveAfterCall.atEnd("))
        // The launch and the next try: `startsAtLook` reads `atEnd` for each marked call (final review m1).
        XCTAssertTrue(try text("AppController+Moves.swift").contains("MoveAfterCall.startsAtLook("), "the launch and the next try")
        // Every start of the pipeline at the end of a call is the `.process` case.
        let lines = controller.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("pipeline.process(record.id)") {
            let near = lines[max(0, i - 3)...i].joined(separator: "\n")
            XCTAssertTrue(near.contains("case .process"), "line \(i + 1): \(line)")
        }
    }

    func testCurrentCallAsksTheGate() throws {
        let live = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MossadCore/Chat/ChatTools+Live.swift"), encoding: .utf8)
        XCTAssertTrue(live.contains("MoveAfterCall.allows(.currentCall"))
    }
}
