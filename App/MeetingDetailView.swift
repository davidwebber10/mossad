import AppKit
import MossadCore
import SwiftUI

/// One meeting: header, banner, player, and the Summary and Transcript tabs. Clicking a time plays from there.
struct MeetingDetailView: View {
    enum Style { case split, fullPage }
    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript", coach = "Coach" }

    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let style: Style
    @Binding var deleting: CallRecord?
    @StateObject private var player: AudioPlayer
    @AppStorage("detailTab") private var tab = Tab.summary

    init(record: CallRecord, style: Style, deleting: Binding<CallRecord?>) {
        self.record = record
        self.style = style
        _deleting = deleting
        _player = StateObject(wrappedValue: AudioPlayer(callDirectory: Paths.live.callDirectory(record.id)))
    }

    var body: some View {
        let people = MeetingPeople(record: record, ownerName: controller.ownerName, library: controller.library)
        content(people)
            .task(id: controller.seekRequest) {
                guard let seek = controller.seekRequest, seek.callID == record.id else { return }
                controller.seekRequest = nil
                tab = .transcript
                // The audio loads when the view appears; give it a moment, as the cloud fallback does.
                for _ in 0..<20 where !player.isAvailable { try? await Task.sleep(for: .milliseconds(100)) }
                player.play(from: seek.at)
            }
    }

    private func content(_ people: MeetingPeople) -> some View {
        VStack(spacing: 0) {
            if style == .split {
                header(people)
                Divider()
            }
            if record.status == .recording {
                LivePanel(record: record)
            } else {
                // The player, the tabs, and the transcript tools stay put; only the tab's content scrolls.
                VStack(alignment: .leading, spacing: 0) {
                    if style == .fullPage { header(people).padding(.horizontal, -24) }
                    banner
                    PlayerBar(player: player, record: record, people: people, retentionDays: controller.deleteRecordings ? controller.recordingDays : nil)
                        .padding(.top, 12)
                        .task(id: record.cloudKey) {
                            // Local audio loads first; give it a moment before falling back to the archive.
                            try? await Task.sleep(for: .milliseconds(600))
                            if !player.isAvailable, let url = controller.cloudArchive?.playbackURL(for: record) { await player.loadRemote(url) }
                        }
                    tabs
                }
                .padding(.horizontal, style == .fullPage ? 32 : 16)
                .frame(maxWidth: style == .fullPage ? 900 : .infinity)
                .frame(maxWidth: .infinity)
                switch tab {
                case .summary:
                    ScrollView {
                        SummaryTab(record: record, people: people, columns: style == .fullPage ? [1.4, 1] : nil)
                            .padding(.horizontal, style == .fullPage ? 32 : 16)
                            .padding(.bottom, 24)
                            .frame(maxWidth: style == .fullPage ? 900 : .infinity)
                            .frame(maxWidth: .infinity)
                    }
                case .transcript:
                    TranscriptTab(record: record, people: people, player: player, horizontalPadding: style == .fullPage ? 32 : 16,
                                  maxWidth: style == .fullPage ? 900 : .infinity)
                case .coach:
                    ScrollView {
                        CoachTab(record: record, player: player)
                            .padding(.horizontal, style == .fullPage ? 32 : 16)
                            .padding(.bottom, 24)
                            .frame(maxWidth: style == .fullPage ? 900 : .infinity)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func header(_ people: MeetingPeople) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.system(size: style == .fullPage ? 24 : 20, weight: .bold)).kerning(style == .fullPage ? -0.4 : -0.3)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                        if let kind = record.kind {
                            Text(kind).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.field, in: Capsule())
                        }
                    }
                }
                Spacer()
                if style == .split { MeetingActions(record: record, deleting: $deleting) }
            }
            if record.status != .recording, !people.speakers.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(people.speakers, id: \.key) { SpeakerChip(speaker: $0, callID: record.id, editable: record.status == .written) }
                }
            }
            if record.status == .written { TagRow(record: record) }
        }
        .padding(EdgeInsets(top: style == .split ? 18 : 20, leading: 24, bottom: 14, trailing: 24))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let day = dayWord(record.start)
        if record.status == .recording {
            return "\(day) · started \(record.start.formatted(date: .omitted, time: .shortened)) · \(record.platform.displayName)"
        }
        let range = (record.start..<max(record.end, record.start)).formatted(.interval.hour().minute())
        return "\(day) · \(range) · \(record.lengthText) · \(record.platform.displayName)"
    }

    @ViewBuilder
    private var banner: some View {
        if let step = ProcessingStep(status: record.status) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(processingText(step))
                    if let detail = controller.stepDetails[record.id], detail != step.title {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if record.attempts > 0 { Button("Retry now") { controller.retry(record.id) }.controlSize(.small) }
            }
            .bannerStyle(Theme.field)
        } else if record.status == .failed {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warning)
                Text(failureText)
                Spacer()
                Button("Retry now") { controller.retry(record.id) }.controlSize(.small)
            }
            .bannerStyle(Color.orange.opacity(0.16))
        }
    }

    private func processingText(_ step: ProcessingStep) -> String {
        var text = "\(step.title), step \(step.rawValue) of \(ProcessingStep.total)"
        if record.attempts > 0, let next = record.nextAttempt {
            text += ". Attempt \(record.attempts) failed; Mossad retries at \(next.formatted(date: .omitted, time: .shortened))."
        }
        return text
    }

    private var failureText: String {
        let step = record.failedStep.flatMap { ProcessingStep(status: $0) }?.title ?? "Processing"
        return "\(step) failed" + (record.failureReason.map { ": \($0)" } ?? "")
    }

    private var tabs: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// "Today", "Yesterday", "Mon" within the last 6 days, else "Oct 9" (with the year in a past year).
