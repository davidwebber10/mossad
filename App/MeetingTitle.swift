import AppKit
import MossadCore
import SwiftUI

/// The meeting's title, renamed in place: a click turns it into a field, Return saves, Esc cancels, and an empty
/// title goes back to the automatic one (the invite's, or the one Mossad wrote).
struct EditableMeetingTitle: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    var size: CGFloat = 22
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var editable: Bool { record.status != .recording }

    var body: some View {
        if editing {
            HStack(spacing: Space.m) {
                TextField("Meeting title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: size, weight: .semibold))
                    .tracking(size * -0.02)
                    .padding(.horizontal, Space.s).padding(.vertical, 2)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.accentFill, lineWidth: 2))
                    .padding(.leading, -Space.s)
                    .frame(maxWidth: 740)
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand(perform: cancel)
                    .onChange(of: focused) { _, now in if !now { cancel() } }
                    .accessibilityLabel("Meeting title")
                Text("Return to save · Esc to cancel")
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).fixedSize()
            }
            .onAppear { focused = true }
        } else {
            Text(record.title)
                .font(.system(size: size, weight: .semibold))
                .tracking(size * -0.02)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.s).padding(.vertical, 2)
                .background(hovering && editable ? Palette.fill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.leading, -Space.s)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { if editable { begin() } }
                // A click renames, so copying is in the right-click menu (and ⌘C after Rename selects the text).
                .contextMenu {
                    Button("Copy Title", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.title, forType: .string)
                    }
                    if editable { Button("Rename…", systemImage: "pencil") { begin() } }
                }
                .help(editable ? "Click to rename" : "")
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: "Rename") { if editable { begin() } }
        }
    }

    private func begin() {
        draft = record.title
        editing = true
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        // An unchanged automatic title stays automatic, so a later invite match or summary can still improve it.
        // Nothing changed, or an empty field when there is no title of the owner's to clear: leave call.json alone.
        guard text != record.title, !(text.isEmpty && record.titleSource != .custom) else { return }
        controller.setTitle(callID: record.id, text.isEmpty ? nil : text)
    }

    private func cancel() {
        editing = false
    }
}

/// "Named by Mossad": the title came from what was said, not from an invite or the owner.
struct NamedByMossadTag: View {
    var body: some View {
        HStack(spacing: Space.xs) {
            IconImage(.sparkle, size: 10)
            Text("Named by Mossad")
        }
        .font(.system(size: Rhythm.noteSize, weight: .medium))
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, Space.s)
        .frame(height: 18)
        .background(Palette.fill, in: Capsule())
        .help("Mossad named this meeting from what was said. Click the title to rename it.")
    }
}
