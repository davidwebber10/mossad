import Foundation

/// What is useful to know about a recurring meeting, from its meetings alone: the key numbers, a short line, each
/// meeting in one row, who comes and who talks, and what is still open. Pure. A number that the meetings cannot
/// give is nil, never 0.
public struct SeriesReport: Sendable, Equatable {
    /// One meeting of the series.
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date
        public var minutes: Double
        public var plannedMinutes: Double?
        /// Positive when the recording began after the planned start, in minutes.
        public var lateMinutes: Double?
        public var overMinutes: Double?
        /// The owner's part of the talk, 0 to 1; nil with no audio or no owner's voice.
        public var ownerShare: Double?
        public var people: Int?
        public var headline: String?
        public var decisions: [Decision]
        public var actionItems: [ActionItem]
        public var notesOnly: Bool
    }

    /// One person of the series.
    public struct Attendee: Sendable, Equatable, Identifiable {
        public enum Trend: Sendable, Equatable { case steady, joined, droppedOff }
        public var id: String { name }
        public var name: String
        /// The meetings they spoke in or were invited to.
        public var came: Int
        public var of: Int
        public var last: Date?
        /// Their mean part of the talk in the meetings they spoke in.
        public var share: Double?
        public var trend: Trend
    }

    /// Something still open in the series.
    public struct OpenItem: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case yourTask, actionItem, pendingDecision }
        public var id: String
        public var kind: Kind
        public var text: String
        public var owner: String?
        public var callID: String?
        public var at: TimeInterval?
        public var date: Date
        public var commitment: Commitment?
    }

    /// Newest first.
    public var rows: [Row]
    public var meetings: Int { rows.count }
    public var since: Date?
    public var medianMinutes: Double?
    public var medianPlannedMinutes: Double?
    /// The usual overrun in minutes, from the meetings with a planned end; nil with fewer than `minimumPlanned`.
    public var usualOverrun: Double?
    public var planned: Int
    public var ranOver: Int
    public var startedLate: Int
    /// Weeks (or intervals of its cadence) with no meeting recorded between the first and the last one.
    public var gaps: Int?
    public var usualPeople: Int?
    public var attendees: [Attendee]
    /// The one who talks most across the meetings with audio; "You" when that is the owner.
    public var talksMost: String?
    public var ownerShare: Double?
    public var openItems: [OpenItem]

    static let minimumPlanned = 3
    static let minimumTalk = 3
    static let recentMeetings = 3

    /// The open decisions come from this many of the last meetings: an old decision with such words is not open for good.
    static let decisionMeetings = 3

    public init(series: MeetingSeries, records: [CallRecord], commitments: [Commitment]?, owner: OwnerIdentity, directory: PersonDirectory,
                ownerEmails: [String] = [], calendar: Calendar = .current) {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recs = series.meetings.compactMap { byID[$0.id] }
        var shares: [String: [Double]] = [:]
        var display: [String: String] = [:]
        var rows: [Row] = []
        var seen: [String: [Int]] = [:]
        for (n, r) in recs.enumerated() {
            let ownerKeys = owner.speakerKeys(in: r)
            // A notes-only meeting has its words placed, not heard: no talk time.
            let talk = r.isNotesOnly ? [:] : Self.talk(r)
            let total = talk.values.reduce(0, +)
            var ownerShare: Double?
            if total > 0 {
                var byName: [String: Double] = [:]
                for (key, seconds) in talk {
                    let name = ownerKeys.contains(key) ? "\u{0}owner" : (r.speakerNames[key].flatMap { $0.hasPrefix("Speaker ") ? nil : $0 } ?? "")
                    guard !name.isEmpty else { continue }
                    byName[name, default: 0] += seconds / total
                }
                ownerShare = ownerKeys.isEmpty ? nil : byName["\u{0}owner"] ?? 0
                for (name, s) in byName {
                    let k = name == "\u{0}owner" ? name : PeopleDuplicates.normalized(name)
                    shares[k, default: []].append(s)
                    if display[k] == nil { display[k] = name }
                }
            }
            let voices = r.speakerNames.values.filter { !owner.isOwner($0) && !$0.hasPrefix("Speaker ") }
            let invited = MeetingPrep.invited(r.attendees, owner: owner.name, directory: directory, ownerEmails: ownerEmails).map(\.name)
            for name in Set((voices + invited).map(PeopleDuplicates.normalized)) {
                seen[name, default: []].append(n)
                if display[name] == nil { display[name] = (voices + invited).first { PeopleDuplicates.normalized($0) == name } }
            }
            let people: Int? = r.speakerNames.isEmpty ? (r.attendees.isEmpty ? nil : r.attendees.count) : Set(r.speakerNames.values).count
            let planned = r.plannedStart.flatMap { s in r.plannedEnd.map { $0.timeIntervalSince(s) / 60 } }
            rows.append(Row(id: r.id, title: r.title, start: r.start, minutes: r.end.timeIntervalSince(r.start) / 60, plannedMinutes: planned,
                            lateMinutes: r.plannedStart.map { r.start.timeIntervalSince($0) / 60 }, overMinutes: r.plannedEnd.map { r.end.timeIntervalSince($0) / 60 },
                            ownerShare: ownerShare, people: people, headline: r.headline?.nonBlank, decisions: r.decisions, actionItems: r.actionItems,
                            notesOnly: r.isNotesOnly))
        }
        self.rows = rows
        since = rows.last?.start
        let audio = rows.filter { !$0.notesOnly }
        medianMinutes = Self.median(audio.map(\.minutes))
        let plannedRows = audio.filter { $0.plannedMinutes != nil }
        planned = plannedRows.count
        medianPlannedMinutes = Self.median(plannedRows.compactMap(\.plannedMinutes))
        ranOver = plannedRows.filter { ($0.overMinutes ?? 0) * 60 >= MeetingAnalytics.Schedule.longOverrun }.count
        startedLate = plannedRows.filter { ($0.lateMinutes ?? 0) * 60 >= MeetingAnalytics.Schedule.lateStart }.count
        usualOverrun = plannedRows.count >= Self.minimumPlanned ? Self.median(plannedRows.compactMap(\.overMinutes)) : nil
        usualPeople = Self.median(rows.compactMap(\.people).map(Double.init)).map { Int($0.rounded()) }
        gaps = Self.gaps(rows.map(\.start), cadence: series.cadence, calendar: calendar)
        let talked = shares.filter { $0.value.count >= Self.minimumTalk }.mapValues { $0.reduce(0, +) / Double($0.count) }
        if let top = talked.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            talksMost = top.key == "\u{0}owner" ? "You" : display[top.key]
        }
        ownerShare = talked["\u{0}owner"]

        let count = rows.count
        attendees = seen.map { key, indices in
            let recent = indices.contains { $0 < Self.recentMeetings }
            let earlier = indices.filter { $0 >= Self.recentMeetings }.count
            let trend: Attendee.Trend
            if count >= 2 * Self.recentMeetings, earlier == 0 { trend = .joined }
            else if count >= 2 * Self.recentMeetings, !recent, Double(earlier) >= Double(count - Self.recentMeetings) / 2 { trend = .droppedOff }
            else { trend = .steady }
            return Attendee(name: display[key] ?? key, came: indices.count, of: count, last: indices.min().map { rows[$0].start },
                            share: talked[key], trend: trend)
        }
        .sorted { ($0.came, $1.name) > ($1.came, $0.name) }

        openItems = Self.openItems(of: recs, commitments: commitments, owner: owner)
    }

    /// What is open: the owner's tasks from the series (their state is known), the other action items of the last
    /// meeting (no state of their own), and the decisions left open. `recs` are the series' records, newest first.
    static func openItems(of recs: [CallRecord], commitments: [Commitment]?, owner: OwnerIdentity) -> [OpenItem] {
        var open: [OpenItem] = []
        let ids = Set(recs.map(\.id))
        for c in (commitments ?? []) where !c.deleted && c.done == nil && c.callID.map(ids.contains) == true {
            open.append(OpenItem(id: "task:\(c.id)", kind: .yourTask, text: c.text, owner: nil, callID: c.callID, at: c.at, date: c.madeAt, commitment: c))
        }
        if let last = recs.first {
            let mine = Set(owner.speakerKeys(in: last).compactMap { last.speakerNames[$0] })
            for (i, item) in last.actionItems.enumerated() {
                guard let who = item.owner?.nonBlank, !owner.isOwner(who), !mine.contains(who) else { continue }
                open.append(OpenItem(id: "item:\(last.id):\(i)", kind: .actionItem, text: item.task, owner: who, callID: last.id, at: nil, date: last.start))
            }
        }
        for r in recs.prefix(Self.decisionMeetings) {
            for (i, d) in r.decisions.enumerated() where SeriesSuggestion.isPending(d.text) {
                open.append(OpenItem(id: "decision:\(r.id):\(i)", kind: .pendingDecision, text: d.text, owner: nil, callID: r.id, at: d.at, date: r.start))
            }
        }
        return open.sorted { $0.date > $1.date }
    }

    /// "Usually 5 people, runs 8 min over, Sam talks most; 3 open items". Each part only when it is known.
    public var line: String? {
        var parts: [String] = []
        if let n = usualPeople { parts.append("Usually \(n) \(n == 1 ? "person" : "people")") }
        if let over = usualOverrun {
            let m = Int(over.rounded())
            parts.append(m >= 2 ? "runs \(m) min over" : m <= -2 ? "ends \(-m) min early" : "ends on time")
        }
        if let who = talksMost { parts.append(who == "You" ? "you talk most" : "\(SeriesSuggestion.first(who)) talks most") }
        var line = parts.joined(separator: ", ")
        if let first = line.first { line = first.uppercased() + line.dropFirst() }
        let items = openItems.count
        if items > 0 { line += (line.isEmpty ? "" : "; ") + "\(items) open \(items == 1 ? "item" : "items")" }
        if line.isEmpty { return nil }
        return line.first!.uppercased() + line.dropFirst()
    }

    /// The times with no meeting between the first and the last, by the cadence: weekdays for a meeting of each
    /// weekday, days for a daily one, weeks, two weeks, months. Nil for an uneven cadence ("about every 10 days").
    static func gaps(_ starts: [Date], cadence: SeriesCadence?, calendar: Calendar) -> Int? {
        guard let cadence, starts.count >= 2, let first = starts.min(), let last = starts.max() else { return nil }
        let days = Set(starts.map { calendar.startOfDay(for: $0) }).count
        let a = calendar.startOfDay(for: first), b = calendar.startOfDay(for: last)
        let span = calendar.dateComponents([.day], from: a, to: b).day ?? 0
        let expected: Int
        switch cadence.rhythm {
        case .weekdays:
            expected = (0...span).filter { !calendar.isDateInWeekend(calendar.date(byAdding: .day, value: $0, to: a)!) }.count
        case .daily: expected = span + 1
        case .weekly: expected = Int((Double(span) / 7).rounded()) + 1
        case .everyOtherWeek: expected = Int((Double(span) / 14).rounded()) + 1
        case .monthly: expected = (calendar.dateComponents([.month], from: a, to: b).month ?? 0) + 1
        case .everyDays: return nil
        }
        return max(0, expected - days)
    }

    /// The seconds each voice spoke.
    static func talk(_ r: CallRecord) -> [String: Double] {
        var out: [String: Double] = [:]
        for u in r.utterances { out[u.speakerKey, default: 0] += max(0, u.end - u.start) }
        return out
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
