import MossadCore
import SwiftUI

private struct PersonRoute: Hashable { let name: String }

/// Everyone you meet with: how often, how much they talk, what they owe, and what the coach notes about them.
struct PeopleScreen: View {
    @EnvironmentObject var store: PhoneStore
    @State private var stats: [String: PersonStats] = [:]
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(people, id: \.self) { name in
                NavigationLink(value: PersonRoute(name: name)) { PersonRow(name: name, stats: stats[name]!) }
            }
            .overlay {
                if stats.isEmpty { ContentUnavailableView("No people yet", systemImage: "person.2", description: Text("People appear once their voices are named on the Mac.")) }
            }
            .navigationTitle("People")
            .searchable(text: $query, prompt: "Name")
            .refreshable { await store.sync() }
            .navigationDestination(for: PersonRoute.self) { PersonView(name: $0.name, stats: stats[$0.name] ?? PersonStats()) }
            .navigationDestination(for: String.self) { id in
                if let r = store.meeting(id) { MeetingView(record: r) }
            }
            .task(id: store.meetings.count) {
                let records = store.meetings
                stats = await Task.detached(priority: .userInitiated) { PersonStatistics.compute(records) }.value
            }
        }
    }

    /// Named people only, most recent first, without the owner.
    private var people: [String] {
        stats.filter { name, _ in name != store.owner && !name.hasPrefix("Speaker ") && (query.isEmpty || name.localizedCaseInsensitiveContains(query)) }
            .sorted { ($0.value.lastHeard ?? .distantPast) > ($1.value.lastHeard ?? .distantPast) }
            .map(\.key)
    }
}

private struct Initials: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) * 37 } % 360) / 360, saturation: 0.45, brightness: 0.75).gradient, in: .circle)
    }
}

private struct PersonRow: View {
    let name: String
    let stats: PersonStats

    var body: some View {
        HStack(spacing: 12) {
            Initials(name: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text("\(stats.meetings.count) \(stats.meetings.count == 1 ? "meeting" : "meetings")" + (stats.lastHeard.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PersonView: View {
    @EnvironmentObject var store: PhoneStore
    let name: String
    let stats: PersonStats

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 10) {
                    Initials(name: name, size: 72)
                    Text(name).font(.title2.bold())
                    if let last = stats.lastHeard {
                        Text("Last met \(last.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatTile(value: "\(stats.meetings.count)", label: "Meetings")
                    StatTile(value: duration(stats.totalTalk), label: "Talking")
                    StatTile(value: stats.averageShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", label: "Share of the talking")
                    StatTile(value: "\(stats.actionItems.count)", label: "Action items")
                }
                if let note = store.profile.people[name]?.note {
                    Card {
                        CardTitle(text: "The coach's note", symbol: "person.wave.2")
                        Text(note)
                    }
                }
                if !stats.actionItems.isEmpty {
                    Card {
                        CardTitle(text: "Action items", symbol: "checklist")
                        ForEach(Array(stats.actionItems.prefix(8).enumerated()), id: \.offset) { _, a in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.item.task).font(.subheadline)
                                Text("\(a.meetingTitle) · \(a.start.formatted(.dateTime.month(.abbreviated).day()))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Card {
                    CardTitle(text: "Meetings", symbol: "calendar")
                    ForEach(stats.meetings.prefix(12), id: \.id) { m in
                        NavigationLink(value: m.id) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                    Text(m.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !stats.oftenWith.isEmpty {
                    Card {
                        CardTitle(text: "Often with", symbol: "person.3")
                        Text(stats.oftenWith.prefix(6).map { "\($0.name) (\($0.meetings))" }.joined(separator: ", ")).font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
