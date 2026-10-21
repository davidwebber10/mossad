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
    var body: some Scene {
        MenuBarExtra("Mossad", systemImage: "waveform") {
            Button("Quit Mossad") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
