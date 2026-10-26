import MossadCore
import SwiftUI

/// The menu bar's commands: every section by number, a new chat, and the actions on the open meeting.
struct MossadCommands: Commands {
    @ObservedObject var controller: AppController

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { controller.open(.settings) }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { controller.startChat() }.keyboardShortcut("n")
        }
        CommandMenu("Go") {
            ForEach(Array(AppController.Section.allCases.enumerated()), id: \.element) { i, section in
                Button(section.rawValue) { controller.open(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
        }
        CommandMenu("Meeting") {
            Button("Regenerate Summary") {
                if let id = controller.selectedMeetingID { controller.regenerateSummary(id) }
            }
            .keyboardShortcut("r")
            .disabled(selected?.status != .written)
            Button("Name Voices…") {
                if let id = controller.selectedMeetingID { controller.namingCallID = id }
            }
            .disabled(selected.map { $0.status != .written || ($0.unknownSpeakers.isEmpty && $0.skippedSpeakers.isEmpty) } ?? true)
            Divider()
            Button("Bookmark This Moment") { controller.bookmarkCurrentCall() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!controller.isRecording)
        }
    }

    private var selected: CallRecord? {
        controller.selectedMeetingID.flatMap { id in controller.meetings.first { $0.id == id } }
    }
}
