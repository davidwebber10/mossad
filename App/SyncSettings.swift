import AppKit
import CoreImage.CIFilterBuiltins
import MossadCore
import SwiftUI

/// Settings › Sync & Server: where meetings sync (iCloud, the owner's own server, or nowhere) as radio rows,
/// then what the server gives: the iPhone, AI apps over MCP, and share links.
struct SyncSettings: View {
    @EnvironmentObject var controller: AppController
    @State private var settingUp = false

    var body: some View {
        LabelColumnStack {
            SettingsGroup(label: "Sync to") {
                RadioRow(title: "iCloud", detail: "Your Apple devices, through your private iCloud. Nothing to set up.",
                         selected: controller.syncWith == .icloud) { controller.chooseSync(.icloud) } trailing: {
                    StatusLine(model: iCloudStatus)
                }
                .disabled(!AppController.hasICloud)
                RadioRow(title: "Your server", detail: "Your own Cloudflare. Adds share links and ChatGPT.",
                         selected: controller.syncWith == .server) {
                    if controller.serverConnection == nil { settingUp = true } else { controller.chooseSync(.server) }
                } trailing: {
                    StatusLine(model: serverStatus)
                }
                RadioRow(title: "Don’t sync", detail: controller.syncWith == .off
                            ? "Your meetings stay on this Mac, and the iPhone app does not get them." : "Keep everything on this Mac.",
                         selected: controller.syncWith == .off) { controller.chooseSync(.off) } trailing: { EmptyView() }
            }
            if controller.serverConnection != nil {
                ServerGroup(settingUp: $settingUp)
                if controller.syncWith == .server { PhonePairing() }
            } else if controller.syncWith == .server {
                SettingsGroup(label: "Your server") {
                    SettingsRow(title: "Finish setting up your server", detail: "Four short steps. Mossad checks each one.") {
                        Button("Set up…") { settingUp = true }.buttonStyle(.settingsAccent)
                    }
                }
            }
            if controller.syncWith == .icloud {
                SettingsGroup(label: "iPhone", footer: "Finished meetings, their summaries and transcripts, and the coach’s notes go to your private iCloud, where Mossad for iPhone reads them. Audio stays where it is.") {
                    SyncNowRow()
                    AIKeyToggle()
                }
            }
            if controller.serverConnection != nil {
                AIAppsGroup()
                ShareLinksGroup()
            }
        }
        .sheet(isPresented: $settingUp) { ServerSetupSheet() }
        // Development hook for screenshots: MOSSAD_SERVER_SETUP shows the setup steps over the page.
        .overlay(alignment: .top) {
            if ProcessInfo.processInfo.environment["MOSSAD_SERVER_SETUP"] != nil {
                ServerSetupSheet()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 30)
            }
        }
    }

    private var iCloudStatus: StatusLine.Model {
        guard AppController.hasICloud else { return .init(text: "Not in this build", color: Palette.ring) }
        guard controller.syncWith == .icloud else { return .init(text: "Available", color: Palette.ring) }
        return activityStatus
    }

    private var serverStatus: StatusLine.Model {
        guard controller.serverConnection != nil else { return .init(text: "Not set up", color: Palette.ring) }
        guard controller.syncWith == .server else {
            return controller.syncWith == .icloud ? .init(text: "Has a copy for ChatGPT and links", color: Palette.ok) : .init(text: "Set up · not syncing", color: Palette.ring)
        }
        return activityStatus
    }

    private var activityStatus: StatusLine.Model {
        let a = controller.syncActivity
        if a.running { return .init(text: "Syncing…", color: Palette.ring, busy: true) }
        if let error = a.error { return .init(text: error.title, color: Palette.accentFill) }
        if let last = a.last { return .init(text: "Synced \(last.formatted(.relative(presentation: .named)))", color: Palette.ok) }
        return .init(text: "On", color: Palette.ok)
    }
}

