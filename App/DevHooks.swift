import AppKit
import MossadCore

/// The development hooks that run at launch, in one place. A hook that only changes what shows runs in a
/// `--ui-preview` copy or a debug build. A hook that changes meetings or bills a provider runs in a debug build
/// only. The installed copy runs none of them, except `--open-window`, which only opens a page.
@MainActor
enum DevHooks {
    /// `--ui-preview` opens the UI on $MOSSAD_ROOT with no detection, recording, or processing, so the screens can
    /// be checked while the installed copy records a call.
    static let preview = CommandLine.arguments.contains("--ui-preview")

    #if DEBUG
    static let debug = true
    #else
    static let debug = false
    #endif

    private static func has(_ flag: String) -> Bool { CommandLine.arguments.contains(flag) }
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func run(_ c: AppController, inert: Bool) {
        // `--regenerate-summaries` writes new summaries for today's finished meetings.
        if debug, !inert, has("--regenerate-summaries") {
            for r in c.meetings where Calendar.current.isDateInToday(r.start) && r.status == .written { c.regenerateSummary(r.id) }
        }
        let looks = preview || debug
        // `--light` shows the UI in light mode, to check both looks. Before the preview's own appearance hooks.
        if looks, has("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if preview { previewOnly(c) }
        // `--open-naming` opens "Who is speaking?" for the first call that needs names.
        if looks, has("--open-naming"), let first = c.callsNeedingNames.first {
            DispatchQueue.main.async { c.openNaming(first.id) }
        }
        // `--open-window [Meetings|People|Settings|Log]`, or `MenuPanel` in a preview for the menu bar panel's
        // content in a window of its own.
        if let i = CommandLine.arguments.firstIndex(of: "--open-window") {
            let name = CommandLine.arguments.dropFirst(i + 1).first
            if preview, name == "MenuPanel" {
                DispatchQueue.main.async { c.openPanelPreview() }
                return
            }
            // `--open-window Onboarding` opens setup alone; MOSSAD_ONBOARDING_STEP picks the step in a preview.
            if name == "Onboarding" {
                DispatchQueue.main.async { c.openOnboarding() }
                return
            }
            let section = AppController.Section.allCases.first { $0.rawValue == name } ?? .meetings
            DispatchQueue.main.async { c.open(section) }
        }
        // `MOSSAD_SEARCH=<query>` opens the search palette with that query.
        if preview, let query = env["MOSSAD_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { c.openSearch(query) }
        }
        // `MOSSAD_PERSON` opens that person's page.
        if looks, let person = env["MOSSAD_PERSON"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { c.openPerson(person) }
        }
    }

    private static func previewOnly(_ c: AppController) {
        c.applyLivePreview()
        if let failure = AppController.errorPreview("sync") {
            var status = SyncStatus()
            status.show(failure)
            c.syncActivity = SyncActivity(last: Date().addingTimeInterval(-7200), status: status)
        }
        if let update = env["MOSSAD_UPDATE_PREVIEW"] { c.updater.applyPreview(update) }
        // `MOSSAD_APPEARANCE=dark|light` picks the look of a preview, to capture both.
        if let look = env["MOSSAD_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        // The high-contrast appearances carry the tokens' Increase Contrast values.
        if PreviewAccessibility.increaseContrast {
            let dark = (NSApp.appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSApp.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
        }
    }
}
