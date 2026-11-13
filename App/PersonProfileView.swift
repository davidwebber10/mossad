import MossadCore
import SwiftUI

/// One person's page, laid out as a meeting's: the band with who they are and the numbers of the two of you, the
/// tabs on its lower edge, then the tab. The owner's own page has the tabs that apply to the owner.
struct PersonProfileView: View {
    enum Tab: String, CaseIterable {
        case overview = "Overview", meetings = "Meetings", tasks = "Tasks", analytics = "Analytics", knowledge = "Knowledge", voice = "Voice"
    }

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
    /// "Delete all saved voices…", from the Voice tab.
    let deleteAllVoices: () -> Void
    /// The voice library changed here (an address): the list reads it again.
    let changed: () -> Void

    @AppStorage("personTab") private var savedTab = Tab.overview
    /// A preview's tab, kept out of the owner's saved choice.
    @State private var previewTab: Tab?
    @State private var relation: PersonRelation?
    @State private var meetings: PersonMeetings?

    private var tabs: [Tab] { profile.isOwner ? [.overview, .meetings, .tasks, .voice] : Tab.allCases }
    private var tab: Tab {
        let t = previewTab ?? savedTab
        return tabs.contains(t) ? t : .overview
    }
    private var tabBinding: Binding<Tab> { Binding(get: { tab }, set: { previewTab = nil; savedTab = $0 }) }
    private var first: String { profile.name.split(separator: " ").first.map(String.init) ?? profile.name }

    var body: some View {
        VStack(spacing: 0) {
            PersonHeader(profile: profile, stats: stats, org: org, chart: chart, others: others, together: meetings?.together,
                         rename: rename, merge: merge, delete: delete, changed: changed)
                .overlay(alignment: .bottom) {
                    DetailTabs(tab: tabBinding, tabs: tabs, accessibilityLabel: "Person tabs").offset(y: Detail.underTabs)
                }
                .zIndex(1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.window)
        .environment(\.openURL, OpenURLAction { url in controller.openLink(url) ? .handled : .systemAction })
        .task(id: "\(profile.name)-\(controller.peopleStamp)-\(controller.meetingsVersion)-\(controller.commitmentsVersion)") { await load() }
        .onAppear {
            // Development hook for screenshots: MOSSAD_PERSON_TAB=overview|meetings|tasks|analytics|knowledge|voice.
            if CommandLine.arguments.contains("--ui-preview"),
               let t = ProcessInfo.processInfo.environment["MOSSAD_PERSON_TAB"].flatMap({ Tab(rawValue: $0.capitalized) }) { previewTab = t }
        }
    }

    @ViewBuilder
    private var content: some View {
        let top = Detail.underTabs + 32
        switch tab {
        case .overview:
            ScrollView {
                PersonOverviewTab(profile: profile, stats: stats, relation: relation, select: select).detailColumn(top: top)
            }
        case .meetings:
            PersonMeetingsTab(meetings: meetings, first: profile.isOwner ? nil : first, top: Detail.underTabs + 24)
        case .tasks:
            ScrollView {
                PersonTasksTab(profile: profile, stats: stats, relation: relation).detailColumn(top: top)
            }
        case .analytics:
            ScrollView {
                if let relation {
                    PersonAnalyticsTab(profile: profile, stats: stats, relation: relation).detailColumn(top: top, width: Rhythm.wideWidth)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, top + 20)
                }
            }
        case .knowledge:
            ScrollView {
                PersonKnowledgeTab(profile: profile, calls: stats.meetings.count).detailColumn(top: top)
            }
        case .voice:
            ScrollView {
                PersonVoiceTab(profile: profile, deleteAll: deleteAllVoices).detailColumn(top: top)
            }
        }
    }

    /// The relation and the meetings, off the main thread: both read every meeting.
    private func load() async {
        let name = profile.name, isOwner = profile.isOwner, owner = controller.ownerName, records = controller.meetings, paths = controller.paths
        let commitments = controller.commitmentBook.visible
        let store = controller.library.identity?.people, profiles = controller.library.profiles
        let made = await Task.detached(priority: .userInitiated) { () -> (PersonRelation?, PersonMeetings) in
            let people = store?.people ?? []
            let list = PersonMeetings(records: records, name: name, isOwner: isOwner,
                                      people: MeetingFilterPeople(profiles: profiles, store: store, owner: owner))
            guard !isOwner else { return (nil, list) }
            // By the person's id where the people store has it: two people with one name or one first name stay apart.
            let same = people.filter { $0.isLive && $0.displayName == name }
            let personID = PeopleStore.id(forVoiceName: name, isOwner: false, in: people)?.rawValue
            let shared = records.filter { $0.speakerNames.values.contains(name) }
            let reviews = Dictionary(uniqueKeysWithValues: shared.compactMap { r in CoachReview.load(in: paths.callDirectory(r.id)).map { (r.id, $0) } })
            let relation = PersonRelation(name: name, personID: personID, owner: owner, records: records, reviews: reviews, commitments: commitments,
                                          nameIsUnique: same.count <= 1)
            return (relation, list)
        }.value
        withAnimation(.smooth) {
            relation = made.0
            meetings = made.1
        }
    }
}

/// Numbers as one typographic row: a 22 pt figure over a quiet word, between two hairlines unless `ruled` is off.
struct FigureRow: View {
    let figures: [(value: String, label: String)]
    var ruled = true
    var maxWidth: CGFloat = 680

    var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            ForEach(Array(figures.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    Text(f.value)
                        .font(.system(size: Rhythm.titleSize, weight: .semibold)).tracking(-0.44).monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    // Two lines before a cut: a caption such as "last met · about every 4 days" carries the meaning.
                    Text(f.label).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, ruled ? Space.m : 0)
        .overlay(alignment: .top) { if ruled { Hairline() } }
        .overlay(alignment: .bottom) { if ruled { Hairline() } }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

/// "1 h 5 min", "12 min", or "40 s" under a minute.
func talkText(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    let minutes = s / 60
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
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
