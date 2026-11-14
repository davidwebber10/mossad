import CryptoKit
import Foundation

/// What the Mac computes for the server's MCP with the app's own rules, so the server serves it and repeats no rule:
/// the recurring meetings, each meeting's numbers by month, the bookmarks, the Analytics page for the app's last 7,
/// 30, and 90 days and the last 365, and the coach's cards and goal. Each part is its own record, sent only when its
/// content changed, with `made`, when its content last changed. Built from allowed-field lists (`allowedKeys`) and
/// from the meetings as they were heard (`spoken`): a person is a voice with a name and an id, never someone who was
/// only invited, and never an address. No upcoming meeting (no next date), never a picture, audio, or fingerprint,
/// and nothing the coach learned about a person who keeps no read (nothing about any person where the reads may not
/// go). To the owner's server only, never during a call.
public enum ServerDigest {
    public static let version = 1
    /// The tests hold each part under this size for 1,500 meetings and 60 series.
    public static let maxPartBytes = 400_000
    static let historyRows = 12
    /// The most people and open items of one series; the Mac's page has them all.
    static let listLimit = 20
    static let bookmarkLimit = 2_000
    /// The words of a bookmark's line, at most.
    static let saidLimit = 300
    static let usualWindow = 10

    // MARK: The parts

    public struct Name: Codable, Equatable, Sendable { public var name: String; public var personID: String? }

    public struct Series: Codable, Equatable, Sendable {
        public struct Row: Codable, Equatable, Sendable {
            var callID: String; var start: Date; var minutes: Double; var ownerShare: Double?; var people: Int?; var headline: String?; var notesOnly: Bool
        }
        public struct Attendee: Codable, Equatable, Sendable {
            var name: String; var personID: String?; var came: Int; var of: Int; var last: Date?; var share: Double?; var trend: String
        }
        public struct Stats: Codable, Equatable, Sendable {
            var meetings: Int; var since: Date?; var medianMinutes: Double?; var skipped: String?; var ownerShare: Double?; var talksMost: String?
        }
        public struct Open: Codable, Equatable, Sendable {
            var kind: String; var text: String; var owner: String?; var callID: String?; var at: Double?; var date: Date
        }
        var id: String; var keys: [String]; var title: String; var schedule: String?; var usualPeople: [Name]; var line: String?
        var rows: [Row]; var attendees: [Attendee]; var stats: Stats; var openItems: [Open]
    }

    public struct Meeting: Codable, Equatable, Sendable {
        public struct Speaker: Codable, Equatable, Sendable {
            var name: String; var personID: String?; var isOwner: Bool; var seconds: Double; var share: Double; var turns: Int?
            var wordsPerMinute: Double?; var fillersPerMinute: Double?; var questions: Int; var cutIn: Int?; var cutOff: Int?; var reply: Double?
        }
        public struct Owner: Codable, Equatable, Sendable { var name: String?; var tasks: [String] }
        public struct Cost: Codable, Equatable, Sendable { var total: Double; var transcription: Double; var ai: Double; var estimated: Bool }
        var callID: String; var title: String; var start: Date; var duration: Double; var byWords: Bool; var sentences: [String]
        var speakers: [Speaker]; var outcomes: String?; var owners: [Owner]; var coach: String?
        var screens: String?; var standouts: [String]; var earlier: Int; var cost: Cost?
    }

    public struct Bookmark: Codable, Equatable, Sendable {
        var callID: String; var title: String; var start: Date; var at: Double; var note: String?; var speaker: String?; var said: String?
    }

    public struct Period: Codable, Equatable, Sendable {
        public struct Named: Codable, Equatable, Sendable { var name: String; var seconds: Double }
        public struct Part: Codable, Equatable, Sendable { var name: String; var dollars: Double }
        public struct Trend: Codable, Equatable, Sendable { var metric: String; var sentence: String; var usual: String? }
        /// `from` is the first day's start and `to` the start of the last day: the period runs to the moment it was made.
        var days: Int; var from: Date; var to: Date; var calls: Int; var callSeconds: Double; var averageSeconds: Double; var callsPerDay: Double
        var talkShare: Double?; var valueHours: [Named]; var topics: [Named]; var people: [Named]
        var hoursPerWorkday: Double; var coreHoursShare: Double; var backToBackShare: Double?; var callFreeDays: Int; var workdays: Int
        var itemsPerHour: Double; var decisionsPerHour: Double; var withOutcomesShare: Double?; var itemsMine: Int; var itemsOthers: Int
        var tasksMade: Int; var tasksDone: Int; var questionsPerHour: Double?; var cutInPerHour: Double?; var cutOffPerHour: Double?
        var oneOnOneShare: Double?; var groupShare: Double?; var trends: [Trend]; var cost: Double; var costParts: [Part]
    }