func dayWord(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return cal.isDate(date, equalTo: Date(), toGranularity: .year)
        ? date.formatted(.dateTime.month(.abbreviated).day())
        : date.formatted(.dateTime.month(.abbreviated).day().year())
}

private extension View {
    func bannerStyle(_ background: Color) -> some View {
        font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.top, 12)
    }
}

// MARK: People

/// The speakers of one meeting with their colors and emails, and helpers to match names.
struct MeetingPeople {
    struct Speaker {
        let key: String
        /// Every speaker key with this name: a merged meeting has one per recording.
        var keys: [String]
        let name: String
        let email: String?
        let color: Color
        let isOwner: Bool
        let isUnknown: Bool
    }

    let speakers: [Speaker]
    private let byKey: [String: Speaker]
    private let names: [String: String]
    let attendees: [(name: String, email: String?)]

    init(record: CallRecord, ownerName: String, library: VoiceLibrary) {
        let names = MarkdownWriter.displayNames(record)
        var order: [String] = []
        for u in record.utterances where !order.contains(u.speakerKey) { order.append(u.speakerKey) }
        // The owner is always the first color.
        if let owner = order.firstIndex(where: { names[$0] == ownerName }) { order.insert(order.remove(at: owner), at: 0) }
        let profiles = library.profiles
        // A named person appears once, however many keys they have; each unnamed voice stays its own speaker.
        var list: [Speaker] = []
        var byKey: [String: Int] = [:]
        for key in order {
            let name = names[key] ?? key
            let known = record.speakerNames[key] != nil
            if known, let i = list.firstIndex(where: { !$0.isUnknown && $0.name == name }) {
                list[i].keys.append(key)
                byKey[key] = i
                continue
            }
            byKey[key] = list.count
            list.append(Speaker(key: key, keys: [key], name: name, email: profiles.first { $0.name == name }?.email,
                                color: Theme.speakerPalette[list.count % Theme.speakerPalette.count],
                                isOwner: name == ownerName, isUnknown: !known))
        }
        speakers = list
        self.byKey = byKey.mapValues { list[$0] }
        self.names = names
        attendees = record.attendees.map { a in
            guard a.contains("@") else { return (a, nil) }
            return (library.name(forEmail: a) ?? a, library.name(forEmail: a) == nil ? nil : a)
        }
    }

    func speaker(forKey key: String) -> Speaker? { byKey[key] }
    func name(forKey key: String) -> String { names[key] ?? key }

    func color(forKey key: String) -> Color { byKey[key]?.color ?? Theme.unknown }

    /// An action item owner matched to a speaker: exact name, then first name.
    func color(forOwner owner: String) -> Color? {
        if let s = speakers.first(where: { $0.name.caseInsensitiveCompare(owner) == .orderedSame }) { return s.color }
        // A first-name match only for real names: "Speaker C" must not match "Speaker A".
        guard !owner.hasPrefix("Speaker ") else { return nil }
        let first = firstName(owner)
        return speakers.first { firstName($0.name).caseInsensitiveCompare(first) == .orderedSame }?.color
    }
}

