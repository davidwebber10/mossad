// Mossad/Views/ConversationBrowserWindow.swift
import SwiftUI
import MossadShared

enum BrowserTab: String, CaseIterable {
    case upcoming = "Upcoming"
    case conversations = "Conversations"
}

struct ConversationBrowserWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: BrowserTab = .upcoming
    @State private var selectedConversationId: String?
    @State private var scrollToUtteranceId: Int64?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Upcoming", systemImage: "calendar", value: .upcoming) {
                UpcomingEventsView()
                    .environmentObject(appState)
            }

            Tab("Conversations", systemImage: "bubble.left.and.bubble.right", value: .conversations) {
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
            }
        }
        .frame(minWidth: 800, minHeight: 500)
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
