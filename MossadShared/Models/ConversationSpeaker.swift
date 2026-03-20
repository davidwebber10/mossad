import Foundation
import GRDB

public struct ConversationSpeaker: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversationSpeakers"
    public var conversationId: String
    public var speakerId: String
    public var diarizationLabel: String

    public init(conversationId: String, speakerId: String, diarizationLabel: String) {
        self.conversationId = conversationId; self.speakerId = speakerId; self.diarizationLabel = diarizationLabel
    }
}
