import XCTest
import GRDB
@testable import MossadShared

final class DatabaseManagerTests: XCTestCase {
    func testDatabaseCreatesAllTables() throws {
        let dbManager = try DatabaseManager(inMemory: true)
        try dbManager.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("conversations"))
            XCTAssertTrue(try db.tableExists("utterances"))
            XCTAssertTrue(try db.tableExists("speakers"))
            XCTAssertTrue(try db.tableExists("conversationSpeakers"))
            XCTAssertTrue(try db.tableExists("utterances_fts"))
        }
    }

    func testInsertAndFetchConversation() throws {
        let dbManager = try DatabaseManager(inMemory: true)
        let conv = Conversation(
            id: UUID().uuidString, title: "Sprint Planning", platform: "meet",
            startedAt: Date(), endedAt: nil, durationSeconds: nil,
            calendarEventId: nil, meetingUrl: "https://meet.google.com/abc-defg-hij"
        )
        try dbManager.dbQueue.write { db in try conv.insert(db) }
        let fetched = try dbManager.dbQueue.read { db in try Conversation.fetchOne(db, key: conv.id) }
        XCTAssertEqual(fetched?.title, "Sprint Planning")
        XCTAssertEqual(fetched?.platform, "meet")
    }
}
