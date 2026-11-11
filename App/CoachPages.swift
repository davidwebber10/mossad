import MossadCore
import SwiftUI

// MARK: - Goals

/// Coach › Goals: the goal of now with how each call went on it, the goals the owner did not take, and the ones
/// the owner learned. With no goal yet, it says how one comes.
struct CoachGoalsPage: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        let profile = controller.shownCoachProfile
        let goals = profile.goalHistory
        if goals.current == nil, goals.offered.isEmpty, goals.finished.isEmpty {
            DetailColumn {
                PageToolbar(title: CoachPage.goals.title) { EmptyView() }
            } content: {
                EmptyState(symbol: "scope", title: "No goal yet",
                           message: "After a few reviewed calls the coach offers one goal, as a card in Findings. When you take it, how each call went on it shows here.")
                    .pageCentered()
            }
        } else {
            CoachPageColumn(page: .goals, subtitle: profile.activeFocus != nil ? "One goal at a time" : nil) {
                LabelColumnStack {
                    if let current = goals.current {
                        LabelColumn(label: current.status == .active ? "Your goal" : "Offered goal", labelTopPadding: 6) {
                            FocusProse(profile: profile)
                        }
                        if current.status == .active {
                            LabelColumn(label: "Call by call", labelTopPadding: 2) { results(current) }
                        }
                    }
                    if !goals.finished.isEmpty {
                        LabelColumn(label: "Learned", labelTopPadding: 2) { list(goals.finished) { "Learned \(day($0.updated)), \(hits($0))" } }
                    }
                    if !goals.offered.isEmpty {
                        LabelColumn(label: "Not taken", labelTopPadding: 2) {
                            list(goals.offered) { $0.accepted == nil ? "Offered \(day($0.proposed))" : "Ended \(day($0.updated)), \(hits($0))" }
                        }
                    }
                }
            }
        }
    }

    private func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    private func hits(_ f: CoachFocus) -> String { "\(f.chances.filter { $0.outcome == .hit }.count) of \(f.chances.count) chances" }

    /// The calls on the goal, the newest first, each with what happened and its moment. The number that the app
    /// measures for a goal comes with a later version of the coach.
    @ViewBuilder
    private func results(_ focus: CoachFocus) -> some View {
        if focus.results.isEmpty {
            Text("No call had a chance for it yet. Each review says how the call went on it.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    FocusDots(results: focus.results)
                    Text(hits(focus)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                .padding(.bottom, Space.s)
                ForEach(focus.results.reversed(), id: \.callID) { r in
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Text(day(r.date)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.secondary).frame(width: 52, alignment: .leading)
                        Text(r.outcome.label).font(.system(size: 12, weight: .medium)).foregroundStyle(r.outcome == .hit ? Palette.okText : Palette.secondary)
                            .frame(width: 104, alignment: .leading)
                        Text(r.evidence).font(.system(size: 12.5)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let at = r.at {
                            Button { controller.showMoment(r.callID, at: at) } label: { Text(coachClock(at)).monospacedDigit() }
                                .buttonStyle(SettingsTextButtonStyle(color: Palette.accent))
                                .help("Show this moment in the call")
                        }
                    }
                    .padding(.vertical, 6)
                    .hairline(.bottom)
                }
            }
        }
    }

    private func list(_ foci: [CoachFocus], detail: @escaping (CoachFocus) -> String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(foci) { f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.plan).font(.system(size: 13)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    Text(detail(f)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Weekly review

/// Coach › Weekly review: the review of the week in the app comes in a later version. Until then the page says
/// so, and shows an email that is written and not sent yet.
struct WeeklyReviewPage: View {
    @EnvironmentObject var controller: AppController
    @State private var waiting: [(weekly: Bool, start: Date, digest: WeeklyDigest)] = []

    var body: some View {
        Group {
            if waiting.isEmpty {
                DetailColumn {
                    PageToolbar(title: CoachPage.weekly.title) { EmptyView() }
                } content: {
                    EmptyState(symbol: "calendar", title: "No weekly review yet",
                               message: controller.coachEmailEnabled
                                   ? "The review of your week comes to this page in a later version. Until then the coach sends it by email on Monday."
                                   : "The review of your week comes to this page in a later version. Until then the coach can send it by email on Monday.",
                               action: controller.coachEmailEnabled ? nil : ("Email settings", { controller.coachPage = .settings }))
                        .pageCentered()
                }
            } else {
                CoachPageColumn(page: .weekly, subtitle: "Written, not sent yet") {
                    LabelColumnStack {
                        ForEach(waiting, id: \.start) { w in
                            LabelColumn(label: (w.weekly ? "Week of " : "Month of ") + w.start.formatted(.dateTime.month(.abbreviated).day()), labelTopPadding: 2) {
                                digest(w.digest)
                            }
                        }
                    }
                }
            }
        }
        .task(id: controller.coachVersion) {
            let dir = controller.paths.coach
            waiting = await Task.detached(priority: .utility) { WeeklyDigest.waiting(in: dir) }.value
        }
    }

    private func digest(_ d: WeeklyDigest) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(d.subject).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(d.intro).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(d.improved, id: \.self) { Label($0, systemImage: "arrow.up.right").font(.system(size: 12.5)).foregroundStyle(Palette.ink) }
            ForEach(d.toWork, id: \.self) { Label($0, systemImage: "scope").font(.system(size: 12.5)).foregroundStyle(Palette.ink) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Knowledge

/// Coach › Knowledge: what the coach knows and was told. The questions that wait with no card, what the owner
/// confirmed, the owner's guidance, the rules from the reasons for a no, what was blocked for good (each with
/// Undo), and the people the owner confirmed something about, with a link to each one's page.
struct CoachKnowledgePage: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        let profile = controller.shownCoachProfile
        // A conclusion that is a card is answered in Findings.
        let carded = Set(controller.findings.compactMap(\.questionID))
        let waiting = profile.openQuestions.filter { !carded.contains($0.id) }
        CoachPageColumn(page: .knowledge) {
            LabelColumnStack {
                if !waiting.isEmpty {
                    LabelColumn(label: "Waiting for you", labelTopPadding: 6) { QuestionProse(questions: waiting) }
                }
                if profile.questions.contains(where: { $0.status != .open }) {
                    LabelColumn(label: "Questions you answered", labelTopPadding: 2) {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: Space.s) { AnsweredQuestions(questions: profile.questions) }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        } label: {
                            Text("\(profile.questions.filter { $0.status != .open }.count) answered")
                                .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                CoachKnowledge(profile: profile)
                WhyRules(profile: profile)
                NeverAgain(profile: profile)
                PersonLearnings(profile: profile)
            }
        }
    }
}

/// The reasons the owner gave for a no to a card. Each is about that card's subject, or its person.
private struct WhyRules: View {
    @EnvironmentObject var controller: AppController
    let profile: CoachProfile

    var body: some View {
        let rules = profile.whyRules
        if !rules.isEmpty {
            SettingsGroup(label: "Rules from your answers",
                          footer: "From the line \u{201C}Why didn\u{2019}t you agree\u{201D} after a no. The coach keeps the newest \(CoachProfile.reasonLimit) and uses each for its subject only.") {
                ForEach(rules) { g in
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Text(g.text).font(.system(size: 12.5)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Remove") { controller.removeCoachGuidance(g.text) }
                            .buttonStyle(SettingsTextButtonStyle())
                            .accessibilityLabel("Remove \(g.text)")
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }
}

/// The people the owner confirmed something about, by person id, each with a link to the person's page.
private struct PersonLearnings: View {
    @EnvironmentObject var controller: AppController
    let profile: CoachProfile

    var body: some View {
        let saved = controller.shownCoachPeople
        let byPerson = Dictionary(grouping: profile.facts.filter { $0.person != nil }) { saved.canonical($0.person!) }
        let rows = byPerson.compactMap { id, facts -> (name: String, facts: [CoachFact])? in
            guard let name = saved.name(of: id) ?? profile.people.first(where: { $0.value.person == id })?.key else { return nil }
            return (name, facts)
        }.sorted { $0.name < $1.name }
        if !rows.isEmpty {
            SettingsGroup(label: "About people", footer: "What you confirmed on a card about a person. It stays with the person, also after a new name.") {
                ForEach(rows, id: \.name) { row in
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Button(row.name) { controller.openPerson(row.name) }
                            .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .semibold))
                            .frame(width: 150, alignment: .leading)
                            .help("Open \(row.name)\u{2019}s page")
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(row.facts) { Text($0.text).font(.system(size: 12.5)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }
}
