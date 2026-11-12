import Foundation

/// Which Gemini notes become what, and what that costs. Pure: the calendar's events and the records in, the plan
/// out. Each document is imported once.
public enum GeminiImport {
    public enum Action: Equatable, Sendable {
        /// No recording of this meeting: a notes-only meeting is made.
        case create
        /// Mossad recorded it: the notes become its second source.
        case attach(callID: String)
        /// A notes-only meeting was made, and a recording of the same meeting came later: the notes move to the
        /// recording and the notes-only meeting goes, so the meeting is there once.
        case move(notesID: String, callID: String)
    }

    public struct Item: Equatable, Sendable {
        public var event: CalendarEventInfo
        public var attachment: EventAttachment
        public var action: Action
        public var docID: String { attachment.fileID ?? "" }
    }

    /// The list price of Mossad's summary and tasks for one meeting with Claude's default model, when the chosen
    /// model's price is not known.
    public static let costPerMeeting = 0.02
    /// The background check looks back at least this far, and to the last good check when that is longer.
    public static let recentWindow: TimeInterval = 2 * 86_400
    /// The longest look back of the background check, after a long time with the Mac closed.
    public static let longestWindow: TimeInterval = 30 * 86_400
    public static let checkEvery: TimeInterval = 15 * 60
    /// Gemini attaches its notes a few minutes after a meeting ends.
    static let grace: TimeInterval = 10 * 60
    /// A transcript with no end line is read only after this, in case Gemini still writes it.
    static let unfinishedWait: TimeInterval = 60 * 60

    /// Where the background check starts: the last good check less an hour, at least 2 days back, at most 30.
    public static func windowStart(lastGood: Date?, now: Date) -> Date {
        let least = now.addingTimeInterval(-recentWindow), most = now.addingTimeInterval(-longestWindow)
        guard let lastGood else { return least }
        return max(most, min(least, lastGood.addingTimeInterval(-3600)))
    }

    /// `noRecord` is the owner's do-not-record list: a meeting it covers gets no notes either. `removed` holds the
    /// event and document ids of notes-only meetings that the owner deleted: they never come back.
    /// `deleted` holds the meetings the owner deleted or skipped, matched by time and title or meeting code.
    public static func plan(events: [CalendarEventInfo], records: [CallRecord], now: Date, noRecord: NoRecordBook = NoRecordBook(),
                            removed: Set<String> = [], deleted: [RemovedNotes.Mark] = []) -> [Item] {
        let imported = Set(records.compactMap { $0.gemini?.docID })
        let notes = records.filter(\.isNotesOnly)
        var seen: Set<String> = []
        return events.sorted { $0.start > $1.start }.compactMap { e in
            guard !e.isAllDay, !e.declinedByOwner, e.end <= now.addingTimeInterval(-grace),
                  let a = GeminiNotes.attachment(in: e), let id = a.fileID, seen.insert(id).inserted else { return nil }
            if removed.contains(id) || e.eventID.map(removed.contains) == true { return nil }
            if noRecord.excludesNotes(of: e) { return nil }
            // A meeting the owner deleted or skipped stays gone.
            if deleted.contains(where: { $0.covers(e) }) { return nil }
            // A failed recording still has its audio: it is this meeting's recording.
            let recorded = records.filter { r in !r.isNotesOnly && isSameMeeting(r, e, now: now) }
            // The call still records or its record is being made: the next check decides.
            if recorded.contains(where: { $0.status == .recording }) { return nil }
            // The notes-only meeting of this very event: its event id, or its time. A document on two events (a series)
            // is not proof that it is this one.
            let madeFromNotes = notes.first { r in
                (e.eventID != nil && r.gemini?.eventID == e.eventID) || (r.gemini?.eventID == nil && r.gemini?.docID == id && overlap(r, e, now: now) > 0)
            }
            if let r = recorded.max(by: { overlap($0, e, now: now) < overlap($1, e, now: now) }) {
                guard r.gemini == nil else { return nil }
                if let madeFromNotes { return Item(event: e, attachment: a, action: .move(notesID: madeFromNotes.id, callID: r.id)) }
                return imported.contains(id) ? nil : Item(event: e, attachment: a, action: .attach(callID: r.id))
            }
            guard madeFromNotes == nil, !imported.contains(id) else { return nil }
            return Item(event: e, attachment: a, action: .create)
        }
    }

    static func overlap(_ r: CallRecord, _ e: CalendarEventInfo, now: Date) -> TimeInterval {
        let end = r.status == .recording ? now : r.end
        return min(end, e.end).timeIntervalSince(max(r.start, e.start))
    }

