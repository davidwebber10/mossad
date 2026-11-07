import MossadCore
import SwiftUI

/// The meetings by day, newest first, as the Mac's list groups them: Today, Yesterday, then the weekday and the
/// date. Search and Settings are glass buttons at the top; Record room floats over the list.
struct MeetingsListView: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var recording = PhoneStore.hook("MOSSAD_ROOM") != nil
    @State private var settings = PhoneStore.hook("MOSSAD_SETTINGS") != nil
    @State private var searching = false
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
                    Button("Search", systemImage: "magnifyingglass") { searching = true }.tint(Palette.ink)
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { settings = true }.tint(Palette.ink)
                }
            }
            .fullScreenCover(isPresented: $recording) { RecordingView() }
            .sheet(isPresented: $settings) { PhoneSettingsView() }
            .sheet(isPresented: $searching) { SearchScreen() }
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
    /// Search results come from any day, so they show the date too.
    var showDate = false

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
        let time = showDate
            ? record.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : record.start.formatted(date: .omitted, time: .shortened)
        var parts = [time, record.platform.shortName]
        let speakers = Set(record.utterances.map(\.speakerKey)).count
        if speakers >= 3 { parts.append("\(speakers) speakers") }
        return parts.joined(separator: " · ")
    }
}

/// Search: titles, people, tags, and transcript text. Tags and people are one tap away before typing.
struct SearchScreen: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        suggestions
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                            NavigationLink(value: r.id) { PhoneMeetingRow(record: r, divided: i < results.count - 1, showDate: true) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Space.l)
            }
            .overlay {
                if !query.isEmpty && results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .phonePage()
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titles, people, tags, transcripts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: String.self) { id in
                if let r = store.meeting(id) { MeetingView(record: r, find: query) }
            }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        let tags = SearchSuggestions.tags(store.meetings), people = SearchSuggestions.people(store.meetings, owner: store.owner)
        if !tags.isEmpty {
            PhoneLabel("Tags").padding(.top, Space.l).padding(.bottom, Space.s)
            FlowChips(items: Array(tags.prefix(12)).map { "#\($0)" }) { query = $0 }
        }
        if !people.isEmpty {
            PhoneLabel("People").padding(.top, Space.xl).padding(.bottom, 2)
            ForEach(Array(people.prefix(8).enumerated()), id: \.element) { i, name in
                Button { query = name } label: {
                    HairlineRow(divided: i < min(people.count, 8) - 1) {
                        HStack(spacing: Space.m) {
                            PersonMark(name: name, size: 28, isOwner: name == store.owner)
                            Text(name).textRole(.body).foregroundStyle(Palette.ink)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var results: [CallRecord] { store.meetings.filter { MeetingSearch.matches($0, query) } }
}

/// Quiet chips that wrap: tags to search for, follow-up questions.
struct FlowChips: View {
    let items: [String]
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: Space.s) {
            ForEach(items, id: \.self) { item in
                Button { pick(item) } label: {
                    Text(item)
                        .textRole(.secondary)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Palette.fill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

enum SearchSuggestions {
    /// Most used first.
    static func tags(_ meetings: [CallRecord]) -> [String] {
        var counts: [String: Int] = [:]
        for r in meetings { for t in r.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// The people met most often, without the owner.
    static func people(_ meetings: [CallRecord], owner: String) -> [String] {
        var counts: [String: Int] = [:]
        for r in meetings { for n in Set(r.speakerNames.values) where n != owner && !n.hasPrefix("Speaker") { counts[n, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
}
