import Foundation

/// After a meeting is written: which of the owner's open points it talked about. One request to the chosen
/// provider for the meeting. A point is discussed only with a quote that code finds in the transcript; the model's
/// word alone is not proof. Every other point stays open and is carried to the next meeting.
public struct NextTimeChecker: Sendable {
    /// What the check found for one point.
    public struct Found: Sendable, Equatable {
        public var point: UUID
        public var at: TimeInterval
        public var quote: String
    }

    private let llm: any LanguageModel

    public init(llm: any LanguageModel) { self.llm = llm }

    static var schema: [String: Any] {
        Schema.object(["points": Schema.array(Schema.object([
            "point": Schema.string, "discussed": ["type": "boolean"], "quote": Schema.nullableString,
        ]))])
    }

    /// The points that the meeting talked about, each with its verified line. No request without points or words.
    public func check(_ points: [NextTimePoint], in r: CallRecord) async throws -> [Found] {
        guard !points.isEmpty, !r.utterances.isEmpty else { return [] }
        let handles = Dictionary(uniqueKeysWithValues: points.enumerated().map { ("P\($0.offset + 1)", $0.element) })
        let list = points.enumerated().map { "P\($0.offset + 1): \($0.element.text)" }.joined(separator: "\n")
        let system = """
        The owner of these notes wrote points to raise in a meeting. For each point, say whether the meeting talked \
        about it. A point counts as discussed only when the transcript has a line where its subject was really \
        talked about; a word in passing is not enough. For a discussed point, quote the exact words of that line \
        (at least six words, copied as they are). When you are not sure, say not discussed. Return every point once.
        """
        let out = try await llm.json(system: system, user: "## Points\n\(list)\n\n## Transcript\n" + MarkdownWriter.transcript(r, screens: false),
                                     schema: Self.schema, effort: .low, purpose: .summary, as: Output.self)
        var found: [Found] = []
        for item in out.points where item.discussed {
            guard let p = handles[item.point], let quote = item.quote?.nonBlank, let match = Self.line(quoting: quote, in: r.utterances),
                  !found.contains(where: { $0.point == p.id }) else { continue }
            // The words as the transcript has them, never the model's.
            found.append(Found(point: p.id, at: match.line.start, quote: match.quote))
        }
        return found
    }

    /// A quote counts with this many words or more, as the prompt asks.
    static let quoteWords = 6

    /// The line that holds every word of the quote, in order and on word limits, with those words as the line
    /// has them. Nil otherwise: a paraphrase or a quote with a made-up end is not proof.
    static func line(quoting quote: String, in lines: [Utterance]) -> (line: Utterance, quote: String)? {
        for line in Transcript.interleaved(lines) {
            if let words = words(quoting: quote, in: line.text) { return (line, words) }
        }
        return nil
    }

    /// The quote's words as `text` has them, when every word of the quote is there in order and on word limits,
    /// and the quote has `quoteWords` words or more. The after-call check and the live check use this one rule.
    static func words(quoting quote: String, in text: String) -> String? {
        func norm(_ word: Substring) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = quote.split(whereSeparator: \.isWhitespace).map(norm).filter { !$0.isEmpty }
        guard wanted.count >= quoteWords else { return nil }
        let raw = text.split(whereSeparator: \.isWhitespace)
        let pairs = raw.enumerated().map { ($0.offset, norm($0.element)) }.filter { !$0.1.isEmpty }
        guard pairs.count >= wanted.count else { return nil }
        for start in 0...(pairs.count - wanted.count) where (0..<wanted.count).allSatisfy({ pairs[start + $0].1 == wanted[$0] }) {
            let first = pairs[start].0, last = pairs[start + wanted.count - 1].0
            var words = raw[first...last].map(String.init)
            // Leading and trailing marks belong to the sentence around the quote.
            words[0] = String(words[0].drop { !$0.isLetter && !$0.isNumber })
            words[words.count - 1] = String(words[words.count - 1].reversed().drop { !$0.isLetter && !$0.isNumber }.reversed())
            return words.joined(separator: " ")
        }
        return nil
    }

