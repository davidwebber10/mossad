import MossadCore
import SwiftUI

/// The list column: the call being recorded, upcoming invites, then one group per day. Rows are plain type on the
/// window, and the selected one sits on a quiet fill; the arrow keys move the selection.
struct MeetingList: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var filters: MeetingFilterModel
    let days: [MeetingGroups.Day]
    let live: [CallRecord]
    @Binding var selection: String?
    @Binding var deleting: CallRecord?
    @FocusState private var focused: Bool
    /// Letters typed in a row select the first title that starts with them, as in Finder.
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    /// Rows on screen, so opening the list scrolls only to a selection that is not.
    @State private var visible: Set<String> = []
    /// Until the first visibility report: only then is it known whether the selection is on screen.
    @State private var waitingForLayout = true
    /// The arrow keys, Home, End, and typing scroll on their own; their selection change must not scroll again.
    @State private var scrolledHere: String?

    /// Invites show only without a search or a filter: both narrow what was recorded.
    private var upcoming: [UpcomingMeeting] {
        controller.meetingQuery.isEmpty && !filters.isActive ? Array(controller.upcoming.prefix(UpcomingRow.shown)) : []
    }

    /// Every row's id in the order shown, for the arrow keys.
    private var order: [String] {
        live.map(\.id) + upcoming.map(\.id) + days.flatMap { $0.records.map(\.id) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !live.isEmpty {
                        GroupHeader(title: "Now", color: Palette.recording, first: true)
                        // Its own id in the stack: with the record's id, a stopped call's row moved to its day kept
                        // the live row's view, timer and all.
                        ForEach(live, id: \.liveRowID) { r in
                            CurrentCallRow(record: r)
                                .listRow(selected: selection == r.id, tint: Palette.recordingTint) { select(r.id) }
                                .contextMenu { MeetingMenuItems(record: r, deleting: $deleting) }
                        }
                    }
                    if !upcoming.isEmpty {
                        GroupHeader(title: "Upcoming", first: live.isEmpty)
                        ForEach(upcoming) { m in
                            UpcomingRow(meeting: m).listRow(selected: selection == m.id) { select(m.id) }
                        }
                    }
                    ForEach(Array(days.enumerated()), id: \.element.date) { i, day in
                        GroupHeader(title: day.title, first: i == 0 && live.isEmpty && upcoming.isEmpty)
                        ForEach(day.records, id: \.id) { r in
                            MeetingRow(record: r, selected: selection == r.id)
                                .listRow(selected: selection == r.id) { select(r.id) }
                                .contextMenu { MeetingMenuItems(record: r, deleting: $deleting) }
                        }
                    }
                    if order.isEmpty, !controller.meetingQuery.isEmpty || filters.isActive {
                        // "Clear all" is just above, at the end of the filter's chips.
                        Text(nothingText)
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.top, Space.m)
                    }
                }
                .padding(.leading, 4).padding(.trailing, Space.s).padding(.bottom, Space.m)
                .scrollTargetLayout()
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { ids in
                visible = Set(ids)
                if waitingForLayout {
                    waitingForLayout = false
                    reveal(selection, proxy)
                }
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.home) { jump(to: order.first, proxy) }
            .onKeyPress(.end) { jump(to: order.last, proxy) }
            .onKeyPress(characters: .alphanumerics.union(.whitespaces), phases: .down) { press in
                guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
                return typeSelect(press.characters, proxy)
            }
            .onDeleteCommand {
                if let id = selection, let r = controller.meetings.first(where: { $0.id == id }), r.canDelete { deleting = r }
            }
            // A meeting opened from elsewhere (a notification, a chat link) comes into view.
            .onChange(of: selection) { _, id in
                defer { scrolledHere = nil }
                guard id != scrolledHere, !waitingForLayout else { return }
                reveal(id, proxy)
            }
            .onAppear {
                // The arrow keys work as soon as the window opens, without a click in the list first.
                focused = true
            }
        }
    }

    private var nothingText: String {
        let query = controller.meetingQuery
        if query.isEmpty { return "No meetings match these filters." }
        return filters.isActive ? "No meetings match “\(query)” with these filters." : "No meetings match “\(query)”."
    }

    /// Only a row off screen: scrolling to one already in view moved the list under the toolbar.
    private func reveal(_ id: String?, _ proxy: ScrollViewProxy) {
        guard let id, !visible.contains(stackID(id)), order.contains(id) else { return }
        proxy.scrollTo(stackID(id), anchor: .center)
    }

    /// The id of a row in the stack: the live row has its own (see `liveRowID`), every other row the record's.
    private func stackID(_ id: String) -> String {
        live.contains { $0.id == id } ? CallRecord.liveRowID(id) : id
    }

    private func select(_ id: String) {
        selection = id
        focused = true
    }

    private func jump(to id: String?, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let id else { return .ignored }
        scrolledHere = id
        selection = id
        proxy.scrollTo(stackID(id))
        return .handled
    }

    /// The player's bare keys: Space plays or pauses, J, K, and L skip and toggle.
    private static let playerKeys: Set<String> = [" ", "j", "k", "l"]

    private func typeSelect(_ characters: String, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let inBurst = Date().timeIntervalSince(typedAt) < 1
        // A player key never starts a type-to-select, so it falls through to the player's shortcut. Within a
        // burst of typing that another letter started, it is part of the title.
        guard inBurst || !Self.playerKeys.contains(characters.lowercased()) else { return .ignored }
        typed = inBurst ? typed + characters : characters
        typedAt = Date()
        let titles = live.map { ($0.id, $0.title) } + upcoming.map { ($0.id, $0.title) }
            + days.flatMap { $0.records.map { ($0.id, $0.title) } }
        guard let match = titles.first(where: { $0.1.lowercased().hasPrefix(typed.lowercased()) }) else { return .handled }
        return jump(to: match.0, proxy)
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = order
        guard !ids.isEmpty else { return .ignored }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + by, 0), ids.count - 1) } ?? 0
        scrolledHere = ids[index]
        selection = ids[index]
        proxy.scrollTo(stackID(ids[index]))
        return .handled
    }
}

