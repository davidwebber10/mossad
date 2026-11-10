import Foundation

extension MeetingAnalytics {
    // MARK: Participation

    /// The invited people against the voices. Nil for a call with no invite.
    ///
    /// An invited entry is matched by its email or its calendar name to a saved person, and by its name (or the
    /// saved person's) to a speaker; a short name counts only among this meeting's people. An entry that matches
    /// neither stays "not matched": Mossad does not know who it is, so it does not say that they were silent.
    static func participation(_ r: CallRecord, speakers: [Speaker], people: PersonDirectory) -> Participation? {
        guard !r.attendees.isEmpty else { return nil }
        let named = speakers.filter { !$0.isUnknown }
        let meeting = named.map(\.name) + r.attendees.filter { !$0.contains("@") }
        // The speakers as a directory of their own, so an invited "Dana" finds the speaker Dana Lee even when
        // nobody saved her as a person.
        let voices = PersonDirectory(named.map { PersonDirectory.Person(name: $0.name, email: nil) })
        var seen: Set<String> = []
        var invited: [Participation.Attendee] = []
        for a in r.attendees {
            let isEmail = a.contains("@")
            let person = people.match(a, among: meeting)
            let voice = person.flatMap { voices.match($0, among: meeting) } ?? (isEmail ? nil : voices.match(a, among: meeting))
            let label = isEmail ? (person ?? a) : a
            // One person invited by name and by email is one entry.
            guard seen.insert(PeopleDuplicates.normalized(label)).inserted, person.map({ seen.insert("person:" + $0).inserted }) ?? true else { continue }
            invited.append(Participation.Attendee(label: label, email: isEmail ? a : nil, person: person,
                                                  speaker: voice.flatMap { v in named.first { $0.name == v }?.id }))
        }
        let heard = Set(invited.compactMap(\.speaker))
        // The invite is the owner's own calendar, so the owner is never a guest who came without one.
        return Participation(invited: invited, unmatchedSpeakers: named.filter { !heard.contains($0.id) && !$0.isOwner }.map(\.id),
                             unnamedVoices: speakers.filter(\.isUnknown).count)
    }

    // MARK: Outcomes

    /// Decisions, action items by owner, and the owner's tasks from this call. Nil when there is none of them.
    ///
    /// Items are counted with a speaker when the written owner can be only that speaker among the meeting's
    /// people ("Sam" in a meeting with one Sam). The row keeps the name as written unless an item wrote the
    /// speaker's whole name, so a first name never turns into a link to a profile.
    static func outcomes(_ r: CallRecord, speakers: [Speaker], commitments: [Commitment]) -> Outcomes? {
        let tasks = commitments.filter { $0.callID == r.id && !$0.deleted }
            .map { Outcomes.TaskRef(id: $0.id, text: $0.text, done: $0.done != nil) }
        guard !r.decisions.isEmpty || !r.actionItems.isEmpty || !tasks.isEmpty else { return nil }
        let named = speakers.filter { !$0.isUnknown }
        let meeting = named.map(\.name) + r.attendees.filter { !$0.contains("@") }
        let voices = PersonDirectory(named.map { PersonDirectory.Person(name: $0.name, email: nil) })
        var order: [String] = []
        var byOwner: [String: Outcomes.Owner] = [:]
        for item in r.actionItems {
            let written = item.owner?.nonBlank
            let speaker = written.flatMap { voices.match($0, among: meeting) }.flatMap { name in named.first { $0.name == name } }
            let key = speaker.map { "speaker:" + $0.id } ?? written.map { "name:" + PeopleDuplicates.normalized($0) } ?? ""
            if byOwner[key] == nil {
                order.append(key)
                byOwner[key] = Outcomes.Owner(name: written, speaker: speaker?.id, tasks: [])
            }
            if let speaker, let written, PeopleDuplicates.normalized(written) == PeopleDuplicates.normalized(speaker.name) {
                byOwner[key]!.name = speaker.name
            }
            byOwner[key]!.tasks.append(item.task)
        }
        let owners = order.enumerated().map { (index: $0.offset, owner: byOwner[$0.element]!) }
            .sorted { a, b in
                if (a.owner.name == nil) != (b.owner.name == nil) { return b.owner.name == nil }
                return a.owner.tasks.count != b.owner.tasks.count ? a.owner.tasks.count > b.owner.tasks.count : a.index < b.index
            }
            .map(\.owner)
        return Outcomes(decisions: r.decisions.count, actionItems: r.actionItems.count, owners: owners, tasks: tasks)
    }

    // MARK: Screens

    /// Share sessions by presenter, in the order they first shared. Nil for a call with no screens.
    static func screens(_ r: CallRecord) -> Screens? {
        guard let screens = r.screens, !screens.isEmpty else { return nil }
        var order: [String] = []
        var by: [String: Screens.Presenter] = [:]
        for session in ShareSession.group(screens) {
            let key = session.presenter ?? ""
            if by[key] == nil {
                order.append(key)
                by[key] = Screens.Presenter(name: session.presenter, sessions: 0, screens: 0, seconds: 0, first: session.start)
            }
            by[key]!.sessions += 1
            by[key]!.screens += session.count
            by[key]!.seconds += max(0, session.end - session.start)
        }
        return Screens(presenters: order.map { by[$0]! })
    }

    // MARK: Cost

    private static let transcriptionPurposes: Set<UsageEvent.Purpose> = [.transcription, .live]

    /// What was logged for this call, at list prices. A call with nothing logged gets the estimate Analytics uses
    /// only when it ended before the log began (`since`): a later call with nothing logged was made with models
    /// on this Mac, and cost nothing. Nil when the call cost nothing.
    static func cost(_ r: CallRecord, usage: [UsageEvent], since: Date?) -> Cost? {
        let logged = usage.filter { $0.callID == r.id }
        var events = logged
        if logged.isEmpty {
            guard let since, r.end < since else { return nil }
            events = Pricing.estimates(for: [r], logged: [])
        }
        var byPurpose: [UsageEvent.Purpose: Double] = [:]
        for e in events { byPurpose[e.purpose, default: 0] += Pricing.cost(e) }
        let total = byPurpose.values.reduce(0, +)
        guard total > 0 else { return nil }
        let transcription = byPurpose.filter { transcriptionPurposes.contains($0.key) }.values.reduce(0, +)
        let lines = UsageEvent.Purpose.allCases.compactMap { p in byPurpose[p].flatMap { $0 > 0 ? Cost.Line(purpose: p, dollars: $0) : nil } }
        return Cost(total: total, transcription: transcription, ai: total - transcription, lines: lines, estimated: logged.isEmpty)
    }
}
