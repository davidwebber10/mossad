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
            guard let p = handles[item.point], let quote = item.quote?.nonBlank, let line = Self.line(quoting: quote, in: r.utterances),
                  !found.contains(where: { $0.point == p.id }) else { continue }
            found.append(Found(point: p.id, at: line.start, quote: quote))
        }
        return found
    }

    /// A quote counts with this many words or more.
    static let quoteWords = 4

    /// The line that holds the quote's first words, or nil: a paraphrase is not proof.
    static func line(quoting quote: String, in lines: [Utterance]) -> Utterance? {
        func norm(_ s: String) -> String {
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
                .split(separator: " ").joined(separator: " ")
        }
        let words = norm(quote).split(separator: " ")
        guard words.count >= quoteWords else { return nil }
        let q = words.prefix(8).joined(separator: " ")
        return Transcript.interleaved(lines).first { norm($0.text).contains(q) }
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
    /// saved before the meeting began. A point the owner reopened from this meeting is left out.
    public static func points(for r: CallRecord, in book: NextTimeBook, series: MeetingSeries?, people: PersonReferences) -> [NextTimePoint] {
        let spoke = Set((r.speakerPeople ?? [:]).values.map(people.canonical))
            .union(r.speakerNames.values.compactMap { people.id(for: $0) })
        return book.visible.filter { p in
            guard p.isOpen, p.created < r.start, !(p.reopened ?? []).contains(r.id) else { return false }
            if let s = series, p.seriesID != nil, p.belongs(to: s) { return true }
            if p.seriesID == nil, let id = p.personID { return spoke.contains(people.canonical(id)) }
            return false
        }
    }

    /// Marks the found points discussed in `r`, and carries the rest of `checked` to the next meeting.
    public static func apply(_ found: [NextTimeChecker.Found], checked: [NextTimePoint], call r: CallRecord, to book: inout NextTimeBook, at date: Date) {
        for p in checked {
            if let f = found.first(where: { $0.point == p.id }) {
                book.update(p.id, at: date) { $0.done = NextTimePoint.Discussed(callID: r.id, at: f.at, quote: f.quote, date: date, byOwner: false) }
            } else if !(p.carried ?? []).contains(r.id), p.seriesID != nil {
                // A person's point waits for a meeting with them; it is not "carried" by a meeting of no series.
                book.update(p.id, at: date) { $0.carried = ($0.carried ?? []) + [r.id] }
            }
        }
        book.checked.insert(r.id)
    }

    /// The written meetings still to check, oldest first: after the first point was made, and not yet checked.
    public static func pending(_ records: [CallRecord], book: NextTimeBook) -> [CallRecord] {
        guard let first = book.visible.map(\.created).min() else { return [] }
        return records.filter { $0.status == .written && $0.start > first && !book.checked.contains($0.id) }.sorted { $0.start < $1.start }
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

    /// Returns how many meetings changed a point. `series` are the recurring meetings of now.
    @discardableResult
    public func run(records: [CallRecord], series: [MeetingSeries], recording: @escaping @Sendable () async -> Bool) async -> Int {
        guard !StoredFile.awaitsMerge(paths.nextTime.appendingPathComponent(NextTimeBook.fileName)),
              let start = try? NextTimeBook.load(from: paths.nextTime) else { return 0 }
        let people = PersonReferences(people: PeopleStore.peek(in: paths.people) ?? [])
        var ledger = RetryLedger.load(from: paths.nextTime)
        var changed = 0
        for r in NextTimeRules.pending(records, book: start) {
            if await recording() { return changed }
            switch ledger.state(r.id, now: now()) {
            case .gaveUp: continue
            case .waiting: return changed
            case .ready: break
            }
            guard let book = try? NextTimeBook.load(from: paths.nextTime) else { return changed }
            let points = NextTimeRules.points(for: r, in: book, series: SeriesCatalog.series(ofCall: r.id, in: series), people: people)
            do {
                // No request for a meeting with nothing to check, or with no words.
                let found = points.isEmpty || r.utterances.isEmpty ? []
                    : try await UsageContext.$callID.withValue(r.id) { try await checker.check(points, in: r) }
                // Read again: the owner may have changed a point while the request ran.
                let checkedNow = r.utterances.isEmpty ? [] : points
                try NextTimeBook.change(in: paths.nextTime) { NextTimeRules.apply(found, checked: checkedNow, call: r, to: &$0, at: now()) }
                if !checkedNow.isEmpty { changed += 1 }
                if ledger.entries[r.id] != nil { ledger.clear(r.id); ledger.save(to: paths.nextTime) }
                if !found.isEmpty { Log.info("Next time: \(found.count) of \(points.count) points discussed in \(r.id)") }
            } catch {
                guard !RetryLedger.isUnbilled(error), !(error is UnreadableFile) else {
                    Log.error("Checking the points in \(r.id) waits: \(error)")
                    return changed
                }
                ledger.fail(r.id, reason: Pipeline.failureReason(error), now: now())
                ledger.save(to: paths.nextTime)
                Log.error("Checking the points in \(r.id) failed: \(error)")
                return changed
            }
        }
        return changed
    }
}
