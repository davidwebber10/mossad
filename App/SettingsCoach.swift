import MossadCore
import SwiftUI

/// Settings › Coach: reviews on or off and their voice, the focus, the coach's questions, what it knows about
/// the owner, and its emails.
struct CoachSettings: View {
    @EnvironmentObject var controller: AppController
    @State private var editingKey: APIKey?
    @State private var sending = false

    var body: some View {
        let profile = controller.coachVersion >= 0 ? controller.coachProfile : CoachProfile()
        LabelColumnStack {
            SettingsGroup(label: "Communication coach") {
                SettingsSwitchRow(title: "Review each call", isOn: $controller.coachEnabled)
                    .help("After each note, the coach reviews how you communicated and gives advice tied to moments in the call. It keeps notes over time, so it tracks your progress and your history with each person.")
                    .onChange(of: controller.coachEnabled) { _, on in if on { controller.turnOnCoach() } }
                if controller.coachEnabled {
                    SettingsRow(title: "Voice") {
                        FillPicker(title: "Voice", selection: Binding(get: { profile.voice }, set: { controller.setCoachVoice($0) }),
                                   choices: CoachVoice.allCases.map { ($0, $0.title) })
                    }
                }
            }
            if controller.coachEnabled {
                if profile.activeFocus != nil || profile.proposedFocus != nil || !profile.openQuestions.isEmpty {
                    LabelColumn(label: profile.activeFocus != nil ? "Your focus" : "Proposed focus", labelTopPadding: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            FocusProse(profile: profile)
                            QuestionProse(questions: profile.openQuestions)
                        }
                    }
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
            }
            SettingsGroup(label: "Email", footer: "Mossad only ever emails you, at one address.") { email }
        }
        .sheet(item: $editingKey) { key in KeySheet(key: key) }
    }

    @ViewBuilder
    private var email: some View {
        if !controller.coachEnabled {
            SettingsRow(title: "Weekly and monthly emails", detail: "The coach writes these emails. Turn on the coach to send them.") {
                Button("Turn on the coach") { controller.coachEnabled = true; controller.turnOnCoach() }.buttonStyle(.settings)
            }
        } else {
            SettingsSwitchRow(title: "Weekly email on Monday", isOn: $controller.coachEmailEnabled)
            SettingsSwitchRow(title: "Month in review on the 1st", isOn: $controller.coachMonthlyEmail)
            if controller.coachEmailEnabled || controller.coachMonthlyEmail {
                SettingsRow(title: "Send to",
                            detail: !controller.coachEmailTo.isEmpty && !WeeklyEmail.isSingleAddress(controller.coachEmailTo)
                                ? "Enter one address, your own. Mossad only ever emails you." : nil) {
                    TextField("Send to", text: $controller.coachEmailTo, prompt: Text("you@example.com")).textFieldStyle(SettingsFieldStyle(width: 260))
                }
                SettingsRow(title: "Send from", titleNote: "a sender verified with your email provider") {
                    TextField("Send from", text: $controller.coachEmailFrom, prompt: Text("Mossad <coach@yourdomain.com>")).textFieldStyle(SettingsFieldStyle(width: 260))
                }
                SettingsRow(title: "Email provider") {
                    FillPicker(title: "Email provider", selection: $controller.mailProvider, choices: MailProvider.allCases.map { ($0, $0.displayName) })
                }
                if controller.mailProvider == .mailgun {
                    SettingsRow(title: "Sending domain") {
                        TextField("Sending domain", text: $controller.mailDomain, prompt: Text("mg.yourdomain.com")).textFieldStyle(SettingsFieldStyle(width: 260))
                    }
                }
                if controller.mailProvider == .mailgun || controller.mailProvider == .sendgrid {
                    SettingsSwitchRow(title: "Use the EU region", isOn: $controller.mailEurope)
                }
                if controller.mailProvider == .ses {
                    SettingsRow(title: "Region") {
                        TextField("Region", text: $controller.mailRegion, prompt: Text("us-east-1")).textFieldStyle(SettingsFieldStyle(width: 260))
                    }
                    SettingsRow(title: "Access key ID") {
                        TextField("Access key ID", text: $controller.mailAccessKeyID, prompt: Text("AKIA…")).textFieldStyle(SettingsFieldStyle(width: 260, monospaced: true))
                    }
                }
                SettingsRow(title: controller.mailProvider.displayName,
                            detail: controller.mailProvider == .ses ? "The secret access key" : "Sends the email with your own account") {
                    KeyStatus(key: controller.mailProvider.key) { editingKey = $0 }
                }
                SettingsRow(title: "Send one now", detail: "To check the address and the provider.") {
                    Menu {
                        Button("Last week’s email") { send(.weekly) }
                        Button("Last month’s review") { send(.monthly) }
                    } label: {
                        FillMenuLabel(text: sending ? "Sending…" : "Send now")
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .disabled(sending || !WeeklyEmail.isSingleAddress(controller.coachEmailTo) || controller.coachEmailFrom.isEmpty
                              || !controller.hasKey(controller.mailProvider.key))
                }
            }
        }
    }

    private func send(_ kind: CoachEmailKind) {
        sending = true
        Task {
            await controller.sendCoachEmail(kind, now: true)
            sending = false
        }
    }
}

/// The focus as prose: the plan, why, and Accept, Edit, Not now; or the agreed plan and how calls went on it.
private struct FocusProse: View {
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
private struct QuestionProse: View {
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
                        Button("No") { send(q, .rejected) }.buttonStyle(.settings)
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

/// What the coach knows about the owner, as a key and value list: each kind with what is saved and a field to
/// add more. The coach also adds from replies.
private struct CoachKnowledge: View {
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
        SettingsGroup(label: "What the coach knows about you",
                      footer: "Reviews use the AI provider. The coach’s notes stay on this Mac in the Coach folder.") {
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
            if !profile.guidance.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(profile.guidance.enumerated()), id: \.element.id) { i, g in
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
