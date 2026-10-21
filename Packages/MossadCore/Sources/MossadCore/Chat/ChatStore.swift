import Foundation

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id = UUID()
    public var role: Role
    public var text: String
    /// The lookups behind an answer, such as "Reading Launch sync".
    public var steps: [String] = []

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

    public init(title: String) {
        self.title = title
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

    public func all() -> [Chat] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.coach.decode(Chat.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    public func save(_ chat: Chat) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.coach.encode(chat).write(to: url(chat.id), options: .atomic)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}