    public struct Card: Codable, Equatable, Sendable {
        var id: String; var title: String; var text: String; var callID: String; var date: Date; var at: Double?; var quote: String?
        var number: String?; var usual: String?; var say: String?; var why: String?; var question: String; var answers: [String]
        /// The saved person a card is about, so the server can check that person's switch again; `aboutPerson` when
        /// its words are about someone (`FindingAbout`), so the server holds it back while the switch is off.
        var personID: String?; var personName: String?; var aboutPerson: Bool?
    }

    public struct Goal: Codable, Equatable, Sendable {
        public struct Result: Codable, Equatable, Sendable { var date: Date; var outcome: String; var callID: String; var at: Double?; var evidence: String }
        var plan: String; var why: String?; var status: String; var target: String?; var before: String?; var progress: String?
        var review: Date?; var results: [Result]; var date: Date; var hits: String
    }

    public struct SeriesPart: Codable, Equatable, Sendable { var version = ServerDigest.version; var made: Date; var series: [Series] }
    public struct MeetingsPart: Codable, Equatable, Sendable { var version = ServerDigest.version; var made: Date; var month: String; var meetings: [Meeting] }
    public struct BookmarksPart: Codable, Equatable, Sendable { var version = ServerDigest.version; var made: Date; var bookmarks: [Bookmark] }
    public struct AnalyticsPart: Codable, Equatable, Sendable { var version = ServerDigest.version; var made: Date; var periods: [Period] }
    public struct CoachPart: Codable, Equatable, Sendable {
        var version = ServerDigest.version; var made: Date; var coachOn: Bool; var findings: [Card]; var goal: Goal?; var learned: [Goal]; var ended: [Goal]
        var notTaken: [Goal]
    }

    // MARK: The allowed fields

    /// The keys each level may have. A test fails when a part has any other key.
    public static let allowedKeys: [String: Set<String>] = [
        "series.root": ["version", "made", "series"],
        "series": ["id", "keys", "title", "schedule", "usualPeople", "line", "rows", "attendees", "stats", "openItems"],
        "name": ["name", "personID"],
        "row": ["callID", "start", "minutes", "ownerShare", "people", "headline", "notesOnly"],
        "attendee": ["name", "personID", "came", "of", "last", "share", "trend"],
        "stats": ["meetings", "since", "medianMinutes", "skipped", "ownerShare", "talksMost"],
        "open": ["kind", "text", "owner", "callID", "at", "date"],
        "meetings.root": ["version", "made", "month", "meetings"],
        "meeting": ["callID", "title", "start", "duration", "byWords", "sentences", "speakers", "outcomes", "owners", "coach",
                    "screens", "standouts", "earlier", "cost"],
        "speaker": ["name", "personID", "isOwner", "seconds", "share", "turns", "wordsPerMinute", "fillersPerMinute", "questions", "cutIn", "cutOff",
                    "reply"],
        "owner": ["name", "tasks"],
        "cost": ["total", "transcription", "ai", "estimated"],
        "bookmarks.root": ["version", "made", "bookmarks"],
        "bookmark": ["callID", "title", "start", "at", "note", "speaker", "said"],
        "analytics.root": ["version", "made", "periods"],
        "period": ["days", "from", "to", "calls", "callSeconds", "averageSeconds", "callsPerDay", "talkShare",
                   "valueHours", "topics", "people", "hoursPerWorkday", "coreHoursShare", "backToBackShare", "callFreeDays", "workdays",
                   "itemsPerHour", "decisionsPerHour", "withOutcomesShare", "itemsMine", "itemsOthers", "tasksMade", "tasksDone",
                   "questionsPerHour", "cutInPerHour", "cutOffPerHour", "oneOnOneShare", "groupShare", "trends", "cost", "costParts"],
        "named": ["name", "seconds"],
        "part": ["name", "dollars"],
        "trend": ["metric", "sentence", "usual"],
        "coach.root": ["version", "made", "coachOn", "findings", "goal", "learned", "ended", "notTaken"],
        "card": ["id", "title", "text", "callID", "date", "at", "quote", "number", "usual", "say", "why", "question", "answers", "personID", "personName", "aboutPerson"],
        "goal": ["plan", "why", "status", "target", "before", "progress", "review", "results", "date", "hits"],
        "result": ["date", "outcome", "callID", "at", "evidence"],
    ]

