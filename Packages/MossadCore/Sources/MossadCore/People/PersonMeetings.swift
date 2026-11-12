import Foundation

/// Every meeting with one person, newest first, for the person page: where they spoke, or where the invite names
/// them on a sure match, by the rule of the Meetings filter (`MeetingFilterPeople.seen`). Pure; make it off the
/// main thread, as it reads every meeting's invite.
public struct PersonMeetings: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public enum Part: String, Sendable { case spoke, invited }
        public var id: String
        public var title: String
        public var start: Date
        /// The recorded length; a notes-only meeting's from its calendar times.
        public var seconds: TimeInterval
        public var platform: Platform
        /// Made from Gemini's notes, not recorded.
        public var notesOnly: Bool
        /// Spoke, or only on the invite: an invite does not prove that they came.
        public var part: Part
        /// Nil for a notes-only meeting where the owner has no line: not known, never "no".
        public var ownerPresent: Bool?
        public var tags: [String]
    }

    /// How often the meetings come, from the last 90 days.
    public enum Cadence: Sendable, Equatable { case daily, severalAWeek, weekly, everyOtherWeek, monthly }

    /// The numbers of the page's top band. Only a meeting they spoke in, with the owner there, proves that the two
    /// met: an invite and a notes-only meeting the owner may have missed count in `meetings` and nowhere else.
    public struct Together: Sendable, Equatable {
        public var meetings = 0
        public var invitedOnly = 0
        /// Meetings they spoke in with the owner there.
        public var met = 0
        public var lastMet: Date?
        /// The length of those meetings.
        public var seconds: TimeInterval = 0
        /// Those of the last 90 days.
        public var recent = 0
        public var cadence: Cadence?

        public init() {}
    }

    public static let recentDays: Double = 90

    public let rows: [Row]
    public let together: Together

    public init(rows: [Row] = [], together: Together = Together()) {
        self.rows = rows
        self.together = together
    }

    /// `isOwner`: the owner's own page, which lists the meetings the owner spoke in.
    public init(records: [CallRecord], name: String, isOwner: Bool = false, people: MeetingFilterPeople, now: Date = Date()) {
        let who = MeetingFilter.Who(id: people.ids[name], name: name)
        var rows: [Row] = []
        for r in records where r.status != .recording {
            let part: Row.Part?
            if isOwner {
                part = r.speakerNames.values.contains { people.ownerKeys.contains(PersonNames.key($0)) } ? .spoke : nil
            } else {
                let seen = people.seen(in: r)
                part = seen.spoke.contains(who) ? .spoke : seen.invited.contains(who) ? .invited : nil
            }
            guard let part else { continue }
            rows.append(Row(id: r.id, title: r.title, start: r.start, seconds: r.recordedSeconds, platform: r.platform,
                            notesOnly: r.isNotesOnly, part: part, ownerPresent: r.ownerPresent, tags: r.tags))
        }
        rows.sort { ($0.start, $0.id) > ($1.start, $1.id) }
        self.rows = rows
        together = Self.together(rows, now: now)
    }

    static func together(_ rows: [Row], now: Date) -> Together {
        var t = Together()
        t.meetings = rows.count
        t.invitedOnly = rows.filter { $0.part == .invited }.count
        let met = rows.filter { $0.part == .spoke && $0.ownerPresent == true }
        t.met = met.count
        t.lastMet = met.first?.start
        t.seconds = met.reduce(0) { $0 + $1.seconds }
        let since = now.addingTimeInterval(-recentDays * 86_400)
        let recent = met.filter { $0.start >= since && $0.start <= now }.map(\.start).sorted()
        t.recent = recent.count
        t.cadence = cadence(recent, now: now)
        return t
    }

    /// The mean gap of three or more meetings, and none when the time since the last one is more than twice it:
    /// a rhythm that stopped is no rhythm.
    static func cadence(_ starts: [Date], now: Date) -> Cadence? {
        guard starts.count >= 3, let last = starts.last else { return nil }
        let gaps = zip(starts, starts.dropFirst()).map { $1.timeIntervalSince($0) / 86_400 }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        guard now.timeIntervalSince(last) / 86_400 <= max(2 * mean, 2) else { return nil }
        switch mean {
        case ..<2: return .daily
        case ..<5: return .severalAWeek
        case ..<10: return .weekly
        case ..<20: return .everyOtherWeek
        case ..<45: return .monthly
        default: return nil
        }
    }

    /// The rows whose title, tags, platform, or notes mark hold every word of `query`, in any case and accent.
    public func matching(_ query: String) -> [Row] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let text = Self.fold(([row.title, row.platform.displayName] + row.tags + (row.notesOnly ? ["Gemini notes"] : [])).joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

extension CallRecord {
    /// The recorded length; for a joined meeting the length of its audio, without the time between its parts.
    public var recordedSeconds: TimeInterval {
        parts.last.map { $0.offset + max(0, $0.end.timeIntervalSince($0.start)) } ?? max(0, end.timeIntervalSince(start))
    }
}

extension MeetingFilterPeople {
    /// From the people the Mac sent (the iPhone has no voice library): each live person by the name shown, with
    /// their id and address.
    public init(people: [Person], owner: String) {
        let live = people.filter(\.isLive)
        var ids: [String: String] = [:]
        for p in live where ids[p.displayName] == nil { ids[p.displayName] = p.id.rawValue }
        self.init(directory: PersonDirectory(live.map { PersonDirectory.Person(name: $0.displayName, emails: $0.emails.filter { $0.state != .rejected && !$0.shared }.map(\.address)) }), ids: ids, owner: owner,
                  ownerNames: live.first(where: \.isOwner)?.forms.map(\.text) ?? [])
    }
}
