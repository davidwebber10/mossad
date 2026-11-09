import AppKit
import MossadCore
import SwiftUI

/// The Meetings pane in one of two modes: List (the list and the open meeting) or Calendar.
struct MeetingsView: View {
    enum Mode: String, CaseIterable { case split = "Split", calendar = "Calendar" }

    @EnvironmentObject var controller: AppController
    @AppStorage("meetingsMode") private var savedMode = Mode.split
    /// A preview's mode, kept out of the owner's saved choice.
    @State private var previewMode: Mode?
    private var mode: Mode { previewMode ?? savedMode }
    @State private var deleting: CallRecord?
    @State private var merging: CallRecord?
    /// The meeting opened full-pane from Calendar mode.
    @State private var opened: String?
    /// The upcoming invite opened full-pane from Calendar mode.
    @State private var openedUpcoming: UpcomingMeeting?
    @State private var openedFrom = ""
    @StateObject private var calendarState = CalendarState()

    private var results: [CallRecord] {
        controller.meetings.filter { MeetingSearch.matches($0, controller.meetingQuery) }
    }

    private var selected: CallRecord? {
        controller.selectedMeetingID.flatMap { id in controller.meetings.first { $0.id == id } }
    }

    var body: some View {
        Group {
            if controller.meetings.isEmpty {
                DetailColumn { toolbar } content: { EmptyMeetings() }
            } else {
                switch mode {
                case .split: splitBody
                case .calendar:
                    DetailColumn { toolbar } content: {
                        if let id = opened, let r = controller.meetings.first(where: { $0.id == id }) {
                            fullPaneDetail(r)
                        } else if let m = openedUpcoming {
                            VStack(spacing: 0) {
                                backBar(title: m.title) { openedUpcoming = nil }
                                UpcomingDetailView(meeting: m)
                            }
                        } else {
                            // Invites show only without a search: a search narrows what was recorded.
                            CalendarPane(state: calendarState, records: controller.meetings, matches: Set(results.map(\.id)), deleting: $deleting,
                                         upcoming: controller.meetingQuery.isEmpty ? controller.calendarUpcoming : [],
                                         openUpcoming: { m in openedFrom = calendarState.title; openedUpcoming = m }) { r, period in
                                open(r, from: period)
                            }
                        }
                    }
                }
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
        .sheet(item: Binding(get: { controller.sharingCallID.flatMap { id in controller.meetings.first { $0.id == id } } },
                             set: { controller.sharingCallID = $0?.id })) { r in
            ShareSheet(record: r)
        }
        .sheet(item: Binding(get: { controller.transcribingAgainCallID.flatMap { id in controller.meetings.first { $0.id == id } } },
                             set: { controller.transcribingAgainCallID = $0?.id })) { r in
            TranscribeAgainSheet(record: r)
        }
        .onAppear {
            if controller.selectedMeetingID == nil { controller.selectedMeetingID = controller.meetings.first?.id }
            let preview = CommandLine.arguments.contains("--ui-preview")
            // Development hook for screenshots: MOSSAD_MEETING=<call id> opens that meeting.
            if preview, let id = ProcessInfo.processInfo.environment["MOSSAD_MEETING"], controller.meetings.contains(where: { $0.id == id }) {
                controller.selectedMeetingID = id
            }
            // Development hook for screenshots: MOSSAD_OPEN_LATER=<call id> opens that meeting 3 s after the list
            // shows, as a notification or a chat link would.
            if preview, let id = ProcessInfo.processInfo.environment["MOSSAD_OPEN_LATER"] {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    controller.openMeeting(id)
                }
            }
            // Development hook for screenshots: MOSSAD_TRANSCRIBE_AGAIN opens the sheet for the first meeting.
            if ProcessInfo.processInfo.environment["MOSSAD_TRANSCRIBE_AGAIN"] != nil, preview {
                controller.transcribingAgainCallID = controller.meetings.first?.id
            }
            // Development hooks for screenshots: MOSSAD_MERGE and MOSSAD_SHARE open those sheets for the selected
            // meeting (MOSSAD_MEETING picks it).
            if preview, ProcessInfo.processInfo.environment["MOSSAD_MERGE"] != nil {
                merging = controller.meetings.first { $0.id == controller.selectedMeetingID }
            }
            if preview, ProcessInfo.processInfo.environment["MOSSAD_SHARE"] != nil {
                controller.sharingCallID = controller.selectedMeetingID
            }
            // Development hook for screenshots: MOSSAD_MEETINGS_MODE=split|calendar picks the mode.
            if preview, let m = ProcessInfo.processInfo.environment["MOSSAD_MEETINGS_MODE"].flatMap({ Mode(rawValue: $0.capitalized) }) {
                previewMode = m
            }
            // Development hook for screenshots: MOSSAD_CALENDAR_DATE=2026-10-22 opens the calendar on that week.
            if preview, let d = ProcessInfo.processInfo.environment["MOSSAD_CALENDAR_DATE"].flatMap({ try? Date($0, strategy: .iso8601.year().month().day()) }) {
                calendarState.anchor = d.addingTimeInterval(12 * 3600)
            }
        }
        .onChange(of: mode) { _, _ in opened = nil; openedUpcoming = nil }
    }

    // MARK: List

    private var splitBody: some View {
        HStack(spacing: 0) {
            ListColumn("Meetings", widthKey: "meetings") {
                CoachMoment(compact: true).padding(.horizontal, 10).padding(.top, Space.s)
                MeetingList(days: MeetingGroups.byDay(results.filter { $0.status != .recording }),
                            live: results.filter { $0.status == .recording },
                            selection: $controller.selectedMeetingID, deleting: $deleting)
            }
            DetailColumn { toolbar } content: {
                if let id = controller.selectedMeetingID, let m = controller.upcoming.first(where: { $0.id == id }) {
                    UpcomingDetailView(meeting: m)
                } else if let r = selected {
                    MeetingDetailView(record: r, style: .split, deleting: $deleting)
                        .id(r.id)
                } else {
                    ContentUnavailableView("Select a meeting", systemImage: "text.rectangle")
                }
            }
        }
    }

    /// List or calendar, the search, then export and more for the open meeting: three glass groups.
    private var toolbar: some View {
        PageToolbar {
            if mode == .calendar, opened == nil, openedUpcoming == nil, !controller.meetings.isEmpty { CalendarControls(state: calendarState) }
        } trailing: {
            ModePicker(mode: Binding(get: { mode }, set: { previewMode = nil; savedMode = $0 }))
            ToolbarSearchField(prompt: "Search titles and transcripts", query: $controller.meetingQuery)
            if mode == .split || opened != nil {
                let record = opened.flatMap { id in controller.meetings.first { $0.id == id } } ?? selected
                ToolbarCapsule {
                    ExportMenu(record: record)
                    ToolbarMenuButton(icon: .more, label: "More", help: "More for this meeting") {
                        if let record { MeetingMenuItems(record: record, deleting: $deleting) }
                    }
                    .disabled(record == nil)
                }
            }
        }
    }

    // MARK: Calendar

    private func open(_ r: CallRecord, from crumb: String) {
        controller.selectedMeetingID = r.id
        openedFrom = crumb
        opened = r.id
    }

    private func fullPaneDetail(_ r: CallRecord) -> some View {
        VStack(spacing: 0) {
            backBar(title: r.title) { opened = nil }
            MeetingDetailView(record: r, style: .fullPage, deleting: $deleting).id(r.id)
        }
    }

    /// Back, then "Meetings › <period> › <title>".
    private func backBar(title: String, back: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { back() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .keyboardShortcut("[", modifiers: .command)
                .keyboardShortcut(.escape, modifiers: [])
                Button("Meetings") { back() }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.tertiaryMark)
                Button(openedFrom) { back() }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.tertiaryMark)
                Text(title).fontWeight(.medium).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(EdgeInsets(top: 14, leading: 24, bottom: 10, trailing: 24))
            Hairline()
        }
    }
}

