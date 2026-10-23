import MossadCore
import SwiftUI

struct MeetingsListView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var showActions = false

    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.red)
                }
                ForEach(MeetingGroups.group(store.meetings), id: \.kind) { group in
                    Section(group.kind.title) {
                        ForEach(group.records, id: \.id) { r in
                            NavigationLink(value: r.id) { MeetingRow(record: r, score: store.scores[r.id]) }
                        }
                    }
                }
            }
            .overlay {
                if store.meetings.isEmpty {
                    ContentUnavailableView(store.syncing ? "Syncing…" : "No meetings yet", systemImage: "icloud",
                                           description: Text("Meetings appear here after Mossad on your Mac writes their notes."))
                }
            }
            .navigationTitle("Meetings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Action items", systemImage: "checklist") { showActions = true }
                }
            }
            .refreshable { await store.sync() }
            .navigationDestination(isPresented: $showActions) { ActionItemsView() }
            .navigationDestination(for: String.self) { id in
                if let r = store.meeting(id) { MeetingView(record: r) }
            }
        }
    }
}

/// The search tab: titles, people, tags, and transcript text. Tags and people are one tap away before typing.
struct SearchScreen: View {
    @EnvironmentObject var store: PhoneStore
    @State private var query = ""
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !tags.isEmpty {
                        Section("Tags") {
                            ForEach(tags.prefix(12), id: \.self) { tag in
                                Button { query = "#\(tag)" } label: { Label(tag, systemImage: "number") }
                            }
                        }
                    }
                    if !people.isEmpty {
                        Section("People") {
                            ForEach(people.prefix(8), id: \.self) { name in
                                Button { query = name } label: { Label(name, systemImage: "person") }
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
                if !query.isEmpty && results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Titles, people, tags, transcripts")
            .navigationDestination(for: String.self) { id in
                if let r = store.meeting(id) { MeetingView(record: r, find: query) }
            }
        }
    }

    private var results: [CallRecord] { store.meetings.filter { MeetingSearch.matches($0, query) } }

    /// Most used first.
    private var tags: [String] {
        var counts: [String: Int] = [:]
        for r in store.meetings { for t in r.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// The people met most often, without the owner.
    private var people: [String] {
        var counts: [String: Int] = [:]
        for r in store.meetings { for n in Set(r.speakerNames.values) where n != store.owner && !n.hasPrefix("Speaker") { counts[n, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
}
