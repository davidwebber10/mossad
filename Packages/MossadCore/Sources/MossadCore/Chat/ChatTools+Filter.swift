import Foundation

/// The Meetings filter's choices as `find_meetings` takes them, matched by the filter's own rule
/// (`MeetingFilterRow`, `MeetingFacets`): a meeting whose number is not known matches no choice of its group.
struct MeetingFilterInput {
    static let sizes: [(String, MeetingFilter.Size)] = [("just_me", .alone), ("one_on_one", .oneOnOne), ("small", .small), ("large", .large), ("not_known", .unknown)]
    static let ratings: [(String, MeetingFilter.Value)] = [("high", .high), ("medium", .medium), ("low", .low), ("not_rated", .notRated)]
    static let lengths: [(String, MeetingFilter.Length)] = [("under_15", .under15), ("15_to_30", .to30), ("30_to_60", .to60), ("over_60", .over60)]
    static let flags: [(String, MeetingFilter.Flag)] = [("action_items", .actionItems), ("decisions", .decisions), ("screens", .screens)]

    var filter = MeetingFilter()

    init(_ input: [String: Any]) {
        func pick<T>(_ key: String, _ table: [(String, T)]) -> [T] {
            (input[key] as? [String] ?? (input[key] as? String).map { [$0] } ?? []).compactMap { v in table.first { $0.0 == v }?.1 }
        }
        filter.sizes = Set(pick("size", Self.sizes))
        filter.values = Set(pick("rating", Self.ratings))
        filter.lengths = Set(pick("length", Self.lengths))
        filter.flags = Set(pick("has", Self.flags))
        filter.platforms = Set(pick("platform", Platform.allCases.map { ($0.rawValue, $0) }))
        if let kind = (input["kind"] as? String)?.nonBlank { filter.kinds = [kind] }
    }

    var isEmpty: Bool { filter.isEmpty }
}

extension ChatTools {
    /// The meetings that the words, people, and dates find, narrowed by the filter's choices, with the counts of
    /// each choice when asked.
    func filtered(_ choices: MeetingFilterInput, input: [String: Any], people: [String], from: Date?, to: Date?, limit: Int) -> String {
        let base = matching(query: input["query"] as? String, people: people, from: from, to: to, tag: input["tag"] as? String)
        let ratings = paths.map { p in MeetingRatings().read(ids: base.map(\.id), directory: p.callDirectory) } ?? [:]
        let rows = MeetingFilterRows().rows(for: base, people: filterPeople, ratings: ratings)
        let facets = MeetingFacets(rows: rows, filter: choices.filter, within: Set(base.map(\.id)), now: now)
        let found = base.filter { facets.matches.contains($0.id) }
        var out = found.isEmpty ? "No meetings match." : found.prefix(min(limit, Self.maxLimit)).map(header).joined(separator: "\n")
        if input["facets"] as? Bool == true {
            func tally<K>(_ name: String, _ table: [(String, K)], _ t: MeetingTally<K>) -> String? {
                let parts = table.compactMap { label, key in t.count(key) > 0 ? "\(label) \(t.count(key))" : nil }
                return parts.isEmpty ? nil : "\(name): " + parts.joined(separator: ", ")
            }
            let groups = [
                tally("size", MeetingFilterInput.sizes, facets.sizes),
                tally("platform", Platform.allCases.map { ($0.rawValue, $0) }, facets.platforms),
                tally("rating", MeetingFilterInput.ratings, facets.values),
                tally("length", MeetingFilterInput.lengths, facets.lengths),
                tally("has", MeetingFilterInput.flags, facets.flags),
                facets.kinds.isEmpty ? nil : "kind: " + facets.kinds.prefix(12).map { "\($0.name) \($0.count)" }.joined(separator: ", "),
                facets.tags.isEmpty ? nil : "tags: " + facets.tags.prefix(12).map { "\($0.name) \($0.count)" }.joined(separator: ", "),
            ].compactMap { $0 }
            out += "\n\nOf \(found.count) matching meetings, by the Meetings filter's choices:\n" + groups.joined(separator: "\n")
        }
        return out
    }

    /// Under a meeting's Summary: the owner's points it discussed, the ones it carried, and the open ones that
    /// came up in a meeting Mossad has only the notes of.
    func meetingPoints(_ callID: String) -> String? {
        guard let book else { return nil }
        let discussed = book.discussed(in: callID)
        let carried = book.visible.filter { $0.isOpen && ($0.carried ?? []).contains(callID) }
        let mentioned = book.mentioned(in: callID)
        var parts: [String] = []
        if !discussed.isEmpty { parts.append("Your points discussed here:\n" + discussed.map(pointLine).joined(separator: "\n")) }
        if !carried.isEmpty { parts.append("Your points left for next time:\n" + carried.map(pointLine).joined(separator: "\n")) }
        if !mentioned.isEmpty { parts.append("Your open points in these notes:\n" + mentioned.map(pointLine).joined(separator: "\n")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
