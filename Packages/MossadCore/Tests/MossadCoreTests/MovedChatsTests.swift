import XCTest
@testable import MossadCore

/// C4: a chat of the call goes only when everything it read was this call. A chat that also read another meeting, a
/// person, the tasks, the coach, or any other tool is deleted in the first profile with the meeting, not moved: words
/// of the moved meeting do not stay in A, and words of A's other meetings do not reach B.
final class MovedChatsTests: XCTestCase {
    private let id = "20261101-100000"
    private let title = "Zebra budget"

    /// The tools that read this call only, when they are given this call.
    private let thisCallOnly: Set<String> = ["read_meeting", "list_screens", "get_screen", "current_call"]

    private var allTools: [String] {
        let names = ChatTools.allDefinitions.map(\.name) + ChatActions.definitions(live: false).map(\.name) + ChatActions.definitions(live: true).map(\.name)
        return Array(Set(names)).sorted()
    }

    private func step(_ tool: String, call: String? = nil) -> String {
        let c = call ?? id
        let input: [String: Any] = ["call_id": c, "meeting_id": c, "query": "budget", "people": ["Sam Carter"], "person": "Sam Carter",
                                    "series": "Weekly sync", "owner": "Sam Carter", "meeting": c]
        return ChatTools.step(tool, input: input, title: { $0 == self.id ? self.title : ($0 == "20261102-090000" ? "Bank" : nil) })
    }

    func testEveryToolHasARule() {
        XCTAssertGreaterThan(allTools.count, 30)
        for tool in allTools {
            let read = MovedChats.read(step(tool), title: title, otherTitles: ["Bank"])
            XCTAssertEqual(read, thisCallOnly.contains(tool) ? .thisCall : .other, tool)
            // The same tool given another meeting reads something else. `current_call` takes no meeting: it is the
            // call of the chat, which records now.
            guard tool != "current_call" else { continue }
            XCTAssertEqual(MovedChats.read(step(tool, call: "20261102-090000"), title: title, otherTitles: ["Bank"]), .other, "\(tool) of another meeting")
        }
        XCTAssertEqual(MovedChats.read("A step of a later build", title: title, otherTitles: []), .other, "an unknown step reads other things")
        XCTAssertEqual(MovedChats.read("Looking it up", title: title, otherTitles: []), .other)
    }

    func testATitleThatAnotherMeetingAlsoHasIsNotThisCallAlone() {
        XCTAssertEqual(MovedChats.read(step("read_meeting"), title: title, otherTitles: [title]), .other)
        XCTAssertEqual(MovedChats.read(step("read_meeting"), title: title, otherTitles: ["Bank"]), .thisCall)
    }

    func testWhichChatsGo() {
        func chat(_ steps: [[String]]) -> Chat {
            var c = Chat(title: title)
            c.callID = id
            c.messages = steps.map { s in ChatMessage(role: .assistant, text: "An answer", steps: s) }
            return c
        }
        let quiet = chat([[], []])
        let own = chat([[step("read_meeting")], [step("current_call"), step("list_screens")]])
        let wide = chat([[step("read_meeting")], [step("search_transcripts")]])
        let tasks = chat([[step("commitments")]])
        let split = MovedChats.split([quiet, own, wide, tasks], title: title, otherTitles: ["Bank"])
        XCTAssertEqual(split.moved.map(\.id), [quiet.id, own.id])
        XCTAssertEqual(split.deleted.map(\.id), [wide.id, tasks.id])
        XCTAssertEqual(split.moved.last?.messages.map(\.steps), own.messages.map(\.steps), "steps that name this call stay")
    }

    func testTheSentenceOfTheChatsThatAreDeleted() {
        XCTAssertNil(MoveWords.chatsDeleted(0))
        XCTAssertEqual(MoveWords.chatsDeleted(1), "1 chat about this meeting also read other meetings. It is deleted, not moved.")
        XCTAssertEqual(MoveWords.chatsDeleted(3), "3 chats about this meeting also read other meetings. They are deleted, not moved.")
    }
}
