import MossadCore
import SwiftUI

/// The meetings by day, newest first, as the Mac's list groups them: Today, Yesterday, then the weekday and the
/// date. Settings is a glass button at the top; Record room floats over the list, on this tab only.
struct MeetingsListView: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var recording = PhoneStore.hook("MOSSAD_ROOM") != nil
    @State private var settings = PhoneStore.hook("MOSSAD_SETTINGS") != nil
    /// A meeting opens out of its row.
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $store.path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .textRole(.secondary)
                            .foregroundStyle(Palette.recording)
                            .padding(.vertical, Space.s)
                    }
                    if !store.outbox.isEmpty { outbox }
                    ForEach(MeetingGroups.byDay(store.meetings), id: \.date) { day in
                        PhoneLabel(day.title).padding(.top, Space.l).padding(.bottom, 2)
                        ForEach(Array(day.records.enumerated()), id: \.element.id) { i, r in
                            NavigationLink(value: r.id) {
                                PhoneMeetingRow(record: r, divided: i < day.records.count - 1)
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
                if store.meetings.isEmpty, store.outbox.isEmpty {
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
                if let r = store.meeting(id) { MeetingView(record: r).navigationTransition(.zoom(sourceID: id, in: zoom)) }
            }
        }
    }

    /// Room recordings made here that the Mac has not written up yet.
    @ViewBuilder
    private var outbox: some View {
        PhoneLabel("On this iPhone").padding(.top, Space.l).padding(.bottom, 2)
        ForEach(Array(store.outbox.enumerated()), id: \.element.id) { i, item in
            HairlineRow(divided: i < store.outbox.count - 1) {
                HStack(alignment: .top, spacing: Space.m) {
                    Circle().fill(Palette.recording).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.recording.title ?? "In-person meeting").textRole(.headline).foregroundStyle(Palette.ink)
                        HStack(spacing: 6) {
                            Text("\(item.recording.start.formatted(date: .omitted, time: .shortened)) · "
                                 + (item.sent ? "Your Mac is writing the notes" : "Waiting to send"))
                            if !item.sent { PhoneProcessingMark() }
                        }
                        .textRole(.secondary)
                        .foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(shortLength(item.recording.end.timeIntervalSince(item.recording.start)))
                        .textRole(.secondary).foregroundStyle(Palette.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var recordButton: some View {
        Button { recording = true } label: {
            // Shorter at the largest text sizes, so the button does not cover most of a row.
            Label(typeSize.isAccessibilitySize ? "Record" : "Record room", systemImage: "circle.fill")
                .labelStyle(RecordLabelStyle())
        }
        .buttonStyle(.phoneFill(Palette.recording))
        .shadow(color: Palette.recording.opacity(0.3), radius: 12, y: 6)
        .padding(.trailing, Space.l)
        .padding(.bottom, Space.m)
        .accessibilityLabel("Record room")
        .accessibilityHint("Records a meeting in this room with the iPhone's microphone")
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
    let record: CallRecord
    var divided = true

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
                    if !record.unknownSpeakers.isEmpty, record.status == .written {
                        let n = record.unknownSpeakers.count
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
        let speakers = Set(record.utterances.map(\.speakerKey)).count
        if speakers >= 3 { parts.append("\(speakers) speakers") }
        return parts.joined(separator: " · ")
    }
}
