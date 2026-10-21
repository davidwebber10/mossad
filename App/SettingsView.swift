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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.system(size: 18, weight: .bold)).kerning(-0.3).padding(.top, 8)
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
                        group("API keys", footer: "Keys are stored in the Keychain.") {
                            keyRow("AssemblyAI", "Transcription and speaker turns", .assemblyai)
                            keyRow("Anthropic", "Summary and action items with Claude", .anthropic)
                        }
                    }
                }
            }
            .font(.system(size: 12))
            .padding(EdgeInsets(top: 8, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
            Text(key == .assemblyai ? "AssemblyAI key" : "Anthropic key").font(.headline)
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
