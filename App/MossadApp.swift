import AppKit
import SwiftUI
import MossadCore

@main
struct MossadEntry {
    static func main() {
        // Before any resolver: the app, `--mcp`, and each command-line step read the same company domains.
        CompanyDomains.loadSaved()
        // The build flag says what this copy does; the bundle id picks its folder and Keychain. They must agree.
        if let mismatch = AppIdentity.current.mismatch(rehearsalBuild: Rehearsal.isOn) { preconditionFailure(mismatch) }
        // `--import-keys` copies API keys from the environment (Doppler) into the Keychain and exits.
        if CommandLine.arguments.contains("--import-keys") {
            let stored = importKeys(from: ProcessInfo.processInfo.environment, into: .app)
            print(stored.isEmpty ? "No keys found in the environment." : "Stored: " + stored.map(\.rawValue).joined(separator: ", "))
            exit(stored.isEmpty ? 1 : 0)
        }
        // `--mcp` serves the meetings to other AI apps over stdio, read-only, with no UI and no recording.
        if CommandLine.arguments.contains("--mcp") {
            // Rehearsal never serves the meetings.
            if Rehearsal.isOn { print("Mossad Rehearsal does not serve MCP."); exit(1) }
            let owner = UserDefaults.standard.string(forKey: "ownerName") ?? NSFullUserName()
            // The coach's reads of how people think: on for other AI apps, unless the owner turned it off.
            let d = UserDefaults.standard
            let traits = MCPServer.showsPersonas(coachEnabled: d.bool(forKey: "coachEnabled"), personaEnabled: d.object(forKey: "personaEnabled") as? Bool ?? true,
                                                 personaInMCP: d.object(forKey: "personaInMCP") as? Bool ?? true)
            MCPServer(paths: .live, owner: owner, personaTraits: traits).run()
            exit(0)
        }
        // `--persona-eval --gold <folder> [--cap 15] [--model claude-sonnet-5-5] [--out <folder>] [--estimate-only]` runs the
        // persona eval on the made-up gold set. It prints its estimated cost first and stops at the cap ($15 at most).
        // It reads no meeting and writes nothing in the data folder; the key comes from the Keychain and is never printed.
        if CommandLine.arguments.contains("--persona-eval") {
            if Rehearsal.isOn { print("Mossad Rehearsal does not run the eval."); exit(1) }
            let args = CommandLine.arguments
            Task {
                let status = await PersonaEval.command(args, key: { Keychain.app.get(.anthropic) }, say: { print($0); fflush(stdout) })
                exit(status)
            }
            dispatchMain()
        }
        // `--persona-fill [--go] [--cap 1]` reads the stored calls once for the coach's reads of how people think. It
        // prints the estimated cost; only `--go` sends requests, and only while the app is not open.
        if CommandLine.arguments.contains("--persona-fill") {
            if Rehearsal.isOn { print("Mossad Rehearsal has no calls to read."); exit(1) }
            let args = CommandLine.arguments
            let open = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if args.contains("--go"), open { print("Quit Mossad first: the fill writes the files that the app keeps."); exit(1) }
            let defaults = UserDefaults.standard
            let typed = (defaults.string(forKey: "ownerName") ?? "").trimmingCharacters(in: .whitespaces)
            let owner = typed.isEmpty ? NSFullUserName() : typed
            let provider = AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .anthropic
            let chosen = defaults.string(forKey: "aiModel") ?? ""
            let server = LocalServer.url(from: defaults.string(forKey: "localServerURL") ?? "") ?? LocalServer.ollama
            Task {
                let status = await PersonaFill.command(args, paths: .live, owner: owner, plan: PersonaExtractor.plan(provider: provider, chosen: chosen), makeModel: { usage in
                    PersonaExtractor.model(provider: provider, chosen: chosen, key: provider.key.flatMap { Keychain.app.get($0) }, usage: usage, serverURL: server)?.llm
                }, say: { print($0); fflush(stdout) })
                exit(status)
            }
            dispatchMain()
        }
        // `--people-migration dry-run | apply | revert | apply-references | revert-references [--out <folder>]` shows or makes the move to person ids and
        // exits. A dry run with `--out` writes nothing in the data folder.
        if CommandLine.arguments.contains("--people-migration") {
            if Rehearsal.isOn { print("Mossad Rehearsal has no people to migrate."); exit(1) }
            // The rule of the app: an empty name is the account's full name, so the dry run shows what the app does.
            let typed = (UserDefaults.standard.string(forKey: "ownerName") ?? "").trimmingCharacters(in: .whitespaces)
            let owner = typed.isEmpty ? NSFullUserName() : typed
            let notDuplicates = (UserDefaults.standard.string(forKey: "peopleNotDuplicates") ?? "").split(separator: "\n").map(String.init)
            let result = PeopleMigration.command(CommandLine.arguments, paths: .live, ownerName: owner, notDuplicates: notDuplicates)
            print(result.text)
            exit(result.status)
        }
        MossadApp.main()
    }
}

