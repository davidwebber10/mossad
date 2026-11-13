import MossadCore
import SwiftUI

/// Every link the owner made: on the left the shares with their expiry and views, on the right one share with
/// its link, its views, its PIN, and its expiry. The numbers come from the owner's server.
struct SharesView: View {
    @EnvironmentObject var controller: AppController
    @StateObject private var model = SharesModel()
    @State private var selection: String?
    @State private var editing: CallRecord?
    @State private var search = ListSearchState()

    private var hasServer: Bool { ShareSample.kind != nil || controller.serverConnection != nil }
    private var links: [MeetingLink] { model.sampleLinks ?? controller.shareBook.links }
    private var rows: [ShareRow] { ShareRows.make(links: links, remote: model.remote) }

    /// Why each share is in the searched list: its title, or a person of its meeting, shown under the row. Nil with
    /// no search.
    private func searched(_ rows: [ShareRow]) -> [String: ListMatch]? {
        let words = ListSearch(search.query)
        guard !words.isEmpty else { return nil }
        var out: [String: ListMatch] = [:]
        for row in rows {
            let record = row.link.flatMap { link in controller.meetings.first { $0.id == link.callID } }
            let people = record.map { Set($0.speakerNames.values.filter { !$0.hasPrefix("Speaker ") }).sorted() + $0.attendees } ?? []
            out[row.id] = words.match(title: row.title, fields: people.map { ListField("People", $0) })
        }
        return out
    }
    /// Development hook for screenshots: MOSSAD_SHARE_ROW=2 opens the third of the made-up shares.
    private static let previewRow = ShareSample.kind == nil ? nil : ProcessInfo.processInfo.environment["MOSSAD_SHARE_ROW"].flatMap { Int($0) }

