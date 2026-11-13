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
    @State private var showAll = false
    private static let shownRows = 4

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
                            rows(points)
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

    private func row(_ p: NextTimePoint) -> some View {
        let ticked = p.done?.callID == record.id
        let mark = model.marks.mark(for: p.id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { controller.toggleLivePoint(p, callID: record.id) } label: {
                Group {
                    if ticked {
                        IconImage(.checkSmall, size: 14).foregroundStyle(Palette.accent)
                    } else {
                        Circle().strokeBorder(Palette.ring, lineWidth: 1.5)
                    }
                }
                .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ticked ? "Not raised yet: open it again" : "Mark it raised now")
            .accessibilityLabel(ticked ? "Open \(p.text) again" : "Mark \(p.text) raised")
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.text)
                    .foregroundStyle(ticked ? Palette.secondary : Palette.ink)
                    .strikethrough(ticked, color: Palette.tertiaryMark)
                    .fixedSize(horizontal: false, vertical: true)
                if ticked {
                    note("You marked it", at: p.done?.at, help: nil)
                } else if let mark {
                    note("Raised", at: mark.at, help: "Mossad heard \u{201C}\(mark.quote)\u{201D}. The check after the call confirms it.")
                } else if p.isForPerson, let name = p.personName {
                    Text("For \(SeriesNames.first(name))").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.vertical, 4).padding(.horizontal, 8)
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
