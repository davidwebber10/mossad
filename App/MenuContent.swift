import MossadCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Text(statusLine)
        if controller.isRecording {
            Button("Skip this call") { controller.skipCurrentCall() }
        }
        Divider()
        Button("Quit Mossad") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.status {
        case .idle: "Idle"
        case .recording(let platform, let since):
            "Recording \(platform.displayName) since \(since.formatted(date: .omitted, time: .shortened))"
        }
    }
}