/// When it last synced and Sync now; after a failure, the reason and that Mossad tries again by itself.
private struct SyncNowRow: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        if let error = controller.syncActivity.error {
            // Also when trying again as it is cannot work: after the owner fixes the cause, this is the way to sync now.
            ErrorCard(error: error, retryTitle: "Sync now", retry: controller.syncActivity.running ? nil : { controller.syncNow() },
                      note: controller.syncActivity.last.map { "Last synced \($0.formatted(.relative(presentation: .named)))." })
                .padding(.vertical, 9)
        } else {
            HStack(alignment: .center, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    if let last = controller.syncActivity.last {
                        Text("Synced \(last.formatted(.relative(presentation: .named)))").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                    }
                    Text("Mossad syncs after each meeting and every five minutes.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: Space.m)
                if controller.syncActivity.running { ProgressView().controlSize(.small) }
                Button("Sync now") { controller.syncNow() }.buttonStyle(.settings).disabled(controller.syncActivity.running)
            }
            .padding(.vertical, 9)
        }
    }
}

private struct AIKeyToggle: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        SettingsSwitchRow(title: "Use my AI key on my iPhone",
                          detail: "Chat and the coach on the iPhone use the provider and key chosen here, through iCloud Keychain.",
                          isOn: $controller.shareAIKey)
            .onChange(of: controller.shareAIKey) { _, _ in controller.updateSharedAIKey() }
    }
}

// MARK: The server, set up

private struct ServerGroup: View {
    @EnvironmentObject var controller: AppController
    @Binding var settingUp: Bool
    @State private var confirmDisconnect = false

    var body: some View {
        SettingsGroup(label: "Your server") {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.serverConnection?.address.host ?? "")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink)
                    Text(controller.syncWith == .server ? "Your meetings sync here. Only your devices have the secret."
                         : controller.syncWith == .icloud ? "Keeps a copy of your meetings for ChatGPT and share links. iCloud still syncs your iPhone."
                         : "Share links work. Sync is off, so no meetings go to it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                Menu {
                    Button("Copy secret") { copy(controller.serverConnection?.secret ?? "") }
                    Button("Change server…") { settingUp = true }
                    Divider()
                    Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                } label: {
                    IconImage(.chevronDown, size: 10).foregroundStyle(Palette.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Server actions")
                .help("Copy the secret, change the server, or disconnect")
            }
            .padding(.vertical, 9)
            if controller.syncWith == .server { SyncNowRow() }
        }
        .confirmationDialog("Disconnect your server?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { controller.disconnectServer() }
        } message: {
            Text("Mossad goes back to iCloud. Your server keeps its data, and share links keep working until you stop them or they expire.")
        }
    }
}

/// The pairing code for the iPhone: a quiet tile with Show code, which opens the code in a card that hides
/// itself after a minute, because it holds the secret.
private struct PhonePairing: View {
    @EnvironmentObject var controller: AppController
    @State private var showCode = false

    var body: some View {
        SettingsGroup(label: "Your iPhone") {
            HStack(alignment: .center, spacing: 20) {
                VStack(spacing: 10) {
                    IconImage(.qrLarge, size: 28).foregroundStyle(Palette.tertiaryMark)
                        .accessibilityHidden(true)
                    Button("Show code") { showCode = true }.buttonStyle(.settings)
                        .popover(isPresented: $showCode, arrowEdge: .trailing) { PairingCard() }
                }
                .frame(width: 120, height: 120)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Connect Mossad on your iPhone").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 0) {
                        step(1, "Open Mossad on your iPhone.")
                        step(2, "Tap the gear on the Meetings screen.")
                        step(3, "Choose Your server, then Scan code.")
                    }
                    .padding(.top, 6)
                    Text("The code holds your secret, so it hides again after a minute.")
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.top, 6)
                }
            }
            .padding(.top, 9).padding(.bottom, 12)
            SettingsSwitchRow(title: "Also send it through iCloud Keychain", detail: "Your iPhone then finds the server on its own, with no code.",
                              isOn: $controller.serverOnPhone)
                .disabled(!AppController.hasICloud)
                .onChange(of: controller.serverOnPhone) { _, _ in controller.updateSharedServer() }
            AIKeyToggle()
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Palette.secondary)
                .frame(width: 18, height: 18).background(Palette.fill, in: Circle())
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 3)
    }
}

