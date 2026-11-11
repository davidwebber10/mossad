import Foundation

/// Text of one searchable field, with its words as vocabulary ids and their places in the text.
struct IndexedField: Sendable {
    var text: String
    var terms: [Int32]
    var spans: [Range<Int>]
}

/// Every folded word seen, each with an id, plus a sorted list for prefix lookups.
struct Vocabulary: Sendable {
    private(set) var terms: [String] = []
    private var ids: [String: Int32] = [:]
    private var sorted: [Int32] = []

    var count: Int { terms.count }

    func id(_ term: String) -> Int32? { ids[term] }

    mutating func intern(_ term: String) -> Int32 {
        if let id = ids[term] { return id }
        let id = Int32(terms.count)
        terms.append(term)
        ids[term] = id
        return id
    }

    /// Brings the sorted list up to date after `intern`. A few new words are inserted in place.
    mutating func sort() {
        let added = terms.count - sorted.count
        guard added > 0 else { return }
        if added > 64 {
            sorted = terms.indices.map { Int32($0) }.sorted { terms[Int($0)] < terms[Int($1)] }
            return
        }
        for id in Int32(sorted.count)..<Int32(terms.count) {
            sorted.insert(id, at: lowerBound(terms[Int(id)]))
        }
    }

    private func lowerBound(_ key: String) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if terms[Int(sorted[mid])] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Ids of the words that start with `prefix`, the word itself included.
    func withPrefix(_ prefix: String) -> [Int32] {
        var out: [Int32] = []
        var i = lowerBound(prefix)
        while i < sorted.count, terms[Int(sorted[i])].hasPrefix(prefix) {
            out.append(sorted[i])
            i += 1
        }
        return out
    }
}

struct OutcomeEntry: Sendable {
    var kind: OutcomeHit.Kind
    var position: Int
    var time: TimeInterval?
    var field: IndexedField
}

struct MeetingEntry: Sendable {
    var id: String
    var start: Date
    var end: Date
    var platform: Platform
    var kind: String?
    var tags: [String]
    var title: IndexedField
    /// The calendar and generated titles when they differ from the shown one, so a rename hides neither.
    var otherTitles: [IndexedField]
    var kindField: IndexedField?
    var tagFields: [IndexedField]
    var tagKeys: [String]
    /// Speaker names and attendees. An email's words are only those before the "@".
    var personFields: [IndexedField]
    /// Attendee emails, lowercased, for a query that is a whole email.
    var emails: [String]
    /// Named speakers, for the People counts.
    var speakers: Set<String>
    var outcomes: [OutcomeEntry]
    var utterances: [Utterance]
    var displayNames: [String: String]
    /// The meeting's first turn in the index's turn arrays; its turns follow in order.
    var turnBase: Int32
}

struct PersonEntry: Sendable {
    var name: IndexedField
    /// The person's other names: a name of before a rename, and a form a calendar showed. The old name finds them.
    var others: [IndexedField] = []
    var email: IndexedField?
    var isOwner: Bool
    var meetings: Int
    var lastMet: Date?
}

struct TaskEntry: Sendable {
    var item: Commitment
    var text: IndexedField
    var to: IndexedField?
    var callTitle: IndexedField?
}

struct ChatEntry: Sendable {
    var id: UUID
    var updated: Date
    var callID: String?
    var title: IndexedField
    var messages: [IndexedField]
}

/// The in-memory search over meetings, people, tasks, and chats. A value: build it off the main thread, keep it,
/// and update it when one meeting changes. Transcript turns sit in an inverted index (word id to turns), so a
/// query reads only the turns that hold its rarest word.
public struct SearchIndex: Sendable {
    var vocab = Vocabulary()
    /// Meetings by slot; nil once removed or replaced.
    var slots: [MeetingEntry?] = []
    var slotOf: [String: Int32] = [:]

    // Transcript turns, across all slots: turn g's word ids are termStore[turnOffset[g]..<turnOffset[g + 1]].
    var termStore: [Int32] = []
    var turnOffset: [Int32] = [0]
    var turnSlot: [Int32] = []
    /// Word id to the turns that hold it, oldest turn first, each turn once.
    var postings: [[Int32]] = []
    var liveTurns = 0
    var deadTurns = 0

    /// Words of titles and names, with their letters, for typo matching.
    var nameTerms: [Int32: [Unicode.Scalar]] = [:]

    var profiles: [VoiceProfile] = []
    var people: [PersonEntry] = []
    /// Each saved person's other names, by the name of now.
    private var otherNames: [String: [String]] = [:]
    var tasks: [TaskEntry] = []
    var chats: [ChatEntry] = []

    public init() {}

