import MossadCore
import SwiftUI

/// Where finished recordings are kept: this Mac, or also a personal Cloudflare R2 or Amazon S3 bucket.
struct StorageSettings: View {
    @EnvironmentObject var controller: AppController
    @State private var secret = ""
    @State private var checking = false
    @State private var checkResult: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Keep recordings in")
                Spacer()
                Picker("Keep recordings in", selection: $controller.storage) {
                    Text("This Mac").tag("local")
                    Text("Cloudflare R2").tag("r2")
                    Text("Amazon S3").tag("s3")
                }
                .labelsHidden()
                .fixedSize()
            }
            if controller.storage != "local" {
                field("Endpoint", text: $controller.cloudEndpoint,
                      prompt: controller.storage == "r2" ? "https://<account id>.r2.cloudflarestorage.com" : "https://s3.us-east-1.amazonaws.com")
                field("Bucket", text: $controller.cloudBucket, prompt: "mossad-recordings")
                if controller.storage == "s3" { field("Region", text: $controller.cloudRegion, prompt: "us-east-1") }
                field("Access key ID", text: $controller.cloudAccessKeyID, prompt: "")
                HStack {
                    Text("Secret access key")
                    Spacer()
                    SecureField(controller.hasKey(.cloudSecret) ? "Saved in the Keychain" : "Paste the secret", text: $secret)
                        .frame(width: 220)
                        .onSubmit(saveSecret)
                    if !secret.isEmpty { Button("Save", action: saveSecret).controlSize(.small) }
                }
                HStack {
                    Text("Keep a local copy for")
                    TextField("", value: $controller.cloudKeepLocalDays, format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 44)
                    Stepper("", value: $controller.cloudKeepLocalDays, in: 0...3650).labelsHidden()
                    Text("days").foregroundStyle(.secondary)
                    Spacer()
                    if checking { ProgressView().controlSize(.small) }
                    if let ok = checkResult {
                        Label(ok ? "Connected" : "Could not connect", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(ok ? .green : .red)
                    }
                    Button("Test connection", action: check).controlSize(.small).disabled(controller.cloudArchive == nil || checking)
                }
                Text("Mossad uploads each meeting's recording (about 14 MB an hour) after the note is written. Notes and transcripts stay on this Mac. Use a key that can only read and write this bucket.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: text, prompt: Text(prompt)).frame(width: 300)
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
