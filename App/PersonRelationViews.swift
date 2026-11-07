import Charts
import MossadCore
import SwiftUI

/// A person's numbers in relation to the owner, as label column rows: time together, talk balance, how you talk
/// together, cadence, open items both ways, topics, and how the meetings went.
struct RelationSections: View {
    @EnvironmentObject var controller: AppController
    let relation: PersonRelation
    let owner: String
    let color: Color

    private var first: String { relation.name.split(separator: " ").first.map(String.init) ?? relation.name }

    var body: some View {
        let r = relation
        LabelColumn(label: "Together") {
            FigureRow(figures: [
                ("\(r.calls)", r.seconds > 0 ? "meetings · \(hours(r.seconds))" : "meetings"),
                (r.lastMet.map(shortDay) ?? "None",
                 r.averageGapDays.map { "last met · about every \(max(1, Int($0.rounded()))) days" } ?? "last met"),
                (r.usualSlot.map(slotText) ?? "None", "usual time"),
                ((r.oneOnOne ?? r.group)?.share.map(percent) ?? "None", "your talk share"),
            ])
        }
        LabelColumn(label: "Talk balance") {
            VStack(alignment: .leading, spacing: Space.m) {
                balance("One to one", r.oneOnOne)
                balance("In groups", r.group)
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        LabelColumn(label: "How you talk") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                GridRow {
                    Text("").gridCellUnsizedAxes(.horizontal)
                    Text("You").textRole(.label).foregroundStyle(Palette.secondary)
                    Text(first).textRole(.label).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                pair("Speaks first", "\(r.ownerFirst)", "\(r.theyFirst)", help: "Calls each of you opened")
                pair("Questions an hour", rate(r.myQuestionsPerHour), rate(r.theirQuestionsPerHour))
                pair("Cuts in an hour", rate(r.iInterruptPerHour), rate(r.theyInterruptPerHour),
                     help: "Starting while the other is still talking, and taking the floor")
                pair("Usual reply", seconds(r.myReply), seconds(r.theirReply), help: "The pause before answering the other")
            }
            .font(.system(size: 13)).monospacedDigit()
        }
        LabelColumn(label: "How often") {
            WeeklyChart(weeks: r.weekly).frame(maxWidth: 680)
        }
        LabelColumn(label: "\(first) owes you") {
            if r.theirItems.isEmpty {
                quiet("No action items for \(first) in your meetings.")
            } else {
                items(r.theirItems.prefix(6).map { item in
                    (item.task, "\(item.title) · \(dayWord(item.date))", nil, { controller.openMeeting(item.callID) })
                })
            }
        }
        LabelColumn(label: "You promised") {
            if r.myCommitments.isEmpty {
                quiet("No commitments to \(first).")
            } else {
                items(r.myCommitments.prefix(6).map { c in
                    (c.text, c.due.map { "Due " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? (c.callTitle ?? ""),
                     c.done != nil, { if let id = c.callID { controller.showMoment(id, at: c.at ?? 0) } })
                })
            }
        }
        if !r.topics.isEmpty {
            LabelColumn(label: "Topics", labelTopPadding: 4) {
                FlowLayout(spacing: 6) {
                    ForEach(r.topics, id: \.self) { t in
                        Button { controller.showTag(t) } label: { TagChip(text: t) }
                            .buttonStyle(.plain)
                            .help("Meetings about \(t)")
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
            }
        }
        LabelColumn(label: "How it went") { ValueStrip(value: r.value).frame(maxWidth: 680, alignment: .leading) }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Palette.secondary)
    }

    private func items(_ rows: [(String, String, Bool?, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                Button(action: row.3) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Image(systemName: row.2 == true ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11)).foregroundStyle(row.2 == true ? Palette.ok : Palette.tertiaryMark)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0).foregroundStyle(Palette.ink).strikethrough(row.2 == true).multilineTextAlignment(.leading)
                            if !row.1.isEmpty { Text(row.1).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(row.2 == true ? "Done" : "")
                if i < rows.count - 1 { Hairline() }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: 680, alignment: .leading)
    }

    @ViewBuilder
    private func balance(_ label: String, _ b: PersonRelation.Balance?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
                if let share = b?.share {
                    Text("You \(percent(share)) · \(first) \(percent(1 - share))").font(.system(size: 12)).foregroundStyle(Palette.secondary).monospacedDigit()
                }
            }
            if let b, b.share != nil {
                BalanceBar(mine: b.mine, theirs: b.theirs, showsShare: false)
            } else {
                Text("No calls like this yet.").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
        }
    }

    private func pair(_ label: String, _ mine: String, _ theirs: String, help: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(Palette.secondary).help(help ?? "")
            Text(mine).foregroundStyle(Palette.ink)
            Text(theirs).foregroundStyle(Palette.ink)
        }
    }

    private func slotText(_ s: PersonRelation.Slot) -> String {
        let day = Calendar.current.shortWeekdaySymbols[s.weekday - 1]
        let time = Calendar.current.date(bySettingHour: s.hour, minute: 0, second: 0, of: Date()).map { $0.formatted(.dateTime.hour()) } ?? "\(s.hour)"
        return "\(day) \(time)"
    }

    private func rate(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
    private func seconds(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f s", $0) } ?? "–" }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

/// Calls a week over the last six months, with the value under the pointer on glass.
private struct WeeklyChart: View {
    let weeks: [PersonRelation.Week]
    @State private var selected: Date?

    var body: some View {
        let picked = selected.flatMap { s in weeks.last { $0.start <= s } }
        Chart {
            ForEach(weeks) { w in
                BarMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Calls", w.calls))
                    .foregroundStyle(Palette.accentFill.opacity(picked == nil || picked?.start == w.start ? 0.9 : 0.35))
                    .cornerRadius(3)
            }
            if let picked {
                RuleMark(x: .value("Week", picked.start, unit: .weekOfYear))
                    .foregroundStyle(.secondary.opacity(0.25))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("Week of \(picked.start.formatted(.dateTime.month(.abbreviated).day())) · \(picked.calls) \(picked.calls == 1 ? "call" : "calls")")
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .fixedSize()
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { AxisGridLine().foregroundStyle(Palette.hairline); AxisValueLabel().foregroundStyle(Palette.tertiary) } }
        .frame(height: 120)
        .animation(.snappy, value: picked?.start)
        .accessibilityLabel("Meetings each week over the last six months")
        .accessibilityChartDescriptor(DateSeriesDescriptor(title: "Meetings each week", unit: "calls", points: weeks.map { ($0.start, Double($0.calls)) }))
    }
}

private struct ValueStrip: View {
    let value: [MeetingValue.Rating: Int]
    private static let ratings: [(MeetingValue.Rating, String, Color)] = [(.high, "High", Palette.ok), (.medium, "Medium", Palette.bar), (.low, "Low", Palette.accentFill)]

    var body: some View {
        let total = value.values.reduce(0, +)
        if total == 0 {
            Text("The coach rates each meeting's worth. Ratings show here after coached calls.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(Self.ratings, id: \.1) { r in
                            Rectangle().fill(r.2).frame(width: max(0, g.size.width * Double(value[r.0] ?? 0) / Double(total) - 2))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .frame(height: 10)
                HStack(spacing: 12) {
                    ForEach(Self.ratings, id: \.1) { r in
                        HStack(spacing: 5) {
                            Circle().fill(r.2).frame(width: 7, height: 7)
                            Text("\(r.1) \(value[r.0] ?? 0)").monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
    }
}
