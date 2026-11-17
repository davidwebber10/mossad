import AppKit
import MossadCore

/// The development hooks that run at launch, in one place. A hook that only changes what shows runs in a
/// `--ui-preview` copy or a debug build. A hook that changes meetings or bills a provider runs in a debug build
/// only. The installed copy runs none of them, except `--open-window`, which only opens a page.
@MainActor
enum DevHooks {
    /// Hooks of the profiles' workers: `MOSSAD_PROOF_WORKERS`, `MOSSAD_PROOF_CALL`, the move's `MOSSAD_PROOF_MEETING`,
    /// `MOSSAD_PROOF_MOVE` (with `MOSSAD_PROOF_MOVE_AFTER`), `MOSSAD_PROOF_MOVE_STOP=copied`, and
    /// `MOSSAD_PROOF_INTAKE_STOP=takingIn`, `MOSSAD_PROOF_INTAKE_REFUSE=1`, `MOSSAD_PROOF_COPY_HOLD=<seconds>` with
    /// `MOSSAD_PROOF_CANCEL_AFTER=<seconds>` (in `WorkerEntry`, on a made-up registry only),
    /// and in a preview
    /// `MOSSAD_WORKER_LINES`, and the move's `MOSSAD_MOVE`, `MOSSAD_MOVE_ENDED`, `MOSSAD_MOVE_LINE`, `MOSSAD_MOVE_SHEET`.
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

    /// `MOSSAD_PROOF_WORKERS=1` on a made-up registry, in a debug build: the window app starts the workers of the
    /// registry's other profiles (never `default`), for the proofs. Those workers stay in their made-up folders.
    static var proofWorkers: Bool {
        #if DEBUG
        env["MOSSAD_PROOF_WORKERS"] == "1" && AppIdentity.current.madeUpRegistry && !preview
        #else
        false
        #endif
    }

    static func run(_ c: AppController, inert: Bool) {
        // `--regenerate-summaries` writes new summaries for today's finished meetings.
        if debug, !inert, has("--regenerate-summaries") {
            for r in c.meetings where Calendar.current.isDateInToday(r.start) && r.status == .written { c.regenerateSummary(r.id) }
        }
        let looks = preview || debug
        #if DEBUG
        // `MOSSAD_PROOF_HOTKEY=1` on a made-up registry: one made-up global key (F19 with Control, Option, Shift, and
        // Command: no keyboard has a key the owner presses by accident there, and no app uses it), for the proof
        // that a switch hands the hot keys over. Registered with the same retries as the real keys.
        if env["MOSSAD_PROOF_HOTKEY"] == "1", AppIdentity.current.madeUpRegistry, !preview {
            let key = HotKeyShortcut(keyCode: 0x50, modifiers: [.control, .option, .shift, .command])
            let held = c.hotKeys.register(.proof, key, retrying: true) {}
            Log.info("Proof hot key: \(held ? "held at launch" : "taken by another copy at launch; trying again")")
        }
        // `MOSSAD_PROFILE_SWITCH=<id>` on a made-up registry: one real switch, a few seconds after launch.
        if let id = env["MOSSAD_PROFILE_SWITCH"], let file = env["MOSSAD_PROFILES"], AppIdentity.current.madeUpRegistry, !preview {
            let failing = env["MOSSAD_PROFILE_SWITCH_FAIL"] == "1"
            // `late`: the new instance starts and finishes its launch, then this copy refuses to quit, as when a call
            // starts in the last moment: the switch is taken back.
            AppController.proofLateRefusal = env["MOSSAD_PROFILE_SWITCH_FAIL"] == "late"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { c.proofSwitch(to: id, file: URL(fileURLWithPath: file), failing: failing) }
        }
        #endif
        // `MOSSAD_PROOF_DAYS=<n>` on a made-up registry: a setting written through `@AppStorage` into the profile's
        // suite, and what Sparkle reads, for the proof that a profile's swap holds.
        // Never as `default`, which on a made-up registry is the owner's real install (it does not start as one anyway).
        if AppIdentity.current.madeUpRegistry, !AppIdentity.current.profile.isDefault, !preview,
           let days = env["MOSSAD_PROOF_DAYS"].flatMap(Int.init) {
            c.recordingDays = days
            Log.info("Proof: updates check automatically: \(c.updater.automaticallyChecks)")
        }
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
        // `MOSSAD_PROFILES=<file>` shows a made-up registry in the switcher and Settings (loaded by `AppIdentity`).
        // `MOSSAD_PROFILE_SHEET=add|rename|delete|code` opens that sheet of Settings > General > Profiles; rename and
        // delete for the first profile that is not `default`.
        // `MOSSAD_WORKER_LINES="1a2b3c4d=2 meetings in work"` (more with `;`): the switcher's second lines.
        if preview, let lines = env["MOSSAD_WORKER_LINES"] {
            c.workerLines = Dictionary(lines.split(separator: ";").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }, uniquingKeysWith: { $1 })
        }
        if preview { moveHooks(c) }
        if preview, let sheet = env["MOSSAD_PROFILE_SHEET"] {
            let other = c.profiles.registry.live.first { !$0.isDefault }?.id
            let chosen: ProfileSheet? = switch sheet {
            case "add": .add
            case "rename": other.map { .rename($0) }
            case "delete": other.map { .delete($0) }
            case "code": .code
            default: nil
            }
            if let chosen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { c.openProfileSettings(sheet: chosen) } }
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

