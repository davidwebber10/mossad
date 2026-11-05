import AppKit
import CoreImage.CIFilterBuiltins
import MossadCore
import SwiftUI

/// Settings > Sync & Server: where meetings sync (iCloud or the owner's own server), and what the server gives:
/// the iPhone, AI apps over MCP, and share links.
struct SyncSettings: View {
    @EnvironmentObject var controller: AppController
    @State private var settingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                SyncChoiceCard(symbol: "icloud.fill", tint: .blue, title: "iCloud",
                               detail: "Your Apple devices, through your private iCloud. Nothing to set up.",
                               status: iCloudStatus, selected: controller.syncWith == .icloud) {
                    controller.chooseSync(.icloud)
                }
                .disabled(!AppController.hasICloud)
                SyncChoiceCard(symbol: "server.rack", tint: .orange, title: "Your server",
                               detail: "Your own Cloudflare. Adds share links and ChatGPT.",
                               status: serverStatus, selected: controller.syncWith == .server) {
                    if controller.serverConnection == nil { settingUp = true } else { controller.chooseSync(.server) }
                }
            }
            HStack(spacing: 6) {
                if controller.syncWith == .off {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("Sync is off. Your meetings stay on this Mac, and the iPhone app does not get them.").foregroundStyle(.secondary)
                } else {
                    Button("Don't sync") { controller.chooseSync(.off) }.buttonStyle(.link)
                    Text("to keep everything on this Mac.").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))
            .padding(.leading, 4)

            switch controller.syncWith {
            case .icloud: ICloudDetails()
            case .server:
                if controller.serverConnection != nil { ServerDetails(settingUp: $settingUp) } else { finishSetup }
            case .off: EmptyView()
            }
            if controller.syncWith != .server, controller.serverConnection != nil {
                ServerExtras()
            }
        }
        .sheet(isPresented: $settingUp) { ServerSetupSheet() }
        // Development hook for screenshots: MOSSAD_SERVER_SETUP shows the setup steps over the page.
        .overlay {
            if ProcessInfo.processInfo.environment["MOSSAD_SERVER_SETUP"] != nil {
                ServerSetupSheet().clipShape(RoundedRectangle(cornerRadius: 12)).shadow(radius: 20)
            }
        }
    }

    private var finishSetup: some View {
        SettingsCard {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 18)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setting up your server").font(.system(size: 13, weight: .semibold))
                    Text("Four short steps. Mossad checks each one.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set up…") { settingUp = true }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var iCloudStatus: StatusLine.Model {
        guard AppController.hasICloud else { return .init(text: "Not in this build", color: .secondary) }
        guard controller.syncWith == .icloud else { return .init(text: "Available", color: .secondary) }
        return activityStatus
    }

    private var serverStatus: StatusLine.Model {
        guard controller.serverConnection != nil else { return .init(text: "Not set up", color: .secondary) }
        guard controller.syncWith == .server else { return .init(text: "Set up · not used for sync", color: .secondary) }
        return activityStatus
    }

    private var activityStatus: StatusLine.Model {
        let a = controller.syncActivity
        if a.running { return .init(text: "Syncing…", color: .blue, busy: true) }
        if a.error != nil { return .init(text: "Sync failed", color: Theme.recording) }
        if let last = a.last { return .init(text: "Synced \(last.formatted(.relative(presentation: .named)))", color: Theme.listening) }
        return .init(text: "On", color: Theme.listening)
    }
}

// MARK: Pieces

/// One of the two big choices at the top of the page.
private struct SyncChoiceCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let status: StatusLine.Model
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18)).foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                StatusLine(model: status)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : (hover ? Color.secondary.opacity(0.5) : Theme.separator), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StatusLine: View {
    struct Model {
        var text: String
        var color: Color
        var busy = false
    }

    let model: Model

    var body: some View {
        HStack(spacing: 6) {
            if model.busy { ProgressView().controlSize(.mini) } else { Circle().fill(model.color).frame(width: 7, height: 7) }
            Text(model.text).font(.system(size: 11, weight: .medium)).foregroundStyle(model.color == .secondary ? .secondary : .primary)
        }
    }
}

/// A rounded card with a title, like the other Settings groups.
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.separator))
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 4).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct ICloudDetails: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        SettingsCard(title: "iPhone", footer: "Finished meetings, their summaries and transcripts, and the coach's notes go to your private iCloud, where Mossad for iPhone reads them. Audio stays where it is.") {
            SyncNowRow()
            Divider()
            AIKeyToggle()
        }
    }
}

