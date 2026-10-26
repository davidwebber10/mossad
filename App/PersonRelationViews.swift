import Charts
import MossadCore
import SwiftUI

/// A person's numbers in relation to the owner: time together, talk balance, cadence, how you talk together,
/// topics, open items both ways, and how the meetings went.
struct RelationSections: View {
    @EnvironmentObject var controller: AppController
    let relation: PersonRelation
    let owner: String
    let color: Color

    private var first: String { relation.name.split(separator: " ").first.map(String.init) ?? relation.name }

    var body: some View {
        let r = relation
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            tile("Meetings together", "\(r.calls)", detail: hours(r.seconds))
            tile("Last met", r.lastMet.map { $0.formatted(.relative(presentation: .named)) } ?? "–",
                 detail: r.averageGapDays.map { "About every \(max(1, Int($0.rounded()))) days" } ?? "")
            tile("Usual time", r.usualSlot.map(slotText) ?? "–", detail: "When you meet most")
            tile("Your talk share", (r.oneOnOne ?? r.group)?.share.map(percent) ?? "–", detail: "When you are both in the call")
        }

        WeightedColumns(weights: [1, 1]) {
            Card("Talk balance") {
                VStack(alignment: .leading, spacing: 14) {
                    balance("One to one", r.oneOnOne)
                    balance("In groups", r.group)
                }
            }
            Card("How you talk together") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("").gridCellUnsizedAxes(.horizontal)
                        Text("You").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Text(first).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    pair("Speaks first", "\(r.ownerFirst)", "\(r.theyFirst)", help: "Calls each of you opened")
                    pair("Questions an hour", rate(r.myQuestionsPerHour), rate(r.theirQuestionsPerHour))
                    pair("Cuts in an hour", rate(r.iInterruptPerHour), rate(r.theyInterruptPerHour),
                         help: "Starting while the other is still talking, and taking the floor")
                    pair("Usual reply", seconds(r.myReply), seconds(r.theirReply), help: "The pause before answering the other")
                }
                .font(.callout).monospacedDigit()
            }
        }

        Card("How often you meet") { WeeklyChart(weeks: r.weekly) }

        WeightedColumns(weights: [1, 1]) {
            Card("\(first) owes you") {
                if r.theirItems.isEmpty {
                    Text("No action items for \(first) in your meetings.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(r.theirItems.prefix(6)) { item in
                            Button { controller.openMeeting(item.callID) } label: {
                                itemRow(item.task, "\(item.title) · \(dayWord(item.date))", done: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Card("You promised \(first)") {
                if r.myCommitments.isEmpty {
                    Text("No commitments to \(first).").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(r.myCommitments.prefix(6)) { c in
                            Button { if let id = c.callID { controller.showMoment(id, at: c.at ?? 0) } } label: {
                                itemRow(c.text, c.due.map { "Due " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? (c.callTitle ?? ""),
                                        done: c.done != nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }

        WeightedColumns(weights: [1, 1]) {
            Card("Topics together") {
                if r.topics.isEmpty {
                    Text("Topics come with each summary.").font(.callout).foregroundStyle(.secondary)
                } else {
                    FlowChips(items: r.topics) { controller.showTag($0) }
                }
            }
            Card("How your meetings went") { ValueStrip(value: r.value) }
        }
    }

    private func tile(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7).contentTransition(.numericText())
            Text(detail.isEmpty ? " " : detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func balance(_ label: String, _ b: PersonRelation.Balance?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.callout.weight(.medium))
                Spacer()
                if let share = b?.share {
                    Text("You \(percent(share)) · \(first) \(percent(1 - share))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let b, b.share != nil {
                BalanceBar(mine: b.mine, theirs: b.theirs, showsShare: false)
            } else {
                Text("No calls like this yet.").font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }

    private func pair(_ label: String, _ mine: String, _ theirs: String, help: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).help(help ?? "")
            Text(mine)
            Text(theirs)
        }
    }

    private func itemRow(_ text: String, _ detail: String, done: Bool?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done == true ? "checkmark.circle.fill" : "circle")
                .font(.caption).foregroundStyle(done == true ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).strikethrough(done == true).multilineTextAlignment(.leading)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }

    private func slotText(_ s: PersonRelation.Slot) -> String {
        let day = Calendar.current.weekdaySymbols[s.weekday - 1]
        let time = Calendar.current.date(bySettingHour: s.hour, minute: 0, second: 0, of: Date()).map { $0.formatted(.dateTime.hour()) } ?? "\(s.hour)"
        return "\(day)s, \(time)"
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
                    .foregroundStyle(Color.accentColor.opacity(picked == nil || picked?.start == w.start ? 0.9 : 0.35))
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
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { AxisGridLine().foregroundStyle(.primary.opacity(0.08)); AxisValueLabel() } }
        .frame(height: 140)
        .animation(.snappy, value: picked?.start)
        .accessibilityLabel("Meetings each week over the last six months")
        .accessibilityChartDescriptor(DateSeriesDescriptor(title: "Meetings each week", unit: "calls", points: weeks.map { ($0.start, Double($0.calls)) }))
    }
}

/// Tags as small capsules that wrap; a click shows their meetings.
private struct FlowChips: View {
    let items: [String]
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { t in
                Button { tap(t) } label: {
                    Text("#\(t)").font(.callout).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ValueStrip: View {
    let value: [MeetingValue.Rating: Int]
    private static let ratings: [(MeetingValue.Rating, String, Color)] = [(.high, "High", .green), (.medium, "Medium", .gray), (.low, "Low", Theme.warning)]

    var body: some View {
        let total = value.values.reduce(0, +)
        if total == 0 {
            Text("The coach rates each meeting's worth. Ratings show here after coached calls.").font(.callout).foregroundStyle(.secondary)
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
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
