import XCTest
@testable import MossadCore

/// Review N6: the chat of a meeting whose move waits is off before any request, a question that waits is not sent,
/// and a chat that the iPhone sends meanwhile is not kept silently.
final class MoveChatOffTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveChatOffTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func marked(_ p: Paths) throws -> CallRecord {
        var r = try writtenCall(in: p)
        r.moveTo = work
        try r.save(to: p.callDirectory(id))
        return r
    }

    func testTheFieldIsOffForAMarkedMeetingOnly() throws {
        let p = temp()
        var r = try writtenCall(in: p)
        XCTAssertNil(MoveShow.chatOff(r, name: "Work"))
        r.moveTo = work
        XCTAssertEqual(MoveShow.chatOff(r, name: "Work"), MoveWords.moving(to: "Work"))
        XCTAssertEqual(MoveShow.chatOff(r, name: nil), MoveWords.heldForGone)
        XCTAssertEqual(MoveShow.chatOff(r, name: "Work", me: work), MoveWords.arriving)
        XCTAssertNil(MoveShow.chatOff(nil, name: "Work"))
    }

    func testAQuestionThatWaitsIsNotSentOnceTheFieldIsOff() {
        XCTAssertEqual(ChatRunRules.next(queued: "and the budget?", failed: false, stopped: false, callRecords: true), .send("and the budget?"))
        XCTAssertEqual(ChatRunRules.next(queued: "and the budget?", failed: false, stopped: false, callRecords: true, off: true),
                       .toField("and the budget?"))
        XCTAssertEqual(ChatRunRules.next(queued: nil, failed: false, stopped: false, callRecords: true, off: true), .nothing)
    }

    func testANewChatFromThePhoneForAMovingMeetingIsNotKeptAndIsCounted() throws {
        let p = temp()
        _ = try marked(p)
        var chat = Chat(title: "From the phone")
        chat.callID = id
        chat.messages = [ChatMessage(role: .user, text: "What did Sam Carter promise?")]
        XCTAssertFalse(try CloudSync.takeChat(chat, paths: p))
        let store = ChatStore(directory: p.chats)
        XCTAssertNil(try store.load(chat.id), "nothing of it is kept here")
        XCTAssertTrue(store.deleted().contains(chat.id), "the next push deletes it from the store, so it cannot come back after the move")
        XCTAssertEqual(MovingChats.all(p), [id: 1])
        var second = Chat(title: "Again")
        second.callID = id
        XCTAssertFalse(try CloudSync.takeChat(second, paths: p))
        XCTAssertEqual(MovingChats.all(p), [id: 2])
        // The file holds a count, never a word of the chat.
        let raw = try String(contentsOf: MovingChats.url(id, paths: p), encoding: .utf8)
        XCTAssertFalse(raw.contains("Sam"))
        XCTAssertEqual(MoveWords.phoneChatsNotKept(1), "A chat from your iPhone about this meeting came in while it was moving. It was not kept.")
        XCTAssertEqual(MoveWords.phoneChatsNotKept(2), "2 chats from your iPhone about a meeting that was moving came in. They were not kept.")
        MovingChats.shown(id, paths: p)
        XCTAssertEqual(MovingChats.all(p), [:])
    }

    func testAChangeFromThePhoneToAChatThatIsThereIsNotKeptAndTheChatStays() throws {
        let p = temp()
        let store = ChatStore(directory: p.chats)
        var chat = Chat(title: "Kept")
        chat.callID = id
        _ = try writtenCall(in: p)
        try store.save(chat)
        _ = try marked(p)
        var phone = chat
        phone.messages = [ChatMessage(role: .user, text: "asked on the phone")]
        phone.updated = chat.updated.addingTimeInterval(60)
        XCTAssertFalse(try CloudSync.takeChat(phone, paths: p))
        XCTAssertEqual(try store.load(chat.id)?.messages.count, 0, "the chat that is there stays as it was")
        XCTAssertFalse(store.deleted().contains(chat.id), "a cancelled move keeps it")
        XCTAssertEqual(MovingChats.all(p), [id: 1])
    }

    func testAChatOfAMeetingThatIsNotMovingIsTakenAsBefore() throws {
        let p = temp()
        _ = try writtenCall(in: p)
        var chat = Chat(title: "Fine")
        chat.callID = id
        XCTAssertTrue(try CloudSync.takeChat(chat, paths: p))
        XCTAssertNotNil(try ChatStore(directory: p.chats).load(chat.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.moves.path), "no Moves folder with no move")
    }
}
