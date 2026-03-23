// Mossad/Views/ConversationListView.swift
import SwiftUI
import MossadShared

struct ConversationListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedConversationId: String?
    @Binding var scrollToUtteranceId: Int64?
    @State private var conversations: [Conversation] = []
    @State private var speakerCounts: [String: Int] = [:]
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []

    var body: some View {
        Group {
            if isSearching && !searchResults.isEmpty {
                SearchResultsView(
                    results: searchResults,
                    selectedConversationId: $selectedConversationId,
                    scrollToUtteranceId: $scrollToUtteranceId
                )
            } else {
                List {
                    ForEach(conversations) { conversation in
                        HStack(spacing: 10) {
                            if isSelecting {
                                Image(systemName: selectedIds.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIds.contains(conversation.id) ? .blue : .secondary)
                                    .font(.title3)
                                    .onTapGesture {
                                        toggleSelection(conversation.id)
                                    }
                            }

                            ConversationRow(
                                conversation: conversation,
                                isSelected: !isSelecting && selectedConversationId == conversation.id,
                                speakerCount: speakerCounts[conversation.id] ?? 0
                            )
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting {
                                toggleSelection(conversation.id)
                            } else {
                                selectedConversationId = conversation.id
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteConversation(conversation)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteConversation(conversation)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Conversations")
        .searchable(text: $searchText, prompt: "Search conversations...")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if isSelecting {
                    Button("Select All") {
                        selectedIds = Set(conversations.map(\.id))
                    }

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete \(selectedIds.count)", systemImage: "trash")
                    }
                    .disabled(selectedIds.isEmpty)

                    Button("Done") {
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                } else {
                    Button {
                        isSelecting = true
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .frame(minWidth: 250)
        .task {
            loadConversations()
        }
        .onChange(of: searchText) {
            loadConversations()
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func deleteSelected() {
        for id in selectedIds {
            try? appState.store.deleteConversation(id: id)
            if selectedConversationId == id {
                selectedConversationId = nil
            }
        }
        selectedIds.removeAll()
        isSelecting = false
        loadConversations()
    }

    private func deleteConversation(_ conversation: Conversation) {
        try? appState.store.deleteConversation(id: conversation.id)
        if selectedConversationId == conversation.id {
            selectedConversationId = nil
        }
        loadConversations()
    }

    private func loadConversations() {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            isSearching = false
            conversations = (try? appState.store.listConversations()) ?? []
            for conv in conversations {
                let speakers = (try? appState.store.fetchSpeakers(conversationId: conv.id)) ?? []
                speakerCounts[conv.id] = speakers.count
            }
        } else {
            isSearching = true
            searchResults = (try? appState.store.search(query: searchText)) ?? []
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let speakerCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)

            HStack {
                Text(conversation.startedAt, style: .date)
                Text("·")
                if let duration = conversation.durationSeconds {
                    Text(formatDuration(duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Label(conversation.platform.capitalized, systemImage: platformIcon(conversation.platform))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if speakerCount > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(speakerCount) speakers")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "\(h)h \(m)m"
        }
        return "\(seconds / 60)m"
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "zoom": return "video.fill"
        case "meet": return "person.3.fill"
        case "teams": return "person.2.fill"
        default: return "phone.fill"
        }
    }
}
