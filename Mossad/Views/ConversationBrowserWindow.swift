// Mossad/Views/ConversationBrowserWindow.swift
import SwiftUI
import MossadShared

struct ConversationBrowserWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedConversationId: String?

    var body: some View {
        NavigationSplitView {
            ConversationListView(selectedConversationId: $selectedConversationId)
                .environmentObject(appState)
        } detail: {
            if let id = selectedConversationId {
                TranscriptPlaceholder(conversationId: id)
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
    }
}

// Placeholder until Task 15
struct TranscriptPlaceholder: View {
    let conversationId: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        Text("Transcript view — next task")
            .foregroundStyle(.secondary)
    }
}
