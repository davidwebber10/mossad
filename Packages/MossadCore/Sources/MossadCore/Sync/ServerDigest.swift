import CryptoKit
import Foundation

/// What the Mac computes for the server's MCP with the app's own rules, so the server serves it and repeats no rule:
/// the recurring meetings, each meeting's numbers by month, the bookmarks, the Analytics page for 7, 30, 90, and
/// 365 days, and the coach's cards and goal. Each part is its own record, sent only when its content changed, with
/// `made`, when its content last changed. Built from allowed-field lists (`allowedKeys`): never calendar data (no
/// next date, no invite), never a picture, audio, or fingerprint, and nothing the coach learned about a person who
/// keeps no read. To the owner's server only, never during a call.
public enum ServerDigest {
    public static let version = 1
    /// A part larger than this is cut (the oldest meetings of a series' history, the oldest bookmarks first).
    public static let maxPartBytes = 400_000
    static let historyRows = 12
    /// The most people and open items of one series; the Mac's page has them all.
    static let listLimit = 20
    static let bookmarkLimit = 2_000

    // MARK: The parts

    public struct Name: Codable, Equatable, Sendable { public var name: String; public var personID: String? }

    public struct Series: Codable, Equatable, Sendable {
        public struct Row: Codable, Equatable, Sendable {
            var callID: String; var start: Date; var minutes: Double; var plannedMinutes: Double?; var lateMinutes: Double?
            var overMinutes: Double?; var ownerShare: Double?; var people: Int?; var headline: String?; var notesOnly: Bool
        }
        public struct Attendee: Codable, Equatable, Sendable {
            var name: String; var personID: String?; var came: Int; var of: Int; var last: Date?; var share: Double?; var trend: String
        }
        public struct Stats: Codable, Equatable, Sendable {
            var meetings: Int; var since: Date?; var medianMinutes: Double?; var medianPlannedMinutes: Double?; var usualOverrun: Double?
            var planned: Int; var ranOver: Int; var startedLate: Int; var skipped: String?; var ownerShare: Double?; var talksMost: String?
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
        var speakers: [Speaker]; var participation: String?; var outcomes: String?; var owners: [Owner]; var coach: String?
        var screens: String?; var standouts: [String]; var earlier: Int; var cost: Cost?
    }

    public struct Bookmark: Codable, Equatable, Sendable {
        var callID: String; var title: String; var start: Date; var at: Double; var note: String?; var speaker: String?; var said: String?
    }

    public struct Period: Codable, Equatable, Sendable {
        public struct Named: Codable, Equatable, Sendable { var name: String; var seconds: Double }
        public struct Part: Codable, Equatable, Sendable { var name: String; var dollars: Double }
        public struct Trend: Codable, Equatable, Sendable { var metric: String; var sentence: String; var usual: String? }
        var days: Int; var from: Date; var to: Date; var calls: Int; var callSeconds: Double; var averageSeconds: Double; var callsPerDay: Double
        var talkShare: Double?; var scheduled: Int; var unscheduled: Int; var valueHours: [Named]; var topics: [Named]; var people: [Named]
        var hoursPerWorkday: Double; var coreHoursShare: Double; var backToBackShare: Double?; var callFreeDays: Int; var workdays: Int
        var itemsPerHour: Double; var decisionsPerHour: Double; var withOutcomesShare: Double?; var itemsMine: Int; var itemsOthers: Int
        var tasksMade: Int; var tasksDone: Int; var questionsPerHour: Double?; var cutInPerHour: Double?; var cutOffPerHour: Double?
        var oneOnOneShare: Double?; var groupShare: Double?; var trends: [Trend]; var cost: Double; var costParts: [Part]
    }

    public struct Card: Codable, Equatable, Sendable {
        var id: String; var title: String; var text: String; var callID: String; var date: Date; var at: Double?; var quote: String?
        var number: String?; var usual: String?; var say: String?; var why: String?; var question: String; var answers: [String]
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
        var version = ServerDigest.version; var made: Date; var findings: [Card]; var goal: Goal?; var learned: [Goal]; var ended: [Goal]; var notTaken: [Goal]
    }

