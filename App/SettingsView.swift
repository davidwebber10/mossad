import MossadCore
import SwiftUI

/// Settings as a second column, like the meeting list: each page with what is inside and an accent dot where
/// something needs the owner, then the page in the label column.
struct SettingsView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @AppStorage("settingsPage") private var page: SettingsPage = .general

    var body: some View {
        HStack(spacing: 0) {
            ListColumn("Settings", widthKey: "settings") {
                SettingsList(selection: $page, attention: attention)
            }
            DetailColumn {
                PageToolbar(title: page.title, subtitle: page.detail) { EmptyView() }
            } content: {
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .padding(EdgeInsets(top: 10, leading: 36, bottom: 40, trailing: 36))
                            .frame(maxWidth: 760 + 72, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Development hook for screenshots: MOSSAD_SCROLL_TO names a group's label, such as "Your server".
                    .task {
                        guard let target = ProcessInfo.processInfo.environment["MOSSAD_SCROLL_TO"] else { return }
                        try? await Task.sleep(for: .milliseconds(600))
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                .id(page)
            }
        }
        .onAppear {
            controller.keysChanged()
            permissions.refresh()
            permissions.setInterval(1)
            // Development hook for screenshots: MOSSAD_SETTINGS_PAGE names a page.
            if let p = ProcessInfo.processInfo.environment["MOSSAD_SETTINGS_PAGE"].flatMap(SettingsPage.init(rawValue:)) { page = p }
        }
        .onDisappear {
            permissions.setInterval(10)
            controller.rebuildPipeline()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralSettings()
        case .recording: RecordingSettings()
        case .google: GoogleSettings()
        case .ai: AISettings()
        case .sync: StorageSyncSettings()
        case .coach: CoachSettings()
        }
    }

    /// The pages that need the owner: missing permissions, missing keys, a failed sync. The coach's cards and
    /// questions are in Coach, with their count in the sidebar.
    private var attention: Set<SettingsPage> {
        var pages = Set<SettingsPage>()
        if !permissions.allGood { pages.insert(.general) }
        let keys = [controller.transcriptionProvider.key, controller.aiProvider.requiresKey ? controller.aiProvider.key : nil].compactMap { $0 }
            + (controller.liveTranscriptEnabled && controller.transcriptionProvider != .assemblyai ? [.assemblyai] : [])
        if keys.contains(where: { !controller.hasKey($0) }) { pages.insert(.ai) }
        if controller.syncActivity.error != nil { pages.insert(.sync) }
        // The backup is chosen and cannot run: the server is gone, or is from before it kept recordings.
        if controller.backupChoice == .server, !controller.serverKeepsRecordings { pages.insert(.sync) }
        return pages
    }
}

/// The pages: a symbol on the fill, the name, one line of what is inside, and the accent dot. The arrow keys
/// move the selection.
private struct SettingsList: View {
    @Binding var selection: SettingsPage
    let attention: Set<SettingsPage>
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsPage.allCases) { p in
                    SettingsListRow(page: p, selected: p == selection, needsYou: attention.contains(p)) {
                        selection = p
                        focused = true
                    }
                }
            }
            .padding(.leading, 4).padding(.trailing, Space.s).padding(.vertical, Space.s)
        }
        .scrollContentBackground(.hidden)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let all = SettingsPage.allCases
        guard let i = all.firstIndex(of: selection) else { return .ignored }
        selection = all[min(max(i + by, 0), all.count - 1)]
        return .handled
    }
}

private struct SettingsListRow: View {
    let page: SettingsPage
    let selected: Bool
    let needsYou: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                IconImage(page.icon, size: 15)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title).font(.system(size: 13, weight: selected ? .semibold : .medium)).foregroundStyle(Palette.ink).cssLineHeight(size: 13)
                    Text(page.contents).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if needsYou {
                    Circle().fill(Palette.accentFill).frame(width: 7, height: 7)
                }
            }
            .padding(.vertical, Space.s).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(needsYou ? "Needs attention" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The pages of Settings, in the order of the list.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, recording, google, ai, sync, coach

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .google: "Google"
        case .ai: "AI"
        case .sync: "Storage & Sync"
        case .coach: "Coach"
        }
    }

    /// The one line in the list.
    var contents: String {
        switch self {
        case .general: "On/off, you, permissions, org chart"
        case .recording: "Recording, voices, calendars, folders"
        case .google: "Calendar, Gemini notes, directory"
        case .ai: "Providers and other AI apps"
        case .sync: "This Mac, iPhone, backup, your server"
        case .coach: "Reviews, voice, emails"
        }
    }

    var detail: String {
        switch self {
        case .general: "Turn Mossad on or off, and what it needs from you and from macOS."
        case .recording: "How Mossad records, names voices, and reads your calendars."
        case .google: "Optional. Your own Google app reads your Google Calendar, the Gemini notes of meetings, and your company directory. Read-only."
        case .ai: "The services that transcribe and summarize your calls, and other apps that read them."
        case .sync: "Where your meetings live: on this Mac, on your iPhone, in a backup of the recordings, and on your own server."
        case .coach: "Reviews of how you communicate, and the coach’s emails."
        }
    }

    var icon: Icon {
        switch self {
        case .general: .settings
        case .recording: .mic
        case .google: .link
        case .ai: .sparkle
        case .sync: .cloud
        case .coach: .coach
        }
    }
}

extension APIKey: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// Saves an API key to the Keychain. The key is never shown, logged, or written anywhere else.
struct KeySheet: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let key: APIKey
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .key, title: key.displayName, subtitle: "Stored in the Keychain. Mossad never shows it again.")
            SecureField("Paste the key", text: $value)
                .textFieldStyle(SheetFieldStyle(monospaced: true))
                .onSubmit(save)
                .padding(.horizontal, 22).padding(.vertical, 16)
            SheetFooter {
                Button("Cancel") { dismiss() }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.sheetPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .mossadSheet(width: 420)
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        do {
            try controller.keychain.set(trimmed, for: key)
            controller.rebuildPipeline()
        } catch {
            Log.error("Saving the \(key.rawValue) key failed")
        }
        controller.keysChanged()
        dismiss()
    }
}

extension APIKey {
    var displayName: String {
        switch self {
        case .assemblyai: "AssemblyAI key"
        case .anthropic: "Anthropic key"
        case .openai: "OpenAI key"
        case .openrouter: "OpenRouter key"
        case .localServer: "Local server key"
        case .deepgram: "Deepgram key"
        case .elevenlabs: "ElevenLabs key"
        case .resend: "Resend key"
        case .postmark: "Postmark server token"
        case .sendgrid: "SendGrid key"
        case .mailgun: "Mailgun key"
        case .brevo: "Brevo key"
        case .sesSecret: "Amazon SES secret access key"
        case .cloudSecret: "Secret access key"
        case .serverSecret: "Server secret"
        case .googleClientID: "Google client ID"
        case .googleClientSecret: "Google client secret"
        case .googleTokens: "Google sign-in"
        }
    }
}
