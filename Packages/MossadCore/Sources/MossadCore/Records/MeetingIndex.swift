import Foundation

/// Reads call records for the Meetings view.
public struct MeetingIndex: Sendable {
    private let queue: ProcessingQueue

    public init(paths: Paths) {
        queue = ProcessingQueue(paths: paths)
    }

    public func all() -> [CallRecord] {
        queue.allRecords().reversed()
    }

    /// Case-insensitive match over the title and the transcript text; an empty query returns everything.
    public func search(_ query: String) -> [CallRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all() }
        return all().filter { r in
            r.title.localizedCaseInsensitiveContains(q) || r.utterances.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }
}