    public init(records: [CallRecord], people: [VoiceProfile] = [], tasks: [Commitment] = [], chats: [Chat] = []) {
        for r in records { insert(r) }
        profiles = people
        setTasksWithoutSorting(tasks)
        setChatsWithoutSorting(chats)
        vocab.sort()
        rebuildPeople()
    }

    /// Builds the index on a background thread.
    @concurrent
    public static func build(records: [CallRecord], people: [VoiceProfile] = [], tasks: [Commitment] = [],
                             chats: [Chat] = []) async -> SearchIndex {
        SearchIndex(records: records, people: people, tasks: tasks, chats: chats)
    }

    public var meetingCount: Int { slotOf.count }

    /// Adds a meeting, or replaces the one with the same id.
    public mutating func update(_ record: CallRecord) {
        insert(record)
        vocab.sort()
        compactIfNeeded()
        rebuildPeople()
    }

    public mutating func removeMeeting(id: String) {
        guard let slot = slotOf[id] else { return }
        kill(slot)
        compactIfNeeded()
        rebuildPeople()
    }

    public mutating func setPeople(_ profiles: [VoiceProfile]) {
        self.profiles = profiles
        rebuildPeople()
    }

    /// The other names of the saved people, from the people store: a person is found by a name of before a rename.
    public mutating func setOtherNames(_ people: [Person]) {
        var out: [String: [String]] = [:]
        for p in people where p.isLive {
            let others = p.forms.map(\.text).filter { PersonNames.nameKey($0) != PersonNames.nameKey(p.displayName) }
            if !others.isEmpty { out[p.displayName, default: []] += others }
        }
        guard out != otherNames else { return }
        otherNames = out
        rebuildPeople()
        vocab.sort()
    }

    /// The commitment book's items; deleted ones are left out.
    public mutating func setTasks(_ items: [Commitment]) {
        setTasksWithoutSorting(items)
        vocab.sort()
    }

    public mutating func setChats(_ chats: [Chat]) {
        setChatsWithoutSorting(chats)
        vocab.sort()
    }

    // MARK: Building

    mutating func field(_ text: String, names: Bool = false) -> IndexedField {
        let tokens = SearchTokenizer.tokens(text)
        let terms = tokens.map { vocab.intern($0.term) }
        if names {
            for (id, t) in zip(terms, tokens) where nameTerms[id] == nil { nameTerms[id] = Array(t.term.unicodeScalars) }
        }
        return IndexedField(text: text, terms: terms, spans: tokens.map(\.range))
    }

    /// An email shown whole but searched by the part before the "@": the domain is every colleague's, not a name.
    mutating func personField(_ text: String, names: Bool) -> IndexedField {
        guard let at = SearchIndex.emailAt(text) else { return field(text, names: names) }
        let tokens = SearchTokenizer.tokens(text).filter { $0.range.upperBound <= at }
        let terms = tokens.map { vocab.intern($0.term) }
        if names {
            for (id, t) in zip(terms, tokens) where nameTerms[id] == nil { nameTerms[id] = Array(t.term.unicodeScalars) }
        }
        return IndexedField(text: text, terms: terms, spans: tokens.map(\.range))
    }

    /// The UTF-8 offset of the "@" in a text that is one email address, or nil.
    static func emailAt(_ text: String) -> Int? {
        guard normalizedEmail(text) != nil, let at = text.utf8.firstIndex(of: UInt8(ascii: "@")) else { return nil }
        return text.utf8.distance(from: text.utf8.startIndex, to: at)
    }

    /// The text lowercased when it is one email address: something before an "@", and a dot after it.
    static func normalizedEmail(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !t.contains(where: \.isWhitespace) else { return nil }
        return t
    }

    static let screenLabel = "screen"

