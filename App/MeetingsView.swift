import AppKit
import MossadCore
import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject var controller: AppController
    @State private var query = ""
    @State private var deleting: CallRecord?

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
                    .contextMenu {
                        Button("Delete…", role: .destructive) { deleting = r }.disabled(!r.canDelete)
                    }
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
                    MeetingDetailView(record: r, deleting: $deleting, audioDirectory: controller.paths.callDirectory(r.id))
                        .id(r.id)
                } else {
                    ContentUnavailableView("Select a meeting", systemImage: "text.bubble")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search titles and transcripts")
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete meeting", role: .destructive) {
                if let id = deleting?.id { controller.deleteMeeting(id) }
            }
        } message: {
            Text("Mossad deletes the note, the transcript, and the audio. Voices it learned from this call stay.")
        }
        .onAppear {
            if controller.selectedMeetingID == nil { controller.selectedMeetingID = controller.meetings.first?.id }
        }
        .sheet(item: Binding(get: { controller.namingCallID.flatMap { id in controller.meetings.first { $0.id == id } } },
                             set: { controller.namingCallID = $0?.id })) { r in
            VoiceNamingView(record: r)
        }
    }
}

extension CallRecord: @retroactive Identifiable {
    /// A call that is still recording or processing cannot be deleted; Skip this call covers the first.
    var canDelete: Bool { status == .written || status == .failed }
}

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
