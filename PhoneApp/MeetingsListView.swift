import MossadCore
import SwiftUI

struct MeetingsListView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var showActions = false
    @State private var recording = false

    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.red)
                }
                if !store.outbox.isEmpty {
                    Section("Recorded on this iPhone") {
                        ForEach(store.outbox) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "mic.fill").font(.footnote).foregroundStyle(.orange)
                                    .frame(width: 30, height: 30).background(Color.orange.opacity(0.14), in: .rect(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.recording.title ?? "In-person meeting").font(.body.weight(.medium))
                                    Text("\(item.recording.start.formatted(.dateTime.hour().minute())) · \(Int(item.recording.end.timeIntervalSince(item.recording.start) / 60)) min · "
                                         + (item.sent ? "Your Mac is writing the notes" : "Waiting to send"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !item.sent { ProgressView() }
                            }
                        }
                    }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Record", systemImage: "mic.fill") { recording = true }
                        .tint(.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Action items", systemImage: "checklist") { showActions = true }
                }
            }
            .fullScreenCover(isPresented: $recording) { RecordingView() }
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
                    let tags = SearchSuggestions.tags(store.meetings), people = SearchSuggestions.people(store.meetings, owner: store.owner)
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