/// A speaker in the header. Click to name the voice or correct its name, with an email.
private struct SpeakerChip: View {
    @EnvironmentObject var controller: AppController
    let speaker: MeetingPeople.Speaker
    let callID: String
    let editable: Bool
    @State private var editing = false
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        Button {
            name = speaker.isUnknown ? "" : speaker.name
            email = speaker.email ?? ""
            editing = true
        } label: { chip }
        .buttonStyle(.plain)
        .disabled(!editable)
        .help(speaker.isUnknown ? "Name this voice" : "Change who this is")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(speaker.isUnknown ? "Who is \(speaker.name)?" : "Who is this voice?").font(.headline)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Email (optional)", text: $email).textFieldStyle(.roundedBorder)
                Text("Mossad saves this voice under the name and recognizes it in later calls.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save") {
                        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
                        controller.applyNames(callID: callID, names: Dictionary(uniqueKeysWithValues: speaker.keys.map { ($0, name) }),
                                              emails: trimmedEmail.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: speaker.keys.map { ($0, trimmedEmail) }))
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Circle().fill(speaker.color).frame(width: 8, height: 8)
            Text(speaker.isOwner ? "\(speaker.name) (you)" : speaker.name).fontWeight(.medium)
            if speaker.isUnknown {
                Text("unknown").foregroundStyle(.secondary)
            } else if !speaker.isOwner, let email = speaker.email {
                Text(email).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 10))
        .background(speaker.isUnknown ? Color.clear : Theme.field, in: Capsule())
        .overlay {
            if speaker.isUnknown { Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(.tertiary) }
        }
    }
}

// MARK: Player

private struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer
    let record: CallRecord
    let people: MeetingPeople
    let retentionDays: Int?

    var body: some View {
        let enabled = player.isAvailable
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    circleButton("gobackward.15", size: 30) { player.skip(-15) }.accessibilityLabel("Back 15 seconds")
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 36, height: 36)
                            .background(Color.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    circleButton("goforward.15", size: 30) { player.skip(15) }.accessibilityLabel("Forward 15 seconds")
                }
                Text(enabled ? clock(player.time) : "0:00").timeLabel()
                Scrubber(player: player, segments: segments, enabled: enabled,
                         bookmarks: record.transcriptMarkers.filter(\.isBookmark).map(\.offset))
                Text(enabled ? clock(player.duration) : clock(record.end.timeIntervalSince(record.start))).timeLabel()
                Picker("Speed", selection: $player.rate) {
                    ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { Text($0 == 1 ? "1×" : "\($0.formatted())×").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            if !enabled, record.status == .written {
                Text(noAudioText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .mossadGlass(cornerRadius: 14)
    }

    private var segments: [(start: Double, end: Double, color: Color)] {
        SpeakerTimeline.segments(record).map { ($0.start, $0.end, people.color(forKey: $0.speakerKey)) }
    }

    private var noAudioText: String {
        if let days = retentionDays, record.end < Date().addingTimeInterval(-Double(days) * 86_400) {
            return "No audio available. The recording was deleted after \(days) days."
        }
        return "No audio available."
    }

    private func circleButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private extension Text {
    func timeLabel() -> some View {
        font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().frame(width: 44)
    }
}

/// The track with the played part and the thumb, and below it the speaker timeline. Seeks on release.
private struct Scrubber: View {
    @ObservedObject var player: AudioPlayer
    let segments: [(start: Double, end: Double, color: Color)]
    let enabled: Bool
    var bookmarks: [Double] = []
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { g in
            let duration = max(player.duration, 1)
            let position = (dragging ?? player.time) / duration
            VStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.field).frame(height: 6)
                    Capsule().fill(Color.primary.opacity(0.85)).frame(width: max(0, g.size.width * position), height: 6)
                    ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, t in
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                            .offset(x: g.size.width * t / duration - 4, y: -9)
                            .help("Bookmarked at \(clock(t))")
                    }
                    if enabled {
                        Circle().fill(.white).frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            .offset(x: g.size.width * position - 7)
                    }
                }
                .frame(height: 14)
                Canvas { context, size in
                    guard !segments.isEmpty, enabled else {
                        context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2.5), with: .color(Theme.unknown))
                        return
                    }
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2.5), with: .color(Theme.field))
                    for s in segments {
                        let x = size.width * s.start / duration
                        let w = max(1, size.width * (s.end - s.start) / duration - 1)
                        context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height), cornerRadius: 2), with: .color(s.color))
                    }
                }
                .frame(height: 5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(max(0, $0.location.x / g.size.width), 1) * duration }
                .onEnded { _ in
                    if let t = dragging { player.seek(to: t) }
                    dragging = nil
                })
        }
        .frame(height: 24)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1)) { Text("Position") }
        }
    }
}

