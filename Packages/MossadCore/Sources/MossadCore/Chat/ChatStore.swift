import Foundation

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id = UUID()
    public var role: Role
    public var text: String
    /// The lookups behind an answer, such as "Reading Launch sync".
    public var steps: [String] = []
    /// An answer given during the call, from the live transcript: its names and letters were not final.
    public var live: Bool?
    /// When the owner asked it; nil on a question from an older build.
    public var asked: Date?

    public init(role: Role, text: String, steps: [String] = []) {
        self.role = role
        self.text = text
        self.steps = steps
    }
}

public struct Chat: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var created = Date()
    public var updated = Date()
    public var messages: [ChatMessage] = []
    /// One or two sentences on what the chat was about and what was decided, for later chats to recall.
    public var summary: String?
    /// The meeting a chat is about, when it was started from that meeting.
    public var callID: String?

    public init(title: String) {
        self.title = title
    }

    /// The copy to keep when two devices changed the same chat.
    public static func newer(_ a: Chat, _ b: Chat) -> Chat {
        a.updated == b.updated ? (a.messages.count >= b.messages.count ? a : b) : (a.updated > b.updated ? a : b)
    }

    /// Both devices added to the same chat while apart: the newer copy, plus the messages only the other has.
    public static func merged(_ a: Chat, _ b: Chat) -> Chat {
        var out = newer(a, b)
        let other = out == a ? b : a
        let ids = Set(out.messages.map(\.id))
        out.messages += other.messages.filter { !ids.contains($0.id) }
        return out
    }

    static let titleLength = 46

    /// The first question, cut at a word near 46 characters.
    public static func title(from question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count > titleLength + 2 else { return q }
        var out = ""
        for word in q.split(separator: " ") {
            if out.count + word.count + 1 > titleLength { break }
            out += (out.isEmpty ? "" : " ") + word
        }
        return out.trimmingCharacters(in: .punctuationCharacters) + "…"
    }
}

/// Chats saved one per file in `~/Mossad/Chats`, newest first.
public struct ChatStore: Sendable {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    /// One chat, or nil when there is none. Throws when its file cannot be read.
    public func load(_ id: UUID) throws -> Chat? {
        try StoredFile.load(Chat.self, from: url(id), decoder: .coach, recovery: .local)
    }

    /// A chat file that does not decode is moved aside (see `StoredFile`) and left out.
    public func all() -> [Chat] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != Self.deletedFileName && !StoredFile.isQuarantined($0) }
            .compactMap { try? StoredFile.load(Chat.self, from: $0, decoder: .coach, recovery: .local) }
            .sorted { $0.updated > $1.updated }
    }

    public func save(_ chat: Chat) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.coach.encode(chat).write(to: url(chat.id), options: .atomic)
    }

    /// `record` keeps the id in a list of deletes made here, so the sync deletes it on the other device. A chat
    /// that is only missing (it did not decode, or the folder could not be read) is never deleted elsewhere.
    public func delete(_ id: UUID, record: Bool = true) {
        try? FileManager.default.removeItem(at: url(id))
        if record { setDeleted(deleted().union([id])) }
    }

    /// Deletes every chat about one call, as a deleted chat, so the sync removes it elsewhere too. For a call that
    /// was skipped or discarded: its chat quotes words whose audio is gone.
    @discardableResult
    public func deleteChats(forCall callID: String) -> [UUID] {
        let ids = all().filter { $0.callID == callID }.map(\.id)
        for id in ids { delete(id) }
        return ids
    }

    static let deletedFileName = "deleted.json"

    /// Chats deleted on this device that the store may still have.
    public func deleted() -> Set<UUID> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.deletedFileName)),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    public func setDeleted(_ ids: Set<UUID>) {
        let url = directory.appendingPathComponent(Self.deletedFileName)
        guard !ids.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString }).write(to: url, options: .atomic)
    }
}