/// Export for the open meeting: a private link, or the note itself.
private struct ExportMenu: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord?

    var body: some View {
        Menu {
            if let record {
                Button("Share…", systemImage: "link") { controller.sharingCallID = record.id }
                    .disabled(record.status != .written)
                Button("Open note", systemImage: "doc.richtext") {
                    if let path = record.markdownPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
                .disabled(record.markdownPath == nil)
                Button("Show note in Finder", systemImage: "folder") {
                    if let path = record.markdownPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                .disabled(record.markdownPath == nil)
            }
        } label: {
            IconImage(.download, size: 15)
                .frame(width: Chrome.iconCell.width, height: Chrome.iconCell.height)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(ChromeCellStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Export")
        .disabled(record == nil || record?.status == .recording)
        .help("Share or open this meeting's note")
    }
}

extension CallRecord: @retroactive Identifiable {
    /// A call that is still recording or processing cannot be deleted; Skip this call covers the first.
    var canDelete: Bool { status == .written || status == .failed }

    var badge: MeetingBadge? {
        switch status {
        case .recording: .recording
        case .failed: .failed
        case .written: unknownSpeakers.isEmpty ? nil : .needsNames
        default: .processing
        }
    }

    /// The call's own meeting link matched a calendar invite, so the invite's people are this call's people.
    var hasInviteLink: Bool { meetingID != nil && calendarTitle != nil }

    var lengthText: String { durationLabel(end.timeIntervalSince(start)) }
}

/// "59 min", "1 h 45 min", at least "1 min".
func durationLabel(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int(seconds / 60))
    return minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
}

extension Platform {
    /// "Meet", "Teams": the list's short name; the dot carries the color.
    var shortName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Meet"
        case .teams: "Teams"
        case .inPerson: "In person"
        }
    }
}

