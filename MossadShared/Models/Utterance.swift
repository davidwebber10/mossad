import Foundation
import GRDB

public struct Utterance: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "utterances"
    public var id: Int64?
    public var conversationId: String
    public var speakerId: String
    public var text: String
    public var startedAt: Double
    public var endedAt: Double

    public init(id: Int64? = nil, conversationId: String, speakerId: String, text: String, startedAt: Double, endedAt: Double) {
        self.id = id; self.conversationId = conversationId; self.speakerId = speakerId
        self.text = text; self.startedAt = startedAt; self.endedAt = endedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
