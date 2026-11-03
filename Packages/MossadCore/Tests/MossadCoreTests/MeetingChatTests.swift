import XCTest
@testable import MossadCore

/// A chat about one meeting: the meeting's text goes with every question, and the chat remembers its meeting.
final class MeetingChatTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record() -> CallRecord {
        var r = CallRecord(id: "c7", platform: .meet, bundleID: "", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.speakerNames = ["me:A": "Dana", "them:A": "Jo Park"]
        r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 5, end: 9, text: "We ship on the ninth.")]
        return r
    }

    func testAChatAboutAMeetingGivesTheModelThatMeeting() async throws {
        let model = FakeModel(output: [:])
        _ = try await ChatAgent(llm: model, ownerName: "Dana").answer("When do we ship?", history: [], records: [record()], about: "c7") { _ in }
        XCTAssertTrue(model.system.contains("This chat is about one meeting"), model.system)
        XCTAssertTrue(model.system.contains("We ship on the ninth."))
    }

    func testAnOrdinaryChatHasNoMeeting() async throws {
        let model = FakeModel(output: [:])
        _ = try await ChatAgent(llm: model, ownerName: "Dana").answer("When do we ship?", history: [], records: [record()]) { _ in }
        XCTAssertFalse(model.system.contains("This chat is about one meeting"))
    }

    func testAChatKeepsItsMeetingAndOlderChatsHaveNone() throws {
        var chat = Chat(title: "Q")
        chat.callID = "c7"
        let back = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
        XCTAssertEqual(back.callID, "c7")
        let old = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","title":"Q","created":0,"updated":0,"messages":[]}"#
        XCTAssertNil(try JSONDecoder().decode(Chat.self, from: Data(old.utf8)).callID)
    }
}
