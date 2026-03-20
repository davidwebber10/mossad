// Mossad/Views/SearchResultsView.swift
import SwiftUI
import MossadShared

struct SearchResultsView: View {
    let results: [SearchResult]
    @Binding var selectedConversationId: String?
    @Binding var scrollToUtteranceId: Int64?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(results, id: \.utterance.id) { result in
                    SearchResultRow(result: result)
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.3)) {
                                selectedConversationId = result.conversation.id
                                scrollToUtteranceId = result.utterance.id
                            }
                        }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.conversation.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(result.conversation.startedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(result.speaker.name)
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text("· at \(formatTimestamp(result.utterance.startedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(result.utterance.text)
                .font(.subheadline)
                .lineLimit(3)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.opacity(0.6))
        }
        .glassEffect(.regular.tint(.clear))
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