    /// The level of a nested object, by its parent's level and its key.
    public static let childLevel: [String: String] = [
        "series.root.series": "series", "series.usualPeople": "name", "series.rows": "row", "series.attendees": "attendee",
        "series.stats": "stats", "series.openItems": "open",
        "meetings.root.meetings": "meeting", "meeting.speakers": "speaker", "meeting.owners": "owner", "meeting.cost": "cost",
        "bookmarks.root.bookmarks": "bookmark", "analytics.root.periods": "period", "period.valueHours": "named", "period.topics": "named",
        "period.people": "named", "period.trends": "trend", "period.costParts": "part",
        "coach.root.findings": "card", "coach.root.goal": "goal", "coach.root.learned": "goal", "coach.root.ended": "goal",
        "coach.root.notTaken": "goal", "goal.results": "result",
    ]

    public static func rootLevel(of key: String) -> String {
        key.hasPrefix("digest:meetings-") ? "meetings.root" : key.replacingOccurrences(of: "digest:", with: "") + ".root"
    }

    /// The month of a meeting by its id ("20270113-100000" is "2027-01"), as the server finds it again.
    public static func month(of callID: String) -> String {
        let d = callID.prefix(6)
        guard d.count == 6, d.allSatisfy(\.isNumber) else { return "other" }
        return "\(d.prefix(4))-\(d.suffix(2))"
    }

    // MARK: Names and addresses

