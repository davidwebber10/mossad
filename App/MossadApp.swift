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
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.isRecording ? "waveform.circle.fill" : "waveform")
        }
    }
}