    /// A recording of this event: it overlaps the event, and it ran on the event's link or took the event's invite.
    static func isSameMeeting(_ r: CallRecord, _ e: CalendarEventInfo, now: Date) -> Bool {
        guard overlap(r, e, now: now) > 0 else { return false }
        if r.calendarTitle?.caseInsensitiveCompare(e.title) == .orderedSame { return true }
        return CalendarMatcher.bestEvent(for: r.platform, meetingID: r.meetingID, start: r.start, end: r.status == .recording ? now : r.end, in: [e]) != nil
    }

    /// Whether the document is ready: a transcript has its end line, or the meeting ended an hour ago. Gemini can
    /// attach the document before it is complete.
    public static func isReady(_ doc: GeminiDoc, event: CalendarEventInfo, now: Date) -> Bool {
        doc.tab("Transcript") == nil || doc.transcriptEnded || now >= event.end.addingTimeInterval(unfinishedWait)
    }

    /// The estimated cost of one new meeting: the chosen model's summary and tasks for the planned length (at least a
    /// quarter hour); `costPerMeeting` when the model's price is not known (`perHour` nil).
    static func cost(_ item: Item, perHour: Double?) -> Double {
        guard item.action == .create else { return 0 }
        guard let perHour else { return costPerMeeting }
        return perHour * max(0.25, item.event.end.timeIntervalSince(item.event.start) / 3600)
    }

    /// The price of an hour of meeting for the requests that follow an import: the summary and the task list (the
    /// notes part of `HourCost`). Nil when the model's price is not known.
    public static func perHour(_ cost: HourCost) -> Double? { cost.parts.first { $0.kind == .notes }?.amount }

    static func cents(_ d: Double) -> Int { Int((d * 100).rounded()) }

    /// The plan within the cap: the newest meetings first, as long as their estimates fit. Counted in cents.
    public static func capped(_ items: [Item], dollars: Double, perHour: Double? = nil) -> [Item] {
        var room = cents(max(0, dollars))
        return items.filter { item in
            let c = cents(cost(item, perHour: perHour))
            guard c <= room else { return false }
            room -= c
            return true
        }
    }

    public static func estimate(_ items: [Item], perHour: Double? = nil) -> Double { items.reduce(0) { $0 + cost($1, perHour: perHour) } }

    /// What an import of old notes will do, in one or two sentences, for the owner and the log. `complete` false
    /// says that the calendar read stopped at its limit.
    public static func estimateLine(_ items: [Item], cap: Double, perHour: Double? = nil, complete: Bool = true) -> String {
        let creates = items.filter { $0.action == .create }.count, linked = items.count - creates
        let short = complete ? "" : " The calendar had more events than Mossad reads at once: choose a shorter time."
        guard !items.isEmpty else { return "No meetings with Gemini notes to import." + short }
        let kept = capped(items, dollars: cap, perHour: perHour).filter { $0.action == .create }.count
        var parts = ["\(creates) \(creates == 1 ? "meeting" : "meetings") without a recording, \(linked) recorded \(linked == 1 ? "meeting" : "meetings") with Gemini notes."]
        let total = estimate(items, perHour: perHour)
        switch perHour {
        case 0?: parts.append("The summaries are free with this model.")
        case nil: parts.append("The price of this model is not known; at Claude's prices the summaries and task lists cost about \(money(total)).")
        default: parts.append("Mossad's summaries and task lists cost about \(money(total)).")
        }
        // The reads of how people think follow later, within their own monthly budget.
        if creates > 0 { parts.append("The reads of how people think keep to their own budget.") }
        if kept < creates { parts.append("The cap of \(money(cap)) allows \(kept).") }
        return parts.joined(separator: " ") + short
    }

    static func money(_ d: Double) -> String { String(format: "$%.2f", d) }

    /// Whether the background check runs now: not while a call records, and every 15 minutes.
    public static func isDue(last: Date?, now: Date, recording: Bool) -> Bool {
        guard !recording else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= checkEvery
    }

    // MARK: The meeting