private struct SyncNowRow: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let error = controller.syncActivity.error {
                    Text("The last sync failed").font(.system(size: 12, weight: .medium))
                    Text(error).foregroundStyle(Theme.recording).fixedSize(horizontal: false, vertical: true)
                } else if let last = controller.syncActivity.last {
                    Text("Synced \(last.formatted(.relative(presentation: .named)))").font(.system(size: 12, weight: .medium))
                    Text("Mossad syncs after each meeting and every five minutes.").foregroundStyle(.secondary)
                } else {
                    Text("Mossad syncs after each meeting and every five minutes.").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if controller.syncActivity.running { ProgressView().controlSize(.small) }
            Button("Sync now") { controller.syncNow() }.disabled(controller.syncActivity.running)
        }
    }
}

private struct AIKeyToggle: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Toggle(isOn: $controller.shareAIKey) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use my AI key on my iPhone")
                Text("Chat and the coach on the iPhone use the provider and key chosen here, through iCloud Keychain.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .onChange(of: controller.shareAIKey) { _, _ in controller.updateSharedAIKey() }
    }
}

// MARK: The server, set up

private struct ServerDetails: View {
    @EnvironmentObject var controller: AppController
    @Binding var settingUp: Bool
    @State private var confirmDisconnect = false

    var body: some View {
        SettingsCard(title: "Your server") {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 16)).foregroundStyle(.orange)
                    .frame(width: 34, height: 34).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.serverConnection?.address.host ?? "").font(.system(size: 13, weight: .semibold))
                    Text("Your meetings sync here. Only your devices have the secret.").foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Copy secret") { copy(controller.serverConnection?.secret ?? "") }
                    Button("Change server…") { settingUp = true }
                    Divider()
                    Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Divider()
            SyncNowRow()
        }
        .confirmationDialog("Disconnect your server?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { controller.disconnectServer() }
        } message: {
            Text("Mossad goes back to iCloud. Your server keeps its data, and share links keep working until you stop them or they expire.")
        }
        ServerExtras()
    }
}

/// The iPhone code, AI apps, and share links: what a set-up server gives, whatever syncs.
private struct ServerExtras: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        if controller.syncWith == .server { PhonePairing() }
        AIAppsCard()
        ShareLinksCard()
    }
}

private struct PhonePairing: View {
    @EnvironmentObject var controller: AppController
    @State private var showCode = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        SettingsCard(title: "Your iPhone") {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    if showCode, let c = controller.serverConnection, let image = QRCode.image(ServerPairing.code(for: c)) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 128, height: 128)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "qrcode").font(.system(size: 34)).foregroundStyle(.tertiary)
                            Button("Show code") { reveal() }.controlSize(.small)
                        }
                    }
                }
                .frame(width: 148, height: 148)
                .background(showCode ? Color.white : Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect Mossad on your iPhone").font(.system(size: 13, weight: .semibold))
                    step(1, "Open Mossad on your iPhone.")
                    step(2, "Tap the gear on the Meetings screen.")
                    step(3, "Choose Your server, then Scan code.")
                    Text("The code holds your secret, so it hides again after a minute.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            Toggle(isOn: $controller.serverOnPhone) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also send it through iCloud Keychain")
                    Text("Your iPhone then finds the server on its own, with no code.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!AppController.hasICloud)
            .onChange(of: controller.serverOnPhone) { _, _ in controller.updateSharedServer() }
            Divider()
            AIKeyToggle()
        }
        .onDisappear { hideTask?.cancel() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 17, height: 17).background(Color.accentColor, in: Circle())
            Text(text)
        }
    }

    private func reveal() {
        withAnimation { showCode = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { withAnimation { showCode = false } }
        }
    }
}

private struct AIAppsCard: View {
    @EnvironmentObject var controller: AppController
    @State private var copied = false