    var body: some View {
        let all = rows
        let matches = searched(all)
        let rows = matches.map { m in all.filter { m[$0.id] != nil } } ?? all
        Group {
            if !hasServer {
                DetailColumn { PageToolbar(title: "Shares") {} } content: {
                    EmptyState(symbol: "link", title: "Share links need your own server",
                               message: "Mossad puts the parts of a meeting that you choose on a small server in your own Cloudflare account, behind a private link. Your shares then show here, with who opened them.",
                               action: ("Set up your server…", openServerSettings))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if all.isEmpty {
                DetailColumn { PageToolbar(title: "Shares") {} } content: {
                    VStack(spacing: 0) {
                        ServerNotice(server: model.server).padding(.horizontal, Detail.gutter).padding(.top, Detail.bodyTop)
                        EmptyState(symbol: "link", title: "No shares yet",
                                   message: "Open a meeting and choose Share… to make a private link to it. The link shows here, with when it expires and who opened it.",
                                   action: ("Go to Meetings", { controller.open(.meetings) }))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                // The chosen share, or the first one: a share that was stopped, or that the search hides, leaves the
                // choice to the next. With no share found, the detail keeps the chosen one.
                let pool = rows.isEmpty ? all : rows
                let shown = pool.first { $0.id == selection } ?? Self.previewRow.flatMap { pool.indices.contains($0) ? pool[$0] : nil } ?? pool[0]
                HStack(spacing: 0) {
                    ListColumn("Shares", widthKey: "shares", search: $search, searchPrompt: "Search shares and their people") {
                        if rows.isEmpty {
                            Text("No share matches “\(search.trimmed)”.")
                                .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary)
                                .padding(.horizontal, 24).padding(.top, Space.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ShareList(rows: rows, matches: matches ?? [:], selection: Binding(get: { shown.id }, set: { selection = $0 }))
                        }
                    }
                    ShareDetailPane(row: shown, model: model, edit: { editing = $0 })
                        .id(shown.id)
                }
            }
        }
        .overlay(alignment: .bottom) { UndoStopBar() }
        .task {
            // The numbers are read when the page opens, and again each minute while it stays open.
            while !Task.isCancelled {
                await model.load(controller)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: controller.shareBook) { _, _ in Task { await model.load(controller) } }
        .navigationPart(.shares, .init(item: selection, search: search.query)) { p in
            search.show(p.search)
            selection = p.item
        }
        .sheet(item: $editing, onDismiss: { Task { await model.load(controller) } }) { record in
            ShareSheet(record: record, startInSettings: true)
        }
    }

    private func openServerSettings() {
        UserDefaults.standard.set(SettingsPage.sync.rawValue, forKey: "settingsPage")
        controller.open(.settings)
    }
}

// MARK: The list

private struct ShareList: View {
    let rows: [ShareRow]
    let matches: [String: ListMatch]
    @Binding var selection: String?
    @Environment(\.navigation) private var navigation
    @FocusState private var focused: Bool

    private var current: String? { selection }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    ForEach(rows) { row in
                        if row.state != .live, row.id == rows.first(where: { $0.state != .live })?.id {
                            Text("No longer working").textRole(.label).foregroundStyle(Palette.tertiary)
                                .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ShareListRow(row: row, selected: current == row.id, match: matches[row.id]) {
                            if current != row.id { navigation?.jumpNext() }
                            selection = row.id
                            focused = true
                        }
                        .id(row.id)
                    }
                }
                .padding(.leading, 4).padding(.trailing, Space.s).padding(.vertical, Space.s)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
        }
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let index = rows.firstIndex { $0.id == current }.map { min(max($0 + by, 0), rows.count - 1) } ?? 0
        selection = rows[index].id
        proxy.scrollTo(rows[index].id)
        return .handled
    }
}

/// A share in the list: its title and whether it has a PIN, when it was made and when it expires, then its views.
private struct ShareListRow: View {
    let row: ShareRow
    let selected: Bool
    var match: ListMatch?
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                HStack(spacing: Space.s) {
                    Text(match?.title.boldMatches(size: Rhythm.bodySize) ?? AttributedString(row.title))
                        .font(.system(size: Rhythm.bodySize, weight: selected ? .semibold : .medium))
                        .foregroundStyle(row.state == .live ? Palette.ink : Palette.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .cssLineHeight(size: Rhythm.bodySize)
                    Spacer(minLength: 4)
                    if row.pin != .off {
                        HStack(spacing: Space.xs) {
                            IconImage(.lock, size: 11)
                            Text(row.pin == .locked ? "Locked" : "PIN").font(.system(size: Rhythm.noteSize, weight: .medium))
                        }
                        .foregroundStyle(row.pin == .locked ? Palette.recording : Palette.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.pin == .locked ? "PIN locked" : "PIN on")
                    }
                }
                Text("\(row.created.formatted(.dateTime.month(.abbreviated).day())) · \(statusText)")
                    .font(.system(size: Rhythm.secondarySize))
                    .foregroundStyle(soon ? Palette.accent : Palette.secondary)
                    .lineLimit(1)
                if let numbers {
                    Text(numbers).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary).lineLimit(1).monospacedDigit()
                }
                if let match { ListMatchLine(match: match, lines: 1).padding(.top, 1) }
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var statusText: String {
        row.state == .missing ? "Not on your server" : row.expiryText()
    }

    /// Under a day left: the one thing in the row that may need the owner.
    private var soon: Bool {
        row.state == .live && (row.expires.map { $0.timeIntervalSinceNow < 86_400 } ?? false)
    }

    private var numbers: String? {
        guard let views = row.viewsText else { return nil }
        if let locked = row.lockedText() { return locked }
        guard let remote = row.remote, remote.views > 0 else { return row.remote?.viewers == nil ? views : "Not viewed yet" }
        guard let last = row.lastViewedText() else { return views }
        return "\(views) · \(last.replacingOccurrences(of: "Last viewed ", with: "last "))"
    }
}

// MARK: Shared parts

/// Says, where the numbers would be, that the server is from before them, with the steps to update it.
struct ServerNotice: View {
    let server: SharesModel.Server
    @State private var copied = false

    var body: some View {
        switch server {
        case .old:
            notice("Update your server", "Your server runs an older version. Copy link and Stop sharing work as before. Views, PINs, and a change of the expiry need the new version: run these steps in your copy of Mossad, then come back.", steps: true)
        case .needsMigration:
            notice("Finish the update of your server", "Your server is new, and its database is not updated yet. Run the migration step, and views and PINs start to work.", steps: true)
        case .unreachable(let why):
            notice("Your server does not answer", "\(why) The links are the ones this Mac holds; the numbers show when the server answers.", steps: false)
        case .ok, .unknown:
            EmptyView()
        }
    }

    private func notice(_ title: String, _ text: String, steps: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            IconImage(.warning, size: 15).foregroundStyle(Palette.accent).padding(.top, 1)
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                Text(title).font(.system(size: Rhythm.bodySize, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(text).font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).lineSpacing(Rhythm.secondaryLineGap)
                    .fixedSize(horizontal: false, vertical: true)
                if steps {
                    Text(AppController.serverUpdateSteps)
                        .font(.system(size: Rhythm.secondarySize, design: .monospaced)).foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.top, 6)
                    Button(copied ? "Copied" : "Copy the steps") {
                        copy(AppController.serverUpdateSteps)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }
                    .buttonStyle(.settings)
                    .padding(.top, 6)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 720, alignment: .leading)
        .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// After "Stop sharing": the link still works for a few seconds, and this brings it back. No dialog asks first.
private struct UndoStopBar: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        if let link = controller.stoppedShare {
            HStack(spacing: Space.m) {
                Text("Stopped sharing “\(link.title)”").font(.system(size: Rhythm.bodySize, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                Button("Undo") { controller.undoStop(link) }
                    .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .semibold))
                    .keyboardShortcut("z")
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .chromeGlass(in: Capsule())
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }
}
