import MossadCore
import SwiftUI

struct PersonRoute: Hashable { let name: String }

/// Everyone you meet with, as the canvas lists them: you first, then the others by the last time you met, with
/// their mark, how often, and when. It opens from Analytics, inside that tab's navigation.
struct PeopleScreen: View {
    enum Sort: String, CaseIterable { case recent = "Most recent", mostMet = "Most met", name = "A to Z" }

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
                        HStack(spacing: 3) {
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
        case .name: return named.keys.sorted { $0.localizedCompare($1) == .orderedAscending }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).textRole(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(subtitle).textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
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

/// One person, as the canvas sets the profile: the mark and name, the coach's read first as prose, the numbers as
/// a row of figures, then the relationship, the meetings, and who they meet with.
struct PersonView: View {
    @Environment(PhoneStore.self) private var store
    let name: String
    let stats: PersonStats
    @State private var relation: PersonRelation?

    private var isOwner: Bool { name == store.owner }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s) {
                header
                // How to present to them, from the Mac's copy; the older read until the person has a card.
                if !isOwner, let read = store.persona(named: name), let card = read.card {
                    PersonaCardView(card: card, first: name.split(separator: " ").first.map(String.init) ?? name)
                    PersonaTraitsView(read: read, date: { id in store.meetings.first { $0.id == id }?.start })
                } else {
                    PersonBriefCard(name: name, brief: store.profile.people[name]?.brief, calls: stats.meetings.count)
                    if !isOwner, stats.meetings.count < PersonaCard.callsNeeded {
                        Text(PersonaCard.needsMore(first: name.split(separator: " ").first.map(String.init) ?? name, calls: stats.meetings.count))
                            .textRole(.secondary).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabelColumn(label: "By the numbers") { numbers }
                // What the owner confirmed on a card about this person. The iPhone has no people store: the label of
                // the coach's note, which the Mac keeps at the person's name of now, gives the person's id.
                let confirmed = isOwner ? [] : store.profile.learnings(named: name)
                if !confirmed.isEmpty {
                    LabelColumn(label: "You confirmed") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(confirmed) { fact in
                                Label { Text(fact.text).fixedSize(horizontal: false, vertical: true) } icon: {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.okText)
                                }
                                .textRole(.body).foregroundStyle(Palette.ink)
                            }
                        }
                    }
                }
                if let note = store.profile.people[name]?.note {
                    LabelColumn(label: "The coach’s note") {
                        Text(note).textRole(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !isOwner {
                    if let r = relation { PhoneRelation(relation: r) } else { PhoneProcessingMark().padding(.vertical, Space.xl) }
                }
                if !stats.actionItems.isEmpty {
                    Card {
                        CardTitle(text: "Action items")
                        ForEach(Array(stats.actionItems.prefix(8).enumerated()), id: \.offset) { _, a in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.item.task).textRole(.body).foregroundStyle(Palette.ink)
                                Text("\(a.meetingTitle) · \(a.start.formatted(.dateTime.month(.abbreviated).day()))")
                                    .textRole(.secondary).foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                }
                Card {
                    CardTitle(text: "Meetings")
                    VStack(spacing: 0) {
                        ForEach(Array(stats.meetings.prefix(12).enumerated()), id: \.element.id) { i, m in
                            NavigationLink(value: m.id) {
                                HairlineRow(divided: i < min(stats.meetings.count, 12) - 1) {
                                    HStack(alignment: .top, spacing: Space.m) {
                                        PlatformDot(platform: m.platform).padding(.top, 6).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.title).textRole(.headline).foregroundStyle(Palette.ink).lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            Text(m.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                                .textRole(.secondary).foregroundStyle(Palette.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(duration(m.talk)).textRole(.secondary).foregroundStyle(Palette.secondary)
                                            .accessibilityLabel("\(duration(m.talk)) talking")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !stats.oftenWith.isEmpty {
                    Card {
                        CardTitle(text: "Often with")
                        Text(stats.oftenWith.prefix(6).map { "\($0.name) (\($0.meetings))" }.joined(separator: ", "))
                            .textRole(.body).foregroundStyle(Palette.ink)
                    }
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xxl)
        }
        .phonePage()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("") } }
        .environment(\.openURL, OpenURLAction { url in
            guard let link = ChatLink.parse(url) else { return .systemAction }
            store.open(link)
            return .handled
        })
        .task(id: store.meetingsVersion) {
            guard name != store.owner else { return }
            let records = store.meetings, owner = store.owner, name = name, commitments = store.commitments.visible
            let reviews = Dictionary(uniqueKeysWithValues: records.filter { $0.speakerNames.values.contains(name) }.compactMap { r in store.coach(r.id).map { (r.id, $0) } })
            let people = store.paths.people
            let r = await Task.detached(priority: .userInitiated) {
                // By the person's id when the Mac sent its people: two people with one first name stay apart.
                let saved = PeopleStore.peek(in: people) ?? []
                let same = saved.filter { $0.isLive && $0.displayName == name }
                return PersonRelation(name: name, personID: PeopleStore.id(forVoiceName: name, isOwner: false, in: saved)?.rawValue, owner: owner,
                                      records: records, reviews: reviews, commitments: commitments, nameIsUnique: same.count <= 1)
            }.value
            withAnimation(.smooth) { relation = r }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            PersonMark(name: name, size: 52, isOwner: isOwner)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).textRole(.title).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(summary).textRole(.secondary).foregroundStyle(Palette.secondary)
            }
        }
        .padding(.top, Space.s)
    }

    /// "6 meetings · 2 h 6 min talking · last met today"
    private var summary: String {
        var parts = ["\(stats.meetings.count) \(stats.meetings.count == 1 ? "meeting" : "meetings")"]
        if stats.totalTalk > 0 { parts.append("\(duration(stats.totalTalk)) talking") }
        if let last = stats.lastHeard { parts.append("last met \(shortDay(last).lowercased())") }
        return parts.joined(separator: " · ")
    }

    private var numbers: some View {
        HStack(alignment: .top, spacing: Space.l) {
            figure("\(stats.meetings.count)", stats.meetings.count == 1 ? "meeting" : "meetings")
            figure(stats.totalTalk > 0 ? duration(stats.totalTalk) : "None", "talking")
            figure(stats.averageShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "talk share")
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).textRole(.title).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).textRole(.secondary).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A person's numbers in relation to the owner, for the phone: the same ones the Mac shows.
private struct PhoneRelation: View {
    let relation: PersonRelation

    private var first: String { relation.name.split(separator: " ").first.map(String.init) ?? relation.name }

    var body: some View {
        let r = relation
        LabelColumn(label: "Together") {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: "\(r.calls)", label: "Meetings together")
            StatTile(value: duration(r.seconds), label: "Time together")
            StatTile(value: r.averageGapDays.map { "\(max(1, Int($0.rounded()))) days" } ?? "–", label: "Between meetings")
            StatTile(value: r.usualSlot.map(slot) ?? "–", label: "Usual time")
        }
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
                        Image(systemName: c.done != nil ? "checkmark.circle.fill" : "circle").foregroundStyle(c.done != nil ? Palette.ok : Palette.secondary)
                    }
                }
            }
        }
        if !r.topics.isEmpty {
            Card {
                CardTitle(text: "Topics together", symbol: "number")
                Text(r.topics.map { "#\($0)" }.joined(separator: "  ")).font(.subheadline).foregroundStyle(Palette.accent)
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
                        Rectangle().fill(Palette.accentFill).frame(width: g.size.width * share)
                        Rectangle().fill(Palette.bar)
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
