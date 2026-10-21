import AppKit
import MossadCore
import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject var controller: AppController
    @State private var query = ""

    private var results: [CallRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return controller.meetings }
        return controller.meetings.filter { r in
            r.title.localizedCaseInsensitiveContains(q) || r.utterances.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(results, id: \.id, selection: $controller.selectedMeetingID) { r in
                MeetingRow(record: r).tag(r.id)
            }
            .overlay {
                if controller.meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Mossad records Zoom, Meet, and Teams calls on its own."))
                }
            }
            .frame(width: 300)

            Divider()

            Group {
                if let id = controller.selectedMeetingID, let r = controller.meetings.first(where: { $0.id == id }) {
                    MeetingDetail(record: r)
                } else {
                    ContentUnavailableView("Select a meeting", systemImage: "text.bubble")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search titles and transcripts")
        .onAppear {
            if controller.selectedMeetingID == nil { controller.selectedMeetingID = controller.meetings.first?.id }
        }
        .sheet(item: Binding(get: { controller.namingCallID.flatMap { id in controller.meetings.first { $0.id == id } } },
                             set: { controller.namingCallID = $0?.id })) { r in
            VoiceNamingView(record: r)
        }
    }
}

extension CallRecord: @retroactive Identifiable {}

private struct MeetingRow: View {
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.title).font(.headline).lineLimit(1)
                Spacer()
                if record.status != .written {
                    Text(record.status == .recording ? "Recording" : "Processing")
                        .font(.caption).foregroundStyle(.orange)
                } else if !record.unknownSpeakers.isEmpty {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.secondary)
                }
            }
            Text("\(record.start.formatted(date: .abbreviated, time: .shortened)) · \(record.platform.displayName) · \(Int(record.end.timeIntervalSince(record.start) / 60)) min")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct MeetingDetail: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord

    var body: some View {
        let names = MarkdownWriter.displayNames(record)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title).font(.title2.bold())
                        Text("\(record.start.formatted(date: .complete, time: .shortened)) · \(record.platform.displayName)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !record.unknownSpeakers.isEmpty, record.status == .written {
                        Button("Name voices") { controller.namingCallID = record.id }
                    }
                    if let path = record.markdownPath {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                }

                if record.status != .written {
                    HStack {
                        Text(statusText).foregroundStyle(.secondary)
                        if record.attempts > 0 { Button("Retry now") { controller.retry(record.id) } }
                    }
                }

                if let summary = record.summary {
                    section("Summary") { Text(summary).textSelection(.enabled) }
                    section("Action items") {
                        if record.actionItems.isEmpty {
                            Text("None.").foregroundStyle(.secondary)
                        } else {
                            ForEach(record.actionItems, id: \.self) { Label($0, systemImage: "circle").textSelection(.enabled) }
                        }
                    }
                }

                let speakers = Array(Set(record.utterances.map { names[$0.speakerKey] ?? $0.speakerKey })).sorted()
                if !speakers.isEmpty {
                    section("Speakers") { Text(speakers.joined(separator: ", ")) }
                }

                if !record.utterances.isEmpty {
                    section("Transcript") {
                        Text(MarkdownWriter.transcript(record))
                            .font(.system(.body, design: .default))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusText: String {
        switch record.status {
        case .recording: "Recording…"
        case .recorded: record.attempts > 0 ? "Transcription failed \(record.attempts)×; Mossad will retry." : "Waiting for transcription…"
        case .transcribed: "Identifying speakers…"
        case .identified: "Writing summary…"
        case .summarized: "Writing file…"
        case .failed: "Failed"
        case .written: ""
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
