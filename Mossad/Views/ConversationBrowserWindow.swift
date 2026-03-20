// Mossad/Views/ConversationBrowserWindow.swift
import SwiftUI
import MossadShared

struct ConversationBrowserWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedConversationId: String?
    @State private var scrollToUtteranceId: Int64?

    var body: some View {
        NavigationSplitView {
            ConversationListView(selectedConversationId: $selectedConversationId, scrollToUtteranceId: $scrollToUtteranceId)
                .environmentObject(appState)
        } detail: {
            if let id = selectedConversationId {
                TranscriptView(conversationId: id, scrollToUtteranceId: scrollToUtteranceId)
                    .environmentObject(appState)
            } else {
                ContentUnavailableView(
                    "Select a Conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation from the sidebar to view the transcript.")
                )
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .glassEffect(.regular.tint(.clear))
        .sheet(isPresented: $appState.showSpeakerLabeling) {
            if let convId = appState.lastEndedConversationId {
                SpeakerLabelingSheet(
                    conversationId: convId,
                    calendarAttendees: appState.lastEndedCalendarAttendees
                )
                .environmentObject(appState)
            }
        }
    }
}
