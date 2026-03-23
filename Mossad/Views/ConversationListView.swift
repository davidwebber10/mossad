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
            } else if conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Conversations will appear here after your first recorded call.")
                )
            } else {
                List {
                    ForEach(conversations) { conversation in
                        HStack(spacing: 10) {
                            if isSelecting {
                                Image(systemName: selectedIds.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIds.contains(conversation.id) ? .blue : .secondary)
                                    .font(.title3)
                                    .contentTransition(.symbolEffect(.replace))
                            }

                            ConversationRow(
                                conversation: conversation,
                                speakerCount: speakerCounts[conversation.id] ?? 0
                            )
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting {
                                withAnimation(.snappy(duration: 0.15)) {
                                    toggleSelection(conversation.id)
                                }
                            } else {
                                selectedConversationId = conversation.id
                            }
                        }
                        .listRowBackground(
                            !isSelecting && selectedConversationId == conversation.id
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .contextMenu {
                            if !isSelecting {
                                Button(role: .destructive) {
                                    deleteConversation(conversation)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if !isSelecting {
                                Button(role: .destructive) {
                                    deleteConversation(conversation)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
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
            ToolbarItem(placement: .automatic) {
                if isSelecting {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isSelecting = false
                            selectedIds.removeAll()
                        }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .help("Done selecting")
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isSelecting = true
                        }
                    } label: {
                        Text("Select")
                    }
                    .help("Select multiple conversations")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                SelectionBar(
                    count: selectedIds.count,
                    total: conversations.count,
                    onSelectAll: {
                        withAnimation(.snappy(duration: 0.15)) {
                            selectedIds = Set(conversations.map(\.id))
                        }
                    },
                    onDeselectAll: {
                        withAnimation(.snappy(duration: 0.15)) {
                            selectedIds.removeAll()
                        }
                    },
                    onDelete: deleteSelected
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

// MARK: - Selection Bar

struct SelectionBar: View {
    let count: Int
    let total: Int
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(count == total ? "Deselect All" : "Select All") {
                if count == total {
                    onDeselectAll()
                } else {
                    onSelectAll()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)

            Spacer()

            if count > 0 {
                Text("\(count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation
    let speakerCount: Int

    var body: some View {
        HStack(spacing: 12) {
            // Time column
            VStack(spacing: 2) {
                Text(conversation.startedAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .fontWeight(.medium)
                Text(conversation.startedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 50)

            // Details
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let duration = conversation.durationSeconds {
                        Text(formatDuration(duration))
                    }
                    Text("·")
                    Image(systemName: platformIcon(conversation.platform))
                    Text(conversation.platform.capitalized)
                    if speakerCount > 0 {
                        Text("·")
                        Text("\(speakerCount) speakers")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if seconds >= 3600 {
            let h = seconds / 3600
            let rm = (seconds % 3600) / 60
            return "\(h)h \(rm)m"
        }
        return "\(m)m \(s)s"
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
