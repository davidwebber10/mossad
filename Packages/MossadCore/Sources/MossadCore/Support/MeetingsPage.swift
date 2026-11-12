import Foundation

/// The pages under Meetings in the sidebar and in the Go menu, in their order there. Recurring is first: the owner
/// opens it most, before a meeting of the series.
public enum MeetingsPage: String, CaseIterable, Sendable {
    case recurring, bookmarks, screens, shares, tasks

    /// A key of the Go menu, with Command: a number alone, or a letter with Option too.
    public struct Key: Hashable, Sendable {
        public let character: Character
        public let option: Bool
    }

    /// Each page keeps the key it had before the order changed, so the owner's habits still work. No number is left
    /// for Recurring and Screens, so they take a letter with Option.
    public var key: Key {
        switch self {
        case .recurring: Key(character: "r", option: true)
        case .bookmarks: Key(character: "0", option: false)
        case .screens: Key(character: "s", option: true)
        case .shares: Key(character: "9", option: false)
        case .tasks: Key(character: "2", option: false)
        }
    }
}
