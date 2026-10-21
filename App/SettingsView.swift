import AppKit
import MossadCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: AppController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Open Mossad at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Log.error("Launch at login change failed: \(error)")
                        }
                    }
                Stepper("Keep audio for \(controller.retentionDays) days", value: $controller.retentionDays, in: 1...365)
                Text("Transcripts are kept forever. Audio is kept so voices can be learned after a call.")
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
