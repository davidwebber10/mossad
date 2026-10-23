import AppKit
import MossadCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmDeleteVoices = false
    @State private var editingKey: APIKey?
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.system(size: 18, weight: .bold)).kerning(-0.3).padding(.top, 8)
                PowerControl()
                group("Permissions") {
                    ForEach(permissions.items) { item in permissionRow(item) }
                }
                consent
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        group("You and voices") { youAndVoices }
                        group("Folders") {
                            folderRow("Meetings", controller.paths.meetings)
                            folderRow("Audio", controller.paths.audio)
                            folderRow("Voices", controller.paths.voices)
                        }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        group("Recording") { recording }
                    }
                }
                group("Calendars", footer: "Mossad reads only the checked calendars, to name calls from their invites and to list upcoming calls.") {
                    calendarChoices
                }
                group("Providers", footer: "Keys are stored in the Keychain. Each provider bills your own account.") { providers }
                group("Communication coach", footer: "Reviews use the AI provider above. The coach's notes stay on this Mac in the Coach folder.") { coach }
                group("Use your meetings in other AI apps",
                      footer: "Read-only. Claude Code, Claude Desktop, and other MCP apps can search and read your meetings, the same way the Chat tab does. Mossad does not need to be open.") {
                    MCPSetup()
                }
                group("Storage") { StorageSettings() }
                group("iPhone", footer: "Finished meetings, their summaries and transcripts, and the coach's notes go to your private iCloud, where Mossad for iPhone reads them. Audio stays where it is.") {
                    switchRow("Sync meetings to iCloud", $controller.iCloudSyncEnabled)
                        .onChange(of: controller.iCloudSyncEnabled) { _, on in if on { controller.syncToICloud() } }
                    switchRow("Use my AI key on my iPhone", $controller.shareAIKey)
                        .help("Chat and the coach on the iPhone use the AI provider and key chosen here. The key travels in iCloud Keychain, which is end-to-end encrypted.")
                        .onChange(of: controller.shareAIKey) { _, _ in controller.updateSharedAIKey() }
                }
                group("Updates", footer: "New versions come from the Mossad releases on GitHub. Each one is signed, and an update never installs during a call.") {
                    UpdateSettings(updater: controller.updater)
                }
            }
            .font(.system(size: 12))
            .padding(EdgeInsets(top: 8, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .onAppear {
            permissions.refresh()
            permissions.setInterval(1)
        }
        .onDisappear {
            permissions.setInterval(10)
            controller.rebuildPipeline()
        }
        .confirmationDialog("Delete every saved voice?", isPresented: $confirmDeleteVoices) {
            Button("Delete all voices", role: .destructive) { controller.deleteAllVoices() }
        } message: {
            Text("Mossad forgets every voice it learned, including yours. Meeting notes keep their names.")
        }
        .sheet(item: $editingKey) { key in KeySheet(key: key) }
    }

    // MARK: Groups

    private func group<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary).padding(.leading, 4)
            VStack(spacing: 0) {
                Group(subviews: content()) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { i, view in
                        if i > 0 { Rectangle().fill(Theme.separator).frame(height: 1) }
                        view.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.separator))
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 4) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var consent: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.warning)
            Text("**Recording consent.** Mossad does not announce itself on calls. Tell the people you meet with that the call is recorded. Some places require the consent of every person on the call. This is not legal advice.")
                .font(.system(size: 12)).lineSpacing(3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }

    // MARK: Rows

    private func permissionRow(_ item: PermissionsMonitor.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.state.isGood ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16)).foregroundStyle(item.state.isGood ? .green : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium))
                Text(item.reason).foregroundStyle(.secondary)
            }
            Spacer()
            if !item.state.isGood {
                Button(fixLabel(item)) { permissions.fix(item) }.controlSize(.small)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { if !item.state.isGood { permissions.fix(item) } }
    }

    private func fixLabel(_ item: PermissionsMonitor.Item) -> String {
        switch item.state {
        case .notAsked: "Allow…"
        case .needsApp: "Open browser"
        default: "Open Settings"
        }
    }

    @ViewBuilder
    private var youAndVoices: some View {
        HStack {
            Text("Your name")
            Spacer()
            TextField("", text: $controller.ownerName).frame(width: 140)
                .onSubmit { controller.rebuildPipeline() }
        }
        HStack {
            Text("Company ") + Text("optional").foregroundStyle(.tertiary)
            Spacer()
            TextField("Example Inc.", text: $controller.organization).frame(width: 140)
                .onSubmit { controller.rebuildPipeline() }
        }
        switchRow("Recognize voices", $controller.voiceFingerprints)
            .help("Mossad saves a voice fingerprint for each person it hears so it can name them in later calls. Some laws treat voice fingerprints as biometric data. Turn it off to keep no fingerprints; speakers are then labeled Speaker A, Speaker B.")
            .onChange(of: controller.voiceFingerprints) { _, _ in controller.rebuildPipeline() }
        Button("Delete all saved voices…") { confirmDeleteVoices = true }
            .buttonStyle(.plain).foregroundStyle(.red).fontWeight(.medium)
    }

    @ViewBuilder
    private var recording: some View {
        switchRow("Open Mossad at login", $launchAtLogin)
            .onChange(of: launchAtLogin) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    Log.error("Launch at login change failed: \(error)")
                }
            }
        switchRow("Live transcript while recording", $controller.liveTranscriptEnabled)
            .help("Shows what is said as the call runs, with AssemblyAI streaming. AssemblyAI bills the time a call records with this on. The note still uses the full transcription after the call.")
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Delete recordings after a period of time", isOn: $controller.deleteRecordings).toggleStyle(.checkbox)
            if controller.deleteRecordings {
                HStack(spacing: 6) {
                    Text("Keep audio for")
                    TextField("", value: $controller.recordingDays, format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 44)
                    Stepper("", value: $controller.recordingDays, in: 1...3650).labelsHidden()
                    Text(controller.recordingDays == 1 ? "day" : "days").foregroundStyle(.secondary)
                }
                .padding(.leading, 22)
            }
            Text("Notes and transcripts are always kept. A recording uses about 14 MB an hour.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 22)
        }
    }

    @ViewBuilder
    private var calendarChoices: some View {
        if controller.calendars.isEmpty {
            Text("Allow Calendars above to choose them.").foregroundStyle(.secondary)
        }
        ForEach(Array(Dictionary(grouping: controller.calendars, by: \.account).sorted { $0.key < $1.key }), id: \.key) { account, list in
            VStack(alignment: .leading, spacing: 4) {
                Text(account.isEmpty ? "On this Mac" : account).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(list) { c in
                    Toggle(c.title, isOn: Binding(get: { controller.chosenCalendars.contains(c.id) },
                                                  set: { on in
                                                      if on { controller.chosenCalendars.insert(c.id) } else { controller.chosenCalendars.remove(c.id) }
                                                  }))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    @ViewBuilder
    private var providers: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transcription").fontWeight(.medium)
                Spacer()
                Picker("Transcription provider", selection: $controller.transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                if controller.transcriptionProvider.models.count > 1 {
                    Picker("Transcription model", selection: $controller.transcriptionModel) {
                        ForEach(controller.transcriptionProvider.models) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 170)
                }
            }
            Text(controller.transcriptionProvider.note).font(.system(size: 11)).foregroundStyle(.secondary)
            RatingView(rating: controller.transcriptionProvider.rating, aspects: Rating.transcriptionAspects)
        }
        .onChange(of: controller.transcriptionProvider) { _, p in
            controller.transcriptionModel = p.models.first?.id ?? ""
            controller.rebuildPipeline()
        }
        if let key = controller.transcriptionProvider.key {
            keyRow(controller.transcriptionProvider.displayName, "Transcribes your calls after they end", key)
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI").fontWeight(.medium)
                    Text("Summaries, the coach, the weekly email, and chat").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("AI provider", selection: $controller.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                ModelPicker(provider: controller.aiProvider, model: $controller.aiModel)
            }
            if let rating = Rating.model(controller.aiModel.isEmpty ? controller.aiProvider.defaultModel : controller.aiModel, provider: controller.aiProvider)
                ?? (controller.aiProvider == .openrouter ? controller.openRouterRating : nil) {
                RatingView(rating: rating, aspects: Rating.modelAspects)
            }
        }
        .onChange(of: controller.aiProvider) { _, _ in
            controller.aiModel = ""
            controller.rebuildPipeline()
        }
        .onChange(of: controller.aiModel) { _, _ in controller.rebuildPipeline() }
        keyRow(controller.aiProvider.displayName, "Answers with your chosen model", controller.aiProvider.key)
        if controller.liveTranscriptEnabled, controller.transcriptionProvider != .assemblyai {
            keyRow("AssemblyAI", "The live transcript while recording uses AssemblyAI", .assemblyai)
        }
    }

    @ViewBuilder
    private var coach: some View {
        switchRow("Review each call", $controller.coachEnabled)
            .help("After each note, Claude reviews how you communicated and gives advice tied to moments in the call. It keeps notes over time, so it tracks your progress and your history with each person.")
            .onChange(of: controller.coachEnabled) { _, on in if on { controller.turnOnCoach() } }
        if controller.coachEnabled {
            let profile = controller.coachProfile
            HStack {
                Text("Voice")
                Spacer()
                Picker("Voice", selection: Binding(get: { profile.voice }, set: { controller.setCoachVoice($0) })) {
                    ForEach(CoachVoice.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if profile.activeFocus != nil || profile.proposedFocus != nil {
                FocusPanel(profile: profile, accept: { controller.acceptFocus($0, plan: $1) }, dismiss: { controller.dismissFocus($0) })
            }
            CoachMemoryEditor()
            switchRow("Weekly email on Monday", $controller.coachEmailEnabled)
            switchRow("Month in review on the 1st", $controller.coachMonthlyEmail)
            if controller.coachEmailEnabled || controller.coachMonthlyEmail {
                HStack {
                    Text("Send to")
                    Spacer()
                    TextField("you@example.com", text: $controller.coachEmailTo).frame(width: 240)
                }
                HStack {
                    Text("Send from ") + Text("a sender verified in Resend").foregroundStyle(.tertiary)
                    Spacer()
                    TextField("Mossad <coach@yourdomain.com>", text: $controller.coachEmailFrom).frame(width: 240)
                }
                HStack {
                    Text("Email provider")
                    Spacer()
                    Picker("Email provider", selection: $controller.mailProvider) {
                        ForEach(MailProvider.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                if controller.mailProvider == .mailgun {
                    HStack {
                        Text("Sending domain")
                        Spacer()
                        TextField("mg.yourdomain.com", text: $controller.mailDomain).frame(width: 240)
                    }
                }
                if controller.mailProvider == .mailgun || controller.mailProvider == .sendgrid {
                    switchRow("Use the EU region", $controller.mailEurope)
                }
                if controller.mailProvider == .ses {
                    HStack {
                        Text("Region")
                        Spacer()
                        TextField("us-east-1", text: $controller.mailRegion).frame(width: 240)
                    }
                    HStack {
                        Text("Access key ID")
                        Spacer()
                        TextField("AKIA…", text: $controller.mailAccessKeyID).frame(width: 240)
                    }
                }
                keyRow(controller.mailProvider.displayName, controller.mailProvider == .ses ? "The secret access key" : "Sends the weekly email with your own account",
                       controller.mailProvider.key)
                if !controller.coachEmailTo.isEmpty, !WeeklyEmail.isSingleAddress(controller.coachEmailTo) {
                    Text("Enter one address, your own. Mossad only ever emails you.").foregroundStyle(Theme.recording)
                }
                HStack {
                    Spacer()
                    Menu(sending ? "Sending…" : "Send now") {
                        Button("Last week's email") { send(.weekly) }
                        Button("Last month's review") { send(.monthly) }
                    }
                    .fixedSize()
                    .controlSize(.small)
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

    private func switchRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(title).fontWeight(.medium)
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.link).foregroundStyle(.tertiary)
        }
    }

    private func keyRow(_ title: String, _ detail: String, _ key: APIKey) -> some View {
        let set = controller.hasKey(key)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
            Text(set ? "Set" : "Missing")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(set ? Color.green : Theme.recording)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background((set ? Color.green : Theme.recording).opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if set {
                Button("Change") { editingKey = key }.controlSize(.small)
            } else {
                Button("Set key") { editingKey = key }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
    }
}

extension APIKey: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// Saves an API key to the Keychain. The key is never shown, logged, or written anywhere else.
private struct KeySheet: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let key: APIKey
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(key.displayName).font(.headline)
            SecureField("Paste the key", text: $value).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        try controller.keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
                        controller.rebuildPipeline()
                    } catch {
                        Log.error("Saving the \(key.rawValue) key failed")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

extension APIKey {
    var displayName: String {
        switch self {
        case .assemblyai: "AssemblyAI key"
        case .anthropic: "Anthropic key"
        case .openai: "OpenAI key"
        case .openrouter: "OpenRouter key"
        case .deepgram: "Deepgram key"
        case .elevenlabs: "ElevenLabs key"
        case .resend: "Resend key"
        case .postmark: "Postmark server token"
        case .sendgrid: "SendGrid key"
        case .mailgun: "Mailgun key"
        case .brevo: "Brevo key"
        case .sesSecret: "Amazon SES secret access key"
        case .cloudSecret: "Secret access key"
        }
    }
}

/// The model menu for the AI provider, filled from the provider's own list. OpenRouter has hundreds of
/// models, so it gets a field to type in with a filtered menu beside it.
/// Stars for each aspect and the price level; the tooltip says what they rest on.
private struct RatingView: View {
    let rating: Rating
    let aspects: [String]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(aspects.filter { rating.stars[$0] != nil }, id: \.self) { aspect in
                HStack(spacing: 4) {
                    Text(aspect).foregroundStyle(.secondary)
                    HStack(spacing: 1) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= rating.stars[aspect]! ? "star.fill" : "star")
                                .font(.system(size: 9)).foregroundStyle(i <= rating.stars[aspect]! ? Color.yellow : Color.secondary.opacity(0.5))
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(aspect): \(rating.stars[aspect]!) of 5")
            }
            if rating.free {
                Text("Free").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
            } else if rating.price > 0 {
                (Text(rating.dollars).foregroundStyle(.primary) + Text(String(repeating: "$", count: 4 - rating.price)).foregroundStyle(.quaternary))
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityLabel("Price level \(rating.price) of 4")
            }
        }
        .font(.system(size: 11))
        .help(rating.basis)
    }
}

private struct ModelPicker: View {
    @EnvironmentObject var controller: AppController
    let provider: AIProvider
    @Binding var model: String
    @State private var models: [ModelInfo] = []

    /// "Claude Opus 5.5 · $$$".
    private func label(_ m: ModelInfo) -> String {
        guard let r = Rating.model(m, provider: provider), r.price > 0 else { return m.name }
        return "\(m.name) · \(r.dollars)"
    }

    var body: some View {
        let current = model.isEmpty ? provider.defaultModel : model
        Group {
            if provider == .openrouter {
                HStack(spacing: 6) {
                    TextField("provider/model", text: $model).frame(width: 190)
                    Menu("Choose") {
                        let q = model.lowercased()
                        let matches = models.filter { q.isEmpty || $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) }
                        ForEach(Array((matches.isEmpty ? models : matches).prefix(60))) { m in
                            Button(label(m)) { model = m.id; controller.openRouterRating = Rating.model(m, provider: .openrouter) }
                        }
                    }
                    .fixedSize()
                    .disabled(models.isEmpty)
                }
            } else {
                Picker("Model", selection: Binding(get: { current }, set: { model = $0 })) {
                    let list = models.contains { $0.id == current } || current.isEmpty ? models : [ModelInfo(id: current, name: current)] + models
                    ForEach(list) { Text(label($0)).tag($0.id) }
                }
                .labelsHidden().frame(width: 220)
            }
        }
        .task(id: "\(provider.rawValue)-\(controller.hasKey(provider.key))") {
            defer { if provider == .openrouter { controller.openRouterRating = models.first { $0.id == model }.flatMap { Rating.model($0, provider: .openrouter) } } }
            models = (try? await ModelCatalog.fetch(provider, apiKey: controller.keychain.get(provider.key))) ?? []
        }
    }
}

/// The commands that connect other AI apps to Mossad's MCP server.
private struct MCPSetup: View {
    @State private var copied: String?
    private var binary: String { Bundle.main.executablePath ?? "/Applications/Mossad.app/Contents/MacOS/Mossad" }
    private var claudeCode: String { "claude mcp add --scope user mossad -- \"\(binary)\" --mcp" }
    private var desktop: String {
        "\"mossad\": { \"command\": \"\(binary)\", \"args\": [\"--mcp\"] }"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Claude Code", "Run this once in Terminal:", claudeCode)
            row("Claude Desktop", "Add this inside \"mcpServers\" in claude_desktop_config.json:", desktop)
        }
    }

    private func row(_ title: String, _ hint: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.medium)
            Text(hint).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied == title ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = title
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.vertical, 2)
    }
}

/// What the coach knows about you, by memory: role, responsibilities, goals, relationships, and the coaching
/// preferences it learned from your corrections. You can add and remove items; the coach also adds from replies.
private struct CoachMemoryEditor: View {
    @EnvironmentObject var controller: AppController
    @State private var drafts: [CoachFact.Kind: String] = [:]

    private func hint(_ kind: CoachFact.Kind) -> String {
        switch kind {
        case .role: "Head of data and technology"
        case .responsibility: "Vendor contracts for data tools"
        case .goal: "Metric ownership agreed by December"
        case .relationship: "Mitch Haus is my direct report"
        }
    }

    var body: some View {
        let profile = controller.coachVersion >= 0 ? controller.coachProfile : CoachProfile()
        VStack(alignment: .leading, spacing: 10) {
            Text("What the coach knows about you").fontWeight(.medium)
            Text("The coach judges each call against this. It also adds to it when you tell it something in a reply.")
                .foregroundStyle(.secondary)
            ForEach(CoachFact.Kind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(profile.facts(kind)) { fact in
                        HStack(alignment: .firstTextBaseline) {
                            Text(fact.text)
                            Spacer()
                            Button("Remove") { controller.removeCoachFact(fact.text) }.buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                    HStack {
                        TextField(hint(kind), text: Binding(get: { drafts[kind, default: ""] }, set: { drafts[kind] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { add(kind) }
                        Button("Add") { add(kind) }.controlSize(.small).disabled(drafts[kind, default: ""].trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            if !profile.guidance.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your coaching preferences").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(profile.guidance) { g in
                        HStack(alignment: .firstTextBaseline) {
                            Text(g.text)
                            Spacer()
                            Button("Remove") { controller.removeCoachGuidance(g.text) }.buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                }
            }
        }
    }

    private func add(_ kind: CoachFact.Kind) {
        let text = drafts[kind, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        controller.addCoachFact(kind, text)
        drafts[kind] = ""
    }
}

private struct UpdateSettings: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack {
            Text("Version \(updater.version)")
            Spacer()
            Button("Check for Updates…") { updater.checkForUpdates() }.controlSize(.small).disabled(!updater.canCheck)
        }
        HStack {
            Text("Check for updates automatically")
            Spacer()
            Toggle("", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        HStack {
            Text("Download and install updates automatically")
            Spacer()
            Toggle("", isOn: Binding(get: { updater.automaticallyInstalls }, set: { updater.automaticallyInstalls = $0 }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}
