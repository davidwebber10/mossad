import MossadCore
import SwiftUI

/// "Move to ▸ <profile>" and its neighbours, in a meeting's context menu and the Meeting menu. Nothing with one
/// profile (`MoveShow.menu` is `.none`).
struct MoveMenuItems: View {
    @ObservedObject var controller: AppController
    let record: CallRecord

    var body: some View {
        switch controller.moveMenu(record) {
        case .none:
            EmptyView()
        case .targets(let ids):
            targets(ids)
        case .cancel:
            Button(MoveWords.cancelMove, systemImage: "xmark.circle") { controller.cancelMove(record.id) }
                .disabled(controller.moveRow(record)?.cancels != true)
        case .refused(let text):
            Menu(MoveWords.menu, systemImage: "arrow.right.square") { EmptyView() }
                .disabled(true)
                .help(text)
        case .held(let ids):
            Button(MoveWords.processHere, systemImage: "gearshape.2") { controller.processHere(record.id) }
            if !ids.isEmpty { targets(ids) }
        }
    }

    private func targets(_ ids: [String]) -> some View {
        Menu(MoveWords.menu, systemImage: "arrow.right.square") {
            ForEach(controller.moveTargets.filter { ids.contains($0.id) }) { p in
                Button(p.name) { controller.askMove(record, to: p) }
            }
        }
    }
}

/// The row's line while a meeting moves, waits, or is held: the sentence, and the one act it allows.
struct MoveRowLine: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let row: MoveShow.Row

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            Text(row.text)
                .font(.system(size: Rhythm.secondarySize))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                if row.cancels { act(MoveWords.cancelMove) { controller.cancelMove(record.id) } }
                if row.retries { act(MoveWords.tryAgain) { controller.tryMoveAgain(record.id) } }
                if row.held { act(MoveWords.processHere) { controller.processHere(record.id) } }
            }
        }
    }

    private func act(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: Rhythm.secondarySize, weight: .medium))
            .foregroundStyle(Palette.accent)
    }
}

/// "Moved to Work", or a refusal, as one quiet line above the list's first group. Text only: nothing in it opens the
/// other profile.
struct MoveLineView: View {
    @EnvironmentObject var controller: AppController
    /// On a meeting's page: only the lines and the reasons about that meeting.
    var meeting: String?
    /// In a scroll view: the line counts as seen only while it is in view.
    var inScroll = false
    @State private var inView = false

    var body: some View {
        if let line = controller.moveLine, line.shows(on: meeting) {
            text(line.text)
        } else if let notice = controller.moveNotices.current(on: meeting) {
            // A reason is forgotten only once it is on the screen: the window shows and the line is in view.
            let seen = controller.windowVisible && (inView || !inScroll)
            text(notice.text)
                .onScrollVisibilityChange(threshold: 0.9) { inView = $0 }
                .task(id: "\(notice.id)|\(seen)") { if seen { controller.moveNoticeSeen(notice.id) } }
        }
    }

    private func text(_ s: String) -> some View {
        Text(s)
            .font(.system(size: Rhythm.secondarySize))
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Rhythm.listRowInset)
            .padding(.top, Rhythm.itemGap)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

extension View {
    /// The confirmation of "Move to": what the first profile already sent, what leaves with the meeting, and the
    /// chats that are deleted and not moved.
    func moveConfirmation(_ controller: AppController) -> some View {
        let request = controller.moveRequest
        let active = controller.activeProfile.name
        return confirmationDialog(request.map { MoveWords.title($0.record.title, to: $0.target.name) } ?? "",
                                  isPresented: Binding(get: { controller.moveRequest != nil }, set: { if !$0 { controller.moveRequest = nil } }),
                                  titleVisibility: .visible) {
            Button(MoveWords.confirm) {
                if let r = request { controller.moveMeeting(r.record.id, to: r.target.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let r = request {
                Text(([MoveWords.sent(r.sent, from: active, to: r.target.name), MoveWords.leaves(active)]
                      + [MoveWords.chatsDeleted(r.deletedChats)].compactMap { $0 }).joined(separator: "\n\n"))
            }
        }
    }
}

/// In place of a chat's field while its meeting moves: the sentence, in the field's own glass. Nothing can be typed or
/// sent, so no request goes to this profile's services.
struct MoveChatOff: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Detail.composerHeight / 2, style: .continuous)
        Text(text)
            .font(.system(size: Rhythm.secondarySize))
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: Detail.composerSend, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 6)
            .frame(minHeight: Detail.composerHeight)
            .background(.ultraThinMaterial, in: shape)
            .chromeGlass(in: shape, shadow: .floating)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// "This call is for ▸ <profile>" in the menu bar panel while a call records, with the note of the choice. Only with
/// two profiles or more (`MoveAfterCall.menu`).
struct CallForRow: View {
    @EnvironmentObject var controller: AppController
    let menu: MoveAfterCall.Menu

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            HStack(spacing: Space.m) {
                Text(MoveAfterCall.Menu.title).font(.system(size: Rhythm.bodySize)).lineLimit(1)
                Spacer(minLength: Space.s)
                // The dot beside the menu: a menu's own label shows text only.
                if let chosen = menu.rows.first(where: \.chosen) { ProfileDot(color: chosen.color) }
                Menu {
                    ForEach(menu.rows) { row in
                        Button { controller.setCallProfile(row.id) } label: {
                            if row.chosen { Label(row.name, systemImage: "checkmark") } else { Text(row.name) }
                        }
                    }
                } label: {
                    Text(menu.rows.first(where: \.chosen)?.name ?? "").font(.system(size: Rhythm.bodySize)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(MoveAfterCall.Menu.title)
            }
            if let note = menu.note {
                Text(note)
                    .font(.system(size: Rhythm.secondarySize))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
