// Mossad/Views/TranscriptView.swift
import SwiftUI
import MossadShared

struct TranscriptView: View {
    let conversationId: String
    var scrollToUtteranceId: Int64? = nil
    @EnvironmentObject var appState: AppState
    @State private var conversation: Conversation?
    @State private var utterances: [(Utterance, Speaker)] = []
    @State private var speakers: [Speaker] = []

    // Speaker color palette
    private let speakerColors: [Color] = [
        .green, .purple, .pink, .orange, .cyan, .yellow, .mint, .indigo
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            if let conversation = conversation {
                transcriptHeader(conversation)
            }

            Divider()

            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(utterances, id: \.0.id) { utterance, speaker in
                            UtteranceRow(
                                utterance: utterance,
                                speaker: speaker,
                                color: colorForSpeaker(speaker)
                            )
                            .id(utterance.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: scrollToUtteranceId) {
                    if let targetId = scrollToUtteranceId {
                        withAnimation {
                            proxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                }
            }
        }
        .task {
            loadTranscript()
        }
    }

    @ViewBuilder
    private func transcriptHeader(_ conv: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conv.title)
                .font(.title2)
                .fontWeight(.bold)

            HStack {
                Text(conv.startedAt, style: .date)
                if let endedAt = conv.endedAt {
                    Text("·")
                    Text("\(conv.startedAt, style: .time) – \(endedAt, style: .time)")
                }
                Text("·")
                Text(conv.platform.capitalized)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(speakers) { speaker in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForSpeaker(speaker))
                            .frame(width: 10, height: 10)
                        Text(speaker.name)
                            .font(.caption)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .glassEffect(.regular.tint(.clear))
    }

    private func colorForSpeaker(_ speaker: Speaker) -> Color {
        if speaker.isMe { return .green }
        guard let index = speakers.firstIndex(where: { $0.id == speaker.id }) else {
            return .gray
        }
        return speakerColors[index % speakerColors.count]
    }

    private func loadTranscript() {
        conversation = try? appState.store.fetchConversation(id: conversationId)
        speakers = (try? appState.store.fetchSpeakers(conversationId: conversationId)) ?? []

        let rawUtterances = (try? appState.store.fetchUtterances(conversationId: conversationId)) ?? []
        utterances = rawUtterances.compactMap { utterance in
            guard let speaker = speakers.first(where: { $0.id == utterance.speakerId })
                ?? (try? appState.store.fetchSpeaker(id: utterance.speakerId)) else {
                return nil
            }
            return (utterance, speaker)
        }
    }
}

struct UtteranceRow: View {
    let utterance: Utterance
    let speaker: Speaker
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(speaker.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)

                Text(formatTimestamp(utterance.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(utterance.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
