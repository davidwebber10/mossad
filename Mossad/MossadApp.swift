import SwiftUI

@main
struct MossadApp: App {
    var body: some Scene {
        MenuBarExtra("Mossad", systemImage: "mic.fill") {
            Text("Mossad is running")
                .padding()
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
