import Foundation

public enum CoachEmailKind: String, Sendable {
    case weekly, monthly
    var noun: String { self == .weekly ? "week" : "month" }
}

/// The month in review goes out once a month, after 8 AM on the 1st, about the month before.
public enum MonthlySchedule {
    static let hour = 8

    static func lastSendTime(atOrBefore now: Date, calendar: Calendar) -> Date {
        let month = calendar.dateInterval(of: .month, for: now)!.start
        let send = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: month)!
        guard send > now else { return send }
        let previous = calendar.date(byAdding: .month, value: -1, to: month)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: previous)!
    }

    public static func isDue(lastSent: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastSent else { return true }
        return lastSent < lastSendTime(atOrBefore: now, calendar: calendar)
    }

    /// The whole month before the latest send time.
    public static func range(before now: Date, calendar: Calendar = .current) -> DateInterval {
        let end = calendar.dateInterval(of: .month, for: lastSendTime(atOrBefore: now, calendar: calendar))!.start
        return DateInterval(start: calendar.date(byAdding: .month, value: -1, to: end)!, end: end)
    }
}

/// The numbers in a coaching email, measured by the app, never written by the model.
public struct EmailFacts: Equatable, Sendable {
    public var calls: Int
    public var previousCalls: Int
    public var seconds: TimeInterval
    public var previousSeconds: TimeInterval
    public var talkShare: Double?
    public var focusPlan: String?
    /// The focus results in the period, oldest first.
    public var focusResults: [FocusOutcome]
    public var overdue: [Commitment]
    /// Due in the next 7 days.
    public var dueSoon: [Commitment]
    /// Finished in the period.
    public var doneCount: Int

    public init(calls: Int, previousCalls: Int, seconds: TimeInterval, previousSeconds: TimeInterval, talkShare: Double?,
                focusPlan: String?, focusResults: [FocusOutcome], overdue: [Commitment], dueSoon: [Commitment], doneCount: Int) {
        self.calls = calls
        self.previousCalls = previousCalls
        self.seconds = seconds
        self.previousSeconds = previousSeconds
        self.talkShare = talkShare
        self.focusPlan = focusPlan
        self.focusResults = focusResults
        self.overdue = overdue
        self.dueSoon = dueSoon
        self.doneCount = doneCount
    }

    public static func gather(paths: Paths, owner: String, range: DateInterval, now: Date, calendar: Calendar = .current) -> EmailFacts {
        let records = ProcessingQueue(paths: paths).allRecords()
        let report = AnalyticsReport(records: records, usage: [], owner: owner, interval: range, calendar: calendar)
        let before = AnalyticsReport(records: records, usage: [], owner: owner, interval: AnalyticsRange.previous(range), calendar: calendar)
        let profile = (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile()
        let focus = profile.activeFocus
        let book = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
        let open = book.visible.filter { $0.done == nil }
        let week = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))!
        return EmailFacts(
            calls: report.calls, previousCalls: before.calls, seconds: report.callSeconds, previousSeconds: before.callSeconds,
            talkShare: report.talkShare, focusPlan: focus?.plan,
            focusResults: focus?.results.filter { range.contains($0.date) }.map(\.outcome) ?? [],
            overdue: open.filter { $0.status(now: now, calendar: calendar) == .overdue }.sorted { ($0.due ?? now) < ($1.due ?? now) },
            dueSoon: open.filter { c in c.status(now: now, calendar: calendar) != .overdue && c.due.map { $0 <= week } == true }
                .sorted { ($0.due ?? now) < ($1.due ?? now) },
            doneCount: book.visible.filter { $0.done.map { range.contains($0) } == true }.count)
    }
}

/// The coaching emails' look: one card, the numbers first, the focus with a dot per call, the coach's words, and
/// the commitments. Tables and inline styles, so it renders the same in every mail app, with a dark version.
public enum CoachEmailDesign {
    static let accent = "#0f7c78"

