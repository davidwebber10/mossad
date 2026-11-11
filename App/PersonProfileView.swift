import MossadCore
import SwiftUI

/// One person's page in the label column: the coach's read first, as prose, then the numbers as one typographic
/// row, then talk time, who they meet with, and (for anyone but the owner) the relationship.
struct PersonProfileView: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let stats: PersonStats
    /// Where the org chart places them, when it does.
    let org: OrgChart.Match?
    let chart: OrgChart?
    let others: [VoiceProfile]
    let rename: () -> Void
    let merge: (VoiceProfile) -> Void
    let delete: () -> Void
    let select: (String) -> Void

    @State private var relation: PersonRelation?
    @State private var refreshing = false

    private var first: String { profile.name.split(separator: " ").first.map(String.init) ?? profile.name }
    /// By the person's id when the people store has one, so the read stays with the person through a new name.
    private var brief: PersonBrief? { controller.shownCoachProfile.note(on: profile.name, people: controller.shownCoachPeople)?.value.brief }

    /// How the person thinks: shown traits and the card, built by code. Nil for the owner and until a trait shows.
    private var read: PersonaSummary? { profile.isOwner ? nil : controller.persona(of: profile.name) }
    private var personID: String? { controller.personID(of: profile.name) }
    private var keepsRead: Bool { controller.keepsRead(profile.name) }

    /// What the owner confirmed about this person on a card, by the person's id; by the label of the coach's
    /// note when the people store is off.
    private var confirmed: [CoachFact] {
        let coach = controller.shownCoachProfile, saved = controller.shownCoachPeople
        let byID = saved.id(of: profile.name).map { coach.learnings(about: $0, people: saved) } ?? []
        return byID.isEmpty ? coach.learnings(named: profile.name) : byID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                LabelColumnStack(spacing: 18) {
                    if !profile.isOwner, (read != nil || brief != nil), controller.personaCovered(personID) {
                        // A colleague must not read this on a shared screen.
                        LabelColumn(label: "The coach’s read") { PersonaCoverRow { controller.uncover(personID) } }
                    } else if let read, let card = read.card {
                        // The card replaces the older read.
                        PersonaCardView(card: card, first: first)
                        PersonaTraitsView(read: read, date: { id in controller.meetings.first { $0.id == id }?.start })
                    } else {
                        coachRead
                        if let brief {
                            ForEach(brief.sections, id: \.title) { section in
                                LabelColumn(label: section.title) { prose(section.points) }
                            }
                        }
                        if let read, !read.traits.isEmpty {
                            PersonaTraitsView(read: read, date: { id in controller.meetings.first { $0.id == id }?.start })
                        }
                    }
                    if !profile.isOwner, !confirmed.isEmpty {
                        LabelColumn(label: "You confirmed") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(confirmed) { fact in
                                    Label { Text(fact.text).fixedSize(horizontal: false, vertical: true) } icon: {
                                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.okText)
                                    }
                                    .font(.system(size: 13)).foregroundStyle(Palette.ink)
                                }
                                Button("All the coach knows") { controller.open(coach: .knowledge) }
                                    .buttonStyle(SettingsTextButtonStyle(color: Palette.accent))
                                    .padding(.top, 2)
                            }
                        }
                    }
                    LabelColumn(label: "By the numbers") { numbers }
                    if !profile.isOwner, let relation {
                        RelationSections(relation: relation, owner: controller.ownerName, color: PersonMark.color(for: profile.name))
                    }
                    if !stats.meetings.isEmpty {
                        LabelColumn(label: "Talk time by meeting") { talkByMeeting }
                    }
                    if !stats.oftenWith.isEmpty {
                        LabelColumn(label: "Often with") { oftenWith }
                    }
                    if profile.isOwner, !stats.actionItems.isEmpty {
                        LabelColumn(label: "Action items") { actionItems }
                    }
                    LabelColumn(label: "Meetings") { meetings }
                }
            }
            .frame(maxWidth: Detail.listMax, alignment: .leading)
            .padding(.horizontal, Detail.gutter).padding(.top, Detail.bodyTop).padding(.bottom, Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, OpenURLAction { url in controller.openLink(url) ? .handled : .systemAction })
        .task(id: "\(profile.name)-\(controller.meetings.count)-\(controller.commitmentsVersion)") { await loadRelation() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            PersonMark(name: profile.name, size: 44, isOwner: profile.isOwner)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.s) {
                    Text(profile.name)
                        .font(.system(size: 26, weight: .semibold)).tracking(-0.52)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if profile.isOwner {
                        Text("You").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(Palette.fill, in: Capsule())
                    }
                }
                if let role = roleLine {
                    Text(role).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                }
                Text(summaryLine).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).textSelection(.enabled)
            }
            Spacer()
            Menu {
                Button(action: rename) { Label { Text("Edit name and email…") } icon: { Icon.pencil.image } }
                Menu {
                    ForEach(others, id: \.name) { target in Button(target.name) { merge(target) } }
                } label: {
                    Label { Text("Merge into") } icon: { Icon.merge.image }
                }
                .disabled(profile.isOwner || others.isEmpty)
                if !profile.isOwner, personID != nil, controller.personasOn {
                    Toggle("Keep a read on \(first)", isOn: Binding(get: { keepsRead }, set: { controller.setKeepsRead(profile.name, $0) }))
                }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive, action: delete).disabled(profile.isOwner)
            } label: {
                IconImage(.more, size: 15).accessibilityLabel("Actions for \(profile.name)")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .fixedSize()
        }
    }

    /// "VP, Planning · reports to Sam Park", from the org chart.
    private var roleLine: String? {
        guard let org else { return nil }
        var parts: [String] = []
        if !org.person.title.isEmpty { parts.append(org.person.title) }
        if let manager = chart?.manager(of: org.person.id) { parts.append("reports to \(manager.fullName)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "jo@example.com · Since Mar 2026 · 14 meetings · 3 h 33 min talking · 6 voice samples"
    private var summaryLine: String {
        var parts: [String] = []
        if let email = profile.email { parts.append(email) }
        if let first = stats.firstHeard { parts.append("Since " + first.formatted(.dateTime.month(.abbreviated).year())) }
        parts.append(meetingsText(stats.meetings.count))
        if stats.totalTalk > 0 { parts.append("\(talkText(stats.totalTalk)) talking") }
        parts.append("\(profile.embeddings.count) voice \(profile.embeddings.count == 1 ? "sample" : "samples")")
        return parts.joined(separator: " · ")
    }

    // MARK: The coach's read

    private var coachRead: some View {
        LabelColumn(label: "The coach’s read") {
            VStack(alignment: .leading, spacing: 4) {
                if let brief {
                    Text(brief.headline)
                        .font(.system(size: 16, weight: .medium)).lineSpacing(3)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text("From \(brief.calls) \(brief.calls == 1 ? "call" : "calls") · updated \(brief.updated.formatted(.relative(presentation: .named)))")
                        refreshButton
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                } else {
                    Text(stats.meetings.count >= 2
                         ? "The coach has not read the calls with \(first) yet."
                         : "After two calls with \(first), the coach writes how to work with them: their goals, how to get through to them, and how they communicate.")
                        .font(.system(size: 13)).lineSpacing(2)
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: 680, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if stats.meetings.count >= 2 { refreshButton.font(.system(size: 12)) }
                }
                readState
            }
        }
    }

    /// Where the read of how they think stands: the count is true to the show rule.
    @ViewBuilder
    private var readState: some View {
        if !profile.isOwner, controller.personasOn, personID != nil {
            if !keepsRead {
                HStack(spacing: 6) {
                    Text("You keep no read on \(first).")
                    Button("Keep a read") { controller.setKeepsRead(profile.name, true) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 4)
            } else if read?.card == nil, read?.traits.isEmpty ?? true {
                Text(PersonaCard.needsMore(first: first, calls: stats.meetings.count))
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if stats.meetings.count >= 2 {
            if refreshing {
                Text("Reading…").foregroundStyle(Palette.tertiary)
            } else {
                Button(brief == nil ? "Read the calls now" : "Read again") {
                    refreshing = true
                    Task {
                        await controller.writePersonBriefs([profile.name])
                        refreshing = false
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .help("Read the calls with \(first) again")
            }
        }
    }

    /// The section's points as one paragraph; a point from a call ends in a quiet link that opens it.
    private func prose(_ points: [PersonBrief.Point]) -> some View {
        var text = AttributedString()
        for (i, point) in points.enumerated() {
            if i > 0 { text += AttributedString(" ") }
            text += AttributedString(point.text)
            if let id = point.callID, let url = URL(string: "mossad://call/\(id)") {
                var link = AttributedString(" ↗")
                link.link = url
                link.foregroundColor = Palette.tertiary
                text += link
            }
        }
        return Text(text)
            .font(.system(size: 13)).lineSpacing(3)
            .foregroundStyle(Palette.ink)
            .tint(Palette.tertiary)
            .frame(maxWidth: 680, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: Numbers

    private var numbers: some View {
        FigureRow(figures: [
            (stats.meetings.count.formatted(), "meetings"),
            (stats.totalTalk > 0 ? talkText(stats.totalTalk) : "None", "total talk time"),
            (stats.averageShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "None", "average talk share"),
            ("\(stats.actionItems.count)", "action items"),
        ])
    }

    private var talkByMeeting: some View {
        let shown = Array(stats.meetings.prefix(8))
        let longest = max(shown.map(\.talk).max() ?? 0, 1)
        let hue = profile.isOwner ? Palette.speaker(0) : PersonMark.color(for: profile.name)
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: Space.s) {
            ForEach(shown, id: \.id) { m in
                GridRow {
                    Button { controller.openMeeting(m.id) } label: {
                        Text(m.title).lineLimit(1).foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("\(m.title), \(dayWord(m.start))")
                    Capsule().fill(Palette.fill)
                        .frame(width: 220, height: 8)
                        .overlay(alignment: .leading) {
                            Capsule().fill(hue).frame(width: max(4, 220 * m.talk / longest))
                        }
                        .accessibilityHidden(true)
                    Text(talkText(m.talk)).foregroundStyle(Palette.secondary).monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: 680, alignment: .leading)
    }

    /// "Dana Lee 5 · Sam Park 4": names in ink as buttons, the counts quiet.
    private var oftenWith: some View {
        FlowLayout(spacing: 0) {
            ForEach(Array(stats.oftenWith.prefix(8).enumerated()), id: \.element.name) { i, co in
                HStack(spacing: 0) {
                    if i > 0 { Text(" · ").foregroundStyle(Palette.secondary) }
                    Button(co.name) { select(co.name) }.buttonStyle(.plain).foregroundStyle(Palette.ink)
                    Text(" \(co.meetings)").foregroundStyle(Palette.secondary).monospacedDigit()
                }
            }
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: 680, alignment: .leading)
    }

    private var actionItems: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stats.actionItems.prefix(12).enumerated()), id: \.offset) { i, a in
                Button { controller.openMeeting(a.meetingID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.item.task).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                        Text("\(a.meetingTitle) · \(dayWord(a.start))").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < min(stats.actionItems.count, 12) - 1 { Hairline() }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: 680, alignment: .leading)
    }

    private var meetings: some View {
        VStack(alignment: .leading, spacing: 0) {
            if stats.meetings.isEmpty {
                Text("No meetings yet.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            ForEach(Array(stats.meetings.enumerated()), id: \.element.id) { i, m in
                Button { controller.openMeeting(m.id) } label: {
                    HStack(spacing: Space.s) {
                        PlatformDot(platform: m.platform)
                        Text(m.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(dayWord(m.start)).frame(width: 90, alignment: .trailing)
                        Text(talkText(m.talk)).frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(Palette.secondary)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < stats.meetings.count - 1 { Hairline() }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private func loadRelation() async {
        guard !profile.isOwner else { return }
        let name = profile.name, owner = controller.ownerName, records = controller.meetings, paths = controller.paths
        let commitments = controller.commitmentBook.visible
        let people = controller.library.identity?.people.people ?? []
        let r = await Task.detached(priority: .userInitiated) {
            // By the person's id where the people store has it: two people with one name or one first name stay apart.
            let same = people.filter { $0.isLive && $0.displayName == name }
            let personID = PeopleStore.id(forVoiceName: name, isOwner: false, in: people)?.rawValue
            let shared = records.filter { $0.speakerNames.values.contains(name) }
            let reviews = Dictionary(uniqueKeysWithValues: shared.compactMap { r in CoachReview.load(in: paths.callDirectory(r.id)).map { (r.id, $0) } })
            return PersonRelation(name: name, personID: personID, owner: owner, records: records, reviews: reviews, commitments: commitments,
                                  nameIsUnique: same.count <= 1)
        }.value
        withAnimation(.smooth) { relation = r }
    }
}

/// Numbers as one typographic row between two hairlines: a 22 pt figure over a quiet word.
struct FigureRow: View {
    let figures: [(value: String, label: String)]

    var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            ForEach(Array(figures.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.value)
                        .font(.system(size: 22, weight: .semibold)).tracking(-0.44).monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    // Two lines before a cut: a caption such as "last met · about every 4 days" carries the meaning.
                    Text(f.label).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

/// "1 h 5 min", "12 min", or "40 s" under a minute.
func talkText(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    let minutes = s / 60
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
}
