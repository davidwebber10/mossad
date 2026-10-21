import AppKit
import MossadCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmDeleteVoices = false

    var body: some View {
        Form {
            Section {
                ForEach(permissions.items) { item in permissionRow(item) }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Click a red row to fix it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recording consent") {
                Label {
                    Text("Mossad records every call automatically and does not tell the other people on the call. Some states and countries require the consent of every person on a call, and the strictest law of any participant can apply. Tell the people on your calls that you record them, or get their consent. Use Skip this call in the menu to stop and delete a recording. This is not legal advice.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section {
                TextField("Your name", text: $controller.ownerName)
                    .onSubmit { controller.rebuildPipeline() }
                TextField("Company (optional)", text: $controller.organization)
                    .onSubmit { controller.rebuildPipeline() }
                Toggle("Recognize voices", isOn: $controller.voiceFingerprints)
                    .onChange(of: controller.voiceFingerprints) { _, _ in controller.rebuildPipeline() }
                Button("Delete all saved voices…", role: .destructive) { confirmDeleteVoices = true }
                    .confirmationDialog("Delete every saved voice?", isPresented: $confirmDeleteVoices) {
                        Button("Delete all voices", role: .destructive) { controller.deleteAllVoices() }
                    } message: {
                        Text("Mossad forgets every voice it learned, including yours. Meeting notes keep their names.")
                    }
            } header: {
                Text("You and voices")
            } footer: {
                Text("Your name labels your side of each call. With Recognize voices on, Mossad saves a voice fingerprint for each person it hears so it can name them in later calls. Some laws treat voice fingerprints as biometric data. Turn it off to keep no fingerprints; speakers are then labeled Speaker A, Speaker B.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recording") {
                Toggle("Open Mossad at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Log.error("Launch at login change failed: \(error)")
                        }
                    }
                Toggle("Delete recordings after a period of time", isOn: $controller.deleteRecordings)
                if controller.deleteRecordings {
                    LabeledContent("Delete after") {
                        HStack(spacing: 6) {
                            TextField("Days", value: $controller.recordingDays, format: .number)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                            Stepper("", value: $controller.recordingDays, in: 1...3650).labelsHidden()
                            Text(controller.recordingDays == 1 ? "day" : "days")
                        }
                    }
                }
                Text(controller.deleteRecordings
                     ? "Mossad deletes a meeting's recording \(controller.recordingDays) days after the call. The note and the transcript stay."
                     : "Mossad keeps each meeting's recording (about 14 MB an hour) so you can listen again. Notes and transcripts are always kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Folders") {
                folderRow("Meetings (Markdown)", controller.paths.meetings)
                folderRow("Audio", controller.paths.audio)
                folderRow("Voices", controller.paths.voices)
            }
            Section("API keys") {
                keyRow("AssemblyAI (transcription)", .assemblyai)
                keyRow("Anthropic (summaries)", .anthropic)
                Text("To update the keys from Doppler, run scripts/import-keys.sh in the Mossad repo, then reopen Mossad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            permissions.setInterval(1)
        }
        .onDisappear {
            permissions.setInterval(10)
            controller.rebuildPipeline()
        }
    }

    private func permissionRow(_ item: PermissionsMonitor.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.state.isGood ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(item.state.isGood ? .green : .red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !item.state.isGood {
                Button(fixLabel(item)) { permissions.fix(item) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { permissions.fix(item) }
    }

    private func fixLabel(_ item: PermissionsMonitor.Item) -> String {
        switch item.state {
        case .notAsked: "Allow…"
        case .needsApp: "Open browser"
        default: "Open Settings…"
        }
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            Button(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { NSWorkspace.shared.open(url) }
                .buttonStyle(.link)
        }
    }

    private func keyRow(_ title: String, _ key: APIKey) -> some View {
        LabeledContent(title) {
            if controller.hasKey(key) {
                Label("Set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}
