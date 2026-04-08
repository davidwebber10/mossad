// Mossad/Views/LiveTranscriptView.swift
import SwiftUI

struct LiveTranscriptView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            RecordingIndicator()
                .frame(width: 48, height: 48)

            VStack(spacing: 8) {
                Text(appState.currentMeetingTitle ?? "Recording...")
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 6) {
                    if let platform = appState.currentPlatform {
                        Text(platform.capitalized)
                    }
                    Text("·")
                    Text(appState.elapsedFormatted)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Text("Recording in progress. Transcription with speaker identification will begin when the call ends.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingIndicator: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(.red)
            .scaleEffect(pulse ? 1.2 : 0.9)
            .opacity(pulse ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