    private mutating func insert(_ r: CallRecord) {
        if let old = slotOf[r.id] { kill(old) }
        let slot = Int32(slots.count)
        var names = MarkdownWriter.displayNames(r)
        // The text on shared screens is searched as turns of a speaker named "Screen", after the spoken ones.
        let screenTurns = (r.screens ?? []).map { Utterance(track: .them, speakerLabel: SearchIndex.screenLabel, start: $0.offset, end: $0.offset, text: $0.text) }
        if !screenTurns.isEmpty { names[screenTurns[0].speakerKey] = "Screen" }
        let turns = r.utterances + screenTurns
        let speakers = Set(r.speakerNames.values.filter { !$0.hasPrefix("Speaker ") })
        var people: [String] = []
        for p in speakers.sorted() + r.attendees where !people.contains(p) { people.append(p) }
        let decisions = r.decisions.enumerated().map { i, d in (OutcomeHit.Kind.decision, i, d.at, d.text) }
        let actions = r.actionItems.enumerated().map { i, a in (OutcomeHit.Kind.actionItem, i, TimeInterval?.none, a.text) }
        var entry = MeetingEntry(
            id: r.id, start: r.start, end: r.end, platform: r.platform, kind: r.kind, tags: r.tags,
            title: field(r.title, names: true), otherTitles: [], kindField: nil, tagFields: [], tagKeys: r.tags.map(SearchTokenizer.key),
            personFields: [], emails: [], speakers: speakers, outcomes: [], utterances: turns, displayNames: names,
            turnBase: Int32(turnSlot.count))
        var titles = [r.title]
        for t in [r.calendarTitle, r.generatedTitle] {
            guard let t, !t.trimmingCharacters(in: .whitespaces).isEmpty, !titles.contains(t) else { continue }
            titles.append(t)
            entry.otherTitles.append(field(t, names: true))
        }
        entry.kindField = r.kind.map { field($0) }
        entry.tagFields = r.tags.map { field($0) }
        entry.personFields = people.map { personField($0, names: true) }
        entry.emails = people.compactMap(SearchIndex.normalizedEmail)
        entry.outcomes = (decisions + actions).map { OutcomeEntry(kind: $0.0, position: $0.1, time: $0.2, field: field($0.3)) }
        for u in turns {
            for t in SearchTokenizer.tokens(u.text) { termStore.append(vocab.intern(t.term)) }
            appendTurn(slot: slot)
        }
        liveTurns += turns.count
        slots.append(entry)
        slotOf[r.id] = slot
    }

    /// Records the turn whose words were just added to `termStore`, and its postings.
    private mutating func appendTurn(slot: Int32) {
        let g = Int32(turnSlot.count)
        let from = Int(turnOffset[turnOffset.count - 1])
        turnOffset.append(Int32(termStore.count))
        turnSlot.append(slot)
        if postings.count < vocab.count { postings.append(contentsOf: repeatElement([], count: vocab.count - postings.count)) }
        for i in from..<termStore.count {
            let id = Int(termStore[i])
            if postings[id].last != g { postings[id].append(g) }
        }
    }

    private mutating func kill(_ slot: Int32) {
        guard let entry = slots[Int(slot)] else { return }
        liveTurns -= entry.utterances.count
        deadTurns += entry.utterances.count
        slots[Int(slot)] = nil
        slotOf[entry.id] = nil
    }

    /// Rewrites the turn arrays without removed meetings once they make up a good part of them.
    private mutating func compactIfNeeded() {
        guard deadTurns > 32, deadTurns > liveTurns / 4 else { return }
        let oldStore = termStore, oldOffset = turnOffset
        termStore = []
        turnOffset = [0]
        turnSlot = []
        postings = []
        var kept: [MeetingEntry?] = []
        slotOf = [:]
        for case var entry? in slots {
            let slot = Int32(kept.count)
            let base = Int(entry.turnBase)
            entry.turnBase = Int32(turnSlot.count)
            for g in base..<(base + entry.utterances.count) {
                termStore.append(contentsOf: oldStore[Int(oldOffset[g])..<Int(oldOffset[g + 1])])
                appendTurn(slot: slot)
            }
            slotOf[entry.id] = slot
            kept.append(entry)
        }
        slots = kept
        deadTurns = 0
    }

    private mutating func rebuildPeople() {
        var counts: [String: (meetings: Int, last: Date?)] = [:]
        for case let entry? in slots {
            for name in entry.speakers {
                var c = counts[name] ?? (0, nil)
                c.meetings += 1
                c.last = max(c.last ?? entry.start, entry.start)
                counts[name] = c
            }
        }
        var out: [PersonEntry] = []
        var seen: Set<String> = []
        for p in profiles where !p.name.hasPrefix("Speaker ") && seen.insert(p.name).inserted {
            let c = counts[p.name]
            out.append(PersonEntry(name: field(p.name, names: true), others: (otherNames[p.name] ?? []).map { field($0, names: true) },
                                   email: p.email.map { personField($0, names: false) }, isOwner: p.isOwner, meetings: c?.meetings ?? 0, lastMet: c?.last))
        }
        for (name, c) in counts.sorted(by: { $0.key < $1.key }) where seen.insert(name).inserted {
            out.append(PersonEntry(name: field(name, names: true), email: nil, isOwner: false, meetings: c.meetings, lastMet: c.last))
        }
        people = out
        vocab.sort()
    }

    private mutating func setTasksWithoutSorting(_ items: [Commitment]) {
        tasks = items.filter { !$0.deleted }.map { c in
            TaskEntry(item: c, text: field(c.text), to: c.to.map { field($0, names: true) }, callTitle: c.callTitle.map { field($0) })
        }
    }

    private mutating func setChatsWithoutSorting(_ list: [Chat]) {
        chats = list.map { c in
            ChatEntry(id: c.id, updated: c.updated, callID: c.callID, title: field(c.title), messages: c.messages.map { field($0.text) })
        }
    }
}
