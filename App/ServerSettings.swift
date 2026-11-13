import AppKit
import MossadCore
import SwiftUI

/// Settings › Storage & Sync › Your server: the connection, then what the server gives: access for AI apps, and
/// share links.
struct ServerGroup: View {
    @EnvironmentObject var controller: AppController
    @Binding var settingUp: Bool
    @State private var confirmDisconnect = false
    @State private var confirmChange = false

    private static let guide = URL(string: "https://github.com/davidwebber10/mossad/tree/main/server#readme")!

    var body: some View {
        SettingsGroup(label: "Your server", footer: controller.serverConnection == nil ? nil : "Anyone with a share link can open that one meeting. Links are hidden from search engines.") {
            if let connection = controller.serverConnection {
                connectionRow(connection)
                if controller.serverNeedsUpdate { ServerUpdateRow() }
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
            Text("Mossad goes back to iCloud. Your server keeps its data, and share links keep working until you stop them or they expire.\(controller.backupChoice == .server ? " Recordings are not backed up until you connect it again." : "")\(recordingsNote)")
        }
        .confirmationDialog("Change to another server?", isPresented: $confirmChange) {
            Button("Change server…") { settingUp = true }
        } message: {
            Text("Another server does not have what is on this one.\(recordingsNote)")
        }
    }

    private func connectionRow(_ connection: ServerConnection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    Text(connection.address.host ?? "")
                        .font(.system(size: Rhythm.bodySize, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink)
                    Text(jobs).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                HStack(spacing: Space.s) {
                    StatusLine(model: status)
                    Button("Check") { controller.checkServer() }.buttonStyle(.settings)
                        .disabled(controller.serverCheck == .checking)
                        .help("Asks your server again. With the recording backup on it, Mossad also sends a small test file.")
                    Menu {
                        Button("Copy secret") { copy(connection.secret) }
                        Button("Change server…") { if recordingsHere > 0 { confirmChange = true } else { settingUp = true } }
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

    /// The recordings whose backup is on this server.
    private var recordingsHere: Int {
        controller.meetings.filter { $0.archived?.kind == .server && $0.archived?.server == controller.serverID && !controller.serverID.isEmpty }.count
    }

    /// What a change of server means for the recordings on this one.
    private var recordingsNote: String {
        let n = recordingsHere
        guard n > 0 else { return "" }
        return " \(n == 1 ? "1 recording is" : "\(n) recordings are") backed up on this server. Without it, \(n == 1 ? "it plays" : "they play") only where this Mac still has the local copy. Mossad keeps every local copy that it has, and sends \(n == 1 ? "it" : "them") to the backup that you choose next."
    }

    /// What the server does now, in one sentence.
    private var jobs: String {
        var list: [String] = []
        if controller.syncWith == .server { list.append("syncs your meetings") }
        else if controller.syncWith == .icloud { list.append("keeps a one-way copy of your meetings, the people in them, your tasks and points, the coach's notes, and your chats for AI apps and share links") }
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
                            detail: "ChatGPT, Claude, and other AI apps can read what your server has after you sign in: your meetings with their transcripts, the people in them, your tasks and points for next time, the coach's notes, and earlier chats. How to present to a person only when Settings › Coach allows it, and never what the coach learned about a person you keep no read on. They cannot change anything.")
                .padding(.top, 9)
            if controller.serverMCP.isEmpty {
                Text("Click Check above to get your server’s AI address.").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.accent)
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
                .font(.system(size: Rhythm.secondarySize))
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

/// Shown when the server reports an older version than this app uses: what is missing, and the steps.
private struct ServerUpdateRow: View {
    @State private var copied = false
    private static let guide = URL(string: "https://github.com/davidwebber10/mossad/tree/main/server#update-your-server")!

    var body: some View {
        SettingsRow(title: "Update your server",
                    detail: "Your server runs an older version than this Mac. Share links, sync, and the backup work as before. Views, PINs, and a change of an expiry need the update.") {
            HStack(spacing: Space.m) {
                SettingsHelpLink(title: "Read the steps", url: Self.guide)
                Button(copied ? "Copied" : "Copy the steps") {
                    copy(AppController.serverUpdateSteps)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .buttonStyle(.settingsAccent)
            }
        }
    }
}

/// The share links that work now, in one line: the Shares page has each link with its numbers and its actions.
private struct ShareLinkRows: View {
    @EnvironmentObject var controller: AppController

    private var count: Int { controller.shareBook.links.filter { !$0.isExpired() && $0.stopping != true }.count }

    var body: some View {
        SettingsRow(title: "Share links",
                    detail: count == 0 ? "No links yet. Open a meeting and click Share." : "\(count == 1 ? "1 link works" : "\(count) links work") now. Shares has each link with its views, its PIN, and its expiry.") {
            Button("Open Shares") { controller.open(.shares) }.buttonStyle(.settings)
        }
    }
}
