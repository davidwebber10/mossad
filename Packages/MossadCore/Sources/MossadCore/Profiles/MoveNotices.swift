import Foundation

/// The reasons that a move left behind for the owner (`Moves/<id>.ended`, `<id>.phone-chats`): each is forgotten only
/// after its line was on the screen, never when it is only set. With the window closed, on another page, or behind
/// another line, it waits. Pure; the app deletes the file of a notice that `shown` returns.
public struct MoveNotices: Equatable, Sendable {
    public enum Kind: String, Sendable { case ended, phoneChats }

    public struct Notice: Equatable, Sendable, Identifiable {
        public let callID: String
        public let kind: Kind
        public let text: String
        /// The reason of a call marked during its recording stays on its row until the owner chooses: its file stays.
        public let keepsFile: Bool
        public var id: String { kind.rawValue + ":" + callID }

        public init(callID: String, kind: Kind, text: String, keepsFile: Bool) {
            self.callID = callID
            self.kind = kind
            self.text = text
            self.keepsFile = keepsFile
        }
    }

    public private(set) var pending: [Notice] = []
    /// Shown in this run of the app: a file kept on its row does not show again. A file that is deleted once shown and is
    /// there again (another chat from the iPhone) is news.
    public private(set) var seen: Set<String> = []

    public init() {}

    /// The notices a look found. One there already, or one kept on its row and shown in this run, is not added again.
    public mutating func offer(_ notices: [Notice]) {
        for n in notices where !(n.keepsFile && seen.contains(n.id)) && !pending.contains(where: { $0.id == n.id }) { pending.append(n) }
    }

    /// The one that shows next.
    public var current: Notice? { pending.first }

    /// The one that shows next on a page: the list and Calendar (nil) show any; a meeting's page only its own, so a
    /// reason about one meeting never reads as "this meeting" on another.
    public func current(on meeting: String?) -> Notice? { meeting.map { m in pending.first { $0.callID == m } } ?? current }

    /// Its line was on the screen: it is forgotten, and the caller deletes its file unless `keepsFile`.
    public mutating func shown(_ id: String) -> Notice? {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return nil }
        seen.insert(id)
        return pending.remove(at: i)
    }
}
