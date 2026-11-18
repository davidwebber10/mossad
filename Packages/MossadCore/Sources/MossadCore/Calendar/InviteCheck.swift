import Foundation

/// What the calendar gives a recording. Pure.
///
/// `proved`: an event that holds the call's link, or the event of its Meet title's key (`CalendarMatcher.byTitle`), or
/// an event that the voices prove (`InviteCheck`). `picked`: main's rule with no proof, the overlapping event with the
/// platform's call link and the largest overlap, sure when it is the only one. `noInvite`: the call has a link and a whole
/// read holds no event with it (an unplanned call). `nothing`: no event, as on main: what the record has stays.
public enum InviteAnswer: Equatable, Sendable {
    case proved(CalendarEventInfo)
    case picked(CalendarEventInfo, sure: Bool)
    case noInvite
    case nothing

    /// `link`: `meetingID`, else `titleLink`. `whole`: the read is whole (`CalendarRead.whole`); only a whole read can
    /// say "no invite".
    public static func of(platform: Platform, link: String?, titleKey: String?, start: Date, end: Date, events: [CalendarEventInfo],
                          whole: Bool) -> InviteAnswer {
        if let link {
            guard let found = CalendarMatcher.match(for: platform, meetingID: link, start: start, end: end, in: events) else {
                return whole ? .noInvite : .nothing
            }
            return found.sure ? .proved(found.event) : .picked(found.event, sure: false)
        }
        if let titleKey, platform == .meet, let e = CalendarMatcher.byTitle(titleKey, start: start, end: end, in: events) {
            return .proved(e)
        }
        guard let found = CalendarMatcher.match(for: platform, meetingID: nil, start: start, end: end, in: events) else { return .nothing }
        return .picked(found.event, sure: found.sure)
    }

    /// The voices may replace a pick (or find an event where none overlaps) only for a call with no link on a call
    /// platform: a proof or "no invite" is never changed by voices.
    public var voicesMayReplace: Bool {
        switch self {
        case .picked, .nothing: true
        case .proved, .noInvite: false
        }
    }

    /// The answer after the voices of the recording (`evidence`): another event on positive evidence
    /// (`InviteCheck.replacement`), else this answer as it is.
    public func checked(platform: Platform, link: String?, start: Date, end: Date, events: [CalendarEventInfo], evidence: Set<String>,
                        unknownVoices: Bool = false, invited: (CalendarEventInfo) -> Set<String>) -> InviteAnswer {
        guard voicesMayReplace, link == nil, Platform.callApps.contains(platform) else { return self }
        let pick: CalendarEventInfo? = if case .picked(let e, _) = self { e } else { nil }
        let candidates = InviteCheck.candidates(platform: platform, start: start, end: end, in: events)
        return InviteCheck.replacement(pick: pick, candidates: candidates, evidence: evidence, unknownVoices: unknownVoices, invited: invited)
            .map { .proved($0) } ?? self
    }

    /// "No invite" takes away an invite that the record has only when the read holds the record's own event (the same
    /// title and planned start), which then does not hold the link. A read without it (a regenerate months later, a
    /// changed calendar, a blind event store) proves nothing about that invite: the answer is `nothing`.
    public func held(by r: CallRecord, events: [CalendarEventInfo]) -> InviteAnswer {
        guard self == .noInvite, let title = r.calendarTitle else { return self }
        let present = events.contains { e in e.title == title && (r.plannedStart.map { e.start == $0 } ?? true) }
        return present ? self : .nothing
    }

    public var isSure: Bool {
        switch self {
        case .proved: true
        case .picked(_, let sure): sure
        case .noInvite, .nothing: false
        }
    }

    public var event: CalendarEventInfo? {
        switch self {
        case .proved(let e), .picked(let e, _): e
        case .noInvite, .nothing: nil
        }
    }
}

/// Who was in the call, against the events around it: the voices can only replace the event picked by the overlap with
/// another one, on positive evidence. They never take an invite away and never make a pick less sure. Pure.
///
/// The evidence is the voices named by their own score in this recording: not from an invite's inference, not the
/// owner, not "Speaker A", not a provisional voice. A voice the owner named counts. An event invites a voice by the rule
/// of `InviteRoster`: the person's id, an address, or the whole name, never a first name alone.
public enum InviteCheck {
    /// An event that ended this long before the recording started, or starts this long after it ended, can be the call's.
    public static let near: TimeInterval = CalendarMatcher.readWindow

    /// An overlap under both of these is no overlap for a replacement (a join some seconds early, a call that runs a
    /// minute into the next event): that event follows the rule of a near event.
    public static let leastOverlap: TimeInterval = 300

