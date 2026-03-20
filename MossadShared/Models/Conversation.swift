import Foundation

public struct Conversation: Identifiable, Codable {
    public let id: String
    public var title: String
    public var platform: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Int?
    public var calendarEventId: String?
    public var meetingUrl: String?
}
