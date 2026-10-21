import MossadCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var permissions: PermissionsMonitor

    var body: some View {
        Text(statusLine)
        if controller.processing > 0 {
            Text("Processing \(controller.processing) call\(controller.processing == 1 ? "" : "s")…")
        }
        if controller.isRecording {
            Button("Skip this call") { controller.skipCurrentCall() }
        }
        if !permissions.allGood {
            Button("Fix permissions…") { controller.open(.settings) }
        }
        Divider()
        Button("Meetings…") { controller.open(.meetings) }
        if let first = controller.callsNeedingNames.first {
            Button("Name voices…") { controller.openNaming(first.id) }
        }
        Button("Voices…") { controller.open(.voices) }
        Button("Settings…") { controller.open(.settings) }
        Button("Log…") { controller.open(.log) }
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
