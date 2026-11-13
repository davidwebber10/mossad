import MossadCore
import SwiftUI

/// One person, laid out as the Mac's page: the band with who they are and the numbers of the two of you, the tabs
/// under it, then the tab.
struct PersonView: View {
    enum Tab: String, CaseIterable { case overview = "Overview", meetings = "Meetings", tasks = "Tasks", analytics = "Analytics", knowledge = "Knowledge" }

    @Environment(PhoneStore.self) private var store
    let name: String
    let stats: PersonStats
    @State private var relation: PersonRelation?
    @State private var meetings: PersonMeetings?
    @State private var tab = Tab(rawValue: (PhoneStore.hook("MOSSAD_PERSON_TAB") ?? "").capitalized) ?? .overview
    @State private var query = ""

    private var isOwner: Bool { name == store.owner }
    private var first: String { name.split(separator: " ").first.map(String.init) ?? name }
    private var tabs: [Tab] { isOwner ? [.overview, .meetings, .tasks] : Tab.allCases }
    private var person: Person? {
        PeopleStore.id(forVoiceName: name, isOwner: isOwner, in: store.people).flatMap { id in store.people.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView(.horizontal, showsIndicators: false) {
                    DetailTabs(tab: $tab, tabs: tabs, accessibilityLabel: "Person tabs")
                        .padding(.horizontal, Space.l).padding(.vertical, 4)
                }
                // A fade at the right edge says that more tabs are there.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .offset(y: -Detail.underTabs - 4)
                .padding(.bottom, -Detail.underTabs)
                VStack(alignment: .leading, spacing: Space.s) { content }
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.s)
            }
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
        .task(id: store.meetingsVersion) { await load() }
    }

    // MARK: The band

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .top, spacing: Space.l) {
                PersonMark(name: name, size: 56, isOwner: isOwner)
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    Text(name).textRole(.title).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    // The job and the team from the Mac's directory; the photo stays on the Mac.
                    let role = [person?.directory?.jobTitle, person?.directory?.department].compactMap { $0 }.joined(separator: " · ")
                    if !role.isEmpty {
                        Text(role).textRole(.body).fontWeight(.medium).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(emails, id: \.self) { e in
                        Text(e).textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(1).textSelection(.enabled)
                    }
                }
            }
            let t = meetings?.together
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 14) {
                figure(t.map { "\($0.meetings)" } ?? "–", t.map { countLabel($0) } ?? "meetings")
                figure(t.map { $0.lastMet.map(shortDay) ?? ($0.meetings > 0 ? "Not known" : "Not yet") } ?? "–", isOwner ? "last meeting" : "last met")
                figure(t.map { $0.cadence.map(\.word) ?? "\($0.recent)" } ?? "–",
                       t.map { $0.cadence == nil ? "in the last 90 days" : "\($0.recent) in the last 90 days" } ?? "how often")
                figure(t.map { $0.seconds > 0 ? duration($0.seconds) : "None" } ?? "–", isOwner ? "in meetings" : "time together")
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.l)
        .padding(.bottom, Space.l + Detail.underTabs + 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.band)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// Every address the Mac sent for the person, the owner's first.
    private var emails: [String] {
        guard let person else { return [] }
        return person.emails.filter { $0.state != .rejected && !$0.shared }.map(\.address)
    }

    /// "meetings together" only when each one proves it, as on the Mac.
    private func countLabel(_ t: PersonMeetings.Together) -> String {
        let word = t.meetings == 1 ? "meeting" : "meetings"
        if isOwner { return word }
        if t.met == t.meetings, t.meetings > 0 { return word + " together" }
        var parts = [word]
        if t.invitedOnly > 0 { parts.append("\(t.invitedOnly) only invited") }
        let notes = t.meetings - t.met - t.invitedOnly
        if notes > 0 { parts.append("\(notes) from notes") }
        return parts.joined(separator: " · ")
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            Text(value).textRole(.title).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
            Text(label).textRole(.secondary).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: The tabs

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: overview
        case .meetings: meetingsList
        case .tasks: tasks
        case .analytics:
            if let r = relation { PhoneRelationAnalytics(relation: r) } else { PhoneProcessingMark().padding(.vertical, Space.xl) }
        case .knowledge: knowledge
        }
    }

    @ViewBuilder
    private var overview: some View {
        // How to present to them, from the Mac's copy; the older read until the person has a card.
        if !isOwner, let read = store.persona(named: name), let card = read.card {
            PersonaCardView(card: card, first: first, compact: true)
        } else if !isOwner {
            PersonBriefCard(name: name, brief: store.profile.people[name]?.brief, calls: stats.meetings.count)
        }
        LabelColumn(label: "By the numbers") {
            HStack(alignment: .top, spacing: Space.l) {
                figure(stats.totalTalk > 0 ? duration(stats.totalTalk) : "None", isOwner ? "talking" : "\(first) talking")
                figure(stats.averageShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "talk share")
                figure("\(stats.actionItems.count)", "action items")
            }
        }
        if let r = relation, r.calls > 0 {
            LabelColumn(label: "Together") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatTile(value: r.usualSlot.map(slot) ?? "–", label: "Usual time")
                    StatTile(value: r.oneOnOne?.share.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", label: "Your share one to one")
                }
            }
            if !r.topics.isEmpty {
                Card {
                    CardTitle(text: "Topics together", symbol: "number")
                    Text(r.topics.map { "#\($0)" }.joined(separator: "  ")).font(.subheadline).foregroundStyle(Palette.accent)
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

    @ViewBuilder
    private var meetingsList: some View {
        if let meetings, !meetings.rows.isEmpty {
            let rows = meetings.matching(query)
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                TextField("Search these meetings", text: $query).textRole(.body)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(Palette.fill, in: Capsule())
            if rows.isEmpty {
                Text("No meeting matches “\(query)”.").textRole(.secondary).foregroundStyle(Palette.secondary).padding(.top, Space.s)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                    NavigationLink(value: m.id) {
                        HairlineRow(divided: i < rows.count - 1) {
                            HStack(alignment: .top, spacing: Space.m) {
                                PlatformDot(platform: m.platform).padding(.top, 6).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                                    Text(m.title).textRole(.headline).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: Space.s) {
                                        Text(Calendar.current.isDate(m.start, equalTo: Date(), toGranularity: .year)
                                             ? m.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                             : m.start.formatted(.dateTime.month(.abbreviated).day().year()))
                                        if m.notesOnly { SourceMark(text: "Gemini notes") }
                                        if m.part == .invited, !isOwner { SourceMark(text: "Invited") }
                                    }
                                    .textRole(.secondary).foregroundStyle(Palette.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(duration(m.seconds)).textRole(.secondary).foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if meetings == nil {
            PhoneProcessingMark().padding(.vertical, Space.xl)
        } else {
            EmptyState(symbol: "calendar", title: "No meetings yet", message: "Meetings where \(first) speaks, or where the invite names \(first), show here.")
                .padding(.top, Space.xl)
        }
    }

    @ViewBuilder
    private var tasks: some View {
        let open = relation?.myCommitments.filter { $0.done == nil } ?? []
        let theirs = relation?.theirItems ?? [], mine = isOwner ? stats.actionItems.map { (task: $0.item.task, title: $0.meetingTitle, date: $0.start) }
            : (relation?.myItems ?? []).map { (task: $0.task, title: $0.title, date: $0.date) }
        if open.isEmpty, theirs.isEmpty, mine.isEmpty {
            EmptyState(symbol: "checklist", title: "No tasks", message: isOwner ? "Your action items show here." : "What you promise \(first), and what \(first) takes on, shows here.")
                .padding(.top, Space.xl)
        } else {
            if !open.isEmpty {
                Card {
                    CardTitle(text: "You promised \(first)", symbol: "checkmark.circle")
                    ForEach(open) { c in Label(c.text, systemImage: "circle").font(.subheadline) }
                }
            }
            if !theirs.isEmpty {
                Card {
                    CardTitle(text: "\(first) owes you", symbol: "arrow.down.circle")
                    ForEach(theirs) { item(item: $0.task, $0.title, $0.date) }
                }
            }
            if !mine.isEmpty {
                Card {
                    CardTitle(text: isOwner ? "Your action items" : "Yours from your 1:1s", symbol: "person.2")
                    ForEach(Array(mine.prefix(12).enumerated()), id: \.offset) { item(item: $0.element.task, $0.element.title, $0.element.date) }
                }
            }
        }
    }

    private func item(item task: String, _ title: String, _ date: Date) -> some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            Text(task).textRole(.body).foregroundStyle(Palette.ink)
            Text("\(title) · \(date.formatted(.dateTime.month(.abbreviated).day()))").textRole(.secondary).foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder
    private var knowledge: some View {
        // What the owner confirmed on a card about this person. The iPhone has no people store: the label of the
        // coach's note, which the Mac keeps at the person's name of now, gives the person's id.
        let confirmed = store.profile.learnings(named: name)
        let read = store.persona(named: name)
        if confirmed.isEmpty, read?.traits.isEmpty ?? true, store.profile.people[name]?.note == nil {
            EmptyState(symbol: "brain", title: "Nothing known yet", message: PersonaCard.needsMore(first: first, calls: stats.meetings.count))
                .padding(.top, Space.xl)
        } else {
            if !confirmed.isEmpty {
                LabelColumn(label: "You confirmed") {
                    VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                        ForEach(confirmed) { fact in
                            Label { Text(fact.text).fixedSize(horizontal: false, vertical: true) } icon: {
                                Image(systemName: "checkmark").font(.system(size: Rhythm.noteSize, weight: .semibold)).foregroundStyle(Palette.okText)
                            }
                            .textRole(.body).foregroundStyle(Palette.ink)
                        }
                    }
                }
            }
            if let read, !read.traits.isEmpty {
                PersonaTraitsView(read: read, date: { id in store.meetings.first { $0.id == id }?.start })
            }
            if let note = store.profile.people[name]?.note {
                LabelColumn(label: "The coach’s note") {
                    Text(note).textRole(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func slot(_ s: PersonRelation.Slot) -> String {
        let day = Calendar.current.shortWeekdaySymbols[s.weekday - 1]
        let time = Calendar.current.date(bySettingHour: s.hour, minute: 0, second: 0, of: Date()).map { $0.formatted(.dateTime.hour()) } ?? ""
        return "\(day) \(time)"
    }

    /// The relation and the meetings, off the main thread.
    private func load() async {
        let records = store.meetings, owner = store.owner, name = name, commitments = store.commitments.visible, saved = store.people, isOwner = isOwner
        let reviews = isOwner ? [:] : Dictionary(uniqueKeysWithValues: records.filter { $0.speakerNames.values.contains(name) }.compactMap { r in store.coach(r.id).map { (r.id, $0) } })
        let made = await Task.detached(priority: .userInitiated) { () -> (PersonRelation?, PersonMeetings) in
            let list = PersonMeetings(records: records, name: name, isOwner: isOwner, people: MeetingFilterPeople(people: saved, owner: owner))
            guard !isOwner else { return (nil, list) }
            // By the person's id when the Mac sent its people: two people with one first name stay apart.
            let same = saved.filter { $0.isLive && $0.displayName == name }
            let relation = PersonRelation(name: name, personID: PeopleStore.id(forVoiceName: name, isOwner: false, in: saved)?.rawValue, owner: owner,
                                          records: records, reviews: reviews, commitments: commitments, nameIsUnique: same.count <= 1)
            return (relation, list)
        }.value
        withAnimation(.smooth) {
            relation = made.0
            meetings = made.1
        }
    }
}

extension PersonMeetings.Cadence {
    var word: String {
        switch self {
        case .daily: "Daily"
        case .severalAWeek: "Several a week"
        case .weekly: "Weekly"
        case .everyOtherWeek: "Every 2 weeks"
        case .monthly: "Monthly"
        }
    }
}

/// How the two of you talk, for the phone: the same numbers the Mac's Analytics tab shows.
private struct PhoneRelationAnalytics: View {
    let relation: PersonRelation

    private var first: String { relation.name.split(separator: " ").first.map(String.init) ?? relation.name }

    var body: some View {
        let r = relation
        if r.calls == 0 {
            EmptyState(symbol: "chart.bar", title: "Nothing to measure yet", message: "After a recorded call where \(first) speaks, how the two of you talk shows here.")
                .padding(.top, Space.xl)
        } else {
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
        }
    }

    @ViewBuilder
    private func balance(_ label: String, _ b: PersonRelation.Balance?) -> some View {
        if let b, let share = b.share {
            VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                HStack {
                    Text(label).font(.subheadline.weight(.medium))
                    Spacer()
                    Text("You \(Int((share * 100).rounded()))% · \(first) \(Int(((1 - share) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    HStack(spacing: Space.xs) {
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

    private func rate(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
    private func secs(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f s", $0) } ?? "–" }
}
