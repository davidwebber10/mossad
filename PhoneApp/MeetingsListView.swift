import MossadCore
import SwiftUI

struct MeetingsListView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var showActions = false
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.red)
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(MeetingGroups.group(store.meetings), id: \.kind) { group in
                        Section(group.kind.title) {
                            ForEach(group.records, id: \.id) { r in
                                NavigationLink(value: r.id) { MeetingRow(record: r, score: store.scores[r.id]) }
                            }
                        }
                    }
                } else {
                    ForEach(results, id: \.id) { r in
                        NavigationLink(value: r.id) { MeetingRow(record: r, score: store.scores[r.id]) }
                    }
                }
            }
            .overlay {
                if store.meetings.isEmpty {
                    ContentUnavailableView(store.syncing ? "Syncing…" : "No meetings yet", systemImage: "icloud",
                                           description: Text("Meetings appear here after Mossad on your Mac writes their notes."))
                } else if !query.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $query, prompt: "Titles, people, tags, transcripts")
            .searchSuggestions {
                if query.isEmpty {
                    ForEach(SearchSuggestions.tags(store.meetings).prefix(6), id: \.self) { Label($0, systemImage: "number").searchCompletion("#" + $0) }
                    ForEach(SearchSuggestions.people(store.meetings, owner: store.owner).prefix(5), id: \.self) { Label($0, systemImage: "person").searchCompletion($0) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Action items", systemImage: "checklist") { showActions = true }
                }
            }
            .refreshable { await store.sync() }
            .navigationDestination(isPresented: $showActions) { ActionItemsView() }
            .navigationDestination(for: String.self) { id in
                if let r = store.meeting(id) { MeetingView(record: r, find: query) }
            }
        }
    }

    private var results: [CallRecord] { store.meetings.filter { MeetingSearch.matches($0, query) } }
}

enum SearchSuggestions {
    /// Most used first.
    static func tags(_ meetings: [CallRecord]) -> [String] {
        var counts: [String: Int] = [:]
        for r in meetings { for t in r.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// The people met most often, without the owner.
    static func people(_ meetings: [CallRecord], owner: String) -> [String] {
        var counts: [String: Int] = [:]
        for r in meetings { for n in Set(r.speakerNames.values) where n != owner && !n.hasPrefix("Speaker") { counts[n, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
}
