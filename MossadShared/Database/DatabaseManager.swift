import Foundation
import GRDB

public final class DatabaseManager {
    public let dbQueue: DatabaseQueue

    public init(inMemory: Bool = false) throws {
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Mossad", isDirectory: true)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let dbPath = appSupport.appendingPathComponent("mossad.db").path
            dbQueue = try DatabaseQueue(path: dbPath)
        }
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("title", .text).notNull()
                t.column("platform", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("durationSeconds", .integer)
                t.column("calendarEventId", .text)
                t.column("meetingUrl", .text)
            }
            try db.create(table: "speakers") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("email", .text)
                t.column("isMe", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "utterances") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("speakerId", .text).notNull().references("speakers", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("startedAt", .double).notNull()
                t.column("endedAt", .double).notNull()
            }
            try db.create(table: "conversationSpeakers") { t in
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("speakerId", .text).notNull().references("speakers", onDelete: .cascade)
                t.column("diarizationLabel", .text).notNull()
                t.primaryKey(["conversationId", "speakerId"])
            }
            try db.create(virtualTable: "utterances_fts", using: FTS5()) { t in
                t.synchronize(withTable: "utterances")
                t.column("text")
            }
        }
        try migrator.migrate(dbQueue)
    }
}