func clock(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: Summary tab

private struct SummaryTab: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let people: MeetingPeople
    /// List mode puts the cards in two weighted columns.
    let columns: [CGFloat]?

    var body: some View {
        if ProcessingStep(status: record.status) != nil {
            Skeleton()
        } else if record.status == .failed, record.summary == nil {
            DetailEmptyState(symbol: "doc.text.magnifyingglass", title: "No transcript yet", message: failedMessage)
        } else if record.status == .written, record.utterances.isEmpty {
            DetailEmptyState(symbol: "waveform.slash", title: "No speech detected", message: "The call was recorded, but nobody spoke.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                summaryCard
                WeightedColumns(weights: columns ?? [1.2, 1], spacing: 12) {
                    actionItemsCard
                    VStack(spacing: 12) {
                        talkTimeCard
                        invitedCard
                        decisionsCard
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private var failedMessage: String {
        if record.failureReason?.contains("key missing") == true {
            return "The audio is saved. Add the AssemblyAI key in Settings, then retry."
        }
        if record.attempts == 0 { return "The recording was interrupted, and a track could not be read. Check the log, then retry." }
        return "Mossad gave up after \(record.attempts) attempts. Check the log, then retry."
    }

    @ViewBuilder
    private var summaryCard: some View {
        if let summary = record.summary {
            Card("Summary") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(SummaryBlock.parse(summary).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let text): inline(text)
                        case .heading(let text): Text(text).font(.system(size: 13, weight: .semibold)).padding(.top, 2)
                        case .bullets(let items):
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•").foregroundStyle(.secondary)
                                        inline(item)
                                    }
                                }
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .textSelection(.enabled)
                if !record.topics.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(record.topics, id: \.self) { topic in TopicRow(topic: topic, inline: inline) }
                    }
                    .padding(.top, 6)
                }
            }
        } else if record.status == .written {
            Card("Summary") {
                HStack {
                    Text(controller.languageModel != nil ? "No summary for this meeting." : "No summary for this meeting. Add the \(controller.aiProvider.displayName) key in Settings.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.languageModel == nil { Button("Retry summary") { controller.retry(record.id) } }
                }
            }
        }
    }

    func inline(_ text: String) -> Text {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(attributed).font(.system(size: 13))
    }

    @ViewBuilder
    private var actionItemsCard: some View {
        // A meeting that only shared information has no action items section at all.
        if record.summary != nil, record.hasOutcomes != false || !record.actionItems.isEmpty {
            Card("Action items") {
                if record.actionItems.isEmpty {
                    Text("None.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(record.actionItems, id: \.self) { item in
                            HStack(alignment: .top, spacing: 9) {
                                Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 15, height: 15).padding(.top, 1)
                                actionText(item).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func actionText(_ item: ActionItem) -> Text {
        guard let owner = item.owner else { return Text(item.task) }
        let color = people.color(forOwner: owner) ?? .secondary
        return Text("\(Text(shortName(owner)).fontWeight(.semibold).foregroundColor(color)) \(item.task)")
    }

    @ViewBuilder
    private var talkTimeCard: some View {
        let talk = TranscriptBlock.talkTime(record)
        if let longest = talk.first?.seconds, longest > 0 {
            Card("Talk time") {
                VStack(spacing: 8) {
                    ForEach(talk, id: \.speaker) { entry in
                        HStack(spacing: 10) {
                            Text(shortName(entry.speaker))
                                .fontWeight(.medium).lineLimit(1).frame(width: 90, alignment: .leading).help(entry.speaker)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.field)
                                    Capsule().fill(color(forSpeaker: entry.speaker)).frame(width: max(4, g.size.width * entry.seconds / longest))
                                }
                            }
                            .frame(height: 8)
                            Text(entry.seconds < 60 ? "<1 min" : "\(Int(entry.seconds / 60)) min")
                                .foregroundStyle(.secondary).monospacedDigit().frame(width: 46, alignment: .trailing)
                        }
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private func color(forSpeaker name: String) -> Color {
        people.speakers.first { $0.name == name }?.color ?? Theme.unknown
    }

    @ViewBuilder
    private var invitedCard: some View {
        if !people.attendees.isEmpty {
            Card("Invited") {
                VStack(spacing: 6) {
                    ForEach(Array(people.attendees.enumerated()), id: \.offset) { _, a in
                        HStack {
                            Text(a.name).fontWeight(.medium).lineLimit(1)
                            Spacer()
                            if let email = a.email { Text(email).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
                .font(.system(size: 12))
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var decisionsCard: some View {
        if !record.decisions.isEmpty {
            Card("Decisions") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(record.decisions.enumerated()), id: \.offset) { _, d in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(.secondary).frame(width: 4, height: 4).padding(.top, 7)
                            Text(d).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// One topic of the summary, collapsed until clicked.
private struct TopicRow: View {
    let topic: SummaryTopic
    let inline: (String) -> Text
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary).frame(width: 12)
                    Text(topic.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(SummaryBlock.parse(topic.summary).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let text), .heading(let text): inline(text)
                        case .bullets(let items):
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    inline(item)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 18)
                .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary)
            content().font(.system(size: 13)).lineSpacing(3)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

private struct Skeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            card(header: 60, lines: [0.96, 0.88, 0.92, 0.6])
            HStack(alignment: .top, spacing: 10) {
                card(header: 80, lines: [0.9, 0.8, 0.7])
                card(header: 70, lines: [0.85, 0.75, 0.6])
            }
        }
        .padding(.top, 6)
        .phaseAnimator(reduceMotion ? [0.7] : [0.5, 1.0]) { view, phase in
            view.opacity(phase)
        } animation: { _ in .easeInOut(duration: 0.8) }
    }

    private func card(header: CGFloat, lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(Theme.field).frame(width: header, height: 9)
            GeometryReader { g in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                        RoundedRectangle(cornerRadius: 3).fill(Theme.field).frame(width: g.size.width * w, height: 10)
                    }
                }
            }
            .frame(height: CGFloat(lines.count) * 18)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DetailEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineSpacing(3).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: Live

private struct LivePanel: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                StatusDot(color: controller.isPaused ? Theme.unknown : Theme.recording, size: 9, pulsing: !controller.isPaused)
                Text(controller.isPaused ? "Paused" : controller.isMuted ? "Current call · you are muted" : "Current call")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(controller.isPaused ? Color.secondary : Theme.recording)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background((controller.isPaused ? Color.secondary : Theme.recording).opacity(0.12), in: Capsule())
            TimelineView(.periodic(from: record.start, by: 1)) { context in
                Text(elapsed(record.start, context.date)).font(.system(size: 40, weight: .semibold)).kerning(-1).monospacedDigit()
            }
            if controller.isMuted, !controller.isPaused {
                MutedBanner(platform: record.platform).frame(maxWidth: 620)
            }
            LiveWaveform(bars: 72, rowHeight: 40)
                .padding(16)
                .frame(maxWidth: 620)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            CallControls()
            if controller.liveTranscriptEnabled {
                LiveTranscriptView(model: controller.live).frame(maxWidth: 620)
            } else {
                Text("Recording your microphone and the call audio. The transcript and summary appear after the call ends.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The streaming transcript while the call runs. The note uses the full transcription after the call.
private struct LiveTranscriptView: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: LiveTranscriptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LIVE TRANSCRIPT").font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.transcript.lines.isEmpty {
                            Text(controller.isPaused ? "Paused." : "Listening…").foregroundStyle(.secondary)
                        }
                        ForEach(model.transcript.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(line.source == .me ? "You" : "Call")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.speakerPalette[line.source == .me ? 0 : 1])
                                    .frame(width: 34, alignment: .leading)
                                Text(line.text)
                                    .foregroundStyle(line.isFinal ? Color.primary : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 13))
                            .id(line.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(12)
                }
                // No animation: an animated scroll per update kept the scroll view busy at display rate.
                .onChange(of: model.transcript.lines.count) { _, _ in
                    if let last = model.transcript.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(minHeight: 140, maxHeight: 260)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: Layout

/// Side-by-side columns that each get a fixed share of the width, whatever their content.
struct WeightedColumns: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 12

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let w = Array(weights.prefix(count)) + Array(repeating: 1, count: max(0, count - weights.count))
        let sum = w.reduce(0, +)
        let available = total - spacing * CGFloat(max(0, count - 1))
        return w.map { available * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let ws = widths(width, count: subviews.count)
        let height = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, w) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: nil))
            x += w + spacing
        }
    }
}

/// Wraps its children onto new lines, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, height: CGFloat = 0, y: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > width {
                rows.append((current, y, x - spacing, height))
                y += height + spacing
                current = []; x = 0; height = 0
            }
            current.append(i)
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !current.isEmpty { rows.append((current, y, x - spacing, height)) }
        return rows
    }
}