struct MossadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, permissions: controller.permissions)
        } label: {
            MenuBarIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)
        .commands { MossadCommands(controller: controller) }

    }
}

/// The five waveform bars: a template image when idle, red bars and the elapsed time while recording.
/// The menu bar draws one image only: a TimelineView or a mixed view there makes the item disappear.
struct MenuBarIcon: View {
    @ObservedObject var controller: AppController

    var body: some View {
        if case .recording(_, let since) = controller.status {
            RecordingMenuBarIcon(since: since)
        } else if Rehearsal.isOn {
            Image(nsImage: Self.rehearsal)
        } else {
            Image(nsImage: controller.isOn ? Self.idle : Self.off)
        }
    }

    /// Dimmed bars while Mossad is turned off.
    static let off: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawBars(.black.withAlphaComponent(0.35), in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mossad is off"
        return image
    }()

    /// Bar x positions and spans on an 18 pt grid, from the design.
    private static let bars: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] = [
        (2.5, 7, 11), (5.75, 4.5, 13.5), (9, 2.5, 15.5), (12.25, 5.5, 12.5), (15.5, 7.5, 10.5),
    ]

    fileprivate static func drawBars(_ color: NSColor, in rect: NSRect) {
        color.setStroke()
        for bar in bars {
            let path = NSBezierPath()
            path.lineWidth = 2.2
            path.lineCapStyle = .round
            // AppKit's y axis points up; the design's spans are measured from the top.
            path.move(to: NSPoint(x: bar.x, y: rect.height - bar.top))
            path.line(to: NSPoint(x: bar.x, y: rect.height - bar.bottom))
            path.stroke()
        }
    }

    static let idle: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawBars(.black, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mossad"
        return image
    }()

    /// The bars with a small "Rehearsal" after them, so the copy for trying setup never passes for the real app.
    static let rehearsal: NSImage = {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let text = NSAttributedString(string: "Rehearsal", attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = NSSize(width: ceil(18 + 4 + text.size().width), height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            drawBars(.black, in: NSRect(x: 0, y: 0, width: 18, height: 18))
            text.draw(at: NSPoint(x: 22, y: (rect.height - text.size().height) / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mossad Rehearsal"
        return image
    }()

    /// Drawn when the menu bar draws it, so the time follows its light or dark look.
    static func recording(_ time: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let text = NSAttributedString(string: time, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let size = NSSize(width: ceil(18 + 5 + text.size().width), height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            drawBars(.systemRed, in: NSRect(x: 0, y: 0, width: 18, height: 18))
            text.draw(at: NSPoint(x: 23, y: (rect.height - text.size().height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Recording \(time)"
        return image
    }
}

/// The recording icon with its clock. A separate view, so the 1 s timer only exists while recording.
private struct RecordingMenuBarIcon: View {
    let since: Date
    @StateObject private var clock = SecondsClock()

    var body: some View {
        Image(nsImage: MenuBarIcon.recording(elapsed(since, clock.now)))
    }
}

/// Publishes the time once a second.
@MainActor
final class SecondsClock: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }
}

/// Makes Mossad behave like a normal app from the Dock: a click on its icon opens the window, and starting it
/// by hand does too. A start at login stays quiet in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `kill` and `pkill` (an install) quit like Quit does, so a live call ends cleanly.
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidBecomeActive(_ notification: Notification) {
        // A key stored by another process (`--import-keys`) shows when the owner comes back.
        AppController.current?.keysChanged()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminateSignal = source
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
            // Login items started by the system do not always say so; a start in the first minutes after
            // booting is one of them.
            || ProcessInfo.processInfo.systemUptime < 180
        // `--background`: a restart after an update, which must not pull the owner away from their work.
        // Rehearsal opens straight into setup, every time.
        if Rehearsal.isOn, !CommandLine.arguments.contains("--ui-preview") {
            DispatchQueue.main.async { AppController.current?.openOnboarding() }
            return
        }
        guard !atLogin, !CommandLine.arguments.contains("--ui-preview"), !CommandLine.arguments.contains("--open-window"),
              !CommandLine.arguments.contains("--background") else { return }
        DispatchQueue.main.async { AppController.current?.open(AppController.current?.section ?? .meetings) }
    }

    /// Quit, logout, or a restart during a call ends the recording cleanly first, with no question. After 3 s the
    /// app quits anyway; the next launch recovers what reached the disk.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // An answer to a card that is on its way to the disk gets there.
        AppController.answerWriter.sync {}
        guard let controller = AppController.current, controller.isRecording else { return .terminateNow }
        Log.info("Quit during a call: ending the recording first")
        quitPending = true
        controller.endCallForQuit { Task { @MainActor in self.finishQuit() } }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.finishQuit()
        }
        return .terminateLater
    }

    private var quitPending = false

    private func finishQuit() {
        guard quitPending else { return }
        quitPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.current?.open(AppController.current?.section ?? .meetings)
        return false
    }
}
