import MossadCore
import SwiftUI

/// The meetings by day, newest first, as the Mac's list groups them: Today, Yesterday, then the weekday and the
/// date. Settings is a glass button at the top; Record room floats over the list, on this tab only.
struct MeetingsListView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var recording = PhoneStore.hook("MOSSAD_ROOM") != nil
    @State private var settings = PhoneStore.hook("MOSSAD_SETTINGS") != nil
    /// A meeting opens out of its row.
    @Namespace private var zoom

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = store.error {
                        ErrorCard(error: error, retry: error.canRetry && !store.syncing ? { Task { await store.sync() } } : nil,
                                  note: error.context == .uploadingAudio ? "The recording is saved on this iPhone." : nil)
                            .padding(.vertical, Space.s)
                    }
                    if !store.outbox.entries.isEmpty { outbox }
                    ForEach(store.days, id: \.date) { day in
                        PhoneLabel(day.title).padding(.top, Space.l).padding(.bottom, 2)
                        ForEach(Array(day.rows.enumerated()), id: \.element.id) { i, r in
                            NavigationLink(value: r.id) {
                                PhoneMeetingRow(row: r, divided: i < day.rows.count - 1)
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: r.id, in: zoom)
                        }
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, 96)
            }
            .overlay {
                if store.loaded, store.days.isEmpty, store.outbox.entries.isEmpty {
                    EmptyState(symbol: store.syncWith == .server ? "server.rack" : "icloud",
                               title: store.syncing ? "Syncing…" : "No meetings yet",
                               message: "Meetings appear here after Mossad on your Mac writes their notes.")
                }
            }
            .overlay(alignment: .bottomTrailing) { recordButton }
            .phonePage()
            .navigationTitle("Meetings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { settings = true }.tint(Palette.ink)
                }
            }
            .fullScreenCover(isPresented: $recording) { RecordingView() }
            .sheet(isPresented: $settings) { PhoneSettingsView() }
            .refreshable { await store.sync() }
            .navigationDestination(for: String.self) { id in
                MeetingPage(id: id).navigationTransition(.zoom(sourceID: id, in: zoom))
            }
            // A recording that runs without its screen (the app came back, or the screen closed) shows it again.
            .onAppear { if store.recorder.state != .idle { recording = true } }
        }
    }

    /// Room recordings made here that the Mac has not written up yet.
    @ViewBuilder
    private var outbox: some View {
        PhoneLabel("On this iPhone").padding(.top, Space.l).padding(.bottom, 2)
        let entries = store.outbox.entries, now = Date()
        ForEach(Array(entries.enumerated()), id: \.element.id) { i, item in
            HairlineRow(divided: i < entries.count - 1) {
                HStack(alignment: .top, spacing: Space.m) {
                    Circle().fill(Palette.recording).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.recording.title ?? "In-person meeting").textRole(.headline).foregroundStyle(Palette.ink)
                        HStack(spacing: 6) {
                            Text("\(item.recording.start.formatted(date: .omitted, time: .shortened)) · " + status(item))
                            if !item.isSent { PhoneProcessingMark() }
                        }
                        .textRole(.secondary)
                        .foregroundStyle(Palette.secondary)
                        // Why it still waits; it stays until this recording uploads.
                        if !item.isSent, let reason = store.syncStatus.uploads[item.id] {
                            InlineError(error: reason).padding(.top, 2)
                        }
                        // The Mac had time and no meeting came back: the owner can send it once more.
                        if item.canSendAgain(now: now), !store.uploading.contains(item.id) {
                            Button("Send again") { store.sendAgain(item.id) }
                                .textRole(.secondary).fontWeight(.semibold)
                                .tint(Palette.accent)
                                .frame(minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if item.state != .recording {
                        Text(shortLength(item.recording.end.timeIntervalSince(item.recording.start)))
                            .textRole(.secondary).foregroundStyle(Palette.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func status(_ item: Outbox.Entry) -> String {
        switch item.state {
        case .recording: item.id == store.recorder.id ? "Recording now" : "Saving the recording"
        case .waiting: store.uploading.contains(item.id) ? "Sending to your Mac" : "Waiting to send"
        case .sent: store.uploading.contains(item.id) ? "Sending again" : "Your Mac is writing the notes"
        }
    }

    private var recordButton: some View {
        Button { recording = true } label: {
            // Shorter at the largest text sizes, so the button does not cover most of a row.
            Label(store.recorder.state != .idle ? "Recording" : typeSize.isAccessibilitySize ? "Record" : "Record room",
                  systemImage: "circle.fill")
                .labelStyle(RecordLabelStyle())
        }
        .buttonStyle(.phoneFill(Palette.recording))
        .shadow(color: Palette.recording.opacity(0.3), radius: 12, y: 6)
        .padding(.trailing, Space.l)
        .padding(.bottom, Space.m)
        .accessibilityLabel(store.recorder.state != .idle ? "Show the recording" : "Record room")
        .accessibilityHint(store.recorder.state != .idle ? "" : "Records a meeting in this room with the iPhone's microphone")
    }
}

private struct RecordLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s) {
            configuration.icon.font(.system(size: 10)).accessibilityHidden(true)
            configuration.title
        }
    }
}

/// "45 min", or "1 h 45" as the canvas shortens a list row's length.
func shortLength(_ seconds: TimeInterval) -> String {
    let m = max(1, Int(seconds / 60))
    return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60)"
}

/// One meeting: the platform dot, the title (up to two lines), the time, platform, and size of the room under it,
/// the length on the right, and "2 voices need names" when the Mac is waiting on the owner.
struct PhoneMeetingRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let record: MeetingRow
    var divided = true

    init(row: MeetingRow, divided: Bool = true) {
        record = row
        self.divided = divided
    }

    var body: some View {
        HairlineRow(divided: divided) {
            HStack(alignment: .top, spacing: Space.m) {
                PlatformDot(platform: record.platform).padding(.top, 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .textRole(.headline)
                        .foregroundStyle(Palette.ink)
                        // Large type wraps instead of cutting the title short.
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                    Text(detail).textRole(.secondary).foregroundStyle(Palette.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    if record.unnamed > 0 {
                        let n = record.unnamed
                        NeedsYouChip(text: n == 1 ? "1 voice needs a name" : "\(n) voices need names").padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(shortLength(record.end.timeIntervalSince(record.start)))
                    .textRole(.secondary)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "10:17 AM · In person · 12 speakers"
    private var detail: String {
        let time = record.start.formatted(date: .omitted, time: .shortened)
        var parts = [time, record.platform.shortName]
        let speakers = record.speakers
        if speakers >= 3 { parts.append("\(speakers) speakers") }
        return parts.joined(separator: " · ")
    }
}

/// What a list row needs from a meeting, made off the main thread, so the list never compares or redraws from
/// whole records with their transcripts.
struct MeetingRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let platform: Platform
    let start: Date
    let end: Date
    let speakers: Int
    /// Voices the Mac waits on the owner to name, once the notes are written.
    let unnamed: Int

    init(_ r: CallRecord) {
        id = r.id
        title = r.title
        platform = r.platform
        start = r.start
        end = r.end
        speakers = Set(r.utterances.map(\.speakerKey)).count
        unnamed = r.status == .written ? r.unknownSpeakers.count : 0
    }
}

struct MeetingDay: Equatable, Sendable {
    let date: Date
    let title: String
    let rows: [MeetingRow]
}

/// A meeting's page by id. A meeting that the Mac deleted while its page was open says so instead of going blank.
struct MeetingPage: View {
    @Environment(PhoneStore.self) private var store
    let id: String
    var find = ""
    var at: TimeInterval?

    var body: some View {
        if let r = store.meeting(id) {
            MeetingView(record: r, find: find, at: at)
        } else if store.loaded {
            EmptyState(symbol: "tray", title: "This meeting is no longer here",
                       message: "It was deleted on your Mac, or it has not synced to this iPhone yet.")
                .phonePage()
        } else {
            PhoneProcessingMark().frame(maxWidth: .infinity, maxHeight: .infinity).phonePage()
        }
    }
}
