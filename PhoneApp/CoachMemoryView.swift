import MossadCore
import SwiftUI

/// The coach on the iPhone: the same pages as Coach on the Mac, as a list. Findings with its count, Goals, the
/// Weekly review, Knowledge (what the coach and Chat remember, which you can change), and Settings.
struct CoachMemoryView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Development hook for screenshots: `MOSSAD_COACH_PAGE` opens a page.
    @State private var path: [String] = PhoneStore.hook("MOSSAD_COACH_PAGE").flatMap { CoachMemoryView.pages.contains($0) ? [$0] : nil } ?? []
    private static let pages = ["findings", "goals", "weekly", "knowledge", "settings"]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: "findings") {
                        LabeledContent { Text(store.findings.isEmpty ? "" : "\(store.findings.count)").monospacedDigit() } label: {
                            Label("Findings", systemImage: "rectangle.stack")
                        }
                    }
                    NavigationLink(value: "goals") { Label("Goals", systemImage: "scope") }
                    NavigationLink(value: "weekly") { Label("Weekly review", systemImage: "calendar") }
                    NavigationLink(value: "knowledge") { Label("Knowledge", systemImage: "brain") }
                    NavigationLink(value: "settings") { Label("Settings", systemImage: "gearshape") }
                } footer: {
                    Text("Chat and the coach use what is in Knowledge in every answer and review, on the Mac and here.")
                }
            }
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: String.self) { page in
                switch page {
                case "findings": FindingsScreen(close: { dismiss() })
                case "goals": PhoneGoalsScreen()
                case "weekly": PhoneWeeklyScreen()
                case "settings": PhoneCoachSettings()
                default: PhoneKnowledgeScreen()
                }
            }
            .onAppear { store.refreshFindings() }
        }
    }
}

/// Coach › Goals: the goal of now with each call on it, what was not taken, and what was learned.
private struct PhoneGoalsScreen: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        let p = store.profile
        let goals = p.goalHistory
        Group {
            if goals.current == nil, goals.offered.isEmpty, goals.ended.isEmpty, goals.finished.isEmpty {
                ContentUnavailableView("No goal yet", systemImage: "scope",
                                       description: Text("After a few reviewed calls the coach offers one goal, as a card in Findings. When you take it, how each call went on it shows here."))
            } else {
                List {
                    if goals.current != nil {
                        Section {
                            FocusPanel(profile: p, accept: { store.acceptFocus($0, plan: $1) }, dismiss: { store.dismissFocus($0) })
                        }
                    }
                    if let active = p.activeFocus, !active.results.isEmpty {
                        Section("Call by call") {
                            ForEach(active.results.reversed(), id: \.callID) { r in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(r.outcome.label).font(.subheadline.weight(.semibold)).foregroundStyle(r.outcome == .hit ? Palette.okText : Palette.secondary)
                                        Spacer()
                                        Text(r.date.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(r.evidence).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !goals.finished.isEmpty {
                        Section("Learned") { ForEach(goals.finished) { Label($0.plan, systemImage: "checkmark.seal.fill") } }
                    }
                    if !goals.ended.isEmpty {
                        Section("Ended") { ForEach(goals.ended) { Text($0.plan).foregroundStyle(.secondary) } }
                    }
                    if !goals.offered.isEmpty {
                        Section("Not taken") { ForEach(goals.offered) { Text($0.plan).foregroundStyle(.secondary) } }
                    }
                }
            }
        }
        .navigationTitle("Goals")
    }
}

/// Coach › Weekly review: it comes to the app in a later version.
private struct PhoneWeeklyScreen: View {
    var body: some View {
        ContentUnavailableView("No weekly review yet", systemImage: "calendar",
                               description: Text("The review of your week comes to this page in a later version. Until then the coach can send it by email on Monday, from the Mac."))
            .navigationTitle("Weekly review")
    }
}

/// Coach › Settings: the coach's settings are on the Mac.
private struct PhoneCoachSettings: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        List {
            Section {
                LabeledContent("Voice", value: store.profile.voice.title)
            } footer: {
                Text("Turn the coach on or off, choose its voice, and set its emails in Mossad on your Mac, in Coach \u{203A} Settings.")
            }
        }
        .navigationTitle("Settings")
    }
}