    private struct Output: Decodable {
        let points: [Item]
        struct Item: Decodable {
            let point: String
            let discussed: Bool
            let quote: String?
        }
    }
}

/// Which points a written meeting is checked for, and what the check changes. Pure.
public enum NextTimeRules {
    /// The open points that `r` can settle: its series' points and the points for a person who spoke in it, each
    /// saved before the meeting ended (a point added during it is read only against the lines after it, in
    /// `apply`). A point the owner reopened from this meeting is left out.
    public static func points(for r: CallRecord, in book: NextTimeBook, series: MeetingSeries?, people: PersonReferences) -> [NextTimePoint] {
        let spoke = Set((r.speakerPeople ?? [:]).values.map(people.canonical))
            .union(r.speakerNames.values.compactMap { people.id(for: $0) })
        return book.visible.filter { p in
            guard p.isOpen, p.created < r.end, !(p.reopened ?? []).contains(r.id) else { return false }
            if let s = series, p.seriesID != nil, p.belongs(to: s) { return true }
            if p.seriesID == nil, let id = p.personID { return spoke.contains(people.canonical(id)) }
            return false
        }
    }

    /// A meeting the owner missed: a notes-only meeting in which the owner is not known to be there
    /// (`CallRecord.ownerPresent`, the rule that keeps it out of the owner's hours and "last met"). A recording is
    /// one the owner attended: Mossad records the owner's own call.
    public static func ownerMissed(_ r: CallRecord) -> Bool { r.isNotesOnly && r.ownerPresent != true }

    /// Marks the found points discussed in `r`, and carries the rest of `checked` to the next meeting. In a
    /// meeting the owner missed, nothing closes and nothing is carried: a found point gets a mention and stays open.
    /// `rejected` are the live marks the owner answered with "Not raised": their lines never close the point.
    /// A point added during the meeting is found only in a line said after it existed, and is never carried by it.
    public static func apply(_ found: [NextTimeChecker.Found], checked: [NextTimePoint], call r: CallRecord, to book: inout NextTimeBook, at date: Date,
                             rejected: [LivePointMarks.Mark] = []) {
        let missed = ownerMissed(r)
        for p in checked {
            let since = p.created > r.start ? p.created.timeIntervalSince(r.start) : nil
            let usable = found.first { f in
                f.point == p.id && since.map { f.at > $0 } != false
                    && !rejected.contains { isRejected(f, by: $0, lines: r.utterances) }
            }
            if let f = usable {
                if missed {
                    book.mention(p.id, .init(callID: r.id, at: f.at, quote: f.quote, date: r.start), at: date)
                } else {
                    book.update(p.id, at: date) { $0.done = NextTimePoint.Discussed(callID: r.id, at: f.at, quote: f.quote, date: date, byOwner: false) }
                }
            } else if !missed, since == nil, !(p.carried ?? []).contains(r.id), p.seriesID != nil {
                // A person's point waits for a meeting with them; it is not "carried" by a meeting of no series.
                book.update(p.id, at: date) { $0.carried = ($0.carried ?? []) + [r.id] }
            }
        }
        book.checked.insert(r.id)
    }

    /// The live times and the final ones differ by a few seconds: a found line this close to a rejected one, or
    /// one that holds the rejected words, is the line the owner rejected.
    static let rejectedNear: TimeInterval = 30

    static func isRejected(_ f: NextTimeChecker.Found, by m: LivePointMarks.Mark, lines: [Utterance]) -> Bool {
        guard f.point == m.point else { return false }
        if abs(f.at - m.at) <= rejectedNear { return true }
        let line = lines.first { $0.start == f.at }?.text ?? f.quote
        return NextTimeChecker.words(quoting: m.quote, in: line) != nil
    }

    /// A meeting older than this is not checked: a point is about the next meetings, not the old ones.
    static let pendingDays = 60.0

