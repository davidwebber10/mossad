// MossadShared/Database/ConversationStore.swift
import Foundation
import GRDB

public struct SearchResult {
    public let utterance: Utterance
    public let conversation: Conversation
    public let speaker: Speaker

    // Convenience accessor for search results
    public var text: String { utterance.text }
}

public final class ConversationStore {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Conversations

    public func createConversation(title: String, platform: String, calendarEventId: String? = nil, meetingUrl: String? = nil) throws -> Conversation {
        let conv = Conversation(title: title, platform: platform, startedAt: Date(), calendarEventId: calendarEventId, meetingUrl: meetingUrl)
        try dbQueue.write { db in try conv.insert(db) }
        return conv
    }

    public func finalizeConversation(id: String) throws {
        try dbQueue.write { db in
            guard var conv = try Conversation.fetchOne(db, key: id) else { return }
            let now = Date()
            conv.endedAt = now
            conv.durationSeconds = Int(now.timeIntervalSince(conv.startedAt))
            try conv.update(db)
        }
    }

    public func fetchConversation(id: String) throws -> Conversation? {
        try dbQueue.read { db in try Conversation.fetchOne(db, key: id) }
    }

    public func listConversations() throws -> [Conversation] {
        try dbQueue.read { db in try Conversation.order(Column("startedAt").desc).fetchAll(db) }
    }

    // MARK: - Speakers

    public func getOrCreateMeSpeaker(name: String) throws -> Speaker {
        try dbQueue.write { db in
            if let existing = try Speaker.filter(Column("isMe") == true).fetchOne(db) { return existing }
            let speaker = Speaker(name: name, isMe: true)
            try speaker.insert(db)
            return speaker
        }
    }

    public func getOrCreateSpeaker(name: String, email: String? = nil) throws -> Speaker {
        try dbQueue.write { db in
            if let email = email, let existing = try Speaker.filter(Column("email") == email).fetchOne(db) { return existing }
            let speaker = Speaker(name: name, email: email)
            try speaker.insert(db)
            return speaker
        }
    }

    public func updateSpeakerName(id: String, name: String) throws {
        try dbQueue.write { db in
            guard var speaker = try Speaker.fetchOne(db, key: id) else { return }
            speaker.name = name
            try speaker.update(db)
        }
    }

    public func fetchSpeaker(id: String) throws -> Speaker? {
        try dbQueue.read { db in try Speaker.fetchOne(db, key: id) }
    }

    // MARK: - Utterances

    public func insertUtterance(conversationId: String, speakerId: String, text: String, startedAt: Double, endedAt: Double) throws {
        try dbQueue.write { db in
            var utterance = Utterance(conversationId: conversationId, speakerId: speakerId, text: text, startedAt: startedAt, endedAt: endedAt)
            try utterance.insert(db)
        }
    }

    public func fetchUtterances(conversationId: String) throws -> [Utterance] {
        try dbQueue.read { db in try Utterance.filter(Column("conversationId") == conversationId).order(Column("startedAt").asc).fetchAll(db) }
    }

    // MARK: - Conversation Speakers

    public func addConversationSpeaker(conversationId: String, speakerId: String, diarizationLabel: String) throws {
        try dbQueue.write { db in
            let cs = ConversationSpeaker(conversationId: conversationId, speakerId: speakerId, diarizationLabel: diarizationLabel)
            try cs.insert(db)
        }
    }

    public func fetchSpeakers(conversationId: String) throws -> [Speaker] {
        try dbQueue.read { db in
            let sql = "SELECT s.* FROM speakers s JOIN conversationSpeakers cs ON cs.speakerId = s.id WHERE cs.conversationId = ?"
            return try Speaker.fetchAll(db, sql: sql, arguments: [conversationId])
        }
    }

    // MARK: - Search

    public func search(query: String) throws -> [SearchResult] {
        try dbQueue.read { db in
            let sql = """
                SELECT u.id AS u_id, u.conversationId, u.speakerId, u.text AS u_text,
                    u.startedAt AS u_startedAt, u.endedAt AS u_endedAt,
                    c.id AS c_id, c.title, c.platform, c.startedAt AS c_startedAt,
                    c.endedAt AS c_endedAt, c.durationSeconds, c.calendarEventId, c.meetingUrl,
                    s.id AS s_id, s.name, s.email, s.isMe
                FROM utterances_fts fts
                JOIN utterances u ON u.rowid = fts.rowid
                JOIN conversations c ON c.id = u.conversationId
                JOIN speakers s ON s.id = u.speakerId
                WHERE utterances_fts MATCH ?
                ORDER BY rank
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [query])
            return rows.map { row in
                SearchResult(
                    utterance: Utterance(id: row["u_id"], conversationId: row["conversationId"], speakerId: row["speakerId"], text: row["u_text"], startedAt: row["u_startedAt"], endedAt: row["u_endedAt"]),
                    conversation: Conversation(id: row["c_id"], title: row["title"], platform: row["platform"], startedAt: row["c_startedAt"], endedAt: row["c_endedAt"], durationSeconds: row["durationSeconds"], calendarEventId: row["calendarEventId"], meetingUrl: row["meetingUrl"]),
                    speaker: Speaker(id: row["s_id"], name: row["name"], email: row["email"], isMe: row["isMe"])
                )
            }
        }
    }
}
