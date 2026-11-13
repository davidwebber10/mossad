import AppKit
import MossadCore
import SwiftUI

/// Settings › General › Shortcuts: the quick panel's shortcut, which the owner sets by pressing it, and the
/// bookmark's, which is fixed.
struct ShortcutSettings: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        SettingsGroup(label: "Shortcuts", footer: "These work in any app, also when a call is in full screen.") {
            ShortcutRecorderRow()
            SettingsRow(title: "Bookmark this moment", detail: "During a call, marks the moment for later.") {
                Text(HotKeyShortcut.bookmark.symbols)
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel(HotKeyShortcut.bookmark.spoken)
            }
        }
    }
}

private struct ShortcutRecorderRow: View {
    @EnvironmentObject var controller: AppController
    @State private var recording = false
    @State private var problem: HotKeyShortcut.Problem?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Ask Mossad", detail: "Opens a small window over any app, to ask about the call or your meetings.") {
                HStack(spacing: 6) {
                    Button(action: toggle) {
                        Text(recording ? "Type a shortcut" : controller.askShortcut?.symbols ?? "None")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(recording ? Palette.accent : Palette.ink)
                            .frame(minWidth: 96).padding(.horizontal, 8).frame(height: 24)
                            .background(recording ? Palette.accentTint : Palette.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(recording ? Palette.accent : .clear, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(recording ? "Press the keys, or Escape to keep the shortcut" : "Click, then press the new shortcut")
                    .accessibilityLabel("Ask Mossad shortcut")
                    .accessibilityValue(recording ? "Waiting for keys" : controller.askShortcut?.spoken ?? "None")
                    .accessibilityHint(recording ? "Press the keys, or Escape to keep the shortcut" : "Records a new shortcut")
                    if controller.askShortcut != nil, !recording {
                        Button { set(nil) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
                                .frame(width: 20, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Clear the shortcut")
                        .accessibilityLabel("Clear the shortcut")
                    }
                    if controller.askShortcut != .askDefault, !recording {
                        Button("Default") { set(.askDefault) }.buttonStyle(.settings)
                            .help("Use \(HotKeyShortcut.askDefault.spoken) again")
                    }
                }
            }
            if let problem = problem ?? (controller.askShortcutFailed && !recording ? .taken : nil) {
                Text(problem.message).font(.system(size: 12)).foregroundStyle(Palette.recording)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onDisappear(perform: stop)
        // A click in another app or window ends the recording, so a later key press is not taken as the shortcut.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in if recording { stop() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in if recording { stop() } }
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    /// The next key press with its modifiers is the shortcut; Escape alone keeps the one before.
    private func start() {
        problem = nil
        recording = true
        controller.pauseAskShortcut(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Caps Lock and the function key are not part of a shortcut.
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let code = event.keyCode
            MainActor.assumeIsolated {
                if code == 53, flags.isEmpty {
                    stop()
                    return
                }
                var mods: HotKeyShortcut.Modifiers = []
                if flags.contains(.command) { mods.insert(.command) }
                if flags.contains(.option) { mods.insert(.option) }
                if flags.contains(.control) { mods.insert(.control) }
                if flags.contains(.shift) { mods.insert(.shift) }
                set(HotKeyShortcut(keyCode: UInt32(code), modifiers: mods))
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { controller.pauseAskShortcut(false) }
        recording = false
    }

    private func set(_ shortcut: HotKeyShortcut?) {
        let wasRecording = recording
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        problem = controller.setAskShortcut(shortcut)
        // A refused shortcut leaves the one before, which the recording had paused.
        if wasRecording, problem != nil { controller.pauseAskShortcut(false) }
        if let problem { AccessibilityNotification.Announcement(problem.message).post() }
    }
}
