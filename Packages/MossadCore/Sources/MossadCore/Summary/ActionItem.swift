import Foundation

public struct ActionItem: Codable, Equatable, Sendable, Hashable {
    /// The owner as the model wrote it: a label.
    public var owner: String?
    public var task: String
    /// The saved person the owner is, by the id in `people.json`, on a sure match among the people of the call.
    public var ownerID: String?

    public init(owner: String?, task: String, ownerID: String? = nil) {
        self.owner = owner
        self.task = task
        self.ownerID = ownerID
    }

    /// The "Owner: task" form used in notes and in older records.
    public var text: String { owner.map { "\($0): \(task)" } ?? task }

    /// Reads the "Owner: task" form. The owner is the text before the first ": " when it is 1 to 3 words.
    public init(parsing s: String) {
        if let r = s.range(of: ": ") {
            let owner = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            if (1...3).contains(owner.split(separator: " ").count) {
                self.init(owner: owner, task: String(s[r.upperBound...]))
                return
            }
        }
        self.init(owner: nil, task: s)
    }

    private enum CodingKeys: String, CodingKey { case owner, task, ownerID }

    public init(from decoder: Decoder) throws {
        // Records written before owners were split store each item as one string.
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.init(parsing: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(owner: try c.decodeIfPresent(String.self, forKey: .owner), task: try c.decode(String.self, forKey: .task),
                  ownerID: try c.decodeIfPresent(String.self, forKey: .ownerID))
    }
}
