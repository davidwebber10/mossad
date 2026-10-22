import MossadCore
import SwiftUI

struct MeetingsListView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                ForEach(MeetingGroups.group(store.meetings.filter { MeetingSearch.matches($0, query) }), id: \.kind) { group in
                    Section(group.kind.title) {
                        ForEach(group.records, id: \.id) { r in
                            NavigationLink(value: r.id) { MeetingRow(record: r) }
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
            .searchable(text: $query, prompt: "Titles, people, tags, transcripts")
            .refreshable { await store.sync() }
            .navigationDestination(for: String.self) { id in
                if let r = store.meetings.first(where: { $0.id == id }) { MeetingView(record: r) }
            }
        }
    }
}

private struct MeetingRow: View {
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(max(1, Int(record.end.timeIntervalSince(record.start) / 60))) min").font(.caption).foregroundStyle(.secondary)
            }
            Text(record.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                .font(.caption).foregroundStyle(.secondary)
            if let h = record.headline {
                Text(h).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if !record.tags.isEmpty {
                Text(record.tags.map { "#\($0)" }.joined(separator: "  ")).font(.caption2).foregroundStyle(.tint).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
