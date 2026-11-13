import MossadCore
import SwiftUI

struct PersonRoute: Hashable { let name: String }

/// Everyone you meet with, as the canvas lists them: you first, then the others by the last time you met, with
/// their mark, how often, and when. It opens from Analytics, inside that tab's navigation.
struct PeopleScreen: View {
    enum Sort: String, CaseIterable { case recent = "Most recent", mostMet = "Most met", firstName = "First name", lastName = "Last name" }

    @Environment(PhoneStore.self) private var store
    @State private var query = ""
    @AppStorage("peopleSort") private var sort = Sort.recent
    /// The stack it sits in, for the profile hook.
    @Binding var path: NavigationPath
    @State private var opened = false

    private var stats: [String: PersonStats] { store.personStats }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.isEmpty, let me = stats[store.owner] {
                    PhoneLabel("You").padding(.top, Space.l)
                    NavigationLink(value: PersonRoute(name: store.owner)) {
                        PersonRow(name: store.owner, stats: me, isOwner: true, divided: false)
                    }
                    .buttonStyle(.plain)
                }
                HStack(alignment: .firstTextBaseline) {
                    PhoneLabel("People · \(people.count)")
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) }
                        }
                    } label: {
                        HStack(spacing: Space.xs) {
                            Text(sort.rawValue)
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }
                        .textRole(.secondary)
                        .foregroundStyle(Palette.secondary)
                        .fixedSize()
                    }
                    .accessibilityLabel("Sort, \(sort.rawValue)")
                }
                .padding(.top, Space.xl)
                ForEach(Array(people.enumerated()), id: \.element) { i, name in
                    NavigationLink(value: PersonRoute(name: name)) {
                        PersonRow(name: name, stats: stats[name]!, divided: i < people.count - 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
        }
        .overlay {
            if stats.isEmpty {
                EmptyState(symbol: "person.2", title: "No people yet", message: "People appear once their voices are named on the Mac.")
            }
        }
        .phonePage()
        .navigationTitle("People")
        .searchable(text: $query, prompt: "Name")
        .refreshable { await store.sync() }
        .navigationDestination(for: PersonRoute.self) { PersonView(name: $0.name, stats: stats[$0.name] ?? PersonStats()) }
        .task(id: stats.count) {
            // Development hook for screenshots: `MOSSAD_PERSON=<name>` opens a profile.
            if let name = PhoneStore.hook("MOSSAD_PERSON"), stats[name] != nil, !opened {
                opened = true
                path.append(PersonRoute(name: name))
            }
        }
    }

    /// Named people only, without the owner.
    private var people: [String] {
        let named = stats.filter { name, _ in name != store.owner && !name.hasPrefix("Speaker ") && (query.isEmpty || name.localizedCaseInsensitiveContains(query)) }
        switch sort {
        case .recent: return named.sorted { ($0.value.lastHeard ?? .distantPast) > ($1.value.lastHeard ?? .distantPast) }.map(\.key)
        case .mostMet:
            return named.sorted { $0.value.meetings.count == $1.value.meetings.count ? $0.key < $1.key : $0.value.meetings.count > $1.value.meetings.count }
                .map(\.key)
        case .firstName: return named.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case .lastName:
            return named.keys.sorted { a, b in
                let c = PeopleSort.lastName(a).localizedStandardCompare(PeopleSort.lastName(b))
                return c == .orderedSame ? a.localizedStandardCompare(b) == .orderedAscending : c == .orderedAscending
            }
        }
    }
}

/// "Today", "Yesterday", or "Oct 26".
func shortDay(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

private struct PersonRow: View {
    let name: String
    let stats: PersonStats
    var isOwner = false
    var divided = true

    var body: some View {
        HairlineRow(divided: divided) {
            HStack(spacing: Space.m) {
                PersonMark(name: name, size: 36, isOwner: isOwner)
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    Text(name).textRole(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(subtitle).textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Rhythm.pairGap) {
                    if !isOwner { Text(meetingsText) }
                    if let last = stats.lastHeard { Text(shortDay(last)) }
                }
                .textRole(.secondary)
                .foregroundStyle(Palette.secondary)
                .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var meetingsText: String { "\(stats.meetings.count) \(stats.meetings.count == 1 ? "meeting" : "meetings")" }

    /// The owner: how much they met; anyone else: the last meeting together.
    private var subtitle: String {
        if isOwner { return "\(meetingsText) · \(duration(stats.totalTalk))" }
        return stats.meetings.first?.title ?? ""
    }
}
