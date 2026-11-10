import AppKit
import MossadCore
import SwiftUI

/// One meeting: the header band with the lanes player, then the Summary, Transcript, Screens, Coach, Analytics, and
/// Chat tabs, which all share the player. Clicking a time plays from there.
struct MeetingDetailView: View {
    enum Style { case split, fullPage }
    enum Tab: String, CaseIterable {
        case summary = "Summary", transcript = "Transcript", screens = "Screens", coach = "Coach", analytics = "Analytics", chat = "Chat"
    }

    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let style: Style
    @Binding var deleting: CallRecord?
    @StateObject private var player: AudioPlayer
    @AppStorage("detailTab") private var savedTab = Tab.summary
    /// A preview's tab, kept out of the owner's saved choice.
    @State private var previewTab: Tab?
    @State private var highlight: TimeInterval?
    @State private var cache = DetailCache()

    /// The frame open in the Screens tab; nil shows its grid.
    @State private var openScreen: String?

    /// The Screens tab exists only for a meeting that has screens.
    private var tab: Tab {
        let t = previewTab ?? savedTab
        return t == .screens && !record.hasScreens ? .summary : t
    }
    private var tabs: [Tab] { Tab.allCases.filter { $0 != .screens || record.hasScreens } }
    private var tabBinding: Binding<Tab> { Binding(get: { tab }, set: { previewTab = nil; savedTab = $0 }) }

    init(record: CallRecord, style: Style, deleting: Binding<CallRecord?>) {
        self.record = record
        self.style = style
        _deleting = deleting
        _player = StateObject(wrappedValue: AudioPlayer(callDirectory: Paths.live.callDirectory(record.id)))
    }

    /// Names and emails of the library, so a rename or a new email in People reaches the open meeting.
    private var profilesKey: Int {
        var h = Hasher()
        for p in controller.library.profiles { h.combine(p.name); h.combine(p.email) }
        return h.finalize()
    }

    /// Changes only when the words, the names, or the people library do, not on each tick of the player.
    private var cacheKey: String {
        "\(record.utterances.count)|\(controller.ownerName)|\(profilesKey)|"
            + record.speakerNames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            + "|" + record.attendees.joined(separator: ",")
            + "|" + record.actionItems.compactMap(\.owner).joined(separator: ",") + "|\(record.screens?.count ?? 0)"
    }

    var body: some View {
        let key = cacheKey
        let (lanes, people) = cache.get(key) {
            (SpeakerLanes.make(record, names: MarkdownWriter.displayNames(record), ownerName: controller.ownerName),
             MeetingPeople(record: record, ownerName: controller.ownerName, library: controller.library, stamp: key))
        }
        // The window's height, not the content's: the detail takes what it is given and the lanes fit it.
        GeometryReader { g in
            content(people, lanes: lanes, maxLanes: Self.maxLanes(height: g.size.height))
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
                .clipped()
        }
            .background(Palette.window)
            .environment(\.personLinks, people.links)
            .environment(\.personOpener, controller.personOpener)
            .environment(\.openScreen) { screen in
                openScreen = screen.file
                tabBinding.wrappedValue = .screens
            }
            .task(id: controller.seekRequest) {
                guard let seek = controller.seekRequest, seek.callID == record.id else { return }
                controller.seekRequest = nil
                tabBinding.wrappedValue = .transcript
                guard seek.play else { if seek.mark { highlight = seek.at }; return }
                await play(from: seek.at)
            }
            .task(id: record.cloudKey) {
                // Local audio loads first; give it a moment before falling back to the archive.
                try? await Task.sleep(for: .milliseconds(600))
                if !player.isAvailable, let url = controller.cloudArchive?.playbackURL(for: record) { await player.loadRemote(url) }
            }
            .onAppear(perform: applyPreviewHooks)
    }

    private func play(from at: TimeInterval) async {
        // The audio loads when the view appears; give it a moment, as the cloud fallback does.
        for _ in 0..<20 where !player.isAvailable { try? await Task.sleep(for: .milliseconds(100)) }
        player.play(from: at)
    }

    @ViewBuilder
    private func content(_ people: MeetingPeople, lanes: [SpeakerLanes.Lane], maxLanes: Int) -> some View {
        VStack(spacing: 0) {
            // A short window keeps room for the tabs' content: up to 12 lanes, fewer as the window gets short. The rest scroll.
            MeetingHeader(record: record, people: people, lanes: lanes, player: player,
                          retentionDays: controller.deleteRecordings ? controller.recordingDays : nil,
                          maxLanes: maxLanes)
                .overlay(alignment: .bottom) {
                    if record.status != .recording, !processingFirstTime { DetailTabs(tab: tabBinding, tabs: tabs).offset(y: Self.underTabs) }
                }
                .zIndex(1)
            if record.status == .recording {
                LiveTranscriptPanel(record: record)
            } else if processingFirstTime, let step = ProcessingStep(status: record.status) {
                // Until the first note is written the tabs have nothing to show, so the progress takes their place.
                ScrollView {
                    ProcessingCard(record: record, step: step).detailColumn(top: 28)
                }
            } else {
                tabContent(people)
            }
        }
    }

