import CryptoKit
import Foundation

/// What both devices write and read: chats, the owner's ratings and conversation on a review, and the
/// coach's memory. Meetings themselves come only from the Mac.
public struct SharedPayload: Sendable {
    public enum Kind: String, Sendable { case chat, notes, profile }

    public let kind: Kind
    /// "chat:<uuid>", "notes:<call id>", or "profile": the record name and the key in the sync state.
    public let key: String
    public let data: Data
    public let hash: String

    init(kind: Kind, key: String, data: Data) {
        self.kind = kind
        self.key = key
        self.data = data
        hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func chat(_ chat: Chat) -> SharedPayload {
        SharedPayload(kind: .chat, key: "chat:\(chat.id.uuidString)", data: (try? JSONEncoder.callRecord.encode(chat)) ?? Data())
    }

    /// Only the owner's own part of a review: the Mac's coach writes the rest.
    public static func notes(callID: String, review: CoachReview) -> SharedPayload? {
        guard !review.feedback.isEmpty || !review.thread.isEmpty else { return nil }
        let notes = ReviewNotes(feedback: review.feedback, thread: review.thread)
        return SharedPayload(kind: .notes, key: "notes:\(callID)", data: (try? JSONEncoder.callRecord.encode(notes)) ?? Data())
    }

    public static func profile(_ profile: CoachProfile) -> SharedPayload {
        SharedPayload(kind: .profile, key: "profile", data: (try? JSONEncoder.callRecord.encode(profile)) ?? Data())
    }
}

/// The owner's ratings and conversation on one review, as they travel between devices.
public struct ReviewNotes: Codable, Sendable {
    public var feedback: [String: CoachFeedback]
    public var thread: [ChatMessage]
}

extension SyncState {
    /// Shared records to upload, and chats deleted here to delete in iCloud.
    public func planShared(_ payloads: [SharedPayload]) -> (upload: [SharedPayload], delete: [String]) {
        let keys = Set(payloads.map(\.key))
        return (payloads.filter { uploaded[$0.key] != $0.hash },
                uploaded.keys.filter { $0.hasPrefix("chat:") && !keys.contains($0) }.sorted())
    }
}
