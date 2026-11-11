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
            Button("Ask…") { controller.startChat() }.keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Search Everything…") { controller.toggleSearch() }.keyboardShortcut("k")
            Divider()
            // In the order of the sidebar, a group for each item with pages under it. Coach opens on Findings.
            ForEach([AppController.Section.meetings] + AppController.Section.underMeetings) { go($0) }
            Divider()
            ForEach([AppController.Section.chat, .people, .analytics]) { go($0) }
            Divider()
            go(.coach)
            ForEach(CoachPage.allCases.filter { $0 != .findings }) { page in
                Button(page == .settings ? "Coach Settings" : page.title) { controller.open(coach: page) }
            }
            Divider()
            ForEach([AppController.Section.settings, .log]) { go($0) }
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
            Button("Share…") {
                if let id = controller.selectedMeetingID { controller.sharingCallID = id }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(selected?.status != .written)
            Divider()
            Button("Bookmark This Moment") { controller.bookmarkCurrentCall() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!controller.isRecording)
        }
    }

    private func go(_ section: AppController.Section) -> some View {
        Button(section.rawValue) { controller.open(section) }.keyboardShortcut(section.shortcut)
    }

    private var selected: CallRecord? {
        controller.selectedMeetingID.flatMap { id in controller.meetings.first { $0.id == id } }
    }
}