/// Coach › Knowledge: what the coach and Chat remember. Swipe to make them forget; add what they should know.
private struct PhoneKnowledgeScreen: View {
    @Environment(PhoneStore.self) private var store
    @State private var newFact = ""
    @State private var kind = CoachFact.Kind.allCases[0]

    var body: some View {
        List {
            let p = store.profile
            let carded = Set(store.findings.compactMap(\.questionID))
            let waiting = p.openQuestions.filter { !carded.contains($0.id) }
            if !waiting.isEmpty {
                Section {
                    QuestionsPanel(questions: waiting, answer: { store.answerQuestion($0, $1, note: $2) })
                        .listRowInsets(EdgeInsets())
                }
            }
            if p.questions.contains(where: { $0.status != .open }) {
                Section("Questions you answered") { AnsweredQuestions(questions: p.questions) }
            }
            // No "How you communicate": the stored summary is what the last call before the log wrote, and no
            // call writes it now. It comes back when the weekly review writes one across calls.
            if !p.patterns.isEmpty {
                // One pass over the log for all rows, not one for each row.
                let standings = p.standings()
                Section("Patterns") {
                    ForEach(p.patterns, id: \.self) { pattern in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: pattern.kind == .strength ? "plus.circle.fill" : "arrow.up.forward.circle.fill")
                                    .foregroundStyle(pattern.kind == .strength ? Palette.ok : Palette.accent)
                                Text(pattern.name).font(.subheadline.weight(.semibold))
                            }
                            Text(pattern.note).font(.subheadline).foregroundStyle(.secondary)
                            // What the log counted. The model's own trend and its old count are not shown.
                            Text(standings[pattern.name] ?? "").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            let own = p.ownGuidance
            if !own.isEmpty {
                Section {
                    ForEach(own) { g in Text(g.text) }
                        .onDelete { offsets in for i in offsets { store.removeGuidance(own[i].text) } }
                } header: { Text("What you told the coach") }
            }
            let rules = p.whyRules
            if !rules.isEmpty {
                Section {
                    ForEach(rules) { g in Text(g.text) }
                        .onDelete { offsets in for i in offsets { store.removeGuidance(rules[i].text) } }
                } header: { Text("Rules from your answers") } footer: {
                    Text("From the line \u{201C}Why didn\u{2019}t you agree\u{201D} after a no. Each is for its subject only.")
                }
            }
            let blocked = p.neverAgain
            if !blocked.isEmpty {
                Section {
                    ForEach(blocked) { a in
                        HStack {
                            Text(a.kind.isBehavior || a.kind == .goalOffer ? CoachSkill.subject(of: a.skill) : a.text)
                            Spacer()
                            Button("Undo") { store.allowFindingAgain(a.id) }.buttonStyle(.borderless)
                        }
                    }
                } header: { Text("Never again") } footer: {
                    Text("From \u{201C}No, never again\u{201D} on a card. Undo lets the coach bring it up again.")
                }
            }
            ForEach(CoachFact.Kind.allCases, id: \.self) { kind in
                let facts = p.facts(kind)
                if !facts.isEmpty {
                    Section(kind.title) {
                        ForEach(facts) { Text($0.text) }
                            .onDelete { offsets in for i in offsets { store.removeFact(facts[i].text) } }
                    }
                }
            }
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(CoachFact.Kind.allCases, id: \.self) { Text($0.title) }
                }
                TextField("Something to remember", text: $newFact, axis: .vertical)
                Button("Remember") {
                    store.addFact(kind, newFact.trimmingCharacters(in: .whitespacesAndNewlines))
                    newFact = ""
                }
                .disabled(newFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Add")
            }
        }
        .navigationTitle("Knowledge")
    }
}