    /// An address in any script, with or without a dot in its domain ("müller@firma.de", "sam@corp").
    static let addressPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}.-]+")

    static func isAddress(_ s: String) -> Bool { s.contains("@") }

    /// Text with every address in it replaced: an address is never a name, and no part holds one.
    static func withoutAddresses(_ s: String) -> String {
        guard s.contains("@") else { return s }
        return addressPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "(address)")
    }

    // MARK: Making the parts

    /// What one run reads once: the people, the meetings as heard, their facts, the usage by call, the tasks, and
    /// each review and rating as they are asked for.
    final class Run: @unchecked Sendable {
        let tools: ChatTools
        let owner: OwnerIdentity
        let facts: MeetingFactsCache
        let usage: (byCall: [String: [UsageEvent]], all: [UsageEvent], since: Date?)
        let commitments: [Commitment]
        let names: [String: String]
        /// The people with "Keep a read" off, by the id of now.
        let off: Set<String>
        private let lock = NSLock()
        private var reviews: [String: CoachReview?] = [:]
        private var historyMade: [MeetingFacts]?
        private(set) lazy var heard: [CallRecord] = tools.records.map(named)
        private(set) lazy var spoken: [CallRecord] = heard.map(Self.withoutInvite)

        init(tools: ChatTools, cache: DigestCache, facts: MeetingFactsCache) {
            self.tools = tools
            owner = tools.ownerIdentity
            self.facts = facts
            let events = cache.usage(tools.paths)
            usage = (Dictionary(grouping: events.events.filter { $0.callID != nil }, by: { $0.callID! }), events.events, events.since)
            commitments = tools.paths.flatMap { CommitmentBook.peek(in: $0.commitments) }?.items ?? []
            names = Dictionary(tools.savedPeople.map { ($0.id.rawValue, $0.displayName) }, uniquingKeysWith: { a, _ in a })
            off = tools.coachPeople.notProfiled
        }

        var history: [MeetingFacts] {
            if let h = lock.withLock({ historyMade }) { return h }
            let h = facts.facts(for: tools.records, owner: tools.owner)
            lock.withLock { historyMade = h }
            return h
        }

        func review(_ id: String) -> CoachReview? {
            if let r = lock.withLock({ reviews[id] }) { return r }
            let r = tools.paths.flatMap { CoachReview.load(in: $0.callDirectory(id)) }
            lock.withLock { reviews[id] = .some(r) }
            return r
        }

        /// A saved person's id for a name, on a sure match only.
        func personID(_ name: String) -> String? { tools.saved.id(for: name).map(tools.saved.canonical) }

        /// A saved person's name by id, never an address.
        func name(of id: String?) -> String? { id.flatMap { names[tools.saved.canonical($0)] ?? names[$0] }.flatMap { isAddress($0) ? nil : $0 } }

        /// The record with no address as a name: a voice named by an address is its saved person's name, else
        /// "Speaker C"; an item's owner the same, else no owner.
        func named(_ r: CallRecord) -> CallRecord {
            var r = r
            for (key, value) in r.speakerNames where isAddress(value) {
                if let n = name(of: r.speakerPeople?[key]) { r.speakerNames[key] = n }
                else {
                    r.speakerNames[key] = "Speaker " + (key.split(separator: ":").last.map(String.init) ?? "")
                    r.speakerPeople?[key] = nil
                }
            }
            for i in r.actionItems.indices where r.actionItems[i].owner.map(isAddress) == true {
                r.actionItems[i].owner = name(of: r.actionItems[i].ownerID)
            }
            return r
        }

        /// The record as it was heard, with nothing of its invite: no invited people, no planned times.
        static func withoutInvite(_ r: CallRecord) -> CallRecord {
            var r = r
            r.attendees = []
            r.invitees = nil
            r.organizer = nil
            r.plannedStart = nil
            r.plannedEnd = nil
            r.speakersExpected = nil
            return r
        }
    }

    /// Every part, each a shared payload to the owner's server. `personasInMCP`: the switch for other AI apps.
    /// `facts`: the app's one cache of the meetings' facts. `stop` is read before each month: a stop sends nothing
    /// and keeps the months already made for the next time.
    public static func parts(_ tools: ChatTools, personasInMCP: Bool, cache: DigestCache? = nil, facts: MeetingFactsCache? = nil,
                             stop: () -> Bool = { false }) -> [SharedPayload]? {
        let cache = cache ?? DigestCache(directory: nil)
        let run = Run(tools: tools, cache: cache, facts: facts ?? MeetingFactsCache())
        let now = tools.now
        var out: [SharedPayload] = []
        func add<T: Encodable>(_ key: String, _ make: (Date) -> T) {
            // `made` is when the content last changed: the same content keeps its date, so it is not sent again.
            let content = clean((try? JSONEncoder.callRecord.encode(make(.distantPast))) ?? Data(), key: key)
            let made = cache.made(key, content: content, now: now)
            if let data = try? JSONEncoder.callRecord.encode(make(made)) { out.append(SharedPayload(kind: .digest, key: key, data: clean(data, key: key))) }
        }
        // A call that starts stops the work at the next part or month: nothing goes, and the months made are kept.
        func stopped() -> Bool {
            guard stop() else { return false }
            cache.save()
            return true
        }
        if stopped() { return nil }
        let series = seriesList(run)
        add("digest:series") { SeriesPart(made: $0, series: series) }
        if stopped() { return nil }
        let marks = bookmarks(run)
        add("digest:bookmarks") { BookmarksPart(made: $0, bookmarks: marks) }
        if stopped() { return nil }
        let periods = analytics(run)
        add("digest:analytics") { AnalyticsPart(made: $0, periods: periods) }
        if stopped() { return nil }
        let coach = coachPart(run, personasInMCP: personasInMCP)
        add("digest:coach") { var c = coach; c.made = $0; return c }
        let byMonth = Dictionary(grouping: run.spoken, by: { month(of: $0.id) })
        for month in byMonth.keys.sorted(by: >) {
            if stopped() { return nil }
            let list = byMonth[month] ?? []
            let meetings = cache.meetings(month, records: list, all: run.spoken, extra: { stamp($0, run: run) }) { meetingNumbers($0, run: run) }
            add("digest:meetings-\(month)") { MeetingsPart(made: $0, month: month, meetings: meetings) }
        }
        cache.save()
        return out.sorted { $0.key < $1.key }
    }

    /// The last wall: a part's JSON with no address left in any string, except a series' id and keys, which are the
    /// calendar's ids as the Mac has them (an iCalendar UID can hold an "@"), by their place in the series part.
    static func clean(_ data: Data, key: String) -> Data {
        guard data.contains(UInt8(ascii: "@")), let object = try? JSONSerialization.jsonObject(with: data) else { return data }
        let series = key == "digest:series"
        func walk(_ v: Any, _ path: [String]) -> Any {
            if let s = v as? String {
                if series, path.first == "series", path.count >= 3, (path.count == 3 && path[2] == "id") || (path.count == 4 && path[2] == "keys") { return s }
                return withoutAddresses(s)
            }
            if let a = v as? [Any] { return a.map { walk($0, path + ["*"]) } }
            if let d = v as? [String: Any] { return Dictionary(uniqueKeysWithValues: d.map { ($0.key, walk($0.value, path + [$0.key])) }) }
            return v
        }
        return (try? JSONSerialization.data(withJSONObject: walk(object, []), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Whether a sentence of "What stood out" may go: never one about a person with "Keep a read" off, by the id of
    /// now. `subject` is a speaker key of the record, or a name (a presenter).
    static func keepsStandout(subject: String?, record: CallRecord, off: Set<String>, canonical: (String) -> String,
                              idOfName: (String) -> String? = { _ in nil }) -> Bool {
        guard let subject, !off.isEmpty else { return true }
        let id = record.speakerPeople?[subject] ?? (record.speakerNames[subject] == nil ? idOfName(subject) : nil)
        guard let id else { return true }
        return !off.contains(canonical(id))
    }

    /// What else a month's numbers stand on: its outcomes, the person ids, its tasks, its cost, and the coach's review.
    static func stamp(_ r: CallRecord, run: Run) -> String {
        let review = run.tools.paths.flatMap { p in
            (try? FileManager.default.attributesOfItem(atPath: p.callDirectory(r.id).appendingPathComponent("coach.json").path))?[.modificationDate] as? Date
        }.map { "\($0.timeIntervalSince1970)" } ?? ""
        let tasks = run.commitments.filter { $0.callID == r.id }.map { "\($0.id)\($0.done != nil)\($0.deleted)" }.sorted()
        let cost = run.usage.byCall[r.id]?.count ?? 0
        return "\(version)|\(run.off.sorted())|\(r.actionItems.map { "\($0.owner ?? "")=\($0.task)" })|\(r.decisions.map(\.text))|"
            + "\((r.speakerPeople ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })|\(tasks)|\(cost)|\(review)"
    }

    /// The recurring meetings: the catalog from the past meetings alone (no upcoming meeting, so no next date; the
    /// schedule reads their planned starts as the app does), each told from the meetings as heard: the people are the
    /// named voices that are surely saved people, never someone who was only invited. A series that ended is left
    /// out, and leaves the server.
    static func seriesList(_ run: Run) -> [Series] {
        let tools = run.tools
        let all = SeriesCatalog.build(records: tools.records, upcoming: [], owner: tools.owner, directory: PersonDirectory(profiles: tools.profiles),
                                      ownerEmails: [tools.settings.ownerEmail], aliases: SeriesCatalog.aliases(tools.snapshot?.calendarEvents ?? []), now: tools.now)
        let directory = tools.fullDirectory
        let byID = Dictionary(run.spoken.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return all.filter { !$0.schedule.ended }.map { s in
            var report = SeriesReport(series: s, records: run.spoken, commitments: run.commitments, owner: run.owner, directory: directory,
                                      ownerEmails: [tools.settings.ownerEmail])
            if let top = report.talksMost, top != "You", run.personID(top) == nil { report.talksMost = nil }
            let rows = report.rows.prefix(historyRows).map {
                Series.Row(callID: $0.id, start: $0.start, minutes: $0.minutes, ownerShare: $0.ownerShare, people: $0.people, headline: $0.headline,
                           notesOnly: $0.notesOnly)
            }
            let attendees = report.attendees.compactMap { a -> Series.Attendee? in
                guard let id = run.personID(a.name) else { return nil }
                return Series.Attendee(name: a.name, personID: id, came: a.came, of: a.of, last: a.last, share: a.share,
                                       trend: a.trend == .joined ? "joined" : a.trend == .droppedOff ? "droppedOff" : "steady")
            }
            let stats = Series.Stats(meetings: report.meetings, since: report.since, medianMinutes: report.medianMinutes,
                                     skipped: report.gaps.flatMap { s.schedule.skippedText(gaps: $0) }, ownerShare: report.ownerShare, talksMost: report.talksMost)
            let open = report.openItems.map { i in
                Series.Open(kind: i.kind == .yourTask ? "yourTask" : i.kind == .actionItem ? "actionItem" : "pendingDecision", text: i.text, owner: i.owner,
                            callID: i.callID, at: i.at, date: i.date)
            }
            // Who usually comes: the named voices of at least half of the last meetings.
            let recent = s.meetings.compactMap { byID[$0.id] }.sorted { $0.start > $1.start }.prefix(usualWindow)
            var counts: [String: (name: String, n: Int)] = [:]
            for r in recent {
                let ids = Set(r.speakerNames.values.filter { !run.owner.isOwner($0) && !$0.hasPrefix("Speaker ") }.compactMap { n in run.personID(n).map { ($0, n) } }.map(\.0))
                for id in ids { counts[id, default: (run.name(of: id) ?? "", 0)].n += 1 }
            }
            let needed = max(1, Int((Double(recent.count) / 2).rounded(.up)))
            let usual = counts.filter { $0.value.n >= needed && !$0.value.name.isEmpty }.sorted { ($0.value.n, $1.value.name) > ($1.value.n, $0.value.name) }
                .map { Name(name: $0.value.name, personID: $0.key) }
            // The keys a point keeps (`savedKeys`): the id, the calendar ids, and the last meetings.
            return Series(id: s.id, keys: s.savedKeys, title: s.title, schedule: s.schedule.text(), usualPeople: usual,
                          line: report.line, rows: Array(rows), attendees: Array(attendees.prefix(listLimit)), stats: stats, openItems: Array(open.prefix(listLimit)))
        }.sorted { $0.id < $1.id }
    }

    static func bookmarks(_ tools: ChatTools) -> [Bookmark] {
        bookmarks(Run(tools: tools, cache: DigestCache(directory: nil), facts: MeetingFactsCache()))
    }

    static func bookmarks(_ run: Run) -> [Bookmark] {
        BookmarkIndex.groups(run.heard).flatMap { g in
            g.bookmarks.map { b in
                let said = b.said.map { $0.text.count > saidLimit ? String($0.text.prefix(saidLimit)) + "…" : $0.text }
                return Bookmark(callID: g.callID, title: g.title, start: g.start, at: b.offset, note: b.note, speaker: b.said?.speaker, said: said)
            }
        }.prefix(bookmarkLimit).map { $0 }
    }

    /// One meeting's Analytics tab, by `MeetingAnalytics` and the sentences of `MeetingFindings`, from the meeting
    /// as heard (no invite: no "who came" against the invited, no late start or overrun against the planned times).
    static func meetingNumbers(_ r: CallRecord, run: Run) -> Meeting? {
        let tools = run.tools
        let a = MeetingAnalytics(record: r, owner: tools.owner, review: run.review(r.id), usage: run.usage.byCall[r.id] ?? [], usageSince: run.usage.since,
                                 history: run.history, value: { run.review($0)?.value?.rating }, people: tools.fullDirectory, commitments: run.commitments)
        guard !a.isEmpty else { return nil }
        var names: [String: String] = [:]
        for s in a.speakers where names[s.id] == nil { names[s.id] = s.isOwner ? "You" : s.name }
        func said(_ s: MeetingFindings.Sentence) -> String { s.said { names[$0] ?? $0 } }
        return Meeting(callID: r.id, title: r.title, start: r.start, duration: a.duration, byWords: a.byWords,
                       sentences: [MeetingFindings.talk(a), MeetingFindings.flow(a), MeetingFindings.delivery(a)].compactMap { $0 }.map(said),
                       speakers: a.speakers.map { s in
                           Meeting.Speaker(name: s.name, personID: r.speakerPeople?[s.id], isOwner: s.isOwner, seconds: s.seconds, share: s.share,
                                           turns: a.byWords ? nil : s.turns, wordsPerMinute: s.wordsPerMinute, fillersPerMinute: s.fillersPerMinute,
                                           questions: s.questions, cutIn: s.interruptionsMade, cutOff: s.interruptionsReceived, reply: s.medianResponse)
                       },
                       outcomes: a.outcomes.map(MeetingFindings.outcomes),
                       owners: a.outcomes?.owners.map { Meeting.Owner(name: $0.name, tasks: $0.tasks) } ?? [],
                       coach: a.coach.flatMap(MeetingFindings.coach), screens: a.screens.map { said(MeetingFindings.screens($0)) },
                       standouts: a.baselines.standouts
                           .filter { keepsStandout(subject: $0.subject, record: r, off: run.off, canonical: tools.coachPeople.canonical, idOfName: run.personID) }
                           .map { said(MeetingFindings.Sentence(subject: $0.subject, $0.text)) }, earlier: a.baselines.earlier,
                       cost: a.cost.map { Meeting.Cost(total: $0.total, transcription: $0.transcription, ai: $0.ai, estimated: $0.estimated) })
    }

    /// The app's own periods: "Last 30 days" starts 29 days before today and runs to now (`AnalyticsRange`), and the
    /// last 365 days by the same rule.
    public static func interval(days: Int, now: Date, calendar: Calendar = .current) -> DateInterval {
        switch days {
        case 7: return AnalyticsRange.last7Days.interval(now: now, calendar: calendar)
        case 30: return AnalyticsRange.last30Days.interval(now: now, calendar: calendar)
        case 90: return AnalyticsRange.last90Days.interval(now: now, calendar: calendar)
        default:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
            return DateInterval(start: start, end: max(start, now))
        }
    }

    /// The Analytics page for the last 7, 30, 90, and 365 days, by `AnalyticsReport` and `CommunicationTrends`.
    static func analytics(_ run: Run) -> [Period] {
        let tools = run.tools
        let reviews = Dictionary(tools.records.compactMap { r in run.review(r.id).map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let facts = run.history
        let today = Calendar.current.startOfDay(for: tools.now)
        return [7, 30, 90, 365].map { days in
            let interval = interval(days: days, now: tools.now)
            let r = AnalyticsReport(records: run.heard, usage: run.usage.all, owner: tools.owner, interval: interval, reviews: reviews, commitments: run.commitments)
            let trends = CommunicationTrends(facts: facts, interval: interval).series(.all).map {
                Period.Trend(metric: CommunicationTrends.title($0.metric), sentence: $0.sentence, usual: $0.usualText)
            }
            return Period(days: days, from: interval.start, to: today, calls: r.calls, callSeconds: r.callSeconds, averageSeconds: r.averageSeconds,
                          callsPerDay: r.callsPerDay, talkShare: r.talkShare,
                          valueHours: MeetingValue.Rating.allCases.compactMap { k in r.valueSeconds[k].map { Period.Named(name: k.rawValue, seconds: $0) } },
                          topics: r.tags.prefix(10).map { Period.Named(name: $0.name, seconds: $0.seconds) },
                          people: r.people.prefix(10).map { Period.Named(name: $0.name, seconds: $0.seconds) },
                          hoursPerWorkday: r.workday.hoursPerWorkday, coreHoursShare: r.workday.coreHoursShare, backToBackShare: r.workday.backToBackShare,
                          callFreeDays: r.workday.callFreeDays, workdays: r.workday.workdays, itemsPerHour: r.outcomes.itemsPerHour,
                          decisionsPerHour: r.outcomes.decisionsPerHour, withOutcomesShare: r.outcomes.withOutcomesShare, itemsMine: r.outcomes.mine,
                          itemsOthers: r.outcomes.others, tasksMade: r.outcomes.commitmentsMade, tasksDone: r.outcomes.commitmentsDone,
                          questionsPerHour: r.communication.questionsPerHour, cutInPerHour: r.communication.interruptionsMadePerHour,
                          cutOffPerHour: r.communication.interruptionsReceivedPerHour, oneOnOneShare: r.communication.oneOnOneShare,
                          groupShare: r.communication.groupShare, trends: trends, cost: r.cost.total,
                          costParts: UsageEvent.Purpose.allCases.compactMap { p in r.cost.byPurpose[p].flatMap { $0 >= 0.005 ? Period.Part(name: p.rawValue, dollars: $0) : nil } })
        }
    }

    /// The coach's cards and goal, by `FindingRules.deck` and `GoalProgress`: no card about a person who keeps no
    /// read, and with the switch for other AI apps off no card about any person (`ChatTools.findingCards`).
    static func coachPart(_ run: Run, personasInMCP: Bool) -> CoachPart {
        let tools = run.tools
        let about = tools.aboutPersonRule()
        let cards: [Card] = !tools.settings.coach ? [] : tools.findingCards(traits: personasInMCP).map { c in
            let person = c.person.map(tools.saved.canonical)
            return Card(id: c.id, title: c.kind.title, text: c.text, callID: c.callID, date: c.date, at: c.at, quote: c.quote, number: c.number, usual: c.usual,
                        say: c.say, why: c.why, question: c.kind.question, answers: [c.kind.yes, c.kind.no], personID: person,
                        personName: person.flatMap { run.name(of: $0) } ?? c.personName.flatMap { isAddress($0) ? nil : $0 },
                        aboutPerson: about(c) ? true : nil)
        }
        let goals = tools.profile.goalHistory
        func hits(_ f: CoachFocus) -> String {
            "\(f.results.filter { $0.outcome == .hit }.count) of \(f.results.count) \(f.goal == nil ? "chances" : "1:1s at the target")"
        }
        func goal(_ f: CoachFocus, progress: Bool) -> Goal {
            let measured = progress && f.status == .active ? f.goal.flatMap { _ in GoalProgress(focus: f, facts: run.history, now: tools.now, people: tools.filterPeople)?.sentence } : nil
            return Goal(plan: f.plan, why: f.why.nonBlank, status: f.status.rawValue, target: f.goal?.targetText,
                        before: f.goal.map { "\($0.typicalText), \($0.usualText)" }, progress: measured, review: f.reviewDate,
                        results: f.results.reversed().map { r in
                            Goal.Result(date: r.date, outcome: f.goal != nil && r.outcome == .hit ? "At the target" : f.goal != nil && r.outcome == .missed ? "Over the target" : r.outcome.label,
                                        callID: r.callID, at: r.at, evidence: r.evidence)
                        }, date: f.updated, hits: hits(f))
        }
        return CoachPart(made: .distantPast, coachOn: tools.settings.coach, findings: cards, goal: goals.current.map { goal($0, progress: true) },
                         learned: goals.finished.map { goal($0, progress: false) }, ended: goals.ended.map { goal($0, progress: false) },
                         notTaken: goals.offered.map { goal($0, progress: false) })
    }
}

/// When the Mac makes the digest again: only with a server, never during a call, never before the meetings were
/// read (a digest of no meeting would empty the server's parts), and when the meetings, the coach, the tasks, the
/// switch, or the day changed since the last digest that arrived whole.
public enum DigestPlan {
    public enum Step: Equatable, Sendable {
        /// Nothing to do: no server, a call, the meetings not read yet, or this digest arrived whole.
        case nothing
        case make
        /// A digest with this key was made and a part did not arrive: send the kept copy again as it is.
        case resend
    }

    public static func key(meetings: Int, coach: Int, commitments: Int, personas: Bool, day: Date, calendar: Calendar = .current) -> String {
        "\(ServerDigest.version)|\(meetings)|\(coach)|\(commitments)|\(personas)|\(calendar.startOfDay(for: day).timeIntervalSince1970)"
    }

    /// `sent`: the key of the last digest whose every part arrived. `pending`: the key of the digest kept in memory
    /// after a part did not arrive.
    public static func step(server: Bool, calling: Bool, meetingsLoaded: Bool, key: String, sent: String?, pending: String?) -> Step {
        guard server, !calling, meetingsLoaded, key != sent else { return .nothing }
        return key == pending ? .resend : .make
    }
}

/// What the digest keeps on this Mac between syncs: when each part's content last changed, each month's meetings
/// with the stamp of what they were made from (a month is made again only when its meetings changed), and the usage
/// log for one run. Never synced.
public final class DigestCache: @unchecked Sendable {
    struct Month: Codable { var stamp: String; var meetings: [ServerDigest.Meeting] }
    struct File: Codable { var made: [String: Made] = [:]; var months: [String: Month] = [:] }
    struct Made: Codable { var hash: String; var date: Date }

    static let fileName = "digest-cache.json"
    private let url: URL?
    private let lock = NSLock()
    private var file: File
    private var usageRead: (events: [UsageEvent], since: Date?)?
    /// How many months were made in this run, not taken from the cache.
    public private(set) var made = 0

    public init(directory: URL?) {
        url = directory?.appendingPathComponent(Self.fileName)
        file = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder.callRecord.decode(File.self, from: $0) } ?? File()
    }

    func made(_ key: String, content: Data, now: Date) -> Date {
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return lock.withLock {
            if let m = file.made[key], m.hash == hash { return m.date }
            file.made[key] = Made(hash: hash, date: now)
            return now
        }
    }

    /// A month's meetings: from the cache while nothing they are made from changed, else made again.
    func meetings(_ month: String, records: [CallRecord], all: [CallRecord], extra: (CallRecord) -> String = { _ in "" },
                  make: (CallRecord) -> ServerDigest.Meeting?) -> [ServerDigest.Meeting] {
        // What the numbers stand on: the month's records with their outcomes, tasks, cost, and reviews (`extra`), and
        // the meetings before them (the baselines). A stable stamp across launches (Swift's Hasher is seeded per process).
        var text = ""
        let last = records.map(\.start).max() ?? .distantPast
        for r in all.sorted(by: { $0.id < $1.id }) where r.start <= last {
            text += "\(r.id)|\(r.end.timeIntervalSince1970)|\(r.utterances.count)|\(r.speakerNames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })\n"
        }
        for r in records.sorted(by: { $0.id < $1.id }) {
            text += "\(r.id)|\(r.markers.count)|\(r.markers.map { $0.note ?? "" })|\(r.tags)|\(r.title)|\(r.summary ?? "")|\(extra(r))\n"
        }
        let stamp = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if let m = lock.withLock({ file.months[month] }), m.stamp == stamp { return m.meetings }
        let made = records.sorted { $0.start > $1.start }.compactMap(make)
        lock.withLock {
            file.months[month] = Month(stamp: stamp, meetings: made)
            self.made += 1
        }
        return made
    }

    func usage(_ paths: Paths?) -> (events: [UsageEvent], since: Date?) {
        if let u = lock.withLock({ usageRead }) { return u }
        let events = paths.map { UsageLog(directory: $0.usage).all() } ?? []
        let u = (events, events.map(\.date).min())
        lock.withLock { usageRead = u }
        return u
    }

    func save() {
        guard let url else { return }
        let data = lock.withLock { try? JSONEncoder.callRecord.encode(file) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: url, options: .atomic)
    }
}