    var body: some View {
        SettingsCard(title: "ChatGPT and other AI apps",
                     footer: "Read-only. The app can search and read your meetings: titles, summaries, action items, and transcripts. It cannot see the coach or change anything.") {
            if controller.serverMCP.isEmpty {
                Text("Check your server again to get its AI address.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(controller.serverMCP).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
                    Button(copied ? "Copied" : "Copy") {
                        copy(controller.serverMCP)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    howTo("ChatGPT", "Settings › Apps & Connectors › Create. Paste the address.")
                    howTo("Claude", "Settings › Connectors › Add custom connector. Paste the address.")
                    howTo("Sign in", "A Mossad page opens. Paste your secret and click Allow.")
                }
                HStack {
                    Spacer()
                    Button("Copy secret") { copy(controller.serverConnection?.secret ?? "") }.controlSize(.small)
                }
            }
        }
    }

    private func howTo(_ app: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(app).font(.system(size: 12, weight: .semibold)).frame(width: 60, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct ShareLinksCard: View {
    @EnvironmentObject var controller: AppController
    @State private var stats: [String: ServerClient.ShareStats] = [:]
    @State private var stopping: MeetingLink?

    private var links: [MeetingLink] { controller.shareBook.links.filter { !$0.isExpired() } }

    var body: some View {
        SettingsCard(title: "Share links", footer: "Anyone with a link can open that one meeting. Links are hidden from search engines.") {
            if links.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(.tertiary)
                    Text("No links yet. Open a meeting and click Share.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(links.enumerated()), id: \.element.token) { i, link in
                    if i > 0 { Divider() }
                    row(link)
                }
            }
        }
        .task { await loadStats() }
        .confirmationDialog("Stop sharing this meeting?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), presenting: stopping) { link in
            Button("Stop sharing", role: .destructive) { Task { try? await controller.stopSharing(link) } }
        } message: { _ in
            Text("The link stops working at once, and the copy on your server is deleted.")
        }
    }

    private func row(_ link: MeetingLink) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Button(link.title) { controller.openMeeting(link.callID) }.buttonStyle(.link).font(.system(size: 12, weight: .medium))
                Text(detail(link)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { if let url = controller.shareURL(link) { copy(url.absoluteString) } } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy link")
            Button { stopping = link } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Stop sharing")
        }
    }

    private func detail(_ link: MeetingLink) -> String {
        var parts = [parts(link.options)]
        parts.append(link.expires.map { "until \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "no expiry")
        if let s = stats[link.id] {
            parts.append("\(s.views) \(s.views == 1 ? "view" : "views")")
            if s.questions > 0 { parts.append("\(s.questions) \(s.questions == 1 ? "question" : "questions")") }
        }
        return parts.joined(separator: " · ")
    }

    private func parts(_ o: ShareOptions) -> String {
        [o.summary ? "Summary" : nil, o.transcript ? "Transcript" : nil, o.recording ? "Recording" : nil, o.chat ? "Chat" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func loadStats() async {
        guard let c = controller.serverConnection, !links.isEmpty else { return }
        stats = (try? await ServerClient(c).shareStats()) ?? [:]
    }
}

// MARK: Setup

/// Four steps, each checked before the next opens: deploy, the address, the secret, the first sync.
struct ServerSetupSheet: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss

    enum Check: Equatable { case idle, checking, ok, failed(String) }

    @State private var address = ""
    @State private var addressCheck = Check.idle
    @State private var foundAddress: URL?
    @State private var makeNew = true
    @State private var newSecret = ServerConnection.newSecret()
    @State private var pasted = ""
    @State private var secretCheck = Check.idle
    @State private var hello: ServerClient.Hello?
    @State private var started = false
    @State private var copiedSecret = false

    private static let guide = URL(string: "https://github.com/davidwebber10/mossad/tree/main/server#readme")!
    private static let commands = """
    cd server && npm install && npx wrangler login
    npx wrangler d1 create mossad
    npx wrangler r2 bucket create mossad-files
    npx wrangler kv namespace create OAUTH_KV
    """

    private var secret: String { makeNew ? newSecret : pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var syncDone: Bool { started && !controller.syncActivity.running && controller.syncActivity.last != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up your server").font(.system(size: 17, weight: .semibold))
                    Text("Sync, share links, and ChatGPT, on your own Cloudflare.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SetupStep(number: 1, title: "Deploy the server", state: foundAddress != nil ? .done : .active, last: false) {
                        Text("The server is a small Cloudflare Worker that runs in your own Cloudflare account. One person's use is free.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Open the setup guide") { NSWorkspace.shared.open(Self.guide) }.buttonStyle(.borderedProminent)
                            Button("Copy the first commands") { copy(Self.commands) }
                        }
                        Text("Already deployed? Go on to step 2.").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    SetupStep(number: 2, title: "Enter its address", state: foundAddress != nil ? .done : .active, last: false) {
                        HStack {
                            TextField("", text: $address, prompt: Text("notes.example.com"))
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                                .onSubmit(checkAddress)
                                .onChange(of: address) { _, _ in if addressCheck != .checking { addressCheck = .idle; foundAddress = nil } }
                            Button("Check", action: checkAddress).disabled(ServerConnection.address(from: address) == nil || addressCheck == .checking)
                        }
                        CheckLabel(check: addressCheck, ok: "Found your Mossad server.")
                    }
                    SetupStep(number: 3, title: "Add your secret", state: hello != nil ? .done : (foundAddress == nil ? .todo : .active), last: false) {
                        Picker("", selection: $makeNew) {
                            Text("Make a new secret").tag(true)
                            Text("I have a secret").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                        .onChange(of: makeNew) { _, _ in secretCheck = .idle; hello = nil }
                        if makeNew {
                            Text("Put this secret on your server. In the server folder, run the command, paste the secret when it asks, then deploy again.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("npx wrangler secret put OWNER_SECRET && npx wrangler deploy")
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
                            HStack {
                                Button(copiedSecret ? "Secret copied" : "Copy secret") {
                                    copy(newSecret)
                                    copiedSecret = true
                                }
                                Button("Copy command") { copy("npx wrangler secret put OWNER_SECRET && npx wrangler deploy") }
                            }
                        } else {
                            SecureField("", text: $pasted, prompt: Text("Paste your secret")).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                                .onSubmit(checkSecret)
                        }
                        HStack {
                            Button("Check secret", action: checkSecret).disabled(secret.isEmpty || secretCheck == .checking)
                            CheckLabel(check: secretCheck, ok: "Your server accepts this secret.")
                        }
                    }
                    .disabled(foundAddress == nil)
                    SetupStep(number: 4, title: "Move your data", state: syncDone ? .done : (hello == nil ? .todo : .active), last: true) {
                        Text("Mossad sends your meetings' notes and transcripts to your server, and then syncs there from now on. Audio stays on this Mac.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !started {
                            Button("Start syncing", action: start).buttonStyle(.borderedProminent)
                        } else if let error = controller.syncActivity.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.recording)
                            Button("Try again") { controller.syncNow() }
                        } else if syncDone {
                            Label("Your meetings are on your server.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.listening)
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Sending your meetings…").foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(hello == nil)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(!started)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .background(Theme.background)
        .onAppear {
            if let c = controller.serverConnection {
                address = c.address.host ?? ""
                makeNew = false
                pasted = c.secret
            }
        }
    }

    private func checkAddress() {
        guard let url = ServerConnection.address(from: address) else { return }
        addressCheck = .checking
        Task {
            do {
                _ = try await ServerClient(ServerConnection(address: url, secret: "")).hello()
                foundAddress = url
                addressCheck = .ok
            } catch {
                foundAddress = nil
                addressCheck = .failed(error is ServerError ? "That address answers, but not like a Mossad server." : "Mossad could not reach that address. Check it, and that the server is deployed.")
            }
        }
    }

    private func checkSecret() {
        guard let url = foundAddress, !secret.isEmpty else { return }
        secretCheck = .checking
        Task {
            do {
                let h = try await ServerClient(ServerConnection(address: url, secret: secret)).hello()
                if h.authorized {
                    hello = h
                    secretCheck = .ok
                } else {
                    hello = nil
                    secretCheck = .failed(makeNew ? "Not yet. Run the command, paste the secret, and deploy, then check again." : "Your server does not accept this secret.")
                }
            } catch {
                secretCheck = .failed("Mossad could not reach your server.")
            }
        }
    }

    private func start() {
        guard let url = foundAddress, let hello else { return }
        started = true
        controller.connectServer(ServerConnection(address: url, secret: secret), hello: hello)
    }
}

private struct SetupStep<Content: View>: View {
    enum State { case todo, active, done }

    let number: Int
    let title: String
    let state: State
    let last: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(state == .done ? Theme.listening : (state == .active ? Color.accentColor : Theme.field))
                    if state == .done {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(state == .active ? .white : .secondary)
                    }
                }
                .frame(width: 24, height: 24)
                if !last { Rectangle().fill(Theme.separator).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(state == .todo ? .secondary : .primary)
                if state != .todo { content }
            }
            .padding(.bottom, last ? 0 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.smooth, value: state)
    }
}

private struct CheckLabel: View {
    let check: ServerSetupSheet.Check
    let ok: String

    var body: some View {
        switch check {
        case .idle: EmptyView()
        case .checking: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        case .ok: Label(ok, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.listening)
        case .failed(let message): Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.recording).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
