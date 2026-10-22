import SwiftUI
import MossadCore

@main
struct MossadEntry {
    static func main() {
        // `--import-keys` copies API keys from the environment (Doppler) into the Keychain and exits.
        if CommandLine.arguments.contains("--import-keys") {
            let stored = importKeys(from: ProcessInfo.processInfo.environment, into: Keychain())
            print(stored.isEmpty ? "No keys found in the environment." : "Stored: " + stored.map(\.rawValue).joined(separator: ", "))
            exit(stored.isEmpty ? 1 : 0)
        }
        // `--mcp` serves the meetings to other AI apps over stdio, read-only, with no UI and no recording.
        if CommandLine.arguments.contains("--mcp") {
            let owner = UserDefaults.standard.string(forKey: "ownerName") ?? NSFullUserName()
            MCPServer(paths: .live, owner: owner).run()
            exit(0)
        }
        MossadApp.main()
    }
}

struct MossadApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, permissions: controller.permissions)
        } label: {
            MenuBarIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)

    }
}

/// The five waveform bars: a template image when idle, red bars and the elapsed time while recording.
/// The menu bar draws one image only: a TimelineView or a mixed view there makes the item disappear.
struct MenuBarIcon: View {
    @ObservedObject var controller: AppController

    var body: some View {
        if case .recording(_, let since) = controller.status {
            RecordingMenuBarIcon(since: since)
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
