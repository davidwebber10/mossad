import MossadCore
import SwiftUI

/// Pause or resume, bookmark, stop and keep, or skip and delete the call being recorded. With the call's id (the
/// meeting band), a bookmark goes in at once and a popover offers an optional note; the menu bar's compact copy
/// bookmarks the moment as the hot key does.
struct CallControls: View {
    @EnvironmentObject var controller: AppController
    var compact = false
    var callID: String?
    var start: Date?
    @State private var confirmSkip = false
    @State private var justBookmarked = false
    @State private var adding = false
    @State private var bookmarked: TimeInterval?

    var body: some View {
        HStack(spacing: Space.s) {
            if controller.isPaused {
                control("Resume", "record.circle", glass: true, tint: Palette.recording) { controller.resumeCurrentCall() }
            } else {
                control("Pause", "pause.fill", glass: true) { controller.pauseCurrentCall() }
            }
            bookmark
            control("Stop", "stop", glass: false) { controller.stopCurrentCall() }
                .help("End the recording now and write the note")
            Spacer(minLength: Space.s)
            Button {
                if confirmSkip { controller.skipCurrentCall() } else { confirmSkip = true }
            } label: {
                Text(confirmSkip ? "Click again to delete" : "Skip and delete")
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                    .foregroundStyle(Palette.recording)
                    .padding(.horizontal, 6)
                    .frame(height: compact ? 26 : 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop recording and delete this call")
        }
        .onChange(of: controller.isRecording) { _, _ in confirmSkip = false }
        .onChange(of: controller.lastBookmark) { _, _ in
            // The hot key and the menu: a short "Bookmarked" on the button. The popover already says so.
            guard bookmarked == nil, !adding else { return }
            justBookmarked = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                justBookmarked = false
            }
        }
    }

    private var bookmark: some View {
        Button(action: addBookmark) {
            HStack(spacing: 6) {
                BookmarkFlag().fill(Palette.accentFill).frame(width: 9, height: 11)
                Text(justBookmarked ? "Bookmarked" : "Bookmark")
                if !compact {
                    Text("⌃⌥B").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
            }
            .font(.system(size: compact ? 12 : 12.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: compact ? 26 : 30)
            .mossadGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(controller.isPaused || adding)
        .help("Mark this moment, with an optional note (⌃⌥B from any app)")
        .popover(isPresented: Binding(get: { bookmarked != nil }, set: { if !$0 { bookmarked = nil } }), arrowEdge: .bottom) {
            if let at = bookmarked, let callID {
                BookmarkNotePopover(at: at) { note in
                    controller.setBookmarkNote(callID: callID, offset: at, note: note)
                } dismiss: { bookmarked = nil }
            }
        }
    }

    /// The bookmark goes in at once, through the recorder; the popover only offers a note.
    private func addBookmark() {
        guard let callID else { return controller.bookmarkCurrentCall() }
        adding = true
        let at = start.map { Date().timeIntervalSince($0) } ?? 0
        Task {
            bookmarked = await controller.addBookmark(callID: callID, at: at)
            adding = false
        }
    }

    private func control(_ title: String, _ symbol: String, glass: Bool, tint: Color = Palette.ink, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(ControlLabel())
                .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, compact ? 11 : 14)
                .frame(height: compact ? 26 : 30)
                .background { if !glass { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.fill) } }
                .modifier(GlassIf(on: glass))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ControlLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

private struct GlassIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.mossadGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), interactive: true) } else { content }
    }
}

/// The big switch at the top of Settings, and the "Turn off" menu used in the panel.
struct PowerControl: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: controller.isOn ? "waveform" : "waveform.slash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(controller.isOn ? Color.accentColor : .secondary)
                .frame(width: 44, height: 44)
                .background((controller.isOn ? Color.accentColor : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.isOn ? "Mossad is on" : "Mossad is off").font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isOn {
                TurnOffMenu().controlSize(.large)
            } else {
                Button("Turn on") { controller.turnOn() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator))
    }

    private var detail: String {
        if controller.isOn { return "Records Zoom, Google Meet, and Microsoft Teams calls on its own." }
        if let date = controller.offUntilDate { return "No calls are detected or recorded until \(date.formatted(date: .abbreviated, time: .shortened))." }
        return "No calls are detected or recorded until you turn it on."
    }
}

struct TurnOffMenu: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Menu("Turn off") {
            Button("For 1 hour") { controller.turnOff(until: Date().addingTimeInterval(3600)) }
            Button("Until tomorrow") { controller.turnOff(until: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 6 * 3600)) }
            Button("For 3 days") { controller.turnOff(until: Date().addingTimeInterval(3 * 86_400)) }
            Button("For 1 week") { controller.turnOff(until: Date().addingTimeInterval(7 * 86_400)) }
            Divider()
            Button("Until I turn it on") { controller.turnOff(until: nil) }
        }
        .fixedSize()
    }
}
