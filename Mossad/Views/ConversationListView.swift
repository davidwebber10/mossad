// Mossad/Views/ConversationListView.swift
import SwiftUI
import MossadShared

struct ConversationListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedConversationId: String?
    @State private var conversations: [Conversation] = []
    @State private var speakerCounts: [String: Int] = [:]
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search conversations...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .glassEffect(.regular.tint(.clear))

            // Conversation list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(conversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isSelected: selectedConversationId == conversation.id,
                            speakerCount: speakerCounts[conversation.id] ?? 0
                        )
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.3)) {
                                selectedConversationId = conversation.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
        }
        .frame(minWidth: 280, maxWidth: 320)
        .task {
            loadConversations()
        }
        .onChange(of: searchText) {
            loadConversations()
        }
    }

    private func loadConversations() {
        // Search wiring added in Task 16
        conversations = (try? appState.store.listConversations()) ?? []
        // Load speaker counts for each conversation
        for conv in conversations {
            let speakers = (try? appState.store.fetchSpeakers(conversationId: conv.id)) ?? []
            speakerCounts[conv.id] = speakers.count
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
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.selection)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
