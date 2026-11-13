import AppKit
import MossadCore
import SwiftUI

/// Mossad Rehearsal: the same app built with the REHEARSAL flag, for walking through setup as a new user. It
/// keeps its own folder and Keychain service (AppIdentity), and never detects calls, records, runs the pipeline,
/// syncs, serves MCP, checks for updates, or registers a login item.
enum Rehearsal {
    #if REHEARSAL
    static let isOn = true
    #else
    static let isOn = false
    #endif

    /// Where the owner's notes from a walkthrough go.
    static var feedbackFile: URL { Paths.live.root.appendingPathComponent("feedback.md") }
}

/// The small mark that tells Rehearsal from the real app at a glance.
struct RehearsalMark: View {
    var body: some View {
        Text("Rehearsal")
            .font(.system(size: Rhythm.noteSize, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 7).frame(height: 18)
            .background(Palette.accentTint, in: Capsule())
            .accessibilityLabel("Mossad Rehearsal")
    }
}