    // MARK: The allowed fields

    /// The keys each level may have. A test fails when a part has any other key.
    public static let allowedKeys: [String: Set<String>] = [
        "series.root": ["version", "made", "series"],
        "series": ["id", "keys", "title", "schedule", "usualPeople", "line", "rows", "attendees", "stats", "openItems"],
        "name": ["name", "personID"],
        "row": ["callID", "start", "minutes", "plannedMinutes", "lateMinutes", "overMinutes", "ownerShare", "people", "headline", "notesOnly"],
        "attendee": ["name", "personID", "came", "of", "last", "share", "trend"],
        "stats": ["meetings", "since", "medianMinutes", "medianPlannedMinutes", "usualOverrun", "planned", "ranOver", "startedLate", "skipped",
                  "ownerShare", "talksMost"],
        "open": ["kind", "text", "owner", "callID", "at", "date"],
        "meetings.root": ["version", "made", "month", "meetings"],
        "meeting": ["callID", "title", "start", "duration", "byWords", "sentences", "speakers", "participation", "outcomes", "owners", "coach",
                    "screens", "standouts", "earlier", "cost"],
        "speaker": ["name", "personID", "isOwner", "seconds", "share", "turns", "wordsPerMinute", "fillersPerMinute", "questions", "cutIn", "cutOff",
                    "reply"],
        "owner": ["name", "tasks"],
        "cost": ["total", "transcription", "ai", "estimated"],
        "bookmarks.root": ["version", "made", "bookmarks"],
        "bookmark": ["callID", "title", "start", "at", "note", "speaker", "said"],
        "analytics.root": ["version", "made", "periods"],
        "period": ["days", "from", "to", "calls", "callSeconds", "averageSeconds", "callsPerDay", "talkShare", "scheduled", "unscheduled",
                   "valueHours", "topics", "people", "hoursPerWorkday", "coreHoursShare", "backToBackShare", "callFreeDays", "workdays",
                   "itemsPerHour", "decisionsPerHour", "withOutcomesShare", "itemsMine", "itemsOthers", "tasksMade", "tasksDone",
                   "questionsPerHour", "cutInPerHour", "cutOffPerHour", "oneOnOneShare", "groupShare", "trends", "cost", "costParts"],
        "named": ["name", "seconds"],
        "part": ["name", "dollars"],
        "trend": ["metric", "sentence", "usual"],
        "coach.root": ["version", "made", "findings", "goal", "learned", "ended", "notTaken"],
        "card": ["id", "title", "text", "callID", "date", "at", "quote", "number", "usual", "say", "why", "question", "answers"],
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

    // MARK: Making the parts

    /// Every part, each a shared payload to the owner's server. `personasInMCP`: the switch for other AI apps.
    public static func parts(_ tools: ChatTools, personasInMCP: Bool, cache: DigestCache? = nil) -> [SharedPayload] {
        let cache = cache ?? DigestCache(directory: nil)
        let now = tools.now
        var out: [SharedPayload] = []
        func add<T: Encodable>(_ key: String, _ make: (Date) -> T) {
            // `made` is when the content last changed: the same content keeps its date, so it is not sent again.
            let content = (try? JSONEncoder.callRecord.encode(make(.distantPast))) ?? Data()
            let made = cache.made(key, content: content, now: now)
            if let data = try? JSONEncoder.callRecord.encode(make(made)) { out.append(SharedPayload(kind: .digest, key: key, data: data)) }
        }
        let series = seriesList(tools)
        add("digest:series") { SeriesPart(made: $0, series: series) }
        let marks = bookmarks(tools)
        add("digest:bookmarks") { BookmarksPart(made: $0, bookmarks: marks) }
        let periods = analytics(tools, cache: cache)
        add("digest:analytics") { AnalyticsPart(made: $0, periods: periods) }
        let coach = coachPart(tools, personasInMCP: personasInMCP)
        add("digest:coach") { var c = coach; c.made = $0; return c }
        for (month, list) in Dictionary(grouping: tools.records, by: { month(of: $0.id) }) {
            // The coach's review is part of a meeting's numbers (its rating): a new review makes the month again.
            let review: (CallRecord) -> String = { r in
                let file = tools.paths?.callDirectory(r.id).appendingPathComponent("coach.json").path ?? ""
                return ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date).map { "\($0.timeIntervalSince1970)" } ?? ""
            }
            let meetings = cache.meetings(month, records: list, all: tools.records, review: review) { meetingNumbers($0, tools: tools, cache: cache) }
            add("digest:meetings-\(month)") { MeetingsPart(made: $0, month: month, meetings: meetings) }
        }
        cache.save()
        return out.sorted { $0.key < $1.key }
    }

