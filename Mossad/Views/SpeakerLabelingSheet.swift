// Mossad/Views/SpeakerLabelingSheet.swift
import SwiftUI
import MossadShared

struct SpeakerLabelingSheet: View {
    let conversationId: String
    let calendarAttendees: [String] // email addresses from calendar
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var speakers: [Speaker] = []
    @State private var assignments: [String: String] = [:] // speakerId → name

    var body: some View {
        VStack(spacing: 16) {
            Text("Identify Speakers")
                .font(.headline)

            Text("Assign names to the speakers detected in this conversation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(speakers.filter { !$0.isMe }) { speaker in
                HStack {
                    Circle()
                        .fill(.purple)
                        .frame(width: 10, height: 10)

                    Text(speaker.name)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)

                    if !calendarAttendees.isEmpty {
                        Picker("", selection: binding(for: speaker.id)) {
                            Text("Unknown").tag("")
                            ForEach(calendarAttendees, id: \.self) { attendee in
                                Text(attendee).tag(attendee)
                            }
                        }
                        .labelsHidden()
                    } else {
                        TextField("Name", text: binding(for: speaker.id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                Button("Skip") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    saveAssignments()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .task {
            speakers = (try? appState.store.fetchSpeakers(conversationId: conversationId)) ?? []
            for speaker in speakers where !speaker.isMe {
                assignments[speaker.id] = speaker.name
            }
        }
    }

    private func binding(for speakerId: String) -> Binding<String> {
        Binding(
            get: { assignments[speakerId] ?? "" },
            set: { assignments[speakerId] = $0 }
        )
    }

    private func saveAssignments() {
        for (speakerId, name) in assignments where !name.isEmpty {
            try? appState.store.updateSpeakerName(id: speakerId, name: name)
        }
    }
}