/// The code itself, black on white so any camera reads it, with a countdown to when it hides.
private struct PairingCard: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var shown = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect Mossad on your iPhone").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            Group {
                if let c = controller.serverConnection, let image = QRCode.image(ServerPairing.code(for: c)) {
                    Image(nsImage: image).interpolation(.none).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 160, height: 160)
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .accessibilityLabel("Pairing code")
            VStack(alignment: .leading, spacing: 2) {
                Text("1. Open Mossad on your iPhone.")
                Text("2. Tap the gear on the Meetings screen.")
                Text("3. Choose Your server, then Scan code.")
            }
            .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
            .padding(.top, 14)
            TimelineView(.periodic(from: shown, by: 1)) { context in
                let left = max(0, 60 - Int(context.date.timeIntervalSince(shown)))
                Text("The code holds your secret, so it hides again in 0:\(String(format: "%02d", left)).")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary).monospacedDigit()
                    .onChange(of: left) { _, l in if l == 0 { dismiss() } }
            }
            .padding(.top, Space.s)
        }
        .padding(18)
        .frame(width: 300)
    }
}

private struct AIAppsGroup: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        SettingsGroup(label: "ChatGPT and other AI apps",
                      footer: "Read-only. The app can search and read your meetings: titles, summaries, action items, and transcripts. It cannot see the coach or change anything.") {
            if controller.serverMCP.isEmpty {
                Text("Check your server again to get its AI address.").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .padding(.vertical, 9)
            } else {
                CopyField(text: controller.serverMCP).padding(.vertical, 9)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.m, verticalSpacing: 5) {
                    howTo("ChatGPT", "Settings › Apps & Connectors › Create. Paste the address.")
                    howTo("Claude", "Settings › Connectors › Add custom connector. Paste the address.")
                    GridRow {
                        Text("Sign in").fontWeight(.semibold).foregroundStyle(Palette.ink)
                        HStack {
                            Text("A Mossad page opens. Paste your secret and click Allow.").foregroundStyle(Palette.secondary)
                            Spacer(minLength: Space.m)
                            Button("Copy secret") { copy(controller.serverConnection?.secret ?? "") }.buttonStyle(.settings)
                        }
                    }
                }
                .font(.system(size: 12.5))
                .padding(.vertical, 9)
            }
        }
    }

    private func howTo(_ app: String, _ text: String) -> some View {
        GridRow {
            Text(app).fontWeight(.semibold).foregroundStyle(Palette.ink).frame(width: 64, alignment: .leading)
            Text(text).foregroundStyle(Palette.secondary)
        }
    }
}

private struct ShareLinksGroup: View {
    @EnvironmentObject var controller: AppController
    @State private var stats: [String: ServerClient.ShareStats] = [:]
    @State private var stopping: MeetingLink?

    private var links: [MeetingLink] { controller.shareBook.links.filter { !$0.isExpired() } }

    var body: some View {
        SettingsGroup(label: "Share links", footer: "Anyone with a link can open that one meeting. Links are hidden from search engines.") {
            if links.isEmpty {
                Text("No links yet. Open a meeting and click Share.").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .padding(.vertical, 9)
            } else {
                ForEach(links, id: \.token) { row($0) }
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
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Button(link.title) { controller.openMeeting(link.callID) }
                    .buttonStyle(SettingsTextButtonStyle(color: Palette.ink, weight: .medium))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(detail(link)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: Space.m)
            Button("Copy link") { if let url = controller.shareURL(link) { copy(url.absoluteString) } }.buttonStyle(.settings)
            Button("Stop") { stopping = link }
                .buttonStyle(SettingsTextButtonStyle(color: Palette.recording, weight: .medium))
                .help("Stop sharing")
                .accessibilityLabel("Stop sharing \(link.title)")
        }
        .padding(.vertical, 9)
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
