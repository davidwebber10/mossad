import Charts
import MossadCore
import SwiftUI

/// What the period cost in API calls: the total, per call and per hour, by service and by purpose, and a bar per
/// day in the same buckets as the time chart.
struct CostsSection: View {
    let report: AnalyticsReport

    /// Token colors, not brand colors: Claude in the accent, AssemblyAI in the bar color as in the canvas, the rest
    /// in quiet inks so a mix of providers still reads.
    private static let allServices: [(UsageEvent.Service, String, Color)] = [
        (.claude, "Claude", Palette.accentFill), (.openai, "OpenAI", Palette.secondary), (.openrouter, "OpenRouter", Palette.accentFill.opacity(0.5)),
        (.assemblyai, "AssemblyAI", Palette.bar), (.deepgram, "Deepgram", Palette.tertiaryMark), (.elevenlabs, "ElevenLabs", Palette.ring),
    ]

    private static let purposes: [(UsageEvent.Purpose, String)] = [
        (.transcription, "Transcription"), (.live, "Live transcript"), (.summary, "Summaries"), (.coach, "Coach reviews"),
        (.weeklyEmail, "Weekly email"), (.question, "Questions"), (.persona, "How people think"),
    ]

    /// Only the services that cost something in this period, so the legend stays short.
    private var services: [(UsageEvent.Service, String, Color)] {
        Self.allServices.filter { (report.cost.byService[$0.0] ?? 0) > 0 }
    }

    var body: some View {
        let c = report.cost
        let days = max(1, report.interval.duration / 86_400)
        SideBySide(sideWidth: 240, sideLeading: true) {
            if c.total > 0 { chart.padding(.top, 28) }
        } side: {
            VStack(alignment: .leading, spacing: 0) {
                if c.total > 0 {
                    Finding("\(money(c.total)) this period, \(money(c.perCall)) a call")
                    Text("About \(money(c.total / days * 30)) a month at this rate")
                        .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).padding(.top, 2)
                    table {
                        row("Per call", money(c.perCall))
                        row("Per hour of calls", money(c.perCallHour))
                        ForEach(services, id: \.1) { s in row(s.1, money(c.byService[s.0] ?? 0), swatch: s.2) }
                    }
                    .padding(.top, 12)
                    table {
                        ForEach(Self.purposes.filter { (c.byPurpose[$0.0] ?? 0) > 0 }, id: \.1) { p in row(p.1, money(c.byPurpose[p.0] ?? 0)) }
                    }
                    .padding(.top, 10)
                    if c.estimatedShare > 0.01 {
                        Text("\(percentText(c.estimatedShare)) is estimated from call length and transcript size, for calls from before Mossad logged usage.")
                            .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                } else {
                    Finding("No API costs this period")
                }
            }
        }
    }

    private func table<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: Rhythm.itemGap) { rows() }
            .padding(.top, 10)
            .hairline(.top)
    }

    private func row(_ title: String, _ value: String, swatch: Color? = nil) -> some View {
        HStack(spacing: Space.s) {
            if let swatch { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(swatch).frame(width: 8, height: 8) }
            Text(title).foregroundStyle(Palette.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Palette.ink).monospacedDigit()
        }
        .font(.system(size: Rhythm.bodySize))
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        // Bottom to top: transcription services, then language models, as the canvas stacks AssemblyAI under Claude.
        let stacked = services.reversed()
        return VStack(alignment: .leading, spacing: Rhythm.itemGap) {
            Chart {
                ForEach(report.days) { bar in
                    ForEach(stacked, id: \.1) { s in
                        BarMark(x: .value("Date", bar.date, unit: report.calendarUnit), y: .value("Cost", bar.cost[s.0] ?? 0))
                            .foregroundStyle(by: .value("Service", s.1))
                            .cornerRadius(2)
                    }
                }
            }
            .chartForegroundStyleScale(domain: stacked.map(\.1), range: stacked.map(\.2))
            .chartLegend(.hidden)
            .chartXAxis { quietDateAxis(report) }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(d.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                                .font(.system(size: Rhythm.noteSize)).foregroundStyle(Palette.tertiary)
                        }
                    }
                }
            }
            .chartPlotStyle { $0.overlay(alignment: .bottom) { Hairline() } }
            .frame(height: 170)
            .accessibilityLabel("API cost by day, \(money(report.cost.total)) in all")
            .accessibilityChartDescriptor(DateSeriesDescriptor(title: "API cost", unit: "dollars",
                                                               points: report.days.map { ($0.date, $0.cost.values.reduce(0, +)) }))
            HStack(spacing: Space.l) {
                ForEach(services, id: \.1) { s in LegendKey(title: s.1, color: s.2) }
            }
        }
    }
}
