import AppKit
import MossadCore
import SwiftUI

/// The Meetings pane in one of three modes: Split (list and detail), List (full-pane rows), or Calendar.
struct MeetingsView: View {
    enum Mode: String, CaseIterable { case split = "Split", calendar = "Calendar" }

    @EnvironmentObject var controller: AppController
    @AppStorage("meetingsMode") private var mode = Mode.split
    @State private var deleting: CallRecord?
    @State private var merging: CallRecord?
    /// The meeting opened full-pane from List or Calendar mode.
    @State private var opened: String?
    @State private var openedFrom = ""
    @StateObject private var calendarState = CalendarState()

    private var results: [CallRecord] {
        controller.meetings.filter { MeetingSearch.matches($0, controller.meetingQuery) }
    }

    var body: some View {
        Group {
            if controller.meetings.isEmpty {
                EmptyMeetings()
            } else {
                switch mode {
                case .split: splitBody
                case .calendar:
                    if let id = opened, let r = controller.meetings.first(where: { $0.id == id }) {
                        fullPaneDetail(r)
                    } else {
                        CalendarPane(state: calendarState, records: controller.meetings, matches: Set(results.map(\.id)), deleting: $deleting) { r, period in
                            open(r, from: period)
                        }
                    }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Meetings")
        .searchable(text: $controller.meetingQuery, placement: .toolbar, prompt: "Search titles and transcripts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if mode == .calendar, opened == nil, !controller.meetings.isEmpty { CalendarControls(state: calendarState) }
                ModePicker(mode: $mode, labeled: false)
                AskButton()
            }
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete meeting", role: .destructive) {
                if let id = deleting?.id {
                    if opened == id { opened = nil }
                    controller.deleteMeeting(id)
                }
            }
        } message: {
            Text("Mossad deletes the note, the transcript, and the audio. Voices it learned from this call stay.")
        }
        .sheet(item: $merging) { r in MergeSheet(record: r) }
        .onReceive(NotificationCenter.default.publisher(for: .mergeMeeting)) { note in
            merging = controller.meetings.first { $0.id == note.object as? String }
        }
        .sheet(item: Binding(get: { controller.namingCallID.flatMap { id in controller.meetings.first { $0.id == id } } },
                             set: { controller.namingCallID = $0?.id })) { r in
            VoiceNamingView(record: r)
        }
        .onAppear {
            if controller.selectedMeetingID == nil { controller.selectedMeetingID = controller.meetings.first?.id }
        }
        .onChange(of: mode) { _, _ in opened = nil }
    }

    // MARK: Split

    private var splitBody: some View {
        HStack(spacing: 0) {
            MeetingList(groups: MeetingGroups.group(results), selection: $controller.selectedMeetingID, deleting: $deleting)
                .frame(width: 330)
            Divider()
            Group {
                if let id = controller.selectedMeetingID, let m = controller.upcoming.first(where: { $0.id == id }) {
                    UpcomingDetailView(meeting: m)
                } else if let id = controller.selectedMeetingID, let r = controller.meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(record: r, style: .split, deleting: $deleting)
                        .id(r.id)
                } else {
                    ContentUnavailableView("Select a meeting", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: List and Calendar

    private func open(_ r: CallRecord, from crumb: String) {
        controller.selectedMeetingID = r.id
        openedFrom = crumb
        opened = r.id
    }

    private func fullPaneDetail(_ r: CallRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { opened = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .keyboardShortcut("[", modifiers: .command)
                .keyboardShortcut(.escape, modifiers: [])
                Button("Meetings") { opened = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                Button(openedFrom) { opened = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(r.title).fontWeight(.medium).lineLimit(1)
                Spacer()
                MeetingActions(record: r, deleting: $deleting)
            }
            .font(.system(size: 13))
            .padding(EdgeInsets(top: 14, leading: 24, bottom: 10, trailing: 24))
            Divider()
            MeetingDetailView(record: r, style: .fullPage, deleting: $deleting).id(r.id)
        }
    }
}

extension CallRecord: @retroactive Identifiable {
    /// A call that is still recording or processing cannot be deleted; Skip this call covers the first.
    var canDelete: Bool { status == .written || status == .failed }

    var badge: StatusBadge.Kind? {
        switch status {
        case .recording: .recording
        case .failed: .failed
        case .written: unknownSpeakers.isEmpty ? nil : .needsNames
        default: .processing
        }
    }

    /// The call's own meeting link matched a calendar invite, so the invite's people are this call's people.
    var hasInviteLink: Bool { meetingID != nil && calendarTitle != nil }

    /// "59 min", at least "1 min".
    var lengthText: String { "\(max(1, Int(end.timeIntervalSince(start) / 60))) min" }
}

/// "11:31 AM" for today and yesterday, "Mon 9:00 AM" this week, "Oct 9" (with the year when not this year) earlier.
func whenText(_ date: Date, kind: MeetingGroups.Kind) -> String {
    switch kind {
    case .today, .yesterday: return date.formatted(date: .omitted, time: .shortened)
    case .thisWeek: return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    case .earlier:
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// The length, or the live elapsed time of a call being recorded.
struct LengthText: View {
    let record: CallRecord

    var body: some View {
        if record.status == .recording {
            TimelineView(.periodic(from: record.start, by: 1)) { context in
                Text(elapsed(record.start, context.date)).foregroundStyle(Theme.recording)
            }
        } else {
            Text(record.lengthText)
        }
    }
}

struct ModePicker: View {
    @Binding var mode: MeetingsView.Mode
    let labeled: Bool

    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(MeetingsView.Mode.allCases, id: \.self) { m in
                if labeled {
                    Label(m.rawValue, systemImage: symbol(m)).tag(m)
                } else {
                    Image(systemName: symbol(m)).help(m.rawValue).tag(m)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(labeled ? .regular : .small)
        .fixedSize()
    }

    private func symbol(_ m: MeetingsView.Mode) -> String {
        switch m {
        case .split: "sidebar.left"
        case .calendar: "calendar"
        }
    }
}

/// Split mode's grouped list.
private struct MeetingList: View {
    @EnvironmentObject var controller: AppController
    let groups: [MeetingGroups.Group]
    @Binding var selection: String?
    @Binding var deleting: CallRecord?

    var body: some View {
        let live = groups.flatMap(\.records).filter { $0.status == .recording }
        List(selection: $selection) {
            if !live.isEmpty {
                Section {
                    ForEach(live, id: \.id) { r in CurrentCallRow(record: r).tag(r.id) }
                } header: {
                    Text("Now").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.recording)
                }
            }
            if !controller.upcoming.isEmpty, controller.meetingQuery.isEmpty {
                Section {
                    ForEach(controller.upcoming.prefix(UpcomingRow.shown)) { m in UpcomingRow(meeting: m).tag(m.id) }
                } header: {
                    Text("Upcoming").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            ForEach(groups, id: \.kind) { group in
                Section {
                    ForEach(group.records.filter { $0.status != .recording }, id: \.id) { r in
                        MeetingRow(record: r, kind: group.kind)
                            .tag(r.id)
                            .contextMenu { MeetingMenuItems(record: r, deleting: $deleting) }
                    }
                } header: {
                    Text(group.kind.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            if let id = selection, let r = controller.meetings.first(where: { $0.id == id }), r.canDelete { deleting = r }
        }
    }
}

/// The call being recorded: tinted, with a pulsing dot, the running time, and a small live waveform.
private struct CurrentCallRow: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(color: controller.isPaused ? Theme.unknown : Theme.recording, size: 8, pulsing: !controller.isPaused)
                Text(record.calendarTitle ?? "Current call").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                LengthText(record: record).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            HStack(spacing: 8) {
                if controller.isMuted, !controller.isPaused {
                    Label("Muted", systemImage: "mic.slash.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warning)
                } else {
                    Text(controller.isPaused ? "Paused" : "\(record.platform.displayName) · recording")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                LiveWaveform(bars: 28, rowHeight: 8, showLabels: false, framesPerSecond: 4).frame(maxWidth: 120)
            }
            .padding(.leading, 16)
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
        .background(Theme.recording.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct MeetingRow: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let kind: MeetingGroups.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                PlatformSquare(platform: record.platform)
                Text(record.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                LengthText(record: record).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Text(whenText(record.start, kind: kind)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if let badge = record.badge {
                    StatusBadge(kind: badge, text: badge == .processing ? controller.progressText(record) : nil)
                }
            }
            .padding(.leading, 20)
        }
        .padding(.vertical, 4)
    }
}

/// The right-click menu and the More menu share these items.
struct MeetingMenuItems: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    @Binding var deleting: CallRecord?

    var body: some View {
        if record.status == .recording {
            Button("Skip and delete this call", systemImage: "xmark.bin", role: .destructive) { controller.skipCurrentCall() }
        } else {
            Button("Open note", systemImage: "doc.richtext") {
                if let path = record.markdownPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            .disabled(record.markdownPath == nil)
            Button("Show note in Finder", systemImage: "folder") {
                if let path = record.markdownPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            .disabled(record.markdownPath == nil)
            Button("Show audio in Finder", systemImage: "folder") { NSWorkspace.shared.open(controller.paths.callDirectory(record.id)) }
            if record.status == .written, record.unknownSpeakers.isEmpty, !record.skippedSpeakers.isEmpty {
                Button("Name skipped voices…", systemImage: "person.wave.2") { controller.namingCallID = record.id }
            }
            Button("Regenerate summary", systemImage: "arrow.clockwise") { controller.regenerateSummary(record.id) }
                .disabled(record.status != .written || record.utterances.isEmpty)
            Button("Merge with…", systemImage: "arrow.triangle.merge") {
                NotificationCenter.default.post(name: .mergeMeeting, object: record.id)
            }
            .disabled(!record.canDelete)
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = record }.disabled(!record.canDelete)
        }
    }
}

/// "Name voices" and the More button, in a detail header.
struct MeetingActions: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    @Binding var deleting: CallRecord?

    var body: some View {
        HStack(spacing: 8) {
            if record.status == .written, !record.unknownSpeakers.isEmpty {
                Button { controller.namingCallID = record.id } label: {
                    Label("Name voices", systemImage: "person.wave.2")
                }
                .buttonStyle(.borderedProminent)
            }
            Menu {
                MeetingMenuItems(record: record, deleting: $deleting)
            } label: {
                Image(systemName: "ellipsis").accessibilityLabel("More")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .fixedSize()
        }
    }
}

private struct EmptyMeetings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("No meetings yet").font(.system(size: 15, weight: .semibold))
            Text("Mossad records Zoom, Google Meet, and Microsoft Teams calls on its own. Join a call and it appears here.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name {
    /// Opens the merge sheet for a meeting, from any menu that lists the meeting.
    static let mergeMeeting = Notification.Name("mergeMeeting")
}

/// Pick the meetings to join with this one. Mossad joins the audio and transcripts into the earliest one,
/// keeps the speaker names, and writes one new summary and note.
private struct MergeSheet: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let record: CallRecord
    @State private var chosen: Set<String> = []

    /// Finished meetings, the ones closest in time first.
    private var candidates: [CallRecord] {
        controller.meetings.filter { $0.id != record.id && $0.canDelete }
            .sorted { abs($0.start.timeIntervalSince(record.start)) < abs($1.start.timeIntervalSince(record.start)) }
            .prefix(12).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge with “\(record.title)”").font(.system(size: 16, weight: .bold))
            Text("Mossad joins the audio and the transcripts into one meeting, keeps the speaker names, and writes a new summary and note. The other meetings are removed.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(candidates, id: \.id) { r in
                Toggle(isOn: Binding(get: { chosen.contains(r.id) }, set: { if $0 { chosen.insert(r.id) } else { chosen.remove(r.id) } })) {
                    HStack(spacing: 8) {
                        PlatformSquare(platform: r.platform)
                        Text(r.title).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text("\(dayWord(r.start)) \(r.start.formatted(date: .omitted, time: .shortened)) · \(r.lengthText)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(chosen.count > 1 ? "Merge \(chosen.count + 1) meetings" : "Merge") {
                    controller.mergeMeetings([record.id] + Array(chosen))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