    /// The written meetings still to check, oldest first: after the first open point was made, in the last
    /// `pendingDays`, and not yet checked.
    public static func pending(_ records: [CallRecord], book: NextTimeBook, now: Date = Date()) -> [CallRecord] {
        guard let first = book.visible.filter(\.isOpen).map(\.created).min() else { return [] }
        let since = max(first, now.addingTimeInterval(-pendingDays * 86_400))
        // By its end: a point added during a meeting is checked against it.
        return records.filter { $0.status == .written && $0.end > since && !book.checked.contains($0.id) }.sorted { $0.start < $1.start }
    }
}

/// Checks each written meeting once for the owner's points, oldest first. Never while a call records: the app
/// asks `recording` before each meeting.
public actor NextTimeRunner {
    private let paths: Paths
    private let checker: NextTimeChecker
    private let now: @Sendable () -> Date

    public init(paths: Paths, checker: NextTimeChecker, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.checker = checker
        self.now = now
    }

    /// Returns how many meetings were checked. The runner reads the records from disk and makes the catalog from
    /// them, so a meeting written a moment ago is in its series. `upcoming` are the calendar's invites.
    @discardableResult
    public func run(upcoming: [UpcomingMeeting], owner: String, directory: PersonDirectory, ownerEmails: [String] = [], aliases: [String: String] = [:],
                    recording: @escaping @Sendable () async -> Bool) async -> Int {
        guard !StoredFile.awaitsMerge(paths.nextTime.appendingPathComponent(NextTimeBook.fileName)),
              let start = try? NextTimeBook.load(from: paths.nextTime) else { return 0 }
        let records = ProcessingQueue(paths: paths).allRecords()
        let pending = NextTimeRules.pending(records, book: start, now: now())
        guard !pending.isEmpty else { return 0 }
        let series = SeriesCatalog.build(records: records, upcoming: upcoming, owner: owner, directory: directory, ownerEmails: ownerEmails, aliases: aliases)
        let people = PersonReferences(people: PeopleStore.peek(in: paths.people) ?? [])
        var ledger = RetryLedger.load(from: paths.nextTime)
        var checked = 0
        for r in pending {
            if await recording() { return checked }
            guard let book = try? NextTimeBook.load(from: paths.nextTime) else { return checked }
            let points = NextTimeRules.points(for: r, in: book, series: SeriesCatalog.series(ofCall: r.id, in: series), people: people)
            // Nothing to check, or no words: no request, and the meeting is not marked as checked.
            guard !points.isEmpty, !r.utterances.isEmpty else { continue }
            switch ledger.state(r.id, now: now()) {
            case .gaveUp: continue
            case .waiting: return checked
            case .ready: break
            }
            do {
                let found = try await UsageContext.$callID.withValue(r.id) { try await checker.check(points, in: r) }
                // The marks made during the call: a line the owner rejected never closes its point.
                let marks = LivePointMarks.load(from: paths.callDirectory(r.id))
                // Read again: the owner may have changed a point while the request ran.
                try NextTimeBook.change(in: paths.nextTime) {
                    NextTimeRules.apply(found, checked: points, call: r, to: &$0, at: now(), rejected: marks?.rejected ?? [])
                }
                checked += 1
                if ledger.entries[r.id] != nil { ledger.clear(r.id); ledger.save(to: paths.nextTime) }
                let missed = NextTimeRules.ownerMissed(r)
                Log.info("Next time: \(found.count) of \(points.count) points \(missed ? "came up while the owner was out" : "discussed") in \(r.id)")
                // The marks made during the call were provisional: this check is the truth.
                if let marks, !marks.marks.isEmpty {
                    let result = LivePointRules.reconcile(marks, found: found, checked: points)
                    Log.info("Next time: live marks in \(r.id): \(result.confirmed.count) confirmed, \(result.unsupported.count) not in the final transcript")
                }
            } catch {
                guard !RetryLedger.isUnbilled(error), !(error is UnreadableFile), !(error is NewerFile) else {
                    Log.error("Checking the points in \(r.id) waits: \(error)")
                    return checked
                }
                ledger.fail(r.id, reason: Pipeline.failureReason(error), now: now())
                ledger.save(to: paths.nextTime)
                Log.error("Checking the points in \(r.id) failed: \(error)")
                return checked
            }
        }
        return checked
    }
}
