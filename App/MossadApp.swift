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
struct MenuBarIcon: View {
    @ObservedObject var controller: AppController

    var body: some View {
        if case .recording(_, let since) = controller.status {
            TimelineView(.periodic(from: since, by: 1)) { context in
                HStack(spacing: 3) {
                    Image(nsImage: Self.redDot)
                    Text(elapsed(since, context.date)).monospacedDigit()
                }
            }
        } else {
            Image(systemName: "waveform")
        }
    }

    /// Menu bar images are drawn as templates (one color); this one keeps its red.
    private static let redDot: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!
            .withSymbolConfiguration(config)!
        image.isTemplate = false
        return image
    }()
}