    /// Processing with no summary yet. A meeting transcribed again keeps its tabs, with the progress in the band.
    private var processingFirstTime: Bool { ProcessingStep(status: record.status) != nil && record.summary == nil }

    /// Room under the tabs that sit on the band's edge.
    private static let underTabs = Detail.underTabs

    /// The band without lanes (meta, title, ruler, transport, and padding) is about this tall.
    private static let bandWithoutLanes: CGFloat = 260

    /// As many lanes as leave the tab's content its reserve, from 4 to 12.
    static func maxLanes(height: CGFloat) -> Int {
        let fit = (height - bandWithoutLanes - Detail.lanesReserve) / (Detail.laneRow + Detail.laneGap)
        return min(12, max(4, Int(fit)))
    }

    @ViewBuilder
    private func tabContent(_ people: MeetingPeople) -> some View {
        switch tab {
        case .summary:
            ScrollView {
                SummaryTab(record: record, people: people, player: player, delete: record.canDelete ? { deleting = record } : nil)
                    .detailColumn(top: Self.underTabs + 32)
            }
        case .transcript:
            TranscriptTab(record: record, people: people, player: player, top: Self.underTabs + 28, highlight: highlight)
        case .screens:
            ScreensTab(record: record, player: player, top: Self.underTabs + 28, selected: $openScreen)
                .equatable()
        case .coach:
            ScrollView {
                CoachTab(record: record, people: people, player: player)
                    .detailColumn(top: Self.underTabs + 32)
            }
        case .analytics:
            // Equatable, so the playback's ticks do not draw it again; its numbers are made off the main thread.
            MeetingAnalyticsTab(record: record, people: people, player: player,
                                top: Self.underTabs + 32, openCoach: { tabBinding.wrappedValue = .coach })
                .equatable()
        case .chat:
            MeetingChatView(record: record, top: Self.underTabs + 14) { at in Task { await play(from: at) } }
        }
    }

    private func applyPreviewHooks() {
        guard CommandLine.arguments.contains("--ui-preview") else { return }
        let env = ProcessInfo.processInfo.environment
        // Development hook for screenshots: MOSSAD_TAB=summary|transcript|screens|coach|analytics|chat picks the tab.
        if let t = env["MOSSAD_TAB"].flatMap({ Tab(rawValue: $0.capitalized) }) { previewTab = t }
        // Development hook for screenshots: MOSSAD_SEEK=<seconds> puts the playhead there, without playing.
        if let at = env["MOSSAD_SEEK"].flatMap(TimeInterval.init) {
            Task {
                for _ in 0..<30 where !player.isAvailable { try? await Task.sleep(for: .milliseconds(100)) }
                player.seek(to: at)
            }
        }
    }
}

/// The lanes and people of the open meeting, kept between body passes. A class, so filling it during a body pass
/// does not count as a state change.
final class DetailCache {
    private var key: String?
    private var value: ([SpeakerLanes.Lane], MeetingPeople)?

    func get(_ key: String, make: () -> ([SpeakerLanes.Lane], MeetingPeople)) -> ([SpeakerLanes.Lane], MeetingPeople) {
        if key == self.key, let value { return value }
        let made = make()
        self.key = key
        value = made
        return made
    }
}