    public static func periodLabel(_ kind: CoachEmailKind, _ range: DateInterval, calendar: Calendar = .current) -> String {
        switch kind {
        case .monthly:
            return range.start.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide).year())
        case .weekly:
            let last = calendar.date(byAdding: .day, value: -1, to: range.end)!
            let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
            return "\(range.start.formatted(style)) – \(last.formatted(style))"
        }
    }

    static func hours(_ s: TimeInterval) -> String {
        s >= 3600 ? (s.truncatingRemainder(dividingBy: 3600) < 300 ? "\(Int(s / 3600)) h" : String(format: "%.1f h", s / 3600)) : "\(Int(s / 60)) min"
    }

    static func change(_ now: Double, _ before: Double) -> String? {
        guard before > 0 else { return nil }
        let pct = Int(((now - before) / before * 100).rounded())
        return pct == 0 ? "same" : "\(pct > 0 ? "+" : "")\(pct)%"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func day(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    public static func text(kind: CoachEmailKind, period: String, digest: WeeklyDigest, facts: EmailFacts?) -> String {
        var lines = [digest.subject + (period.isEmpty ? "" : " · \(period)"), "", digest.intro, ""]
        if let f = facts {
            var numbers = ["\(f.calls) meetings", "\(hours(f.seconds)) in meetings"]
            if let t = f.talkShare { numbers.append("you talked \(Int((t * 100).rounded()))%") }
            lines += [numbers.joined(separator: " · "), ""]
        }
        if !digest.improved.isEmpty { lines += ["What got better:"] + digest.improved.map { "- \($0)" } + [""] }
        if !digest.toWork.isEmpty { lines += ["Try next:"] + digest.toWork.map { "- \($0)" } + [""] }
        lines += ["Your focus: \(facts?.focusPlan.map { "\($0) " } ?? "")\(digest.focus)", ""]
        if let m = digest.bestMoment { lines += ["Best moment: \(m)", ""] }
        if let f = facts {
            if !f.overdue.isEmpty { lines += ["Overdue:"] + f.overdue.map { "- \($0.text)" + ($0.due.map { " (due \(day($0)))" } ?? "") } + [""] }
            if !f.dueSoon.isEmpty { lines += ["Coming up:"] + f.dueSoon.map { "- \($0.text)" + ($0.due.map { " (\(day($0)))" } ?? "") } + [""] }
        }
        return lines.joined(separator: "\n")
    }

    public static func html(kind: CoachEmailKind, period: String, digest: WeeklyDigest, facts: EmailFacts?) -> String {
        let label = (kind == .weekly ? "YOUR WEEK" : "MONTH IN REVIEW") + (period.isEmpty ? "" : " · \(escape(period.uppercased()))")
        let versus = kind == .weekly ? "vs. last week" : "vs. last month"
        var body = """
        <tr><td style="padding:32px 32px 8px">
        <div style="font-size:11px;font-weight:700;letter-spacing:1.2px;color:\(accent)">\(label)</div>
        <h1 class="ink" style="margin:10px 0 0;font-size:26px;line-height:1.2;font-weight:700;letter-spacing:-0.4px;color:#15201f">\(escape(digest.subject))</h1>
        <p class="soft" style="margin:12px 0 0;font-size:16px;line-height:1.55;color:#3d4b4a">\(escape(digest.intro))</p>
        </td></tr>
        """
        if let f = facts {
            func cell(_ value: String, _ label: String, _ delta: String?) -> String {
                """
                <td class="tile" width="33%" style="padding:14px 12px;background:#f3f6f5;border-radius:14px;vertical-align:top">\
                <div class="ink" style="font-size:24px;font-weight:700;color:#15201f">\(value)</div>\
                <div class="soft" style="font-size:12px;color:#5d6b6a;margin-top:2px">\(label)</div>\
                \(delta.map { "<div style=\"font-size:12px;color:\(accent);margin-top:4px\">\($0) \(versus)</div>" } ?? "")</td>
                """
            }
            body += """
            <tr><td style="padding:20px 32px 4px"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:separate;border-spacing:8px 0;margin:0 -8px"><tr>
            \(cell("\(f.calls)", f.calls == 1 ? "meeting" : "meetings", change(Double(f.calls), Double(f.previousCalls))))
            \(cell(hours(f.seconds), "in meetings", change(f.seconds, f.previousSeconds)))
            \(cell(f.talkShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "you talked", nil))
            </tr></table></td></tr>
            """
        }
        // The focus, with a dot per call.
        let results = facts?.focusResults ?? []
        let chances = results.filter { $0 != .noChance }
        let dots = results.map { o in
            let color = o == .hit ? "#2f8f4e" : o == .missed ? "#d07a12" : "#c5cdcc"
            return "<span style=\"display:inline-block;width:12px;height:12px;border-radius:6px;background:\(color);margin-right:5px\"></span>"
        }.joined()
        body += """
        <tr><td style="padding:20px 32px 0"><div class="focus" style="background:#e3f2f0;border-radius:16px;padding:18px 20px">
        <div style="font-size:11px;font-weight:700;letter-spacing:1.2px;color:\(accent)">YOUR FOCUS</div>
        \(facts?.focusPlan.map { "<div class=\"ink\" style=\"font-size:17px;font-weight:600;margin-top:6px;color:#15201f\">\(escape($0))</div>" } ?? "")
        \(results.isEmpty ? "" : "<div style=\"margin-top:10px\">\(dots)<span class=\"soft\" style=\"font-size:13px;color:#5d6b6a;vertical-align:2px\">\(chances.filter { $0 == .hit }.count) of \(chances.count) chances</span></div>")
        <div class="soft" style="font-size:15px;line-height:1.5;margin-top:8px;color:#3d4b4a">\(escape(digest.focus))</div>
        </div></td></tr>
        """
        func list(_ title: String, _ items: [String], _ mark: String, _ color: String) -> String {
            guard !items.isEmpty else { return "" }
            return """
            <tr><td style="padding:24px 32px 0"><div class="ink" style="font-size:13px;font-weight:700;color:#15201f">\(title)</div>
            \(items.map { "<table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\" style=\"margin-top:10px\"><tr><td style=\"vertical-align:top;width:22px;color:\(color);font-weight:700\">\(mark)</td><td class=\"soft\" style=\"font-size:15px;line-height:1.5;color:#3d4b4a\">\(escape($0))</td></tr></table>" }.joined())
            </td></tr>
            """
        }
        body += list("What got better", digest.improved, "✓", "#2f8f4e")
        body += list("Try next", digest.toWork, "→", "#d07a12")
        if let m = digest.bestMoment {
            body += """
            <tr><td style="padding:24px 32px 0"><div style="border-left:3px solid \(accent);padding:4px 0 4px 16px">
            <div style="font-size:11px;font-weight:700;letter-spacing:1.2px;color:\(accent)">BEST MOMENT</div>
            <div class="ink" style="font-family:Georgia,'Times New Roman',serif;font-size:18px;line-height:1.45;margin-top:6px;color:#15201f">\(escape(m))</div>
            </div></td></tr>
            """
        }
        if let f = facts, !f.overdue.isEmpty || !f.dueSoon.isEmpty || f.doneCount > 0 {
            func row(_ c: Commitment, _ color: String, _ when: String) -> String {
                """
                <tr><td class="soft line" style="padding:8px 0;border-top:1px solid #e6ebea;font-size:15px;color:#3d4b4a">\(escape(c.text))\
                \(c.to.map { "<div style=\"font-size:12px;color:#8a9796\">Promised to \(escape($0))</div>" } ?? "")</td>\
                <td class="line" style="padding:8px 0 8px 12px;border-top:1px solid #e6ebea;font-size:12px;font-weight:600;color:\(color);text-align:right;white-space:nowrap;vertical-align:top">\(when)</td></tr>
                """
            }
            let rows = f.overdue.prefix(6).map { row($0, "#c4352b", $0.due.map { "Due \(day($0))" } ?? "Overdue") }
                + f.dueSoon.prefix(6).map { row($0, "#5d6b6a", $0.due.map(day) ?? "") }
            body += """
            <tr><td style="padding:24px 32px 0"><div class="ink" style="font-size:13px;font-weight:700;color:#15201f">Your commitments\
            <span style="font-weight:400;color:#8a9796"> · \(f.overdue.count) overdue · \(f.doneCount) done</span></div>
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin-top:8px">\(rows.joined())</table></td></tr>
            """
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">\
        <meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">
        <style>
        @media (prefers-color-scheme: dark) {
          .page { background:#0d1211 !important } .card { background:#172120 !important }
          .ink { color:#eef4f3 !important } .soft { color:#b4c2c0 !important }
          .tile { background:#1f2b2a !important } .focus { background:#16312e !important } .line { border-color:#2a3735 !important }
        }
        @media (max-width: 480px) { h1 { font-size:22px !important } }
        </style></head>
        <body style="margin:0;padding:0">
        <table role="presentation" class="page" width="100%" cellspacing="0" cellpadding="0" style="background:#eef1f0;font-family:-apple-system,'SF Pro Text','Helvetica Neue',Helvetica,Arial,sans-serif">
        <tr><td align="center" style="padding:28px 12px">
        <table role="presentation" class="card" width="100%" cellspacing="0" cellpadding="0" style="max-width:600px;background:#ffffff;border-radius:22px">
        \(body)
        <tr><td style="padding:28px 32px 30px"><div style="font-size:12px;color:#8a9796">From Mossad, your coach on your Mac. Only you get this email.</div></td></tr>
        </table></td></tr></table></body></html>
        """
    }
}
