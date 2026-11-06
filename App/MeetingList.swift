import MossadCore
import SwiftUI

/// The list column: the call being recorded, upcoming invites, then one group per day. Rows are plain type on the
/// window, and the selected one sits on a quiet fill; the arrow keys move the selection.
struct MeetingList: View {
    @EnvironmentObject var controller: AppController
    let days: [MeetingGroups.Day]
    let live: [CallRecord]
    @Binding var selection: String?
    @Binding var deleting: CallRecord?
    @FocusState private var focused: Bool

    private var upcoming: [UpcomingMeeting] {
        controller.meetingQuery.isEmpty ? Array(controller.upcoming.prefix(UpcomingRow.shown)) : []
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
                        ForEach(live, id: \.id) { r in
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
                    if order.isEmpty, !controller.meetingQuery.isEmpty {
                        Text("No meetings match “\(controller.meetingQuery)”.")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 10).padding(.top, Space.m)
                    }
                }
                .padding(.leading, 4).padding(.trailing, Space.s).padding(.bottom, Space.m)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onDeleteCommand {
                if let id = selection, let r = controller.meetings.first(where: { $0.id == id }), r.canDelete { deleting = r }
            }
            .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
        }
    }

    private func select(_ id: String) {
        selection = id
        focused = true
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = order
        guard !ids.isEmpty else { return .ignored }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + by, 0), ids.count - 1) } ?? 0
        selection = ids[index]
        proxy.scrollTo(ids[index])
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
            .background(
                tint ?? (selected ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear),
                in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
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
                    Text("\(record.start.formatted(date: .omitted, time: .shortened)) · \(record.platform.shortName)")
                        .foregroundStyle(Palette.secondary)
                    status
                }
                .font(.system(size: 12))
                .lineLimit(1)
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
            Text(" · ").foregroundStyle(Palette.secondary)
            Text(record.unknownSpeakers.count > 1 ? "\(record.unknownSpeakers.count) need names" : "Needs names")
                .fontWeight(.medium).foregroundStyle(Palette.accent)
        case .processing:
            Text(" · ").foregroundStyle(Palette.secondary)
            ProcessingMark().padding(.trailing, 5)
            Text(controller.progressText(record) ?? "Processing").foregroundStyle(Palette.secondary).truncationMode(.tail)
        case .failed:
            Text(" · ").foregroundStyle(Palette.secondary)
            Text("Failed").fontWeight(.medium).foregroundStyle(Palette.recording)
        case .recording, nil:
            EmptyView()
        }
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
