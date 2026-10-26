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

private struct PersonRow: View {
    let name: String
    let stats: PersonStats

    var body: some View {
        HStack(spacing: 12) {
            PersonMark(name: name, size: 40)
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
    @State private var relation: PersonRelation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 10) {
                    PersonMark(name: name, size: 72)
                    Text(name).font(.title2.bold())
                    if let last = stats.lastHeard {
                        Text("Last met \(last.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                if let r = relation {
                    PhoneRelation(relation: r)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
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
        .task(id: store.meetings.count) {
            let records = store.meetings, owner = store.owner, name = name, commitments = store.commitments.visible
            let reviews = Dictionary(uniqueKeysWithValues: records.filter { $0.speakerNames.values.contains(name) }.compactMap { r in store.coach(r.id).map { (r.id, $0) } })
            let r = await Task.detached(priority: .userInitiated) {
                PersonRelation(name: name, owner: owner, records: records, reviews: reviews, commitments: commitments)
            }.value
            withAnimation(.smooth) { relation = r }
        }
    }
}

/// A person's numbers in relation to the owner, for the phone: the same ones the Mac shows.
private struct PhoneRelation: View {
    let relation: PersonRelation

    private var first: String { relation.name.split(separator: " ").first.map(String.init) ?? relation.name }

    var body: some View {
        let r = relation
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: "\(r.calls)", label: "Meetings together")
            StatTile(value: duration(r.seconds), label: "Time together")
            StatTile(value: r.averageGapDays.map { "\(max(1, Int($0.rounded()))) days" } ?? "–", label: "Between meetings")
            StatTile(value: r.usualSlot.map(slot) ?? "–", label: "Usual time")
        }
        Card {
            CardTitle(text: "Talk balance", symbol: "person.2.wave.2")
            balance("One to one", r.oneOnOne)
            balance("In groups", r.group)
        }
        Card {
            CardTitle(text: "How you talk together", symbol: "bubble.left.and.bubble.right")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(first).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                row("Speaks first", "\(r.ownerFirst)", "\(r.theyFirst)")
                row("Questions an hour", rate(r.myQuestionsPerHour), rate(r.theirQuestionsPerHour))
                row("Cuts in an hour", rate(r.iInterruptPerHour), rate(r.theyInterruptPerHour))
                row("Usual reply", secs(r.myReply), secs(r.theirReply))
            }
            .font(.subheadline).monospacedDigit()
        }
        if !r.myCommitments.isEmpty {
            Card {
                CardTitle(text: "You promised \(first)", symbol: "checkmark.circle")
                ForEach(r.myCommitments.prefix(6)) { c in
                    Label {
                        Text(c.text).strikethrough(c.done != nil).font(.subheadline)
                    } icon: {
                        Image(systemName: c.done != nil ? "checkmark.circle.fill" : "circle").foregroundStyle(c.done != nil ? .green : .secondary)
                    }
                }
            }
        }
        if !r.topics.isEmpty {
            Card {
                CardTitle(text: "Topics together", symbol: "number")
                Text(r.topics.map { "#\($0)" }.joined(separator: "  ")).font(.subheadline).foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private func balance(_ label: String, _ b: PersonRelation.Balance?) -> some View {
        if let b, let share = b.share {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label).font(.subheadline.weight(.medium))
                    Spacer()
                    Text("You \(Int((share * 100).rounded()))% · \(first) \(Int(((1 - share) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    HStack(spacing: 1) {
                        Rectangle().fill(.tint).frame(width: g.size.width * share)
                        Rectangle().fill(Color.secondary.opacity(0.35))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 6)
            }
        }
    }

    private func row(_ label: String, _ a: String, _ b: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(a)
            Text(b)
        }
    }

    private func slot(_ s: PersonRelation.Slot) -> String {
        let day = Calendar.current.shortWeekdaySymbols[s.weekday - 1]
        let time = Calendar.current.date(bySettingHour: s.hour, minute: 0, second: 0, of: Date()).map { $0.formatted(.dateTime.hour()) } ?? ""
        return "\(day) \(time)"
    }

    private func rate(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
    private func secs(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f s", $0) } ?? "–" }
}
