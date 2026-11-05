import AVFoundation
import MossadCore
import SwiftUI
import VisionKit

/// Settings on the iPhone: where meetings come from (iCloud or the owner's server), and how to connect.
struct PhoneSettingsView: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice(.icloud, symbol: "icloud.fill", tint: .blue, title: "iCloud",
                           detail: "Your Mac sends meetings through your private iCloud. Nothing to set up.")
                    choice(.server, symbol: "server.rack", tint: .orange, title: "Your server",
                           detail: store.server.map { $0.address.host ?? "" } ?? "Your own Cloudflare. Connect with a code from your Mac.")
                } header: {
                    Text("Sync with")
                } footer: {
                    Text("Use the same choice as Mossad on your Mac, in Settings › Sync & Server.")
                }

                Section {
                    HStack {
                        Label(status, systemImage: store.error == nil ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(store.error == nil ? Color.primary : Color.red)
                        Spacer()
                        if store.syncing { ProgressView() } else {
                            Button("Sync now") { Task { await store.sync() } }
                        }
                    }
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Status") }

                if store.syncWith == .server, store.server != nil {
                    Section {
                        Button("Connect to another server") { connecting = true }
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                    }
                }
                Section {
                    Button("Don't sync", role: store.syncWith == .off ? nil : .destructive) { store.choose(.off) }
                        .disabled(store.syncWith == .off)
                } footer: {
                    Text("With sync off, this iPhone keeps what it has and gets nothing new.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $connecting) { ConnectServerView() }
            .confirmationDialog("Disconnect your server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { store.disconnectServer() }
            } message: {
                Text("This iPhone goes back to iCloud. Your server and its data stay as they are.")
            }
        }
    }

    private var status: String {
        switch store.syncWith {
        case .off: return "Sync is off"
        case .icloud, .server:
            if store.syncing { return "Syncing…" }
            if store.error != nil { return "Sync failed" }
            return store.lastSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Ready"
        }
    }

    private func choice(_ c: SyncChoice, symbol: String, tint: Color, title: String, detail: String) -> some View {
        Button {
            if c == .server, store.server == nil { connecting = true } else { store.choose(c) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(tint.gradient, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: store.syncWith == c ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(store.syncWith == c ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(.vertical, 4)
        }
        .accessibilityAddTraits(store.syncWith == c ? .isSelected : [])
    }
}

/// Connect to the owner's server: scan the code the Mac shows, use the one the Mac put in iCloud Keychain,
/// or type it in. Each way is checked before it is used.
struct ConnectServerView: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var address = ""
    @State private var secret = ""
    @State private var checking = false
    @State private var error: String?
    @State private var connected: ServerConnection?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: connected == nil ? "qrcode.viewfinder" : "checkmark.circle.fill")
                            .font(.system(size: 44)).foregroundStyle(connected == nil ? Color.accentColor : Color.green)
                            .contentTransition(.symbolEffect(.replace))
                        Text(connected == nil ? "Connect your server" : "Connected to \(connected?.address.host ?? "")").font(.title3.weight(.semibold))
                        Text(connected == nil ? "On your Mac, open Mossad › Settings › Sync & Server, and click Show code." : "Your meetings are on the way.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    if connected == nil {
                        Button { scanning = true } label: {
                            Label("Scan code", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!DataScannerViewController.isSupported)
                        .listRowBackground(Color.clear)
                    }
                }
                if connected == nil, let shared = ServerPairing.shared() {
                    Section {
                        Button { check(shared) } label: {
                            Label("Use \(shared.address.host ?? "the server") from iCloud Keychain", systemImage: "key.icloud")
                        }
                    } footer: { Text("Your Mac shared this server through iCloud Keychain.") }
                }
                if connected == nil {
                    Section {
                        TextField("notes.example.com", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        SecureField("Secret", text: $secret)
                        Button("Connect") {
                            guard let url = ServerConnection.address(from: address) else { error = "That is not a web address."; return }
                            check(ServerConnection(address: url, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                        .disabled(address.isEmpty || secret.isEmpty)
                    } header: { Text("Or enter it by hand") }
                }
                if checking { HStack { ProgressView(); Text("Checking your server…").foregroundStyle(.secondary) } }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            .navigationTitle("Your server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: connected == nil ? .cancellationAction : .confirmationAction) {
                    Button(connected == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                CodeScanner { code in
                    scanning = false
                    if let c = ServerPairing.connection(fromCode: code) { check(c) } else { error = "That code is not from Mossad." }
                }
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Button("Cancel") { scanning = false }.buttonStyle(.borderedProminent).padding()
                }
            }
        }
    }

    private func check(_ c: ServerConnection) {
        checking = true
        error = nil
        Task {
            defer { checking = false }
            do {
                let hello = try await ServerClient(c).hello()
                guard hello.authorized else { error = "Your server does not accept this secret."; return }
                withAnimation { connected = c }
                store.connect(c)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Mossad could not reach that server."
            }
        }
    }
}

/// The camera, looking for one QR code.
private struct CodeScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue, text.hasPrefix("mossad-server:") {
                    done = true
                    scanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}