    public struct Candidates: Equatable, Sendable {
        /// The events with the platform's call link that overlap the recording by `leastOverlap` or half of it at least.
        public var overlapping: [CalendarEventInfo]
        /// The other events with the platform's call link that touch the recording or end up to `near` before it or start
        /// up to `near` after it.
        public var near: [CalendarEventInfo]
        public var all: [CalendarEventInfo] { overlapping + near }
    }

    public static func candidates(platform: Platform, start: Date, end: Date, in events: [CalendarEventInfo]) -> Candidates {
        var out = Candidates(overlapping: [], near: [])
        let length = end.timeIntervalSince(start)
        for e in events where !e.isAllDay && CalendarMatcher.hasCallLink(e, platform: platform) {
            let overlap = min(end, e.end).timeIntervalSince(max(start, e.start))
            if overlap > 0, overlap >= leastOverlap || overlap >= length / 2 {
                out.overlapping.append(e)
            } else if e.end >= start.addingTimeInterval(-near), e.start <= end.addingTimeInterval(near) {
                out.near.append(e)
            }
        }
        return out
    }

    /// The people of every candidate as one invite that is not sure: in the first naming of the voices, before the check,
    /// each of them gets the bar of an invited voice and a person invited to none of them the higher bar, and nobody is
    /// named from the invite. Nil when no candidate names people.
    public static func pool(_ candidates: Candidates) -> CallInvite? {
        var guests: [CallInvite.Guest] = []
        for e in candidates.all {
            for g in CallInvite(event: e, sure: false)?.guests ?? [] where !guests.contains(g) { guests.append(g) }
        }
        return guests.isEmpty ? nil : CallInvite(guests: guests, sure: false)
    }

    /// The event that replaces `pick`, or nil when the pick stays.
    /// - An overlapping event replaces it with at least one evidence voice among its invited people and strictly more than
    ///   the pick has, and more than any other overlapping event. A tie keeps the pick.
    /// - A near event replaces it only when there is a pick, every evidence voice is invited to the near event, the pick
    ///   has none of them, no voice heard on the call side is unknown (`unknownVoices`: it can be the pick's person), the
    ///   pick invites nobody through a room or a group (seen only where the calendar marks one: Google does not), and it
    ///   is the only such event.
    public static func replacement(pick: CalendarEventInfo?, candidates: Candidates, evidence: Set<String>, unknownVoices: Bool = false,
                                   invited: (CalendarEventInfo) -> Set<String>) -> CalendarEventInfo? {
        guard !evidence.isEmpty else { return nil }
        func count(_ e: CalendarEventInfo) -> Int { invited(e).intersection(evidence).count }
        let held = pick.map(count) ?? 0
        let others = candidates.overlapping.filter { $0 != pick }.map { ($0, count($0)) }
        if let top = others.max(by: { $0.1 < $1.1 }), top.1 >= 1, top.1 > held, others.filter({ $0.1 == top.1 }).count == 1 {
            return top.0
        }
        guard let pick, held == 0, !unknownVoices, !pick.participants.contains(where: { !$0.isPerson }) else { return nil }
        let fits = candidates.near.filter { $0 != pick && evidence.isSubset(of: invited($0)) }
        return fits.count == 1 ? fits[0] : nil
    }

    /// A voice of the call side with a fingerprint that has no name of a person: unknown, held back, or a letter.
    public static func unknownVoices(names: [String: String], unknown: [String], fingerprints: [String: [Float]]) -> Bool {
        let unnamed = unknown + names.filter { $0.value.hasPrefix("Speaker ") }.map(\.key)
        return unnamed.contains { $0.hasPrefix("them:") && fingerprints[$0] != nil }
    }

    /// The saved voices each event invites, by `InviteRoster`'s rule, without the owner's.
    public static func invitedVoices(profiles: [VoiceProfile], people: [Person]) -> (CalendarEventInfo) -> Set<String> {
        let owners = Set(profiles.filter(\.isOwner).map(\.name))
        return { e in
            guard let invite = CallInvite(event: e, sure: true) else { return [] }
            return InviteRoster(invite: invite, profiles: profiles, people: people).invited.subtracting(owners)
        }
    }

    /// The evidence of a recording's names: by their own score (not `fromInvite`), not the owner, not "Speaker A", not a
    /// provisional voice.
    public static func evidence(names: [String: String], fromInvite: Set<String>, owners: Set<String>, provisional: Set<String>) -> Set<String> {
        Set(names.filter { !fromInvite.contains($0.key) && !$0.value.hasPrefix("Speaker ") }.values).subtracting(owners).subtracting(provisional)
    }
}