    /// The recurring meetings from the meetings alone: no calendar, so no next date and no invite. A series that
    /// ended is left out, and leaves the server.
    static func seriesList(_ tools: ChatTools) -> [Series] {
        let all = SeriesCatalog.build(records: tools.records, upcoming: [], owner: tools.owner, directory: PersonDirectory(profiles: tools.profiles),
                                      ownerEmails: [tools.settings.ownerEmail], now: tools.now)
        let identity = tools.ownerIdentity
        let commitments = tools.paths.flatMap { CommitmentBook.peek(in: $0.commitments) }?.items
        let directory = tools.fullDirectory, refs = tools.saved
        func id(_ name: String) -> String? { refs.id(for: name).map(refs.canonical) }
        return all.filter { !$0.schedule.ended }.map { s in
            let report = SeriesReport(series: s, records: tools.records, commitments: commitments, owner: identity, directory: directory,
                                      ownerEmails: [tools.settings.ownerEmail])
            let rows = report.rows.prefix(historyRows).map {
                Series.Row(callID: $0.id, start: $0.start, minutes: $0.minutes, plannedMinutes: $0.plannedMinutes, lateMinutes: $0.lateMinutes,
                           overMinutes: $0.overMinutes, ownerShare: $0.ownerShare, people: $0.people, headline: $0.headline, notesOnly: $0.notesOnly)
            }
            let attendees = report.attendees.map { a in
                Series.Attendee(name: a.name, personID: id(a.name), came: a.came, of: a.of, last: a.last, share: a.share,
                                trend: a.trend == .joined ? "joined" : a.trend == .droppedOff ? "droppedOff" : "steady")
            }
            let stats = Series.Stats(meetings: report.meetings, since: report.since, medianMinutes: report.medianMinutes,
                                     medianPlannedMinutes: report.medianPlannedMinutes, usualOverrun: report.usualOverrun, planned: report.planned,
                                     ranOver: report.ranOver, startedLate: report.startedLate,
                                     skipped: report.gaps.flatMap { s.schedule.skippedText(gaps: $0) }, ownerShare: report.ownerShare, talksMost: report.talksMost)
            let open = report.openItems.map { i in
                Series.Open(kind: i.kind == .yourTask ? "yourTask" : i.kind == .actionItem ? "actionItem" : "pendingDecision", text: i.text, owner: i.owner,
                            callID: i.callID, at: i.at, date: i.date)
            }
            // The keys a point keeps (`savedKeys`): the id, the calendar ids, and the last meetings.
            return Series(id: s.id, keys: s.savedKeys, title: s.title, schedule: s.schedule.text(), usualPeople: s.usualPeople.map { Name(name: $0, personID: id($0)) },
                          line: report.line, rows: Array(rows), attendees: Array(attendees.prefix(listLimit)), stats: stats, openItems: Array(open.prefix(listLimit)))
        }.sorted { $0.id < $1.id }
    }

    static func bookmarks(_ tools: ChatTools) -> [Bookmark] {
        BookmarkIndex.groups(tools.records).flatMap { g in
            g.bookmarks.map { Bookmark(callID: g.callID, title: g.title, start: g.start, at: $0.offset, note: $0.note, speaker: $0.said?.speaker, said: $0.said?.text) }
        }.prefix(bookmarkLimit).map { $0 }
    }

