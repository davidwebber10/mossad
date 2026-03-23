// Mossad/Views/LiveTranscriptView.swift
import SwiftUI

struct LiveTranscriptView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    RecordingIndicator()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.currentMeetingTitle ?? "Recording...")
                            .font(.title3)
                            .fontWeight(.semibold)
                        HStack(spacing: 6) {
                            if let platform = appState.currentPlatform {
                                Text(platform.capitalized)
                            }
                            Text("·")
                            Text(appState.elapsedFormatted)
                                .monospacedDigit()
                            if appState.speakerCount > 0 {
                                Text("·")
                                Text("\(appState.speakerCount) speakers")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding()

            Divider()

            // Live transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(appState.liveUtterances.enumerated()), id: \.offset) { index, utterance in
                            LiveUtteranceRow(
                                speaker: utterance.speaker,
                                text: utterance.text,
                                timestamp: utterance.timestamp
                            )
                            .id(index)
                        }

                        // Partial (in-progress) text
                        if !appState.livePartialText.isEmpty {
                            LiveUtteranceRow(
                                speaker: "",
                                text: appState.livePartialText,
                                timestamp: -1,
                                isPartial: true
                            )
                            .id("partial")
                        }
                    }
                    .padding()
                }
                .onChange(of: appState.liveUtterances.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(appState.liveUtterances.count - 1, anchor: .bottom)
                    }
                }
                .onChange(of: appState.livePartialText) {
                    if !appState.livePartialText.isEmpty {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("partial", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

struct RecordingIndicator: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

struct LiveUtteranceRow: View {
    let speaker: String
    let text: String
    let timestamp: Double
    var isPartial: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timestamp
            if timestamp >= 0 {
                Text(formatTimestamp(timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            } else {
                Spacer()
                    .frame(width: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                if !speaker.isEmpty {
                    Text(speaker)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(speaker == "Me" || speaker.contains("David") ? .green : .purple)
                }

                Text(text)
                    .font(.body)
                    .foregroundStyle(isPartial ? .secondary : .primary)
                    .italic(isPartial)
            }
        }
        .opacity(isPartial ? 0.7 : 1.0)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
