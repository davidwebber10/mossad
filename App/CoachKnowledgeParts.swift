import MossadCore
import SwiftUI

/// The focus as prose: the plan, why, and Accept, Edit, Not now; or the agreed plan and how calls went on it.
struct FocusProse: View {
    @EnvironmentObject var controller: AppController
    let profile: CoachProfile
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        if let f = profile.activeFocus {
            VStack(alignment: .leading, spacing: 6) {
                Text(f.plan).font(.system(size: 16, weight: .medium)).cssLineHeight(1.4, size: 16).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !f.results.isEmpty {
                    HStack(spacing: 10) {
                        FocusDots(results: f.results)
                        Text("\(f.chances.filter { $0.outcome == .hit }.count) of \(f.chances.count) chances")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.top, 4)
                }
                if let since = f.accepted {
                    Text("Since \(since.formatted(.dateTime.month(.wide).day())). Each review reports how the call went on it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
            }
            .padding(.top, 4).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline(.bottom)
        } else if let f = profile.proposedFocus {
            VStack(alignment: .leading, spacing: 0) {
                if editing {
                    TextField("Your focus", text: $text, axis: .vertical).textFieldStyle(SheetFieldStyle())
                } else {
                    Text(f.plan).font(.system(size: 16, weight: .medium)).cssLineHeight(1.4, size: 16).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(f.why).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).cssLineHeight(1.45, size: 12.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                HStack(spacing: 6) {
                    Button(editing ? "Save" : "Accept") {
                        controller.acceptFocus(f.id, plan: editing ? text : nil)
                        editing = false
                    }
                    .buttonStyle(.settingsAccent)
                    if !editing { Button("Edit") { text = f.plan; editing = true }.buttonStyle(.settings) }
                    Button(editing ? "Cancel" : "Not now") { if editing { editing = false } else { controller.dismissFocus(f.id) } }
                        .buttonStyle(.settings)
                    Text("Nothing counts until you accept it. Each review then reports how the call went on it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 6)
                }
                .padding(.top, 12)
            }
            .padding(.top, 4).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline(.bottom)
        }
    }
}

/// "Is this right?": the coach's first open question as a sentence, the moment it came from, and Yes, Not
/// quite, No.
struct QuestionProse: View {
    @EnvironmentObject var controller: AppController
    let questions: [CoachQuestion]
    @State private var correcting = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        if let q = questions.first {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Is this right?").textRole(.label).foregroundStyle(Palette.accent)
                    Spacer()
                    if questions.count > 1 {
                        Text("1 of \(questions.count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Palette.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
                Text(q.statement).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink)
                    .cssLineHeight(size: 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                if let name = q.personName {
                    Label("About \(name)", systemImage: "person.crop.circle")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .padding(.top, 3)
                }
                if !q.evidence.isEmpty {
                    Button {
                        if let id = q.callID { controller.showMoment(id, at: q.at ?? 0) }
                    } label: {
                        Text(q.evidence).font(.system(size: 12.5)).italic().foregroundStyle(Palette.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(q.callID == nil)
                    .help("Show this moment in the call")
                    .padding(.top, 4)
                }
                HStack(spacing: 6) {
                    if correcting {
                        TextField("What is right?", text: $note, axis: .vertical)
                            .textFieldStyle(SettingsFieldStyle())
                            .focused($noteFocused)
                            .onSubmit { send(q, .corrected) }
                        Button("Save") { send(q, .corrected) }.buttonStyle(.settingsAccent)
                            .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { correcting = false }.buttonStyle(.settings)
                    } else {
                        Button("Yes") { send(q, .confirmed) }.buttonStyle(.settingsAccent)
                        Button("Not quite…") { correcting = true; noteFocused = true }.buttonStyle(.settings)
                        // Not a plain no: the coach never asks this again.
                        Button("Not true") { send(q, .rejected) }.buttonStyle(.settings)
                        Text("Your answer shapes how the coach reads your calls.")
                            .font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.leading, 6)
                    }
                }
                .padding(.top, 10)
            }
            .id(q.id)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline(.bottom)
        }
    }

    private func send(_ q: CoachQuestion, _ status: CoachQuestion.Status) {
        let text = note
        correcting = false
        note = ""
        controller.answerQuestion(q.id, status, note: status == .corrected ? text : nil)
    }
}

/// What the owner blocked with "No, never again" on a card of the findings deck. Each has Undo.
struct NeverAgain: View {
    @EnvironmentObject var controller: AppController
    let profile: CoachProfile

    private func effect(_ a: FindingAnswer) -> String {
        switch a.kind {
        case .learning: "The coach does not ask this again."
        case .goalOffer: "The coach does not offer this goal again."
        default: "The coach says nothing more about this subject."
        }
    }

    var body: some View {
        let blocked = profile.neverAgain
        if !blocked.isEmpty {
            SettingsGroup(label: "Never again", footer: "From \u{201C}No, never again\u{201D} on a card in Findings. Undo lets the coach bring it up again.") {
                ForEach(blocked) { a in
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.kind.isBehavior || a.kind == .goalOffer ? CoachSkill.subject(of: a.skill) : a.text)
                                .font(.system(size: 12.5)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                            Text(effect(a)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Undo") { controller.allowFindingAgain(a.id) }
                            .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .semibold))
                            .accessibilityLabel("Undo never again: \(a.text)")
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }
}

/// What the coach knows about the owner, as a key and value list: each kind with what is saved and a field to
/// add more. The coach also adds from replies.
struct CoachKnowledge: View {
    @EnvironmentObject var controller: AppController
    let profile: CoachProfile
    @State private var drafts: [CoachFact.Kind: String] = [:]

    private func hint(_ kind: CoachFact.Kind) -> String {
        switch kind {
        case .role: "Head of operations"
        case .responsibility: "Vendor contracts for data tools"
        case .goal: "Metric ownership agreed by December"
        case .relationship: "Sam Park is my direct report"
        case .context: "The Monday call is for decisions"
        }
    }

    var body: some View {
        SettingsGroup(label: "What the coach knows about you") {
            Text("The coach judges each call against this. It also adds to it when you tell it something in a reply.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s).padding(.bottom, 4)
            ForEach(CoachFact.Kind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(profile.facts(kind)) { fact in
                        entry(kind.title) {
                            Text(fact.text).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        } action: {
                            Button("Remove") { controller.removeCoachFact(fact.text) }
                                .buttonStyle(SettingsTextButtonStyle())
                                .accessibilityLabel("Remove \(fact.text)")
                        }
                    }
                    entry(profile.facts(kind).isEmpty ? kind.title : "") {
                        TextField(kind.title, text: Binding(get: { drafts[kind, default: ""] }, set: { drafts[kind] = $0 }), prompt: Text(hint(kind)))
                            // Fills the row instead of a fixed width, which pushed this page wider than the others.
                            .textFieldStyle(SettingsFieldStyle())
                            // The canvas's 320 pt field, but it may shrink in a narrow window.
                            .frame(maxWidth: 320 + 2 * Space.s)
                            .onSubmit { add(kind) }
                    } action: {
                        Button("Add") { add(kind) }
                            .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .semibold))
                            .disabled(drafts[kind, default: ""].trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel("Add to \(kind.title)")
                    }
                }
            }
            if !profile.ownGuidance.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(profile.ownGuidance.enumerated()), id: \.element.id) { i, g in
                        entry(i == 0 ? "Your coaching preferences" : "") {
                            Text(g.text).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        } action: {
                            Button("Remove") { controller.removeCoachGuidance(g.text) }
                                .buttonStyle(SettingsTextButtonStyle())
                                .accessibilityLabel("Remove \(g.text)")
                        }
                    }
                }
            }
        }
    }

    private func entry<Value: View, Action: View>(_ key: String, @ViewBuilder value: () -> Value, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(key).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .cssLineHeight(size: 12)
                .frame(width: 150, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            value().frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(.vertical, 7)
    }

    private func add(_ kind: CoachFact.Kind) {
        let text = drafts[kind, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        controller.addCoachFact(kind, text)
        drafts[kind] = ""
    }
}
