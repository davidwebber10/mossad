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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                                .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).lineLimit(1)
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
        Button { withAnimation(reduceMotion ? nil : .snappy) { collapsed.toggle() } } label: {
            VStack(alignment: .trailing, spacing: Rhythm.pairGap) {
                HStack(spacing: Space.xs) {
                    Text("Your points").textRole(.label).foregroundStyle(Palette.secondary)
                    IconImage(collapsed ? .chevronRight : .chevronDown, size: 9).foregroundStyle(Palette.tertiary)
                }
                Text(open == 0 ? "All raised" : "\(open) open")
                    .font(.system(size: Rhythm.secondarySize, weight: late ? .semibold : .regular))
                    .foregroundStyle(late ? Palette.accent : Palette.tertiary)
                    .monospacedDigit()
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show your points" : "Hide your points")
        .accessibilityLabel("Your points, \(open == 0 ? "all raised" : "\(open) open")\(late ? ", the meeting ends soon" : "")")
        .accessibilityHint(collapsed ? "Shows the list" : "Hides the list")
    }
}

/// The checklist itself, one component for the live page and the quick panel: open, heard by Mossad (confirm or
/// "Not raised"), and the owner's tick, with the time chips. The open points first (`LivePointRules.shownOrder`),
/// four rows, then "N more", which scrolls past a height.
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
    @State private var allHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let shownRows = 4
    /// "N more" opens to this height at most, then scrolls, so the transcript under it stays on the page.
    private static let allMax: CGFloat = 260

    var body: some View { rows(LivePointRules.shownOrder(points, marks: model.marks)) }

    @ViewBuilder
    private func rows(_ points: [NextTimePoint]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showAll {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { ForEach(points) { row($0) } }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { allHeight = $0 }
                }
                .frame(height: min(allHeight, Self.allMax))
            } else {
                ForEach(Array(points.prefix(Self.shownRows))) { row($0) }
            }
            if points.count > Self.shownRows {
                Button(showAll ? "Show fewer" : "\(points.count - Self.shownRows) more") { withAnimation(reduceMotion ? nil : .snappy) { showAll.toggle() } }
                    .buttonStyle(.plain)
                    .font(.system(size: Rhythm.secondarySize, weight: .semibold)).foregroundStyle(Palette.accent)
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
        return HStack(alignment: .firstTextBaseline, spacing: Space.m) {
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
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                Text(p.text)
                    .foregroundStyle(ticked || mark != nil ? Palette.secondary : Palette.ink)
                    .strikethrough(ticked, color: Palette.tertiaryMark)
                    .fixedSize(horizontal: false, vertical: true)
                if ticked {
                    note("You marked it", at: p.done?.at, help: nil)
                } else if let mark {
                    HStack(spacing: Space.m) {
                        note("Raised", at: mark.at, help: "Mossad heard \u{201C}\(mark.quote)\u{201D}. The check after the call confirms it.")
                        if hovered == p.id {
                            Button("Not raised") { controller.rejectLivePoint(p) }
                                .buttonStyle(.plain)
                                .font(.system(size: Rhythm.secondarySize, weight: .semibold)).foregroundStyle(Palette.secondary)
                                .help("Mossad heard it wrong: the point is open again")
                        }
                    }
                } else if p.isForPerson, let name = p.personName {
                    Text("For \(SeriesNames.first(name))").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(p.text), \(ticked ? "you marked it raised" : mark != nil ? "Mossad heard it raised" : "open")")
        .accessibilityActions {
            if mark != nil { Button("Not raised") { controller.rejectLivePoint(p) } }
        }
    }

    /// "Raised 12:04" with the time as a chip that shows the moment in the live transcript.
    private func note(_ words: String, at: TimeInterval?, help: String?) -> some View {
        HStack(spacing: Space.s) {
            Text(words).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
            if let at {
                Button { show(at) } label: {
                    Text(longClock(at)).font(.system(size: Rhythm.noteSize, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6).frame(height: 17)
                        .background(Palette.accentTint, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Show this moment in the live transcript")
                .accessibilityLabel("Show \(longClock(at)) in the live transcript")
            }
        }
        .help(help ?? "")
    }
}
