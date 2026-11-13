import Foundation

/// What the Recurring filter reads of one series, made from the Meetings filter's rows of its meetings: who comes,
/// and what is usual. A value that the series cannot give is nil, never 0 or false.
public struct SeriesFilterRow: Sendable, Equatable {
    public var id: String
    /// Who spoke in or was invited to its meetings, and who is invited to the next one, on a sure match; the one in
    /// the most meetings first.
    public var people: [MeetingFilter.Who]
    public var cadence: SeriesFilter.Cadence?
    /// Where it usually runs; from the next invite's link when nothing was recorded.
    public var platform: Platform?
    /// The median recorded length of its meetings; a notes-only meeting has none.
    public var seconds: TimeInterval?
    /// The usual size by the Meetings filter's rule; `.unknown` when no meeting says.
    public var size: MeetingFilter.Size
    /// The coach's usual rating of its meetings; `.notRated` when none has one.
    public var value: MeetingFilter.Value
    /// Nil when the owner's tasks could not be read and nothing else is open.
    public var openItems: Bool?
    public var next: Date?
    /// The newest meeting the owner was in.
    public var last: Date?

    /// `meetings` may hold every meeting's row; `invited` are the next invite's people on a sure match.
    public init(series: MeetingSeries, meetings: [String: MeetingFilterRow], invited: [MeetingFilter.Who] = [], openItems: Bool?) {
        id = series.id
        let rows = series.meetings.compactMap { meetings[$0.id] }
        var count: [String: (who: MeetingFilter.Who, n: Int)] = [:]
        for r in rows {
            // The newest meeting's spelling: the rows come newest first.
            for who in Set(r.people) { count[who.key] = (count[who.key]?.who ?? who, (count[who.key]?.n ?? 0) + 1) }
        }
        var people = count.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.who.name.localizedStandardCompare($1.who.name) == .orderedAscending }.map(\.who)
        for who in invited where !people.contains(who) { people.append(who) }
        self.people = people
        cadence = SeriesFilter.Cadence(series.schedule)
        platform = Self.usual(rows.map(\.platform)) ?? series.next?.platform
        let notesOnly = Set(series.meetings.filter(\.notesOnly).map(\.id))
        seconds = Self.median(rows.filter { !notesOnly.contains($0.id) && $0.seconds > 0 }.map(\.seconds))
        // "Usually" needs at least half of the meetings to say: one known value of twelve is no habit.
        let sizes = rows.map(\.size).filter { $0 != .unknown }, ratings = rows.compactMap(\.value)
        size = sizes.count * 2 >= rows.count ? Self.usual(sizes) ?? .unknown : .unknown
        value = ratings.count * 2 >= rows.count ? Self.usual(ratings).map { MeetingFilter.Value($0) } ?? .notRated : .notRated
        self.openItems = openItems
        next = series.next?.start
        // The owner met them only where the owner was there: a notes-only meeting can be one the owner missed.
        last = rows.first { $0.ownerPresent == true }?.start
    }

    /// The rows of every series, from every meeting's row. The next invite's people are read by the Meetings filter's
    /// rule for an invite (`MeetingFilterPeople`).
    public static func rows(_ series: [MeetingSeries], meetings: [MeetingFilterRow], people: MeetingFilterPeople, openItems: [String: Bool]) -> [SeriesFilterRow] {
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return series.map { s in
            let invited = s.next.map { people.seen(speakers: [], attendees: $0.attendees, invitees: nil).invited } ?? []
            return SeriesFilterRow(series: s, meetings: byID, invited: invited, openItems: openItems[s.id])
        }
    }

    /// Whether anything is open in the series, by the rule of its Open items tab (`SeriesReport.openItems`). Nil when
    /// nothing is open and the tasks could not be read: one of them could be.
    public static func openItems(series: MeetingSeries, records: [String: CallRecord], commitments: [Commitment]?, owner: OwnerIdentity) -> Bool? {
        let recs = series.meetings.compactMap { records[$0.id] }
        if !SeriesReport.openItems(of: recs, commitments: commitments, owner: owner).isEmpty { return true }
        return commitments == nil ? nil : false
    }

    /// The value most of them have; on a tie the newest one's. `newestFirst` is in the order of the series' meetings.
    static func usual<T: Hashable>(_ newestFirst: [T]) -> T? {
        var counts: [T: Int] = [:]
        for v in newestFirst { counts[v, default: 0] += 1 }
        let most = counts.values.max() ?? 0
        return newestFirst.first { counts[$0] == most }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