    /// One meeting's Analytics tab, by `MeetingAnalytics` and the sentences of `MeetingFindings`.
    static func meetingNumbers(_ r: CallRecord, tools: ChatTools, cache: DigestCache) -> Meeting? {
        let usage = cache.usage(tools.paths)
        let a = MeetingAnalytics(record: r, owner: tools.owner, review: tools.paths.flatMap { CoachReview.load(in: $0.callDirectory(r.id)) },
                                 usage: usage.events.filter { $0.callID == r.id }, usageSince: usage.since, history: cache.facts(tools),
                                 value: { id in tools.paths.flatMap { CoachReview.load(in: $0.callDirectory(id))?.value?.rating } },
                                 people: tools.fullDirectory, commitments: [])
        guard !a.isEmpty else { return nil }
        var names: [String: String] = [:]
        for s in a.speakers where names[s.id] == nil { names[s.id] = s.isOwner ? "You" : s.name }
        func said(_ s: MeetingFindings.Sentence) -> String { (s.subject.map { (names[$0] ?? $0) + " " } ?? "") + s.text }
        return Meeting(callID: r.id, title: r.title, start: r.start, duration: a.duration, byWords: a.byWords,
                       sentences: [MeetingFindings.talk(a), MeetingFindings.flow(a), MeetingFindings.delivery(a)].compactMap { $0 }.map(said),
                       speakers: a.speakers.map { s in
                           Meeting.Speaker(name: s.name, personID: r.speakerPeople?[s.id], isOwner: s.isOwner, seconds: s.seconds, share: s.share,
                                           turns: a.byWords ? nil : s.turns, wordsPerMinute: s.wordsPerMinute, fillersPerMinute: s.fillersPerMinute,
                                           questions: s.questions, cutIn: s.interruptionsMade, cutOff: s.interruptionsReceived, reply: s.medianResponse)
                       },
                       participation: a.participation.map(MeetingFindings.participation), outcomes: a.outcomes.map(MeetingFindings.outcomes),
                       owners: a.outcomes?.owners.map { Meeting.Owner(name: $0.name, tasks: $0.tasks) } ?? [],
                       coach: a.coach.flatMap(MeetingFindings.coach), screens: a.screens.map { said(MeetingFindings.screens($0)) },
                       standouts: a.baselines.standouts.map { (($0.subject.map { (names[$0] ?? $0) + " " }) ?? "") + $0.text }, earlier: a.baselines.earlier,
                       cost: a.cost.map { Meeting.Cost(total: $0.total, transcription: $0.transcription, ai: $0.ai, estimated: $0.estimated) })
    }