extension View {
    /// A list row: the canvas's padding, the quiet selection fill, and a click that selects.
    fileprivate func listRow(selected: Bool, tint: Color? = nil, select: @escaping () -> Void) -> some View {
        modifier(ListRow(selected: selected, tint: tint, select: select))
    }
}

private struct ListRow: ViewModifier {
    let selected: Bool
    let tint: Color?
    let select: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 9).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The selection lies over a tint (the call being recorded) so a selected live row still reads as selected.
                let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                ZStack {
                    if let tint { shape.fill(tint) }
                    shape.fill(selected ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .onTapGesture(perform: select)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }
}

/// "TODAY", "WEDNESDAY": the label role in tertiary, more space above than below so it binds to its rows.
private struct GroupHeader: View {
    let title: String
    var color: Color = Palette.tertiary
    var first = false

    var body: some View {
        Text(title)
            .textRole(.label)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.top, first ? 10 : 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One finished or processing meeting: the platform dot, the title on one line, the time and platform under it,
/// and the length on the right. What needs the owner reads as accent text, not a badge.
private struct MeetingRow: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PlatformDot(platform: record.platform).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 0) {
                    // The time and platform keep their width; a long progress line is what gets cut.
                    Text("\(record.start.formatted(date: .omitted, time: .shortened)) · \(record.platform.shortName)")
                        .foregroundStyle(Palette.secondary)
                        .layoutPriority(1)
                    status
                }
                .font(.system(size: 12))
                .lineLimit(1)
                // The open meeting says how many voices, on a line of its own, as the canvas shows it.
                if selected, record.badge == .needsNames {
                    let n = record.unknownSpeakers.count
                    NamesPill(text: "\(n) \(n == 1 ? "voice needs" : "voices need") names", height: 18).padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LengthText(record: record)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.secondary)
                .fixedSize()
                .padding(.top, 1)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch record.badge {
        case .needsNames:
            if !selected { NamesPill(text: "Needs names", height: 17).padding(.leading, 8) }
        case .processing:
            Text(" · ").foregroundStyle(Palette.secondary)
            ProcessingMark().padding(.trailing, 5)
            Text(controller.progressText(record) ?? "Processing").foregroundStyle(Palette.secondary).truncationMode(.tail)
        case .failed:
            Text(" · ").foregroundStyle(Palette.secondary)
            Text("Failed").fontWeight(.medium).foregroundStyle(Palette.accent)
        case .recording, nil:
            EmptyView()
        }
    }
}

/// "Needs names" in the accent on its tint, the canvas's small pill.
private struct NamesPill: View {
    let text: String
    let height: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: height)
            .background(Palette.accentTint, in: Capsule())
            .fixedSize()
    }
}

/// Processing as the design draws it: a short accent track at low opacity with a fill that keeps moving, never a
/// spinner. The fill still moves under Reduce Motion, which only stills pulses.
struct ProcessingMark: View {
    @Environment(\.animationsActive) private var active

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Capsule().fill(Palette.accentFill.opacity(0.22))
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Palette.accentFill)
                            .frame(width: g.size.width * 0.4)
                            .offset(x: (g.size.width * 1.4) * phase - g.size.width * 0.4)
                    }
                    .clipShape(Capsule())
                }
        }
        .frame(width: 16, height: 4)
        .accessibilityHidden(true)
    }
}

/// The call being recorded: a red tint, a pulsing dot, the running time, and a small live waveform.
private struct CurrentCallRow: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusDot(color: controller.isPaused ? Palette.tertiaryMark : Palette.recording, size: 8, pulsing: !controller.isPaused)
                Text(record.titleSource == .platform ? "Current call" : record.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 6)
                LengthText(record: record).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            HStack(spacing: 8) {
                if controller.isMuted, !controller.isPaused {
                    Label("Muted", systemImage: "mic.slash.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                } else {
                    Text(controller.isPaused ? "Paused" : "\(record.platform.shortName) · recording")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                LiveWaveform(bars: 28, rowHeight: 8, showLabels: false, framesPerSecond: 4).frame(maxWidth: 120)
            }
            .padding(.leading, 18)
        }
    }
}

extension CallRecord {
    /// The live row's id in the list's stack, apart from the same call's row in its day.
    static func liveRowID(_ id: String) -> String { "now:" + id }
    var liveRowID: String { Self.liveRowID(id) }
}
