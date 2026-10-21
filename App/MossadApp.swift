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

/// While recording, a red dot and the time since the call started; otherwise the plain waveform.
/// The menu bar draws one image only: a TimelineView or a mixed view there makes the item disappear.
struct MenuBarIcon: View {
    @ObservedObject var controller: AppController
    @StateObject private var clock = SecondsClock()

    var body: some View {
        if case .recording(_, let since) = controller.status {
            Image(nsImage: Self.badge(elapsed(since, clock.now)))
        } else {
            Image(systemName: "waveform")
        }
    }

    /// A red dot and the time. Drawn when the menu bar draws it, so the text follows its light or dark look.
    static func badge(_ time: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let text = NSAttributedString(string: time, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let dot: CGFloat = 8, gap: CGFloat = 4
        let size = NSSize(width: ceil(dot + gap + text.size().width), height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: (rect.height - dot) / 2, width: dot, height: dot)).fill()
            text.draw(at: NSPoint(x: dot + gap, y: (rect.height - text.size().height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Recording \(time)"
        return image
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
