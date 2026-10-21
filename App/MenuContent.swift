import MossadCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Text(statusLine)
        Divider()
        Button("Quit Mossad") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.status {
        case .idle: "Idle"
        case .inCall(let platform, _): "In call: \(platform.displayName)"
        }
    }
}
