import Foundation
import GRDB

public struct Speaker: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speakers"
    public let id: String
    public var name: String
    public var email: String?
    public var isMe: Bool

    public init(id: String = UUID().uuidString, name: String, email: String? = nil, isMe: Bool = false) {
        self.id = id; self.name = name; self.email = email; self.isMe = isMe
    }
}
