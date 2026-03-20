// MossadTests/ConversationStoreTests.swift
import XCTest
import GRDB
@testable import MossadShared

final class ConversationStoreTests: XCTestCase {
    var store: ConversationStore!

    override func setUp() async throws {
        let db = try DatabaseManager(inMemory: true)
        store = ConversationStore(dbQueue: db.dbQueue)
    }

    func testCreateAndFetchConversation() throws {
        let conv = try store.createConversation(title: "Standup", platform: "zoom", meetingUrl: "https://zoom.us/j/123")
        let fetched = try store.fetchConversation(id: conv.id)
        XCTAssertEqual(fetched?.title, "Standup")
    }

    func testFinalizeConversation() throws {
        let conv = try store.createConversation(title: "Standup", platform: "zoom")
        try store.finalizeConversation(id: conv.id)
        let fetched = try store.fetchConversation(id: conv.id)
        XCTAssertNotNil(fetched?.endedAt)
        XCTAssertNotNil(fetched?.durationSeconds)
    }

    func testListConversationsChronological() throws {
        var first = Conversation(title: "First", platform: "zoom", startedAt: Date(timeIntervalSince1970: 1000))
        var second = Conversation(title: "Second", platform: "meet", startedAt: Date(timeIntervalSince1970: 2000))
        try store.dbQueue.write { db in
            try first.insert(db)
            try second.insert(db)
        }
        let list = try store.listConversations()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first?.title, "Second")
    }

    func testInsertAndFetchUtterances() throws {
        let conv = try store.createConversation(title: "Call", platform: "meet")
        let speaker = try store.getOrCreateMeSpeaker(name: "David")
        try store.insertUtterance(conversationId: conv.id, speakerId: speaker.id, text: "Hello everyone", startedAt: 0.0, endedAt: 2.5)
        let utterances = try store.fetchUtterances(conversationId: conv.id)
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances.first?.text, "Hello everyone")
    }

    func testFullTextSearch() throws {
        let conv = try store.createConversation(title: "Planning", platform: "meet")
        let speaker = try store.getOrCreateMeSpeaker(name: "David")
        try store.insertUtterance(conversationId: conv.id, speakerId: speaker.id, text: "We need to fix the authentication bug", startedAt: 0.0, endedAt: 3.0)
        try store.insertUtterance(conversationId: conv.id, speakerId: speaker.id, text: "The deployment pipeline is broken", startedAt: 3.0, endedAt: 6.0)
        let results = try store.search(query: "authentication")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.text.contains("authentication") ?? false)
    }

    func testGetOrCreateMeSpeaker() throws {
        let speaker1 = try store.getOrCreateMeSpeaker(name: "David")
        let speaker2 = try store.getOrCreateMeSpeaker(name: "David")
        XCTAssertEqual(speaker1.id, speaker2.id)
        XCTAssertTrue(speaker1.isMe)
    }
}
