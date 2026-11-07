import MossadCore
import SwiftUI

/// Where finished recordings are kept: this Mac, or also a personal Cloudflare R2 or Amazon S3 bucket.
struct StorageSettings: View {
    @EnvironmentObject var controller: AppController
    @State private var secret = ""
    @State private var checking = false
    @State private var checkResult: Bool?

    var body: some View {
        SettingsGroup(label: "Storage",
                      footer: controller.storage == "local" ? nil : "Mossad uploads each meeting’s recording (about 14 MB an hour) after the note is written. Notes and transcripts stay on this Mac. Use a key that can only read and write this bucket.") {
            SettingsRow(title: "Keep recordings in") {
                FillPicker(title: "Keep recordings in", selection: $controller.storage,
                           choices: [("local", "This Mac"), ("r2", "Cloudflare R2"), ("s3", "Amazon S3")])
            }
            if controller.storage != "local" {
                field("Endpoint", text: $controller.cloudEndpoint,
                      prompt: controller.storage == "r2" ? "https://<account id>.r2.cloudflarestorage.com" : "https://s3.us-east-1.amazonaws.com")
                field("Bucket", text: $controller.cloudBucket, prompt: "mossad-recordings")
                if controller.storage == "s3" { field("Region", text: $controller.cloudRegion, prompt: "us-east-1") }
                field("Access key ID", text: $controller.cloudAccessKeyID, prompt: "")
                SettingsRow(title: "Secret access key") {
                    HStack(spacing: Space.s) {
                        if !secret.isEmpty { Button("Save", action: saveSecret).buttonStyle(.settingsAccent) }
                        SecureField("Secret access key", text: $secret,
                                    prompt: Text(controller.hasKey(.cloudSecret) ? "Saved in the Keychain" : "Paste the secret"))
                            .textFieldStyle(SettingsFieldStyle(width: 300))
                            .onSubmit(saveSecret)
                    }
                }
                SettingsRow(title: "Keep a local copy for") {
                    HStack(spacing: Space.s) {
                        DaysField(title: "Days to keep a local copy", value: $controller.cloudKeepLocalDays, range: 0...3650)
                        if checking { ProgressView().controlSize(.small) }
                        if let ok = checkResult {
                            HStack(spacing: 5) {
                                Circle().fill(ok ? Palette.ok : Palette.recording).frame(width: 7, height: 7)
                                Text(ok ? "Connected" : "Could not connect").foregroundStyle(ok ? Palette.okText : Palette.recording)
                            }
                            .font(.system(size: 12))
                        }
                        Button("Test connection", action: check).buttonStyle(.settings).disabled(controller.cloudArchive == nil || checking)
                    }
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        SettingsRow(title: title) {
            TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(SettingsFieldStyle(width: 300, monospaced: true))
        }
    }

    private func saveSecret() {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { try controller.keychain.set(value, for: .cloudSecret) } catch { Log.error("Saving the cloud secret failed") }
        secret = ""
        controller.objectWillChange.send()
    }

    private func check() {
        guard let archive = controller.cloudArchive else { return }
        checking = true
        checkResult = nil
        Task {
            let ok = await archive.check()
            checkResult = ok
            checking = false
            if ok { controller.syncCloud() }
        }
    }
}
