import Foundation
import GRDB

public struct Conversation: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversations"
    public let id: String
    public var title: String
    public var platform: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Int?
    public var calendarEventId: String?
    public var meetingUrl: String?

    public init(id: String = UUID().uuidString, title: String, platform: String, startedAt: Date, endedAt: Date? = nil, durationSeconds: Int? = nil, calendarEventId: String? = nil, meetingUrl: String? = nil) {
        self.id = id; self.title = title; self.platform = platform; self.startedAt = startedAt
        self.endedAt = endedAt; self.durationSeconds = durationSeconds
        self.calendarEventId = calendarEventId; self.meetingUrl = meetingUrl
    }
}
