import MossadCore
import SwiftUI

/// "Your points" over the live transcript: the owner's points for this meeting as a short checklist, in the label
/// column's layout, so it lines up with the transcript under it and never covers it. A tick marks a point raised
/// now; "Raised 12:04" is a point Mossad heard. The count turns to the accent near the planned end while points are
/// open. No notification, no sound.
struct LivePointsPanel: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: LivePointsModel
    let record: CallRecord
    var top: CGFloat
    /// Shows a moment in the live transcript.
    let show: (TimeInterval) -> Void
    @AppStorage("livePointsCollapsed") private var collapsed = false

    var body: some View {
        let points = controller.livePointList()
        if !points.isEmpty {
            // Each 15 s, for the planned end; the points and the marks redraw it as they change.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let open = LivePointRules.open(points, marks: model.marks).count
                let late = LivePointRules.nearEnd(plannedEnd: record.plannedEnd, now: context.date, open: open)
                HStack(alignment: .top, spacing: Space.m) {
                    header(open: open, late: late)
                        .frame(width: LabelColumn<EmptyView>.labelWidth, alignment: .trailing)
                    Group {
                        if collapsed {
                            Text(points.filter { $0.done == nil && model.marks.mark(for: $0.id) == nil }.map(\.text).joined(separator: " · "))
                                .font(.system(size: 12.5)).foregroundStyle(Palette.secondary).lineLimit(1)
                                .padding(.top, 2)
                        } else {
                            LivePointRows(model: model, record: record, points: points, show: show)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, Space.m)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
            .detailColumn(top: top, bottom: 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Your points")
        }
    }

    private func header(open: Int, late: Bool) -> some View {
        Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Your points").textRole(.label).foregroundStyle(Palette.secondary)
                    IconImage(collapsed ? .chevronRight : .chevronDown, size: 9).foregroundStyle(Palette.tertiary)
                }
                Text(open == 0 ? "All raised" : "\(open) open")
                    .font(.system(size: 11.5, weight: late ? .semibold : .regular))
                    .foregroundStyle(late ? Palette.accent : Palette.tertiary)
                    .monospacedDigit()
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show your points" : "Hide your points")
        .accessibilityLabel("Your points, \(open == 0 ? "all raised" : "\(open) open")\(late ? ", the meeting ends soon" : "")")
    }
}

/// The checklist itself, one component for the live page and the quick panel: open, heard by Mossad (confirm or
/// "Not raised"), and the owner's tick, with the time chips. Four rows, then "N more".
struct LivePointRows: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: LivePointsModel
    let record: CallRecord
    let points: [NextTimePoint]
    /// A time chip: the live page shows the moment in its transcript, the panel opens its peek.
    let show: (TimeInterval) -> Void
    var compact = false
    @State private var showAll = false
    @State private var hovered: UUID?
    private static let shownRows = 4

    var body: some View { rows(points) }

    @ViewBuilder
    private func rows(_ points: [NextTimePoint]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(showAll ? points : Array(points.prefix(Self.shownRows))) { row($0) }
            if points.count > Self.shownRows {
                Button(showAll ? "Show fewer" : "\(points.count - Self.shownRows) more") { withAnimation(.snappy) { showAll.toggle() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 8).padding(.top, 2)
            }
        }
    }

    /// Three looks: open (an empty circle), heard by Mossad (a quiet check in the circle, the text dimmed), and
    /// the owner's tick (a solid check, the text struck through). A click on a heard point's circle confirms it as
    /// the owner's tick; "Not raised" opens it again.
    private func row(_ p: NextTimePoint) -> some View {
        let ticked = p.done?.callID == record.id
        let mark = ticked ? nil : model.marks.mark(for: p.id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { controller.toggleLivePoint(p, callID: record.id) } label: {
                Group {
                    if ticked {
                        IconImage(.checkSmall, size: 14).foregroundStyle(Palette.accent)
                    } else if mark != nil {
                        Circle().fill(Palette.accentTint)
                            .overlay(IconImage(.checkSmall, size: 10).foregroundStyle(Palette.accent.opacity(0.75)))
                    } else {
                        Circle().strokeBorder(Palette.ring, lineWidth: 1.5)
                    }
                }
                .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ticked ? "Not raised yet: open it again" : mark != nil ? "Confirm: you raised it" : "Mark it raised now")
            .accessibilityLabel(ticked ? "Open \(p.text) again" : mark != nil ? "Confirm \(p.text) raised" : "Mark \(p.text) raised")
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.text)
                    .foregroundStyle(ticked || mark != nil ? Palette.secondary : Palette.ink)
                    .strikethrough(ticked, color: Palette.tertiaryMark)
                    .fixedSize(horizontal: false, vertical: true)
                if ticked {
                    note("You marked it", at: p.done?.at, help: nil)
                } else if let mark {
                    HStack(spacing: 10) {
                        note("Raised", at: mark.at, help: "Mossad heard \u{201C}\(mark.quote)\u{201D}. The check after the call confirms it.")
                        if hovered == p.id {
                            Button("Not raised") { controller.rejectLivePoint(p) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                                .help("Mossad heard it wrong: the point is open again")
                        }
                    }
                } else if p.isForPerson, let name = p.personName {
                    Text("For \(SeriesNames.first(name))").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: compact ? 12.5 : 13))
        .padding(.vertical, compact ? 3 : 4).padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = p.id } else if hovered == p.id { hovered = nil }
        }
        .contextMenu {
            if mark != nil {
                Button("Confirm: I raised it") { controller.toggleLivePoint(p, callID: record.id) }
                Button("Not raised") { controller.rejectLivePoint(p) }
            } else {
                Button(ticked ? "Not raised yet" : "Mark raised") { controller.toggleLivePoint(p, callID: record.id) }
            }
        }
        .accessibilityAction(named: "Not raised") { if mark != nil { controller.rejectLivePoint(p) } }
    }

    /// "Raised 12:04" with the time as a chip that shows the moment in the live transcript.
    private func note(_ words: String, at: TimeInterval?, help: String?) -> some View {
        HStack(spacing: 6) {
            Text(words).font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
            if let at {
                Button { show(at) } label: {
                    Text(longClock(at)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6).frame(height: 17)
                        .background(Palette.accentTint, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Show this moment in the live transcript")
            }
        }
        .help(help ?? "")
    }
}
