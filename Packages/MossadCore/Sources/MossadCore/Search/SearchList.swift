import Foundation

/// The rows a search palette shows, in order: the groups of a result, or the suggestions before anything is typed.
/// It also holds what the keys do: the arrows move one row across groups, Tab moves to the next group.
public struct SearchList: Sendable, Equatable {
    public enum Row: Sendable, Equatable, Identifiable {
        case hit(SearchHit)
        /// "N more in this meeting": expands the meeting's moments in place.
        case more(callID: String, count: Int)
        /// One of the owner's recent searches: runs it again.
        case recent(String)

        public var id: String {
            switch self {
            case .hit(let hit): hit.id
            case .more(let callID, _): "more:\(callID)"
            case .recent(let query): "recent:\(query)"
            }
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var group: SearchGroup
        public var rows: [Row]
    }

    public private(set) var sections: [Section]
    /// Every row's id in display order.
    public private(set) var rowIDs: [String]
    private var rows: [String: Row]
    private var resultCount: Int

    /// `expanded` holds every moment of the meetings whose "N more" row was opened.
    public init(results: SearchResults, expanded: [String: [MomentHit]] = [:]) {
        let topID = results.topHit?.id
        var moments: [Row] = []
        for group in results.moments {
            if let all = expanded[group.callID] {
                moments += all.map { SearchHit.moment($0) }.filter { $0.id != topID }.map(Row.hit)
            } else {
                moments += group.moments.map { Row.hit(.moment($0)) }
                if group.moreCount > 0 { moments.append(.more(callID: group.callID, count: group.moreCount)) }
            }
        }
        let all: [(SearchGroup, [Row])] = [
            (.topHit, results.topHit.map { [Row.hit($0)] } ?? []),
            (.meetings, results.meetings.map { .hit(.meeting($0)) }),
            (.people, results.people.map { .hit(.person($0)) }),
            (.moments, moments),
            (.decisionsAndActions, results.decisionsAndActions.map { .hit(.outcome($0)) }),
            (.bookmarks, results.bookmarks.map { .hit(.outcome($0)) }),
            (.tasks, results.tasks.map { .hit(.task($0)) }),
            (.chats, results.chats.map { .hit(.chat($0)) }),
        ]
        self.init(sections: all.filter { !$0.1.isEmpty }.map { Section(id: $0.0.rawValue, title: $0.0.title, group: $0.0, rows: $0.1) })
    }

    /// Before anything is typed: the owner's recent searches, then recent meetings and the people met most.
    public init(suggestions: SearchSuggestions, recent: [String] = []) {
        let all = [
            Section(id: "searches", title: "Recent searches", group: .topHit, rows: recent.map { .recent($0) }),
            Section(id: "recent", title: "Recent meetings", group: .meetings, rows: suggestions.meetings.map { .hit(.meeting($0)) }),
            Section(id: "frequent", title: "People you meet most", group: .people, rows: suggestions.people.map { .hit(.person($0)) }),
        ]
        self.init(sections: all.filter { !$0.rows.isEmpty })
    }

    private init(sections: [Section]) {
        self.sections = sections
        let flat = sections.flatMap(\.rows)
        rowIDs = flat.map(\.id)
        rows = Dictionary(flat.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        resultCount = flat.filter { if case .hit = $0 { true } else { false } }.count
    }

    public var first: String? { rowIDs.first }

    public func row(_ id: String) -> Row? { rows[id] }

    /// One row up or down, stopping at the ends. A selection no longer in the list starts at the first row.
    public func moved(_ from: String?, by step: Int) -> String? {
        guard let from, let i = rowIDs.firstIndex(of: from) else { return first }
        return rowIDs[min(max(i + step, 0), rowIDs.count - 1)]
    }

    /// The first row of the next group (or the previous one), wrapping around.
    public func nextSection(after id: String?, backward: Bool = false) -> String? {
        guard !sections.isEmpty else { return nil }
        guard let id, let current = sections.firstIndex(where: { $0.rows.contains { $0.id == id } }) else { return first }
        let n = sections.count
        return sections[((current + (backward ? -1 : 1)) % n + n) % n].rows.first?.id
    }

    /// For VoiceOver: "7 results", without the "N more" rows.
    public var announcement: String {
        switch resultCount {
        case 0: "No results"
        case 1: "1 result"
        default: "\(resultCount) results"
        }
    }
}
