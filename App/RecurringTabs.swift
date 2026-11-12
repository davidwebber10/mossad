import MossadCore
import SwiftUI

// MARK: History

/// Every meeting of the series, newest first, with its decisions and action items in one line each.
struct SeriesHistoryTab: View {
    @EnvironmentObject var controller: AppController
    let series: MeetingSeries
    let report: SeriesReport?

    var body: some View {
        if let report {
            if report.rows.isEmpty {
                Text("Mossad has recorded no meeting of this series yet.").foregroundStyle(Palette.tertiary)
            } else {
                MeetingAnalyticsGroup("Meetings") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(report.rows) { row in HistoryRow(row: row, discussed: controller.series.book.discussed(in: row.id)) }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject var controller: AppController
    let row: SeriesReport.Row
    let discussed: [NextTimePoint]
    @State private var hovering = false

    var body: some View {
        Button { controller.openMeeting(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(row.start.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 12.5, weight: .medium)).monospacedDigit().foregroundStyle(Palette.secondary)
                    .frame(width: 92, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.headline ?? row.title).foregroundStyle(Palette.ink).lineLimit(1)
                        if row.notesOnly { TagChip(text: "Gemini notes") }
                    }
                    line("Decisions", row.decisions.map(\.text))
                    line("Action items", row.actionItems.map { item in item.owner.map { "\($0): \(item.task)" } ?? item.task })
                    if !discussed.isEmpty {
                        Text("Your points discussed: " + discussed.map(\.text).joined(separator: "; "))
                            .font(.system(size: 12)).foregroundStyle(Palette.accent).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("\(Int(row.minutes.rounded())) min").font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.tertiary)
            }
            .font(.system(size: 13))
            .padding(.vertical, 9).padding(.horizontal, 8)
            .background(hovering ? Palette.fill.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open this meeting")
    }

    /// "2 decisions: Ship on Friday; …", or nothing.
    @ViewBuilder
    private func line(_ label: String, _ texts: [String]) -> some View {
        if let first = texts.first {
            Text("\(texts.count) \(texts.count == 1 ? String(label.lowercased().dropLast()) : label.lowercased()): \(first)\(texts.count > 1 ? "; …" : "")")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
        }
    }
}

// MARK: People

/// Who comes, how often, who talks most, and who joined or dropped off.
struct SeriesPeopleTab: View {
    let report: SeriesReport?

    var body: some View {
        if let report {
            MeetingAnalyticsGroup("Who comes") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Person").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Came").frame(width: 80, alignment: .trailing)
                        Text("Talks").frame(width: 70, alignment: .trailing)
                        Text("Last").frame(width: 90, alignment: .trailing)
                    }
                    .textRole(.label).foregroundStyle(Palette.secondary).padding(.bottom, 6)
                    ForEach(report.attendees) { a in
                        HStack(alignment: .firstTextBaseline) {
                            HStack(spacing: 8) {
                                PersonName(a.name).foregroundStyle(Palette.ink).lineLimit(1)
                                switch a.trend {
                                case .joined: TagChip(text: "Joined recently")
                                case .droppedOff: TagChip(text: "Dropped off")
                                case .steady: EmptyView()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(a.came) of \(a.of)").frame(width: 80, alignment: .trailing)
                            Text(a.share.map { "\(Int(($0 * 100).rounded()))%" } ?? "\u{2013}").frame(width: 70, alignment: .trailing)
                                .help(a.share == nil ? "Too few meetings with their voice to say" : "Their usual part of the talk")
                            Text(a.last.map(shortDay) ?? "").frame(width: 90, alignment: .trailing)
                        }
                        .monospacedDigit()
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                }
            }
            if let who = report.talksMost {
                MeetingAnalyticsGroup("Talks most") {
                    Text(who == "You" ? "You talk most in this series" + (report.ownerShare.map { ", \(Int(($0 * 100).rounded()))% of the time." } ?? ".")
                         : "\(who) talks most in this series.")
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

// MARK: Stats

/// Length against the plan, the talk balance, the outcomes per meeting, the starts, and the gaps.
struct SeriesStatsTab: View {
    let series: MeetingSeries
    let report: SeriesReport?

    var body: some View {
        if let report, !report.rows.isEmpty {
            let rows = Array(report.rows.prefix(16).reversed())
            MeetingAnalyticsGroup("Length") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(lengthLine(report)).fixedSize(horizontal: false, vertical: true)
                    Bars(values: rows.map(\.minutes), marks: rows.map(\.plannedMinutes), format: { "\(Int($0.rounded())) min" }, dates: rows.map(\.start))
                }
            }
            MeetingAnalyticsGroup("Talk balance") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.ownerShare.map { "You usually talk \(Int(($0 * 100).rounded()))% of the time" + (report.talksMost.map { $0 == "You" ? ", the most of anyone." : "; \($0) talks most." } ?? ".") }
                         ?? "Too few meetings with your voice to say.")
                    Bars(values: rows.map { ($0.ownerShare ?? 0) * 100 }, marks: [], format: { "\(Int($0.rounded()))%" }, dates: rows.map(\.start))
                }
            }
            MeetingAnalyticsGroup("Outcomes") {
                let d = Double(report.rows.map(\.decisions.count).reduce(0, +)) / Double(report.rows.count)
                let a = Double(report.rows.map(\.actionItems.count).reduce(0, +)) / Double(report.rows.count)
                Text(String(format: "%.1f decisions and %.1f action items per meeting.", d, a))
            }
            MeetingAnalyticsGroup("Start") {
                Text(report.planned == 0 ? "No meeting has its planned time, so Mossad cannot say whether it starts on time."
                     : "Started 5 min or more late \(report.startedLate) of \(report.planned) times; ran 5 min or more over \(report.ranOver) of \(report.planned) times.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let gaps = report.gaps, let cadence = series.cadence {
                MeetingAnalyticsGroup("Skipped") {
                    Text(gaps == 0 ? "Mossad recorded every meeting (\(cadence.text.lowercased())) since the first."
                         : "\(gaps) \(gaps == 1 ? "time" : "times") with no meeting recorded (\(cadence.text.lowercased())). Mossad cannot tell a cancelled meeting from one it did not record.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if report == nil {
            ProgressView().controlSize(.small)
        } else {
            Text("The numbers come once Mossad has recorded a meeting of this series.").foregroundStyle(Palette.tertiary)
        }
    }

    private func lengthLine(_ r: SeriesReport) -> String {
        guard let m = r.medianMinutes else { return "No recorded length yet." }
        var line = "Usually \(Int(m.rounded())) min"
        if let p = r.medianPlannedMinutes { line += " of \(Int(p.rounded())) planned" }
        if let over = r.usualOverrun { line += over >= 2 ? ", \(Int(over.rounded())) min over." : over <= -2 ? ", \(Int(-over.rounded())) min early." : ", on time." } else { line += "." }
        return line
    }
}

/// A row of small bars, oldest left, with an optional mark (the plan) on each.
private struct Bars: View {
    let values: [Double]
    let marks: [Double?]
    let format: (Double) -> String
    let dates: [Date]

    var body: some View {
        let top = max(1, (values + marks.compactMap { $0 }).max() ?? 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(values.indices, id: \.self) { i in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.fill).frame(height: 70)
                    RoundedRectangle(cornerRadius: 2).fill(Palette.accentFill.opacity(0.75)).frame(height: max(2, 70 * values[i] / top))
                    if i < marks.count, let m = marks[i] {
                        Rectangle().fill(Palette.ink.opacity(0.55)).frame(height: 1.5).offset(y: -70 * m / top)
                    }
                }
                .frame(width: 18)
                .help("\(dates[i].formatted(.dateTime.month(.abbreviated).day())): \(format(values[i]))" + (i < marks.count ? marks[i].map { " (\(format($0)) planned)" } ?? "" : ""))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(values.map(format).joined(separator: ", "))
    }
}

// MARK: Open items

/// What is still open across the series: the owner's tasks, the others' items of the last meeting, and the
/// decisions left open.
struct SeriesOpenTab: View {
    @EnvironmentObject var controller: AppController
    let report: SeriesReport?

    var body: some View {
        if let report {
            let groups: [(String, SeriesReport.OpenItem.Kind, String)] = [
                ("Your tasks", .yourTask, "Your open tasks from meetings of this series."),
                ("Action items", .actionItem, "The other people's action items of the last meeting. Mossad does not know whether they are done."),
                ("Open decisions", .pendingDecision, "Decisions whose words say they are still open."),
            ]
            if report.openItems.isEmpty {
                Text("Nothing open: no task of yours, no action item of the last meeting, and no decision left open.").foregroundStyle(Palette.tertiary)
            }
            ForEach(groups, id: \.0) { title, kind, help in
                let items = report.openItems.filter { $0.kind == kind }
                if !items.isEmpty {
                    MeetingAnalyticsGroup(title) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(items) { item in row(item) }
                        }
                        .help(help)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func row(_ item: SeriesReport.OpenItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let c = item.commitment {
                Button { controller.toggleDone(c.id) } label: {
                    Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 14, height: 14).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Mark done")
            } else {
                Circle().fill(Palette.tertiaryMark).frame(width: 5, height: 5).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).fixedSize(horizontal: false, vertical: true)
                Text([item.owner, item.date.formatted(.dateTime.month(.abbreviated).day())].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
            }
            Spacer(minLength: 8)
            if let call = item.callID { SeriesMoment(callID: call, at: item.at) }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
    }
}
