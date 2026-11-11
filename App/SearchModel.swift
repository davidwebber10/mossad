import Foundation
import MossadCore
import SwiftUI

/// The search palette's index and its open state. The index is built and updated off the main actor; until a
/// rebuild finishes, queries run on the index from before, so typing never waits for it.
@MainActor
final class SearchModel: ObservableObject {
    @Published var isOpen = false
    @Published var query = ""
    @Published private(set) var list = SearchList(results: .empty)
    @Published private(set) var suggestions = SearchSuggestions.empty
    /// The query `list` answers, so a stale answer is never shown for a newer query.
    @Published private(set) var answered = ""
    /// Each meeting whose "N more" row was opened, with all its moments.
    @Published private(set) var expanded: [String: [MomentHit]] = [:]
    @Published private(set) var isReady = false

    private var index = SearchIndex()
    private var results = SearchResults.empty
    /// The records the index holds, to find what changed.
    private var indexed: [String: CallRecord] = [:]
    private var updating: Task<Void, Never>?
    private var pending: Snapshot?
    private var searching: Task<Void, Never>?

    struct Snapshot: Sendable {
        let records: [CallRecord]
        let library: VoiceLibrary
        let paths: Paths
    }

    /// Takes in what changed. Calls that arrive while an update runs are folded into one more update after it.
    func update(_ snapshot: Snapshot) {
        guard updating == nil else { pending = snapshot; return }
        let base = index, old = indexed, fresh = !isReady
        updating = Task(priority: .utility) {
            let (next, records) = await Self.apply(snapshot, to: base, old: old, fresh: fresh)
            index = next
            indexed = records
            isReady = true
            suggestions = next.suggestions()
            updating = nil
            if !query.isEmpty { search() }
            if let again = pending {
                pending = nil
                update(again)
            }
        }
    }

    @concurrent
    nonisolated private static func apply(_ s: Snapshot, to base: SearchIndex, old: [String: CallRecord], fresh: Bool)
        async -> (SearchIndex, [String: CallRecord]) {
        let tasks = ((try? CommitmentBook.load(from: s.paths.commitments)) ?? CommitmentBook()).items
        let chats = ChatStore(directory: s.paths.chats).all()
        let records = Dictionary(s.records.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        // One by one costs more than a fresh build once many meetings change, as at launch.
        let changed = records.filter { old[$0.key] != $0.value }.count + old.keys.filter { records[$0] == nil }.count
        if fresh || changed > 20 {
            var index = SearchIndex(records: s.records, people: s.library.profiles, tasks: tasks, chats: chats)
            index.setOtherNames(s.library.identity?.people.people ?? [])
            return (index, records)
        }
        var index = base
        for (id, r) in records where old[id] != r { index.update(r) }
        for id in old.keys where records[id] == nil { index.removeMeeting(id: id) }
        index.setPeople(s.library.profiles)
        index.setOtherNames(s.library.identity?.people.people ?? [])
        index.setTasks(tasks)
        index.setChats(chats)
        return (index, records)
    }

    /// Runs the query on the newest index, off the main actor; the last answer stays until the new one arrives.
    func search() {
        searching?.cancel()
        let text = query, index = index
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = .empty
            expanded = [:]
            answered = ""
            list = SearchList(results: .empty)
            return
        }
        searching = Task {
            let found = await Self.run(text, on: index)
            guard !Task.isCancelled, text == query else { return }
            if answered != text { expanded = [:] }
            results = found
            answered = text
            list = SearchList(results: found, expanded: expanded)
        }
    }

    @concurrent
    nonisolated private static func run(_ text: String, on index: SearchIndex) async -> SearchResults { index.search(text) }

    func expand(_ callID: String) {
        expanded[callID] = index.moments(in: callID, matching: answered)
        list = SearchList(results: results, expanded: expanded)
    }

    /// The suggestions as rows, for the empty query.
    var suggestionList: SearchList { SearchList(suggestions: suggestions) }
}
