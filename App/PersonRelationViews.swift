import Charts
import MossadCore
import SwiftUI

/// The person page's Analytics tab: talk balance, how the two of you talk, how often, talk time by meeting, and how
/// the meetings went.
struct PersonAnalyticsTab: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let stats: PersonStats
    let relation: PersonRelation

    private var first: String { relation.name.split(separator: " ").first.map(String.init) ?? relation.name }

    var body: some View {
        let r = relation
        LabelColumnStack(spacing: Rhythm.sectionGap) {
            if r.calls == 0 {
                EmptyState(symbol: "chart.bar", title: "Nothing to measure yet",
                           message: "After a recorded call where \(first) speaks, how the two of you talk shows here.")
                    .frame(maxWidth: .infinity).padding(.top, Space.xl)
            } else {
                LabelColumn(label: "Talk balance") {
                    VStack(alignment: .leading, spacing: Space.m) {
                        balance("One to one", r.oneOnOne)
                        balance("In groups", r.group)
                    }
                    .frame(maxWidth: Rhythm.measure, alignment: .leading)
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
                    .font(.system(size: Rhythm.bodySize)).monospacedDigit()
                }
                LabelColumn(label: "How often") {
                    WeeklyChart(weeks: r.weekly).frame(maxWidth: Rhythm.measure)
                }
                if !stats.meetings.isEmpty {
                    LabelColumn(label: "Talk time by meeting") { PersonTalkByMeeting(profile: profile, stats: stats) }
                }
                LabelColumn(label: "How it went") { ValueStrip(value: r.value).frame(maxWidth: Rhythm.measure, alignment: .leading) }
            }
        }
    }

    @ViewBuilder
    private func balance(_ label: String, _ b: PersonRelation.Balance?) -> some View {
        VStack(alignment: .leading, spacing: Rhythm.itemGap) {
            HStack {
                Text(label).font(.system(size: Rhythm.bodySize, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
                if let share = b?.share {
                    Text("You \(percent(share)) · \(first) \(percent(1 - share))").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).monospacedDigit()
                }
            }
            if let b, b.share != nil {
                BalanceBar(mine: b.mine, theirs: b.theirs, showsShare: false)
            } else {
                Text("No calls like this yet.").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
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

    private func rate(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
    private func seconds(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f s", $0) } ?? "–" }
}

func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

/// Each meeting's talk time as a bar, the newest 8.
struct PersonTalkByMeeting: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let stats: PersonStats

    var body: some View {
        let shown = Array(stats.meetings.filter { $0.talk > 0 }.prefix(8))
        let longest = max(shown.map(\.talk).max() ?? 0, 1)
        let hue = profile.isOwner ? Palette.speaker(0) : PersonMark.color(for: profile.name)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: Space.s) {
            ForEach(shown, id: \.id) { m in
                GridRow {
                    Button { controller.openMeeting(m.id) } label: {
                        Text(m.title).lineLimit(1).foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("\(m.title), \(dayWord(m.start))")
                    Capsule().fill(Palette.fill)
                        .frame(width: 220, height: 8)
                        .overlay(alignment: .leading) {
                            Capsule().fill(hue).frame(width: max(4, 220 * m.talk / longest))
                        }
                        .accessibilityHidden(true)
                    Text(talkText(m.talk)).foregroundStyle(Palette.secondary).monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
        }
        .font(.system(size: Rhythm.bodySize))
        .frame(maxWidth: Rhythm.measure, alignment: .leading)
    }
}

/// The person page's Tasks tab: what the owner promised them, what they owe the owner, and the owner's items from
/// the 1:1s. An action item has no state of its own; only a task of the owner's is open or done.
struct PersonTasksTab: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let stats: PersonStats
    let relation: PersonRelation?
    @State private var showsDone = false

    private var first: String { profile.name.split(separator: " ").first.map(String.init) ?? profile.name }

    var body: some View {
        LabelColumnStack(spacing: Rhythm.sectionGap) {
            if profile.isOwner {
                if stats.actionItems.isEmpty {
                    empty("No action items for you yet.")
                } else {
                    LabelColumn(label: "Your action items") {
                        items(stats.actionItems.prefix(30).map { a in (a.item.task, "\(a.meetingTitle) · \(dayWord(a.start))", nil, { controller.openMeeting(a.meetingID) }) })
                    }
                }
            } else if let r = relation {
                let open = r.myCommitments.filter { $0.done == nil }, done = r.myCommitments.filter { $0.done != nil }
                if open.isEmpty, done.isEmpty, r.theirItems.isEmpty, r.myItems.isEmpty {
                    empty("No tasks between you and \(first) yet. What you promise \(first) in a call, and what \(first) takes on, shows here.")
                } else {
                    LabelColumn(label: "You promised \(first)") {
                        VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                            if open.isEmpty { quiet("Nothing open for \(first).") } else { items(open.map(commitment)) }
                            if !done.isEmpty {
                                Button(showsDone ? "Hide done" : "\(done.count) done") { withAnimation(.snappy) { showsDone.toggle() } }
                                    .buttonStyle(SettingsTextButtonStyle(color: Palette.accent))
                                if showsDone { items(done.map(commitment)) }
                            }
                        }
                    }
                    LabelColumn(label: "\(first) owes you") {
                        if r.theirItems.isEmpty { quiet("No action items for \(first) in your meetings.") }
                        else { items(r.theirItems.map { item in (item.task, "\(item.title) · \(dayWord(item.date))", nil, { controller.openMeeting(item.callID) }) }) }
                    }
                    LabelColumn(label: "Yours from your 1:1s") {
                        if r.myItems.isEmpty { quiet("No action items for you in your 1:1s with \(first).") }
                        else { items(r.myItems.map { item in (item.task, "\(item.title) · \(dayWord(item.date))", nil, { controller.openMeeting(item.callID) }) }) }
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
    }

    private func commitment(_ c: Commitment) -> (String, String, Bool?, () -> Void) {
        (c.text, c.due.map { "Due " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? (c.callTitle ?? ""),
         c.done != nil, { if let id = c.callID { controller.showMoment(id, at: c.at ?? 0) } })
    }

    private func empty(_ text: String) -> some View {
        EmptyState(symbol: "checklist", title: "No tasks", message: text).frame(maxWidth: .infinity).padding(.top, Space.xl)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary)
    }

    private func items(_ rows: [(String, String, Bool?, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                Button(action: row.3) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        // An action item has no state of its own: no circle, so it does not look like an open task.
                        if let done = row.2 {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: Rhythm.noteSize)).foregroundStyle(done ? Palette.ok : Palette.tertiaryMark)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                            Text(row.0).foregroundStyle(Palette.ink).strikethrough(row.2 == true).multilineTextAlignment(.leading)
                            if !row.1.isEmpty { Text(row.1).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary) }
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
        .font(.system(size: Rhythm.bodySize))
        .frame(maxWidth: Rhythm.measure, alignment: .leading)
    }
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
            Text("The coach rates each meeting's worth. Ratings show here after coached calls.").font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary)
        } else {
            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                GeometryReader { g in
                    HStack(spacing: Space.xs) {
                        ForEach(Self.ratings, id: \.1) { r in
                            Rectangle().fill(r.2).frame(width: max(0, g.size.width * Double(value[r.0] ?? 0) / Double(total) - 2))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .frame(height: 10)
                HStack(spacing: Space.m) {
                    ForEach(Self.ratings, id: \.1) { r in
                        HStack(spacing: Space.xs) {
                            Circle().fill(r.2).frame(width: 7, height: 7)
                            Text("\(r.1) \(value[r.0] ?? 0)").monospacedDigit()
                        }
                    }
                }
                .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
            }
        }
    }
}
