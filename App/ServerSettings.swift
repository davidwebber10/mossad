import AppKit
import MossadCore
import SwiftUI

/// Settings › Storage & Sync › Your server: the connection, then what the server gives: access for AI apps, and
/// share links.
struct ServerGroup: View {
    @EnvironmentObject var controller: AppController
    @Binding var settingUp: Bool
    @State private var confirmDisconnect = false

    private static let guide = URL(string: "https://github.com/davidwebber10/mossad/tree/main/server#readme")!

    var body: some View {
        SettingsGroup(label: "Your server", footer: controller.serverConnection == nil ? nil : "Anyone with a share link can open that one meeting. Links are hidden from search engines.") {
            if let connection = controller.serverConnection {
                connectionRow(connection)
                AIAccessRows()
                ShareLinkRows()
            } else {
                SettingsRow(title: "Your own server",
                            detail: "A small Cloudflare Worker in your own Cloudflare account. It adds share links, access for ChatGPT and Claude, sync without iCloud, and a backup of your recordings. One person’s use is free.") {
                    HStack(spacing: Space.m) {
                        SettingsHelpLink(title: "Read the guide", url: Self.guide)
                        Button("Set up…") { settingUp = true }.buttonStyle(.settings)
                    }
                }
            }
        }
        .confirmationDialog("Disconnect your server?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { controller.disconnectServer() }
        } message: {
            Text("Mossad goes back to iCloud. Your server keeps its data, and share links keep working until you stop them or they expire.\(controller.backupChoice == .server ? " Recordings are not backed up until you connect it again." : "")")
        }
    }

    private func connectionRow(_ connection: ServerConnection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.address.host ?? "")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink)
                    Text(jobs).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                HStack(spacing: Space.s) {
                    StatusLine(model: status)
                    Button("Check") { controller.checkServer() }.buttonStyle(.settings)
                        .disabled(controller.serverCheck == .checking)
                        .help("Asks your server again. With the recording backup on it, Mossad also sends a small test file.")
                    Menu {
                        Button("Copy secret") { copy(connection.secret) }
                        Button("Change server…") { settingUp = true }
                        Divider()
                        Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                    } label: {
                        IconImage(.chevronDown, size: 10).foregroundStyle(Palette.secondary)
                            .frame(width: 24, height: 24)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Server actions")
                    .help("Copy the secret, change the server, or disconnect")
                }
                .fixedSize()
            }
            .padding(.vertical, 9)
            SettingsCheckFailure(state: controller.serverCheck)
        }
    }

    /// What the server does now, in one sentence.
    private var jobs: String {
        var list: [String] = []
        if controller.syncWith == .server { list.append("syncs your meetings") }
        else if controller.syncWith == .icloud { list.append("keeps a copy of your meetings for AI apps and share links") }
        if controller.backupChoice == .server, controller.serverKeepsRecordings { list.append("keeps your recordings") }
        if controller.syncWith != .icloud { list.append("serves share links") }
        guard let first = list.first else { return "Connected." }
        let sentence = list.count == 1 ? first : list.count == 2 ? list.joined(separator: " and ") : list.dropLast().joined(separator: ", ") + ", and " + list.last!
        return "It " + sentence + "." + (controller.syncWith == .off ? " Sync is off, so no meetings go to it." : "")
    }

    private var status: StatusLine.Model {
        switch controller.serverCheck {
        case .idle: .init(text: "Not checked yet", color: Palette.ring)
        case .checking: .init(text: "Checking…", color: Palette.ring, busy: true)
        case .passed: .init(text: "Connected", color: Palette.ok)
        case .failed: .init(text: "Needs you", color: Palette.accentFill)
        }
    }
}

/// The address AI apps connect to, and how to add it.
private struct AIAccessRows: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRowText(title: "AI access",
                            detail: "ChatGPT, Claude, and other AI apps can search and read your meetings after you sign in: titles, summaries, action items, and transcripts. They cannot see the coach or change anything.")
                .padding(.top, 9)
            if controller.serverMCP.isEmpty {
                Text("Click Check above to get your server’s AI address.").font(.system(size: 12)).foregroundStyle(Palette.accent)
                    .padding(.vertical, 9)
            } else {
                CopyField(text: controller.serverMCP).padding(.top, Space.s)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.m, verticalSpacing: 5) {
                    howTo("ChatGPT", "Settings › Apps & Connectors › Create. Paste the address.")
                    howTo("Claude", "Settings › Connectors › Add custom connector. Paste the address.")
                    GridRow {
                        Text("Sign in").fontWeight(.medium).foregroundStyle(Palette.ink)
                        HStack {
                            Text("A Mossad page opens. Paste your secret and click Allow.").foregroundStyle(Palette.secondary)
                            Spacer(minLength: Space.m)
                            Button("Copy secret") { copy(controller.serverConnection?.secret ?? "") }.buttonStyle(.settings)
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(.top, Space.s).padding(.bottom, 9)
            }
        }
    }

    private func howTo(_ app: String, _ text: String) -> some View {
        GridRow {
            Text(app).fontWeight(.medium).foregroundStyle(Palette.ink).frame(width: 64, alignment: .leading)
            Text(text).foregroundStyle(Palette.secondary)
        }
    }
}

/// The share links that work now, each with Copy link and Stop.
private struct ShareLinkRows: View {
    @EnvironmentObject var controller: AppController
    @State private var stats: [String: ServerClient.ShareStats] = [:]
    @State private var stopping: MeetingLink?

    private var links: [MeetingLink] { controller.shareBook.links.filter { !$0.isExpired() } }

    var body: some View {
        Group {
            SettingsRow(title: "Share links",
                        detail: links.isEmpty ? "No links yet. Open a meeting and click Share." : "\(links.count == 1 ? "1 link works" : "\(links.count) links work") now.")
            ForEach(links, id: \.token) { row($0) }
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
        guard !ServerSample.isOn, let c = controller.serverConnection, !links.isEmpty else { return }
        stats = (try? await ServerClient(c).shareStats()) ?? [:]
    }
}
