import AppKit
import MossadCore
import SwiftUI

/// Rehearsal's slim bar over setup: jump to a step, start over, reset the permissions macOS gave Rehearsal, and
/// write a note that lands in `~/Mossad Rehearsal/feedback.md`, tagged with the step and the time.
struct RehearsalBar: View {
    @ObservedObject var model: OnboardingModel
    @State private var note = ""
    @State private var saved = false
    @State private var confirmReset = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        HStack(spacing: Chrome.groupGap) {
            RehearsalMark()
            Menu {
                ForEach(OnboardingStep.allCases) { step in
                    Button("\(step.number). \(step.title)") { model.jump(to: step) }
                }
            } label: {
                FillMenuLabel(text: "Step \(model.step.number) · \(model.step.title)")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Jump to a step")
            Button("Restart onboarding") { model.restart() }
                .buttonStyle(.settings)
                .help("Back to step 1. Names, keys, and choices already made stay.")
            Button("Reset permissions…") { confirmReset = true }
                .buttonStyle(.settings)
                .help("Forgets every permission macOS gave Mossad Rehearsal, then opens it again.")
            Spacer(minLength: Space.m)
            TextField("Note", text: $note, prompt: Text("A note on this step…"))
                .textFieldStyle(SettingsFieldStyle(width: 260))
                .focused($noteFocused)
                .onSubmit(save)
            Button(saved ? "Saved" : "Save note", action: save)
                .buttonStyle(SettingsButtonStyle(accent: !note.trimmingCharacters(in: .whitespaces).isEmpty))
                .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty && !saved)
                .help("Adds the note to ~/Mossad Rehearsal/feedback.md")
        }
        .padding(.leading, Space.xl).padding(.trailing, Space.l)
        .frame(height: Onboard.topRow)
        .background { WindowDragArea() }
        .hairline(.bottom)
        .confirmationDialog("Reset Mossad Rehearsal's permissions?", isPresented: $confirmReset) {
            Button("Reset and reopen", role: .destructive) { Self.resetPermissions() }
        } message: {
            Text("macOS forgets every permission it gave Mossad Rehearsal, and Rehearsal opens again so it asks fresh. The real Mossad keeps its own.")
        }
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let step = model.step.title
        let file = Rehearsal.feedbackFile
        note = ""
        Task.detached(priority: .utility) {
            do { try RehearsalFeedback.append(step: step, text: text, to: file) } catch { Log.error("Saving the rehearsal note failed: \(error)") }
        }
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saved = false
        }
    }

    /// `tccutil reset All` for Rehearsal's own bundle id only, then a fresh launch of this same copy.
    static func resetPermissions() {
        guard Rehearsal.isOn, Bundle.main.bundleIdentifier == AppIdentity.rehearsalBundleID else { return }
        let bundle = Bundle.main.bundlePath
        DispatchQueue.global(qos: .userInitiated).async {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "All", AppIdentity.rehearsalBundleID]
            do {
                try reset.run()
                reset.waitUntilExit()
            } catch {
                Log.error("tccutil failed: \(error)")
            }
            // A shell that outlives this process opens Rehearsal again once it has quit.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", bundle]
            try? relaunch.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