    /// The id of a notes-only meeting: the date of its start like a recording's, with "-notes".
    public static func callID(for event: CalendarEventInfo) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: event.start) + "-notes"
    }

    /// The reference kept on the record.
    public static func reference(_ item: Item, doc: GeminiDoc, now: Date) -> GeminiNotesRef {
        GeminiNotesRef(docID: item.docID, title: doc.title.nonBlank ?? item.attachment.title, url: item.attachment.url, eventID: item.event.eventID,
                       // Gemini's own text only for a meeting made from it; a recording keeps the link.
                       imported: now, notes: item.action == .create ? doc.notesText.map { String($0.prefix(20_000)) } : nil)
    }

    /// A meeting made from the notes: the invite, the transcript with names, and the step after the voices, so the
    /// pipeline writes the summary, the note, and what follows. The owner's lines are on the mic track with the
    /// owner's name, as in a recording; everyone else is on the call track with the name Gemini wrote.
    public static func record(_ item: Item, doc: GeminiDoc, id: String, ownerName: String, ownerNames: [String], now: Date) -> CallRecord {
        let e = item.event
        let platform = e.meetingLink.flatMap { UpcomingMeeting.callLink(in: $0.absoluteString).0 } ?? UpcomingMeeting.callLink(in: e.text).0 ?? .meet
        var r = CallRecord(id: id, platform: platform, bundleID: "", start: e.start, end: e.end, status: .identified)
        r.setInvite(e)
        r.source = CallRecord.geminiNotesSource
        r.gemini = reference(item, doc: doc, now: now)
        r.meetingID = e.meetingLink.flatMap { meetCode($0) } ?? meetCode(in: e.text)
        let owner = Set((ownerNames + [ownerName] + [e.ownEntry?.name].compactMap { $0 }).map(PersonNames.nameKey).filter { !$0.isEmpty })
        var labels: [String: String] = [:]
        var next = 0
        r.utterances = doc.transcript.map { line in
            let isOwner = owner.contains(PersonNames.nameKey(line.name))
            let key = isOwner ? "me:A" : labels[line.name].map { "them:\($0)" } ?? {
                let label = SpeakerLetter.at(next)
                next += 1
                labels[line.name] = label
                return "them:\(label)"
            }()
            r.speakerNames[key] = isOwner ? ownerName : line.name
            return Utterance(track: isOwner ? .me : .them, speakerLabel: String(key.split(separator: ":")[1]), start: line.start, end: line.end, text: line.text)
        }
        // A meeting whose lines run past the invite's end ran over.
        if let last = r.utterances.last?.end, e.start.addingTimeInterval(last) > r.end { r.end = e.start.addingTimeInterval(last) }
        return r
    }

    /// The Meet code of a link: "abc-defg-hij".
    static func meetCode(_ url: URL) -> String? { meetCode(in: url.absoluteString) }

    static func meetCode(in text: String) -> String? {
        guard let range = text.range(of: #"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range].split(separator: "/").last ?? "").lowercased()
    }
}

/// Reads the notes of a plan and hands each one to the pipeline: a notes-only meeting, a second source, or a move
/// to a recording that came later. A document that cannot be read now, or is not complete yet, is tried again at the
/// next check.
public struct GeminiRunner: Sendable {
    let session: GoogleSession
    let pipeline: Pipeline
    let paths: Paths

    public init(session: GoogleSession, pipeline: Pipeline, paths: Paths) {
        self.session = session
        self.pipeline = pipeline
        self.paths = paths
    }

    public struct Outcome: Equatable, Sendable {
        public var made = 0
        public var attached = 0
        public var failed = 0
        /// Stopped before the end: a call started, or the cap was reached.
        public var stopped = false
        /// The meetings made, for what they cost.
        public var madeIDs: [String] = []

        public init(made: Int = 0, attached: Int = 0, failed: Int = 0, stopped: Bool = false) {
            self.made = made
            self.attached = attached
            self.failed = failed
            self.stopped = stopped
        }
    }

    /// The events of the owner's Google calendar in the window, read in parts of 30 days so each part stays within
    /// the page limit. Nil when a part could not be read; `complete` false when a part stopped at its limit.
    public func events(from: Date, to: Date) async -> (events: [CalendarEventInfo], complete: Bool)? {
        let source = GoogleCalendarSource(session: session)
        var all: [CalendarEventInfo] = [], complete = true
        var start = from
        while start < to {
            let end = min(to, start.addingTimeInterval(30 * 86_400))
            guard let page = await source.page(from: start, to: end) else { return nil }
            all += page.events.filter { e in !all.contains { $0.eventID != nil && $0.eventID == e.eventID } }
            complete = complete && page.complete
            start = end
        }
        return (all, complete)
    }

