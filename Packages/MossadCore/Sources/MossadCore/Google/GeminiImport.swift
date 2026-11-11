import Foundation

/// Which Gemini notes become what, and what that costs. Pure: the calendar's events and the records in, the plan
/// out. Each document is imported once.
public enum GeminiImport {
    public enum Action: Equatable, Sendable {
        /// No recording of this meeting: a notes-only meeting is made.
        case create
        /// Mossad recorded it: the notes become its second source.
        case attach(callID: String)
    }

    public struct Item: Equatable, Sendable {
        public var event: CalendarEventInfo
        public var attachment: EventAttachment
        public var action: Action
        public var docID: String { attachment.fileID ?? "" }
    }

    /// Mossad's summary, tasks, and person traits of one meeting, at list prices.
    public static let costPerMeeting = 0.02
    /// The background check looks this far back, every `checkEvery`.
    public static let recentWindow: TimeInterval = 2 * 86_400
    public static let checkEvery: TimeInterval = 15 * 60
    /// Gemini attaches its notes a few minutes after a meeting ends.
    static let grace: TimeInterval = 10 * 60

    public static func plan(events: [CalendarEventInfo], records: [CallRecord], now: Date) -> [Item] {
        let imported = Set(records.compactMap { $0.gemini?.docID })
        let notesEvents = Set(records.filter(\.isNotesOnly).compactMap { $0.gemini?.eventID })
        var seen: Set<String> = []
        return events.sorted { $0.start > $1.start }.compactMap { e in
            guard !e.isAllDay, !e.declinedByOwner, e.end <= now.addingTimeInterval(-grace),
                  let a = GeminiNotes.attachment(in: e), let id = a.fileID, !imported.contains(id), seen.insert(id).inserted else { return nil }
            if let eventID = e.eventID, notesEvents.contains(eventID) { return nil }
            let recorded = records.filter { r in !r.isNotesOnly && r.status != .failed && isSameMeeting(r, e, now: now) }
            // The call still records or its record is being made: the next check decides.
            if recorded.contains(where: { $0.status == .recording }) { return nil }
            if let r = recorded.max(by: { overlap($0, e, now: now) < overlap($1, e, now: now) }) {
                return Item(event: e, attachment: a, action: .attach(callID: r.id))
            }
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

    /// The plan within the cap: the newest meetings first. An attach costs nothing.
    public static func capped(_ items: [Item], dollars: Double) -> [Item] {
        var room = Int((max(0, dollars) / costPerMeeting).rounded(.down))
        return items.filter { item in
            guard item.action == .create else { return true }
            guard room > 0 else { return false }
            room -= 1
            return true
        }
    }

    public static func estimate(_ items: [Item]) -> Double { Double(items.filter { $0.action == .create }.count) * costPerMeeting }

    /// What an import of old notes will do, in one or two sentences, for the owner and the log.
    public static func estimateLine(_ items: [Item], cap: Double) -> String {
        let creates = items.filter { $0.action == .create }.count, attaches = items.count - creates
        guard !items.isEmpty else { return "No meetings with Gemini notes to import." }
        let kept = capped(items, dollars: cap).filter { $0.action == .create }.count
        var parts = ["\(creates) \(creates == 1 ? "meeting" : "meetings") without a recording, \(attaches) recorded"]
        parts[0] += " \(attaches == 1 ? "meeting" : "meetings") with Gemini notes."
        parts.append("Mossad's summaries cost about \(money(estimate(items))).")
        if kept < creates { parts.append("The cap of \(money(cap)) allows \(kept).") }
        return parts.joined(separator: " ")
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
                       imported: now, notes: doc.notesText.map { String($0.prefix(20_000)) })
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

/// Reads the notes of a plan and hands each one to the pipeline: a notes-only meeting, or a second source. A
/// document that cannot be read now is tried again at the next check.
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

        public init(made: Int = 0, attached: Int = 0, failed: Int = 0) {
            self.made = made
            self.attached = attached
            self.failed = failed
        }
    }

    /// The events of the owner's Google calendar in the window, the declined ones left out by the plan.
    public func events(from: Date, to: Date) async -> [CalendarEventInfo]? {
        await GoogleCalendarSource(session: session).page(from: from, to: to)?.events
    }

    public func run(_ items: [GeminiImport.Item], ownerName: String, ownerNames: [String], now: @Sendable () -> Date = Date.init) async -> Outcome {
        var outcome = Outcome()
        for item in items {
            let doc: GeminiDoc
            do { doc = try GeminiDoc.parse(try await session.get(GeminiDoc.url(documentID: item.docID), scope: .docs)) } catch {
                Log.error("Gemini notes: a document was not read (\(GoogleError.from(error).logText))")
                outcome.failed += 1
                continue
            }
            switch item.action {
            case .attach(let callID):
                if await pipeline.attachNotes(callID: callID, GeminiImport.reference(item, doc: doc, now: now())) { outcome.attached += 1 }
            case .create:
                let record = GeminiImport.record(item, doc: doc, id: freeID(GeminiImport.callID(for: item.event)), ownerName: ownerName,
                                                 ownerNames: ownerNames, now: now())
                if await pipeline.importNotes(record) { outcome.made += 1 }
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