/// The length, or the live elapsed time of a call being recorded.
struct LengthText: View {
    let record: CallRecord

    var body: some View {
        if record.status == .recording {
            TimelineView(.periodic(from: record.start, by: 1)) { context in
                Text(elapsed(record.start, context.date)).foregroundStyle(Palette.recording)
            }
        } else {
            Text(record.lengthText)
        }
    }
}

/// List and Calendar, as one glass toggle in the toolbar.
struct ModePicker: View {
    @Binding var mode: MeetingsView.Mode

    var body: some View {
        ToolbarSegmented(selection: $mode, options: [
            .init(value: .split, label: "List", icon: .viewList),
            .init(value: .calendar, label: "Calendar", icon: .viewCalendar),
        ], accessibilityLabel: "View")
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
            Button("Share…", systemImage: "square.and.arrow.up") { controller.sharingCallID = record.id }
                .disabled(record.status != .written)
            Button("Regenerate summary", systemImage: "arrow.clockwise") { controller.regenerateSummary(record.id) }
                .disabled(record.status != .written || record.utterances.isEmpty)
            let dir = controller.paths.callDirectory(record.id)
            let finished = record.status == .written || record.status == .failed
            Button("Transcribe again…", systemImage: "waveform.badge.magnifyingglass") { controller.transcribingAgainCallID = record.id }
                .disabled(!finished || !Pipeline.canTranscribeAgain(dir))
            if finished, Pipeline.hasPreviousTranscript(dir) {
                Button("Restore previous transcript", systemImage: "arrow.uturn.backward") { controller.restorePreviousTranscript(record.id) }
            }
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

    /// The meeting everything joins into: the earliest of the ones picked.
    private var earliest: String {
        ([record] + controller.meetings.filter { chosen.contains($0.id) }).min { $0.start < $1.start }?.id ?? record.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .merge, title: "Merge with “\(record.title)”",
                        subtitle: "Pick the parts of one meeting. Mossad joins them into the earliest one.")
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        row(record, locked: true)
                        ForEach(candidates, id: \.id) { r in row(r, locked: false) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 330)
                if !chosen.isEmpty {
                    Text("Audio, transcripts, and speaker names are joined, and Mossad writes one new summary and note. \(chosen.count > 1 ? "The other meetings are" : "The other meeting is") removed from the list.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 22, bottom: 14, trailing: 22))
            SheetFooter {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sheetSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Merge" : "Merge \(chosen.count + 1) meetings") {
                    controller.mergeMeetings([record.id] + Array(chosen))
                    dismiss()
                }
                .buttonStyle(.sheetPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .mossadSheet(width: 560)
    }

    /// The meeting the sheet opened from is always part of the merge, so its box stays checked and is not a
    /// control.
    @ViewBuilder
    private func row(_ r: CallRecord, locked: Bool) -> some View {
        if locked {
            HStack(spacing: 12) {
                SheetCheckbox(isOn: true)
                rowText(r)
            }
            .padding(.vertical, 10)
            .hairline(.bottom)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Always part of the merge")
        } else {
            Toggle(isOn: Binding(get: { chosen.contains(r.id) },
                                 set: { if $0 { chosen.insert(r.id) } else { chosen.remove(r.id) } })) {
                rowText(r)
            }
            .toggleStyle(SheetCheckboxStyle())
            .padding(.vertical, 10)
            .hairline(.bottom)
        }
    }

    private func rowText(_ r: CallRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(r.title).fontWeight(.medium).lineLimit(1)
                if r.id == earliest, !chosen.isEmpty {
                    Text("Joins into this one")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 8).frame(height: 18)
                        .background(Palette.fill, in: Capsule())
                }
            }
            Text("\(dayWord(r.start)), \((r.start..<max(r.end, r.start)).formatted(.interval.hour().minute())) · \(r.lengthText)")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