    /// `isLive` stops the run between two meetings while a call records. `spent` is what the imported meetings cost
    /// so far; the run stops when it reaches `cap`.
    public func run(_ items: [GeminiImport.Item], ownerName: String, ownerNames: [String], now: @Sendable () -> Date = Date.init,
                    isLive: @Sendable () async -> Bool = { false }, spent: @Sendable ([String]) -> Double = { _ in 0 },
                    cap: Double? = nil) async -> Outcome {
        var outcome = Outcome()
        var made: [String] = []
        for item in items {
            if await isLive() { outcome.stopped = true; break }
            if let cap, item.action == .create, spent(made) >= cap { outcome.stopped = true; break }
            let doc: GeminiDoc
            do { doc = try GeminiDoc.parse(try await session.get(GeminiDoc.url(documentID: item.docID), scope: .docs)) } catch {
                Log.error("Gemini notes: a document was not read (\(GoogleError.from(error).logText))")
                outcome.failed += 1
                continue
            }
            switch item.action {
            case .attach(let callID):
                if await pipeline.attachNotes(callID: callID, GeminiImport.reference(item, doc: doc, now: now())) { outcome.attached += 1 }
            case .move(let notesID, let callID):
                if await pipeline.moveNotes(from: notesID, to: callID) { outcome.attached += 1 }
            case .create:
                guard GeminiImport.isReady(doc, event: item.event, now: now()) else { continue }
                let record = GeminiImport.record(item, doc: doc, id: freeID(GeminiImport.callID(for: item.event)), ownerName: ownerName,
                                                 ownerNames: ownerNames, now: now())
                if await pipeline.importNotes(record) {
                    outcome.made += 1
                    made.append(record.id)
                    outcome.madeIDs.append(record.id)
                }
            }
        }
        return outcome
    }

    func freeID(_ base: String) -> String {
        var id = base, n = 2
        while FileManager.default.fileExists(atPath: paths.callDirectory(id).path) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }
}

/// The meetings that the owner deleted or skipped: their Gemini notes are never imported or billed again. A
/// notes-only meeting by its event id and document id; a recording, deleted or skipped, also by its time, title,
/// and meeting code, so the plan finds its event by the rule of `GeminiImport.isSameMeeting`. On this Mac only
/// (`Google/removed-notes.json`).
public struct RemovedNotes: Codable, Equatable, Sendable {
    /// A meeting that is gone, as the plan matches it to an event.
    public struct Mark: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var title: String?
        public var meetingID: String?
        public var platform: Platform

        public init(start: Date, end: Date, title: String?, meetingID: String?, platform: Platform) {
            self.start = start
            self.end = end
            self.title = title
            self.meetingID = meetingID
            self.platform = platform
        }

        /// Whether this is the meeting of the event.
        public func covers(_ e: CalendarEventInfo) -> Bool {
            var r = CallRecord(id: "", platform: platform, bundleID: "", start: start, end: end, status: .written)
            r.calendarTitle = title
            r.meetingID = meetingID
            return GeminiImport.isSameMeeting(r, e, now: end)
        }
    }

    public var ids: Set<String> = []
    public var meetings: [Mark] = []

    public init(ids: Set<String> = [], meetings: [Mark] = []) {
        self.ids = ids
        self.meetings = meetings
    }

    enum CodingKeys: String, CodingKey { case ids, meetings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try c.decodeIfPresent(Set<String>.self, forKey: .ids) ?? []
        meetings = try c.decodeIfPresent([Mark].self, forKey: .meetings) ?? []
    }

    public static func url(_ paths: Paths) -> URL { paths.root.appendingPathComponent("Google").appendingPathComponent("removed-notes.json") }

    public static func load(_ paths: Paths) -> RemovedNotes {
        (try? Data(contentsOf: url(paths))).flatMap { try? JSONDecoder.callRecord.decode(RemovedNotes.self, from: $0) } ?? RemovedNotes()
    }

    /// The mark of a meeting the owner deleted or skipped. A recording keeps no notes, so the owner's delete holds.
    public static func mark(_ r: CallRecord, end: Date? = nil) -> (ids: Set<String>, mark: Mark?) {
        var ids: Set<String> = []
        if let g = r.gemini {
            ids.insert(g.docID)
            if let event = g.eventID { ids.insert(event) }
        }
        let mark = r.isNotesOnly ? nil : Mark(start: r.start, end: max(end ?? r.end, r.start.addingTimeInterval(60)), title: r.calendarTitle,
                                              meetingID: r.meetingID, platform: r.platform)
        return (ids, mark)
    }

    /// Adds the mark of a deleted or skipped meeting. `end` is for a call that was skipped while it ran.
    public static func add(_ r: CallRecord, end: Date? = nil, paths: Paths) {
        let (newIDs, mark) = Self.mark(r, end: end)
        guard !newIDs.isEmpty || mark != nil else { return }
        var book = load(paths)
        book.ids.formUnion(newIDs)
        if let mark { book.meetings.append(mark) }
        // Marks older than the longest look back of "Old notes" match nothing.
        book.meetings.removeAll { $0.end < Date().addingTimeInterval(-400 * 86_400) }
        do {
            try FileManager.default.createDirectory(at: url(paths).deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.callRecord.encode(book).write(to: url(paths), options: .atomic)
        } catch {
            Log.error("Gemini notes: the list of deleted meetings was not saved: \(error)")
        }
    }
}
