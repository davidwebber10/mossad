import Foundation

public struct MeetingHit: Sendable, Equatable, Identifiable {
    public var id: String { callID }
    public var callID: String
    public var title: SearchText
    public var start: Date
    public var end: Date
    public var platform: Platform
    public var kind: String?
    public var tags: [String]
    /// The best match outside the title, such as a tag or a person, when the title did not hold every word.
    public var context: SearchText?
    var score: Double = 0
}

public struct PersonHit: Sendable, Equatable, Identifiable {
    public var id: String { name.text }
    public var name: SearchText
    public var email: String?
    /// The job title from the directory, when one is known.
    public var title: String? = nil
    public var isOwner: Bool
    /// Meetings where this person spoke.
    public var meetings: Int
    public var lastMet: Date?
    var score: Double = 0
}

/// One transcript turn that holds every word of the query.
public struct MomentHit: Sendable, Equatable, Identifiable {
    public var id: String { "\(callID)#\(turn)" }
    public var callID: String
    public var meetingTitle: String
    public var meetingStart: Date
    /// The turn's position in the meeting's utterances.
    public var turn: Int
    public var speaker: String
    /// Seconds into the meeting; play from here.
    public var time: TimeInterval
    /// About 120 characters around the match; the ranges point into this text.
    public var snippet: SearchText
    var score: Double = 0
}

/// A meeting's best moments, at most three, and how many more matched.
public struct MomentGroup: Sendable, Equatable, Identifiable {
    public var id: String { callID }
    public var callID: String
    public var title: String
    public var start: Date
    /// In time order.
    public var moments: [MomentHit]
    /// Matching turns in this meeting that are not shown; `SearchIndex.moments(in:matching:)` lists them all.
    public var moreCount: Int
    var score: Double = 0
}

/// A decision or an action item from a meeting's summary, or the note of a bookmark.
public struct OutcomeHit: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case decision, actionItem, bookmark }
    public var id: String { "\(callID)#\(kind.rawValue)\(position)" }
    public var kind: Kind
    public var callID: String
    public var meetingTitle: String
    public var meetingStart: Date
    /// The position in the meeting's decisions, action items, or bookmarks.
    public var position: Int
    /// Seconds into the meeting, when known.
    public var time: TimeInterval?
    public var text: SearchText
    var score: Double = 0
}

/// A commitment, shown as a task.
public struct TaskHit: Sendable, Equatable, Identifiable {
    public var id: UUID { commitmentID }
    public var commitmentID: UUID
    public var text: SearchText
    public var to: String?
    public var callID: String?
    public var callTitle: String?
    public var time: TimeInterval?
    public var due: Date?
    public var isDone: Bool
    var score: Double = 0
}

public struct ChatHit: Sendable, Equatable, Identifiable {
    public var id: UUID { chatID }
    public var chatID: UUID
    public var title: SearchText
    /// Part of the first message that matched, when one did.
    public var snippet: SearchText?
    public var updated: Date
    public var callID: String?
    var score: Double = 0
}

public enum SearchHit: Sendable, Equatable, Identifiable {
    case meeting(MeetingHit)
    case person(PersonHit)
    case moment(MomentHit)
    case outcome(OutcomeHit)
    case task(TaskHit)
    case chat(ChatHit)

    public var id: String {
        switch self {
        case .meeting(let h): "meeting:\(h.id)"
        case .person(let h): "person:\(h.id)"
        case .moment(let h): "moment:\(h.id)"
        case .outcome(let h): "outcome:\(h.id)"
        case .task(let h): "task:\(h.id.uuidString)"
        case .chat(let h): "chat:\(h.id.uuidString)"
        }
    }

    var score: Double {
        switch self {
        case .meeting(let h): h.score
        case .person(let h): h.score
        case .moment(let h): h.score
        case .outcome(let h): h.score
        case .task(let h): h.score
        case .chat(let h): h.score
        }
    }
}

public enum SearchGroup: String, Sendable, CaseIterable, Identifiable {
    case topHit, meetings, people, moments, decisionsAndActions, bookmarks, tasks, chats

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topHit: "Top hit"
        case .meetings: "Meetings"
        case .people: "People"
        case .moments: "Transcript"
        case .decisionsAndActions: "Decisions and action items"
        case .bookmarks: "Bookmarks"
        case .tasks: "Tasks"
        case .chats: "Chats"
        }
    }
}

public struct SearchSection: Sendable, Equatable, Identifiable {
    public var id: SearchGroup { group }
    public var group: SearchGroup
    /// For moments: each meeting's shown moments in turn, in the order of `SearchResults.moments`.
    public var hits: [SearchHit]
}

public struct SearchResults: Sendable, Equatable {
    public var query: String = ""
    /// The single best result. It is not repeated in its own group.
    public var topHit: SearchHit?
    public var meetings: [MeetingHit] = []
    public var people: [PersonHit] = []
    public var moments: [MomentGroup] = []
    public var decisionsAndActions: [OutcomeHit] = []
    /// Bookmarks whose note holds the words.
    public var bookmarks: [OutcomeHit] = []
    public var tasks: [TaskHit] = []
    public var chats: [ChatHit] = []

    public static let empty = SearchResults()

    public var isEmpty: Bool { sections.isEmpty }

    /// The groups that have results, in display order.
    public var sections: [SearchSection] {
        let all: [SearchSection] = [
            SearchSection(group: .topHit, hits: topHit.map { [$0] } ?? []),
            SearchSection(group: .meetings, hits: meetings.map(SearchHit.meeting)),
            SearchSection(group: .people, hits: people.map(SearchHit.person)),
            SearchSection(group: .moments, hits: moments.flatMap { $0.moments.map(SearchHit.moment) }),
            SearchSection(group: .decisionsAndActions, hits: decisionsAndActions.map(SearchHit.outcome)),
            SearchSection(group: .bookmarks, hits: bookmarks.map(SearchHit.outcome)),
            SearchSection(group: .tasks, hits: tasks.map(SearchHit.task)),
            SearchSection(group: .chats, hits: chats.map(SearchHit.chat)),
        ]
        return all.filter { !$0.hits.isEmpty }
    }

    /// Every shown result in display order, for moving through them with the arrow keys.
    public var hits: [SearchHit] { sections.flatMap(\.hits) }

    /// The top hit when it is a moment, then the moments of every group.
    public var allMoments: [MomentHit] {
        var out: [MomentHit] = []
        if case .moment(let m) = topHit { out.append(m) }
        return out + moments.flatMap(\.moments)
    }
}

/// What to show before anything is typed.
public struct SearchSuggestions: Sendable, Equatable {
    /// Newest first.
    public var meetings: [MeetingHit] = []
    /// Most meetings first; the owner is left out.
    public var people: [PersonHit] = []
    /// Most used first.
    public var tags: [String] = []

    public static let empty = SearchSuggestions()
}

/// How many results each group holds at most.
public struct SearchLimits: Sendable, Equatable {
    public var meetings = 20
    public var people = 8
    /// Meetings in the Transcript group.
    public var momentMeetings = 10
    public var momentsPerMeeting = 3
    public var decisionsAndActions = 20
    public var bookmarks = 10
    public var tasks = 10
    public var chats = 10

    public init() {}

    public static let standard = SearchLimits()
}