    /// The Analytics page for the last 7, 30, 90, and 365 days, by `AnalyticsReport` and `CommunicationTrends`.
    static func analytics(_ tools: ChatTools, cache: DigestCache) -> [Period] {
        let paths = tools.paths
        let reviews = Dictionary(tools.records.compactMap { r in paths.flatMap { CoachReview.load(in: $0.callDirectory(r.id)) }.map { (r.id, $0) } },
                                 uniquingKeysWith: { a, _ in a })
        let commitments = paths.flatMap { CommitmentBook.peek(in: $0.commitments) }?.items ?? []
        let usage = cache.usage(paths).events
        let facts = cache.facts(tools)
        let end = Calendar.current.startOfDay(for: tools.now)
        return [7, 30, 90, 365].map { days in
            let interval = DateInterval(start: end.addingTimeInterval(-Double(days) * 86_400), end: end)
            let r = AnalyticsReport(records: tools.records, usage: usage, owner: tools.owner, interval: interval, reviews: reviews, commitments: commitments)
            let trends = CommunicationTrends(facts: facts, interval: interval).series(.all).map {
                Period.Trend(metric: CommunicationTrends.title($0.metric), sentence: $0.sentence, usual: $0.usualText)
            }
            return Period(days: days, from: interval.start, to: interval.end, calls: r.calls, callSeconds: r.callSeconds, averageSeconds: r.averageSeconds,
                          callsPerDay: r.callsPerDay, talkShare: r.talkShare, scheduled: r.scheduled.calls, unscheduled: r.unscheduled.calls,
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
    /// read, and trait cards only with the switch for other AI apps on.
    static func coachPart(_ tools: ChatTools, personasInMCP: Bool) -> CoachPart {
        let cards = tools.findingCards(traits: personasInMCP).map { c in
            Card(id: c.id, title: c.kind.title, text: c.text, callID: c.callID, date: c.date, at: c.at, quote: c.quote, number: c.number, usual: c.usual,
                 say: c.say, why: c.why, question: c.kind.question, answers: [c.kind.yes, c.kind.no])
        }
        let goals = tools.profile.goalHistory
        func hits(_ f: CoachFocus) -> String {
            "\(f.results.filter { $0.outcome == .hit }.count) of \(f.results.count) \(f.goal == nil ? "chances" : "1:1s at the target")"
        }
        func goal(_ f: CoachFocus, progress: Bool) -> Goal {
            let measured = progress && f.status == .active ? f.goal.flatMap { _ in GoalProgress(focus: f, facts: MeetingFactsCache().facts(for: tools.records, owner: tools.owner),
                                                                                              now: tools.now, people: tools.filterPeople)?.sentence } : nil
            return Goal(plan: f.plan, why: f.why.nonBlank, status: f.status.rawValue, target: f.goal?.targetText,
                        before: f.goal.map { "\($0.typicalText), \($0.usualText)" }, progress: measured, review: f.reviewDate,
                        results: f.results.reversed().map { r in
                            Goal.Result(date: r.date, outcome: f.goal != nil && r.outcome == .hit ? "At the target" : f.goal != nil && r.outcome == .missed ? "Over the target" : r.outcome.label,
                                        callID: r.callID, at: r.at, evidence: r.evidence)
                        }, date: f.updated, hits: hits(f))
        }
        return CoachPart(made: .distantPast, findings: tools.settings.coach ? cards : [], goal: goals.current.map { goal($0, progress: true) },
                         learned: goals.finished.map { goal($0, progress: false) }, ended: goals.ended.map { goal($0, progress: false) },
                         notTaken: goals.offered.map { goal($0, progress: false) })
    }
}

/// What the digest keeps on this Mac between syncs: when each part's content last changed, each month's meetings
/// with the stamp of what they were made from (a month is made again only when its meetings changed), and the
/// meetings' facts and the usage log for one run. Never synced.
public final class DigestCache: @unchecked Sendable {
    struct Month: Codable { var stamp: String; var meetings: [ServerDigest.Meeting] }
    struct File: Codable { var made: [String: Made] = [:]; var months: [String: Month] = [:] }
    struct Made: Codable { var hash: String; var date: Date }

    static let fileName = "digest-cache.json"
    private let url: URL?
    private let lock = NSLock()
    private var file: File
    private var factsMade: [MeetingFacts]?
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
    func meetings(_ month: String, records: [CallRecord], all: [CallRecord], review: (CallRecord) -> String = { _ in "" },
                  make: (CallRecord) -> ServerDigest.Meeting?) -> [ServerDigest.Meeting] {
        // What the numbers stand on: the month's records and reviews, and the meetings before them (the baselines).
        // A stable stamp across launches (Swift's Hasher is seeded per process).
        var text = ""
        let last = records.map(\.start).max() ?? .distantPast
        for r in all.sorted(by: { $0.id < $1.id }) where r.start <= last {
            text += "\(r.id)|\(r.end.timeIntervalSince1970)|\(r.utterances.count)|\(r.speakerNames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })\n"
        }
        for r in records.sorted(by: { $0.id < $1.id }) {
            text += "\(r.id)|\(r.markers.count)|\(r.markers.map { $0.note ?? "" })|\(r.tags)|\(r.title)|\(r.summary ?? "")|\(review(r))\n"
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

    func facts(_ tools: ChatTools) -> [MeetingFacts] {
        if let f = lock.withLock({ factsMade }) { return f }
        let f = MeetingFactsCache().facts(for: tools.records, owner: tools.owner)
        lock.withLock { factsMade = f }
        return f
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
