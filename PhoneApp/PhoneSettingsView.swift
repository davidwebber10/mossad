import AVFoundation
import MossadCore
import SwiftUI
import VisionKit

/// Settings on the iPhone: where meetings come from (iCloud or the owner's server), and how to connect.
struct PhoneSettingsView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = PhoneStore.hook("MOSSAD_CONNECT") != nil
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice(.icloud, symbol: "icloud", title: "iCloud",
                           detail: "Your Mac sends meetings through your private iCloud. Nothing to set up.")
                    choice(.server, symbol: "server.rack", title: "Your server",
                           detail: store.server.map { $0.address.host ?? "" } ?? "Your own Cloudflare. Connect with a code from your Mac.")
                } header: {
                    PhoneLabel("Sync with")
                } footer: {
                    Text("Use the same choice as Mossad on your Mac, in Settings › Sync & Server.")
                        .foregroundStyle(Palette.secondary)
                }
                .listRowBackground(Palette.fill)

                Section {
                    HStack {
                        Label {
                            Text(status).foregroundStyle(Palette.ink)
                        } icon: {
                            if store.error == nil {
                                Image(systemName: "checkmark").foregroundStyle(Palette.ok)
                            } else {
                                WarningMark(size: 18).foregroundStyle(Palette.accent)
                            }
                        }
                        Spacer()
                        if store.syncing { PhoneProcessingMark() } else {
                            Button("Sync now") { Task { await store.sync() } }
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                        }
                    }
                    if let error = store.error {
                        Text(error.message).textRole(.secondary).foregroundStyle(Palette.secondary)
                    }
                } header: { PhoneLabel("Status") }
                .listRowBackground(Palette.fill)

                if store.syncWith == .server, store.server != nil {
                    Section {
                        Button("Connect to another server") { connecting = true }.foregroundStyle(Palette.accent)
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }.foregroundStyle(Palette.recording)
                    } header: { PhoneLabel("Server") }
                    .listRowBackground(Palette.fill)
                }
                Section {
                    Button("Don't sync", role: store.syncWith == .off ? nil : .destructive) { store.choose(.off) }
                        .foregroundStyle(store.syncWith == .off ? Palette.secondary : Palette.recording)
                        .disabled(store.syncWith == .off)
                } footer: {
                    Text("With sync off, this iPhone keeps what it has and gets nothing new.").foregroundStyle(Palette.secondary)
                }
                .listRowBackground(Palette.fill)
            }
            .phonePage()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.buttonStyle(.glassProminent).tint(Palette.accentFill)
                }
            }
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
            if let error = store.error { return error.title }
            return store.lastSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Ready"
        }
    }

    private func choice(_ c: SyncChoice, symbol: String, title: String, detail: String) -> some View {
        Button {
            if c == .server, store.server == nil { connecting = true } else { store.choose(c) }
        } label: {
            HStack(spacing: 14) {
                // The accent tint, not a brand color: platform colors are only for dots.
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36).background(Palette.accentTint, in: .rect(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).textRole(.headline).foregroundStyle(Palette.ink)
                    Text(detail).textRole(.secondary).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Image(systemName: store.syncWith == c ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(store.syncWith == c ? Palette.accentFill : Palette.ring)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityAddTraits(store.syncWith == c ? .isSelected : [])
    }
}

/// Connect to the owner's server: scan the code the Mac shows, use the one the Mac put in iCloud Keychain,
/// or type it in. Each way is checked before it is used.
struct ConnectServerView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var address = ""
    @State private var secret = ""
    @State private var checking = false
    @State private var error: FriendlyError? = PhoneStore.hook("MOSSAD_CONNECT_ERROR").flatMap(ErrorPreview.sample)
    @State private var connected: ServerConnection?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.l) {
                    VStack(spacing: Space.s) {
                        Image(systemName: connected == nil ? "qrcode" : "checkmark")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(connected == nil ? Palette.accent : Palette.ok)
                            .frame(width: 64, height: 64)
                            .background(connected == nil ? Palette.accentTint : Palette.fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            .contentTransition(.symbolEffect(.replace))
                            .accessibilityHidden(true)
                        Text(connected == nil ? "Connect your server" : "Connected to \(connected?.address.host ?? "")")
                            .textRole(.title).foregroundStyle(Palette.ink)
                        Text(connected == nil ? "On your Mac, open Mossad › Settings › Sync & Server, and click Show code." : "Your meetings are on the way.")
                            .textRole(.body).foregroundStyle(Palette.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.s)
                    if connected == nil {
                        Button { scanning = true } label: {
                            Label("Scan code", systemImage: "camera")
                        }
                        .buttonStyle(.phoneFill(wide: true))
                        .disabled(!DataScannerViewController.isSupported)
                        if let shared = ServerPairing.shared() {
                            VStack(alignment: .leading, spacing: 6) {
                                Button { check(shared) } label: {
                                    HStack(spacing: Space.m) {
                                        Image(systemName: "key").foregroundStyle(Palette.accent).accessibilityHidden(true)
                                        Text("Use \(shared.address.host ?? "the server") from iCloud Keychain")
                                            .textRole(.body).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                                        Spacer(minLength: Space.s)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.tertiaryMark)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(Space.m)
                                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                Text("Your Mac shared this server through iCloud Keychain.")
                                    .textRole(.secondary).foregroundStyle(Palette.secondary).padding(.horizontal, 4)
                            }
                        }
                        VStack(alignment: .leading, spacing: Space.s) {
                            PhoneLabel("Or enter it by hand").padding(.horizontal, 4)
                            VStack(spacing: 0) {
                                TextField("notes.example.com", text: $address)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                    .padding(Space.m)
                                Hairline()
                                SecureField("Secret", text: $secret).padding(Space.m)
                            }
                            .textRole(.body)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            Button("Connect") {
                                guard let url = ServerConnection.address(from: address) else { error = Self.problem("That isn't a web address. Check it, then try again."); return }
                                check(ServerConnection(address: url, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines)))
                            }
                            .buttonStyle(.mossadFill)
                            .disabled(address.isEmpty || secret.isEmpty)
                        }
                    }
                    if checking {
                        HStack(spacing: Space.s) {
                            PhoneProcessingMark()
                            Text("Checking your server…").textRole(.secondary).foregroundStyle(Palette.secondary)
                        }
                    }
                    if let error {
                        ErrorCard(error: error)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xl)
            }
            .phonePage()
            .navigationTitle("Your server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: connected == nil ? .cancellationAction : .confirmationAction) {
                    Button(connected == nil ? "Cancel" : "Done") { dismiss() }.tint(Palette.ink)
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                CodeScanner { code in
                    scanning = false
                    if let c = ServerPairing.connection(fromCode: code) { check(c) } else { error = Self.problem("That code isn't from Mossad. Show the code on your Mac again.") }
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
                guard hello.authorized else { error = FriendlyError(kind: .wrongSecret, context: .connectingServer); return }
                withAnimation { connected = c }
                store.connect(c)
            } catch {
                Log.error("Checking the server failed: \(error)")
                self.error = FriendlyError(error, context: .connectingServer, service: "your server")
            }
        }
    }

    private static func problem(_ sentence: String) -> FriendlyError {
        FriendlyError(kind: .other, context: .connectingServer, said: sentence, retries: false)
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