    /// The move's states, shown from made-up values; nothing moves in a preview.
    /// `MOSSAD_MOVE="<call id>=moving|copying|slow|slow:notSetUp|slow:unreachable|cancelling|removing|notFinished:<kind>"` (more with `;`):
    /// a made-up ledger of a move to the first other profile of `MOSSAD_PROFILES` (started 0 s ago, or 120 s for `slow`;
    /// `copying` at 42%; `removing` waits at the backup step).
    /// `MOSSAD_MOVE_ENDED="<call id>=<reason>"`: a move of a call marked during its recording that ended (its row is held).
    /// `MOSSAD_MOVE_LINE=<text>`: the line above the list. `MOSSAD_MOVE_SHEET=<call id>`: the confirmation for the first target.
    private static func moveHooks(_ c: AppController) {
        guard let to = c.moveTargets.first else { return }
        func pairs(_ key: String) -> [(String, String)] {
            (env[key] ?? "").split(separator: ";").compactMap { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
        }
        for (id, state) in pairs("MOSSAD_MOVE") {
            let parts = state.split(separator: ":").map(String.init)
            var m = MoveOut(callID: id, to: to.id, started: Date().addingTimeInterval(parts[0] == "slow" ? -120 : 0))
            switch parts[0] {
            case "copying": m.state = .copying; c.moveProgress[id] = 0.42
            case "cancelling": m.state = .cancelling
            case "notFinished":
                // The target took the meeting and a part after its file check keeps failing (`:voices|record|chats|failed`).
                m.state = .waiting
                m.targetWaits = parts.count > 1 ? MoveMarker.TakeInWait(rawValue: parts[1]) ?? .failed : .record
            case "removing":
                m.state = .removing
                m.removed = ["voices", "people", "coach", "books", "shares"]
                m.because = .backupNotDone
                m.waitsAt = MoveOut.Step.backup.rawValue
            default: m.state = .waiting
            }
            if parts.count > 1, parts[0] != "notFinished" { c.moveReach[to.id] = parts[1] == "notSetUp" ? .notSetUp : parts[1] == "unreachable" ? .unreachable : .notRunning }
            c.moves[id] = m
        }
        for (id, why) in pairs("MOSSAD_MOVE_ENDED") {
            c.moveEnded[id] = MoveEnded(callID: id, to: to.id, why: MovePlan.Cancel(rawValue: why) ?? .refusedIDTaken, afterCall: true, at: Date())
        }
        if let text = env["MOSSAD_MOVE_LINE"] { c.moveLine = MoveShow.Line(text: text, since: Date(), lasts: 3600) }
        if let id = env["MOSSAD_MOVE_SHEET"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let r = c.meetings.first(where: { $0.id == id }) { c.askMove(r, to: to) }
            }
        }
    }

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
