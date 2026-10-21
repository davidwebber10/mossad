import Foundation

public enum Tags {
    public static let knownLimit = 80

    /// Tags across meetings, most used first, each in its first spelling, for the summary prompt and the filters.
    public static func known(_ records: [CallRecord], limit: Int = knownLimit) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for tag in records.flatMap(\.tags) {
            counts[tag.lowercased(), default: (tag, 0)].count += 1
        }
        return counts.values.sorted { ($0.count, $1.name) > ($1.count, $0.name) }.prefix(limit).map(\.name)
    }
}

/// The meeting search: `#tag` matches a tag exactly; other text matches the title, tags, and transcript.
public enum MeetingSearch {
    public static func matches(_ r: CallRecord, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if q.hasPrefix("#") {
            let tag = q.dropFirst().trimmingCharacters(in: .whitespaces)
            return r.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        return r.title.localizedCaseInsensitiveContains(q) || r.tags.contains { $0.localizedCaseInsensitiveContains(q) }
            || r.utterances.contains { $0.text.localizedCaseInsensitiveContains(q) }
    }
}