extension View {
    /// The detail's reading column: the page gutter, at most 980 pt, from the left like the header.
    func detailColumn(top: CGFloat, bottom: CGFloat = Space.xxl) -> some View {
        frame(maxWidth: Detail.columnMax, alignment: .leading)
            .padding(.horizontal, Detail.gutter)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Summary, Transcript, Coach, Chat: a glass segmented control centered on the band's lower edge.
private struct DetailTabs: View {
    @Binding var tab: MeetingDetailView.Tab
    var tabs = MeetingDetailView.Tab.allCases
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { t in
                let on = t == tab
                Button { withAnimation(.snappy(duration: 0.2)) { tab = t } } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.ink : Palette.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background {
                            if on {
                                Capsule().fill(Palette.segmentOn)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "on", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        // Solid and raised: lighter than the header band, with an edge and a floating shadow, so the tabs read as
        // their own control and nothing shows through them.
        .background(Palette.raised, in: Capsule())
        .chromeGlass(in: Capsule(), fill: .clear, shadow: .floating)
        .overlay(Capsule().strokeBorder(Palette.bar, lineWidth: 1).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting tabs")
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

/// "Today", or "Oct 26": the list's last-met column, kept short.
func shortDay(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    return cal.isDate(date, equalTo: Date(), toGranularity: .year)
        ? date.formatted(.dateTime.month(.abbreviated).day())
        : date.formatted(.dateTime.month(.abbreviated).year())
}

func clock(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Always with the hour, as the player and the header show it: "0:52:08".
func longClock(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

// MARK: People

/// The speakers of one meeting with their colors and emails, and helpers to match names. The order is the
/// player's (the owner, then the most talk), so one speaker keeps one hue in the lanes, transcript, and talk share.
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
        let seconds: TimeInterval
        /// The saved person this speaker is, whose profile the name opens; nil for a voice Mossad has not saved.
        var person: String?
    }

    let speakers: [Speaker]
    private let byKey: [String: Speaker]
    private let names: [String: String]
    let attendees: [(name: String, email: String?)]
    /// Which saved person each name of the meeting stands for.
    let links: PersonLinks
    /// What these people were made from: the same stamp means the same names, colors, and links.
    let stamp: String

    init(record: CallRecord, ownerName: String, library: VoiceLibrary, stamp: String = "") {
        self.stamp = stamp
        let names = MarkdownWriter.displayNames(record)
        let lanes = SpeakerLanes.make(record, names: names, ownerName: ownerName)
        var allKeys: [String] = []
        for u in record.utterances where !allKeys.contains(u.speakerKey) { allKeys.append(u.speakerKey) }
        let profiles = library.profiles
        let directory = PersonDirectory(profiles: profiles)
        // Everyone the meeting names, saved or not: a second "Sam" among them makes a person saved as "Sam" unsure.
        let knownNames = lanes.filter { record.speakerNames[$0.key] != nil }.map(\.name) + record.attendees.filter { !$0.contains("@") }
        var byKey: [String: Speaker] = [:]
        let list = lanes.enumerated().map { i, lane in
            let known = record.speakerNames[lane.key] != nil
            // A named person has every key with their name; each unnamed voice is its own speaker.
            let keys = known ? allKeys.filter { record.speakerNames[$0] != nil && names[$0] == lane.name } : [lane.key]
            let s = Speaker(key: lane.key, keys: keys, name: lane.name, email: profiles.first { $0.name == lane.name }?.email,
                            color: Palette.speaker(i), isOwner: lane.name == ownerName, isUnknown: !known, seconds: lane.seconds,
                            person: known ? directory.link(for: lane.name, in: knownNames) : nil)
            for k in keys { byKey[k] = s }
            return s
        }
        speakers = list
        self.byKey = byKey
        self.names = names
        attendees = record.attendees.map { a in
            guard a.contains("@") else { return (a, nil) }
            return (library.name(forEmail: a) ?? a, library.name(forEmail: a) == nil ? nil : a)
        }
        links = PersonLinks(stamp: stamp, directory: directory, meeting: knownNames,
                            names: list.map(\.name) + record.attendees + attendees.map(\.name) + record.actionItems.compactMap(\.owner)
                                + (record.screens ?? []).compactMap(\.presenter))
    }

    func speaker(forKey key: String) -> Speaker? { byKey[key] }

    /// The saved people among the first speakers, each one time, for the lanes' VoiceOver actions.
    var profileActions: [String] {
        var seen: Set<String> = []
        return speakers.prefix(12).compactMap(\.person).filter { seen.insert($0).inserted }
    }
    func name(forKey key: String) -> String { names[key] ?? key }

    func color(forKey key: String) -> Color { byKey[key]?.color ?? Palette.tertiaryMark }

    /// An action item owner matched to a speaker: exact name, then first name.
    func color(forOwner owner: String) -> Color? {
        if let s = speakers.first(where: { $0.name.caseInsensitiveCompare(owner) == .orderedSame }) { return s.color }
        // A first-name match only for real names: "Speaker C" must not match "Speaker A".
        guard !owner.hasPrefix("Speaker ") else { return nil }
        let first = firstName(owner)
        return speakers.first { firstName($0.name).caseInsensitiveCompare(first) == .orderedSame }?.color
    }
}

/// Names a voice or corrects who it is, with an optional email. Mossad then knows the voice in later calls.
struct SpeakerNamingPopover: View {
    @EnvironmentObject var controller: AppController
    let speaker: MeetingPeople.Speaker
    let callID: String
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(speaker.isUnknown ? "Who is \(speaker.name)?" : "Who is this voice?").font(.system(size: 13, weight: .semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Email (optional)", text: $email).textFieldStyle(.roundedBorder)
            ExistingPersonHint(name: name, email: email)
            Text("Mossad saves this voice under the name and recognizes it in later calls.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Save") {
                    let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
                    controller.applyNames(callID: callID, names: Dictionary(uniqueKeysWithValues: speaker.keys.map { ($0, name) }),
                                          emails: trimmedEmail.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: speaker.keys.map { ($0, trimmedEmail) }))
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            name = speaker.isUnknown ? "" : speaker.name
            email = speaker.email ?? ""
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
