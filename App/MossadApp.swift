import SwiftUI
import MossadCore

@main
struct MossadApp: App {
    var body: some Scene {
        MenuBarExtra("Mossad", systemImage: "waveform") {
            Button("Quit Mossad") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
