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

    /// A path as a page shows it. A preview shows a made-up one, so a capture never holds the Mac account's name.
    static func shownPath(_ path: String) -> String {
        guard AppIdentity.current.isPreview else { return path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        return "~/Mossad/" + (path as NSString).lastPathComponent
    }

    /// The app's binary as a page shows it, with the same rule.
    static func shownBinary(_ path: String) -> String {
        AppIdentity.current.isPreview ? "/Applications/Mossad.app/Contents/MacOS/Mossad" : path
    }

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
            // `AskPanel` in a preview: the quick panel in a window of its own (see `openAskPanelPreview`).
            if preview, name == "AskPanel" {
                DispatchQueue.main.async { c.openAskPanelPreview() }
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
        // `MOSSAD_NAV_OPEN=<call id>` opens that meeting 3 s after launch, as a link on the page would, so Back
        // shows enabled after the path to it.
        if preview, let id = env["MOSSAD_NAV_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { c.openMeeting(id) }
        }
        // `MOSSAD_PERSON` opens that person's page.
        if looks, let person = env["MOSSAD_PERSON"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { c.openPerson(person) }
        }
    }

    private static let launch = Date()

    /// `MOSSAD_ASK_POINTS=open|closed` in a preview: the quick panel's points row shown open or closed, without
    /// the owner's saved choice.
    static var askPoints: Bool? { preview ? env["MOSSAD_ASK_POINTS"].map { $0 == "open" } : nil }

    /// `MOSSAD_DECK_CARDS=<file>` in a preview: a JSON list of made-up cards to show as the Findings deck, so a
    /// picture of each kind of card needs no review files.
    static func sampleCards() -> [CoachFinding]? {
        guard preview, let path = env["MOSSAD_DECK_CARDS"], let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode([CoachFinding].self, from: data)
    }

    /// `MOSSAD_UPCOMING=<file>` in a preview: a JSON list of made-up invites (`title`, `inMinutes` from the launch,
    /// `minutes`, `attendees`, `link`) to show in place of the calendar's, so a picture never holds a real invite.
    static func sampleInvites() -> [CalendarEventInfo]? {
        struct Invite: Decodable {
            let title: String
            let inMinutes: Double
            let minutes: Double
            let attendees: [String]
            let link: String
            /// A made-up calendar series id, for a recurring invite.
            let seriesID: String?
        }
        guard preview, let path = env["MOSSAD_UPCOMING"], let data = FileManager.default.contents(atPath: path),
              let invites = try? JSONDecoder().decode([Invite].self, from: data) else { return nil }
        return invites.map { i in
            let start = launch.addingTimeInterval(i.inMinutes * 60)
            var e = CalendarEventInfo(title: i.title, start: start, end: start.addingTimeInterval(i.minutes * 60), attendees: i.attendees,
                                      text: i.link, isAllDay: false)
            e.seriesID = i.seriesID
            e.isRecurring = i.seriesID != nil
            return e
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
        // `MOSSAD_SHARING=1` acts as if the owner shares the screen: the coach's reads of people are covered.
        if env["MOSSAD_SHARING"] == "1" { c.ownerSharing = true }
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
