import Foundation

/// A query split into words and the leading `#tag` and `@person` filters.
struct ParsedQuery: Equatable {
    static let maxWords = 8

    var words: [String] = []
    var tag: String?
    var person: [String] = []

    init(_ text: String) {
        var chunks = text.split(whereSeparator: \.isWhitespace).map(String.init)
        while let c = chunks.first, c.hasPrefix("#") || c.hasPrefix("@") {
            if c.hasPrefix("#") {
                let key = SearchTokenizer.key(String(c.dropFirst()))
                if !key.isEmpty { tag = key }
            } else {
                person += SearchTokenizer.terms(String(c.dropFirst()))
            }
            chunks.removeFirst()
        }
        words = Array(SearchTokenizer.terms(chunks.joined(separator: " ")).prefix(Self.maxWords))
    }

    var isEmpty: Bool { words.isEmpty && tag == nil && person.isEmpty }
}

/// How each vocabulary word matches one query word: a code per word id, the best kind of match it allows.
struct QueryWord {
    static let exact: UInt8 = 4, prefix: UInt8 = 3, nickname: UInt8 = 2, typo: UInt8 = 1

    let text: String
    /// Words that start with the query word, for reading postings.
    let prefixIDs: [Int32]
    private var codes: [UInt8]

    init(_ text: String, in index: SearchIndex) {
        self.text = text
        let vocab = index.vocab
        codes = [UInt8](repeating: 0, count: vocab.count)
        prefixIDs = vocab.withPrefix(text)
        for id in prefixIDs { codes[Int(id)] = Self.prefix }
        if let id = vocab.id(text) { codes[Int(id)] = Self.exact }
        for name in Nicknames.variants(of: text) {
            if let id = vocab.id(name), codes[Int(id)] == 0 { codes[Int(id)] = Self.nickname }
        }
        let letters = Array(text.unicodeScalars)
        guard letters.count >= 5 else { return }
        for (id, term) in index.nameTerms where codes[Int(id)] == 0 && Self.withinOneTypo(letters, term) {
            codes[Int(id)] = Self.typo
        }
    }

    /// The match quality of a word in a field, or nil. Nicknames count only in names; typos only in names and titles.
    @inline(__always)
    func quality(_ id: Int32, names: Bool = false, typos: Bool = false) -> Double? {
        switch codes[Int(id)] {
        case Self.exact: 1
        case Self.prefix: 0.8
        case Self.nickname: names ? 0.9 : nil
        case Self.typo: typos ? 0.6 : nil
        default: nil
        }
    }

    func matchesPrefix(_ id: Int32) -> Bool { codes[Int(id)] >= Self.prefix }

    /// Whether the query word is one edit (a letter added, dropped, changed, or two letters swapped) from the
    /// start of `term`, so a typo in a half-typed word still matches.
    static func withinOneTypo(_ word: [Unicode.Scalar], _ term: [Unicode.Scalar]) -> Bool {
        let n = word.count
        for k in [n, n - 1, n + 1] where k >= 4 && k <= term.count {
            if oneEdit(word, term[0..<k]) { return true }
        }
        return false
    }

    private static func oneEdit(_ a: [Unicode.Scalar], _ b: ArraySlice<Unicode.Scalar>) -> Bool {
        let b = Array(b)
        if a.count == b.count {
            var diffs: [Int] = []
            for i in a.indices where a[i] != b[i] {
                diffs.append(i)
                if diffs.count > 2 { return false }
            }
            if diffs.count == 1 { return true }
            if diffs.count == 2 {
                let (i, j) = (diffs[0], diffs[1])
                return j == i + 1 && a[i] == b[j] && a[j] == b[i]
            }
            return false
        }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        guard long.count == short.count + 1 else { return false }
        var i = 0
        while i < short.count, long[i] == short[i] { i += 1 }
        return long[(i + 1)...].elementsEqual(short[i...])
    }
}

/// Field weights: how much a match in each field counts.
enum SearchWeight {
    static let title = 10.0
    static let person = 8.0
    static let tag = 6.0
    static let meetingPerson = 4.0
    static let outcome = 3.0
    static let task = 3.0
    static let chatTitle = 3.0
    static let email = 3.0
    static let taskDetail = 2.0
    static let transcript = 1.0
    static let chatMessage = 1.0
    /// Added, times the weight, for each word when the words stand together in the query's order.
    static let phrase = 0.5
}

extension SearchIndex {
    public func search(_ query: String, limits: SearchLimits = .standard, now: Date = Date()) -> SearchResults {
        let parsed = ParsedQuery(query)
        guard !parsed.isEmpty else { return .empty }
        let words = parsed.words.map { QueryWord($0, in: self) }
        let personWords = parsed.person.map { QueryWord($0, in: self) }
        let allowed = allowedSlots(tag: parsed.tag, person: personWords)
        let filtered = allowed != nil
        var r = SearchResults(query: query)

        var meetings = filtered && words.isEmpty ? filteredMeetings(allowed!, now: now) : matchMeetings(words, allowed: allowed, now: now)
        var people = matchPeople(words.isEmpty ? personWords : words, now: now)
        var moments = words.isEmpty ? [] : momentGroups(words, allowed: allowed, limits: limits, now: now)
        var outcomes = words.isEmpty ? [] : matchOutcomes(words, allowed: allowed, now: now)
        let callIDs = allowed.map { Set($0.map { slots[Int($0)]!.id }) }
        var tasks = words.isEmpty ? [] : matchTasks(words, callIDs: callIDs, now: now)
        var chats = words.isEmpty ? [] : matchChats(words, callIDs: callIDs, now: now)

        let candidates: [SearchHit?] = [
            meetings.first.map(SearchHit.meeting), people.first.map(SearchHit.person),
            moments.first?.moments.max { $0.score < $1.score }.map(SearchHit.moment),
            outcomes.first.map(SearchHit.outcome), tasks.first.map(SearchHit.task), chats.first.map(SearchHit.chat),
        ]
        var top: SearchHit?
        for case let c? in candidates where c.score > (top?.score ?? -1) { top = c }
        switch top {
        case .meeting: meetings.removeFirst()
        case .person: people.removeFirst()
        case .moment(let m):
            moments[0].moments.removeAll { $0.id == m.id }
            if moments[0].moments.isEmpty { moments.removeFirst() }
        case .outcome: outcomes.removeFirst()
        case .task: tasks.removeFirst()
        case .chat: chats.removeFirst()
        case nil: break
        }
        r.topHit = top
        r.meetings = Array(meetings.prefix(limits.meetings))
        r.people = Array(people.prefix(limits.people))
        r.moments = moments
        r.decisionsAndActions = Array(outcomes.prefix(limits.decisionsAndActions))
        r.tasks = Array(tasks.prefix(limits.tasks))
        r.chats = Array(chats.prefix(limits.chats))
        return r
    }

    /// Every turn of one meeting that holds the query's words, in time order, for "N more in this meeting".
    public func moments(in callID: String, matching query: String) -> [MomentHit] {
        let words = ParsedQuery(query).words.map { QueryWord($0, in: self) }
        guard let slot = slotOf[callID], !words.isEmpty, let entry = slots[Int(slot)] else { return [] }
        let base = Int(entry.turnBase)
        return (base..<(base + entry.utterances.count)).compactMap { g in
            momentScore(turn: g, words).map { moment(entry, turn: g - base, score: $0, words) }
        }
    }

    public func suggestions(meetings: Int = 6, people: Int = 6, tags: Int = 8) -> SearchSuggestions {
        let recent = slots.compactMap { $0 }.sorted { $0.start > $1.start }.prefix(meetings)
        let met = self.people.filter { !$0.isOwner && $0.meetings > 0 }
            .sorted { ($0.meetings, $1.name.text) > ($1.meetings, $0.name.text) }.prefix(people)
        var counts: [String: (name: String, count: Int)] = [:]
        for case let entry? in slots { for t in entry.tags { counts[t.lowercased(), default: (t, 0)].count += 1 } }
        let tagList = counts.values.sorted { ($0.count, $1.name) > ($1.count, $0.name) }.prefix(tags).map(\.name)
        return SearchSuggestions(meetings: recent.map { meetingHit($0, title: SearchText($0.title.text), context: nil, score: 0) },
                                 people: met.map { personHit($0, name: SearchText($0.name.text), score: 0) }, tags: Array(tagList))
    }

    // MARK: Scoring helpers

    /// A small lift for newer items: at most 10%, half that after a month.
    func recency(_ date: Date?, now: Date) -> Double {
        guard let date else { return 1 }
        let days = max(0, now.timeIntervalSince(date)) / 86_400
        return 1 + 0.1 / (1 + days / 30)
    }

    func best(_ field: IndexedField, _ word: QueryWord, names: Bool = false, typos: Bool = false) -> Double? {
        var best: Double?
        for id in field.terms {
            if let q = word.quality(id, names: names, typos: typos), q > (best ?? 0) { best = q }
        }
        return best
    }

    /// Whether the query words stand together, in order, in `terms`.
    func hasPhrase<C: RandomAccessCollection>(_ terms: C, _ words: [QueryWord]) -> Bool where C.Element == Int32, C.Index == Int {
        guard words.count > 1, terms.count >= words.count else { return false }
        let start = terms.startIndex
        for i in 0...(terms.count - words.count) {
            var all = true
            for (j, w) in words.enumerated() where !w.matchesPrefix(terms[start + i + j]) {
                all = false
                break
            }
            if all { return true }
        }
        return false
    }

    func highlights(_ field: IndexedField, _ words: [QueryWord], names: Bool = false, typos: Bool = false) -> [Range<String.Index>] {
        let spans = zip(field.terms, field.spans).filter { id, _ in
            words.contains { $0.quality(id, names: names, typos: typos) != nil }
        }.map(\.1)
        return field.text.searchRanges(spans)
    }

    // MARK: Filters

    private func allowedSlots(tag: String?, person: [QueryWord]) -> [Int32]? {
        guard tag != nil || !person.isEmpty else { return nil }
        var keys: Set<String> = []
        if let tag {
            let all = Set(slots.compactMap { $0 }.flatMap(\.tagKeys))
            keys = all.contains(tag) ? [tag] : all.filter { $0.hasPrefix(tag) }
        }
        return slots.indices.compactMap { i -> Int32? in
            guard let entry = slots[i] else { return nil }
            if tag != nil, !entry.tagKeys.contains(where: keys.contains) { return nil }
            for w in person where !entry.personFields.contains(where: { best($0, w, names: true, typos: true) != nil }) { return nil }
            return Int32(i)
        }
    }

    // MARK: Meetings

    private func filteredMeetings(_ allowed: [Int32], now: Date) -> [MeetingHit] {
        allowed.map { slots[Int($0)]! }.sorted { $0.start > $1.start }
            .map { meetingHit($0, title: SearchText($0.title.text), context: nil, score: recency($0.start, now: now)) }
    }

    private func matchMeetings(_ words: [QueryWord], allowed: [Int32]?, now: Date) -> [MeetingHit] {
        guard !words.isEmpty else { return [] }
        var scored: [(entry: MeetingEntry, score: Double)] = []
        let list = allowed ?? slots.indices.map { Int32($0) }
        for i in list {
            guard let e = slots[Int(i)] else { continue }
            var total = 0.0
            var all = true
            for w in words {
                var b = (best(e.title, w, typos: true) ?? 0) * SearchWeight.title
                for f in e.tagFields + (e.kindField.map { [$0] } ?? []) { b = max(b, (best(f, w) ?? 0) * SearchWeight.tag) }
                for f in e.personFields { b = max(b, (best(f, w, names: true, typos: true) ?? 0) * SearchWeight.meetingPerson) }
                if b == 0 { all = false; break }
                total += b
            }
            guard all else { continue }
            var bonus = 0.0
            if hasPhrase(e.title.terms, words) { bonus = SearchWeight.title }
            for f in e.tagFields + (e.kindField.map { [$0] } ?? []) where hasPhrase(f.terms, words) { bonus = max(bonus, SearchWeight.tag) }
            for f in e.personFields where hasPhrase(f.terms, words) { bonus = max(bonus, SearchWeight.meetingPerson) }
            total += bonus * SearchWeight.phrase * Double(words.count)
            scored.append((e, total * recency(e.start, now: now)))
        }
        scored.sort { ($0.score, $0.entry.start) > ($1.score, $1.entry.start) }
        return scored.map { e, score in
            let title = SearchText(e.title.text, matches: highlights(e.title, words, typos: true))
            let inTitle = words.allSatisfy { best(e.title, $0, typos: true) != nil }
            return meetingHit(e, title: title, context: inTitle ? nil : context(e, words), score: score)
        }
    }

    /// The field outside the title that matched the most query words, shown under the title.
    private func context(_ e: MeetingEntry, _ words: [QueryWord]) -> SearchText? {
        let fields = e.tagFields.map { ($0, false) } + (e.kindField.map { [($0, false)] } ?? []) + e.personFields.map { ($0, true) }
        var pick: (IndexedField, Bool, Int)?
        for (f, names) in fields {
            let n = words.filter { best(f, $0, names: names, typos: names) != nil }.count
            if n > (pick?.2 ?? 0) { pick = (f, names, n) }
        }
        return pick.map { SearchText($0.0.text, matches: highlights($0.0, words, names: $0.1, typos: $0.1)) }
    }

    private func meetingHit(_ e: MeetingEntry, title: SearchText, context: SearchText?, score: Double) -> MeetingHit {
        MeetingHit(callID: e.id, title: title, start: e.start, end: e.end, platform: e.platform, kind: e.kind, tags: e.tags,
                   context: context, score: score)
    }

    // MARK: People

    private func matchPeople(_ words: [QueryWord], now: Date) -> [PersonHit] {
        guard !words.isEmpty else { return [] }
        var scored: [(PersonEntry, Double)] = []
        for p in people {
            var total = 0.0
            var all = true
            for w in words {
                let b = max((best(p.name, w, names: true, typos: true) ?? 0) * SearchWeight.person,
                            (p.email.flatMap { best($0, w) } ?? 0) * SearchWeight.email)
                if b == 0 { all = false; break }
                total += b
            }
            guard all else { continue }
            if hasPhrase(p.name.terms, words) { total += SearchWeight.person * SearchWeight.phrase * Double(words.count) }
            let familiar = 1 + 0.05 * log2(1 + Double(p.meetings))
            scored.append((p, total * familiar * recency(p.lastMet, now: now)))
        }
        scored.sort { ($0.1, $1.0.name.text) > ($1.1, $0.0.name.text) }
        return scored.map { p, score in
            personHit(p, name: SearchText(p.name.text, matches: highlights(p.name, words, names: true, typos: true)), score: score)
        }
    }

    private func personHit(_ p: PersonEntry, name: SearchText, score: Double) -> PersonHit {
        PersonHit(name: name, email: p.email?.text, isOwner: p.isOwner, meetings: p.meetings, lastMet: p.lastMet, score: score)
    }

    // MARK: Moments

    /// The score of a transcript turn that holds every word, or nil.
    func momentScore(turn g: Int, _ words: [QueryWord]) -> Double? {
        let terms = termStore[Int(turnOffset[g])..<Int(turnOffset[g + 1])]
        var total = 0.0
        for w in words {
            var b = 0.0
            for id in terms { if let q = w.quality(id), q > b { b = q; if q == 1 { break } } }
            if b == 0 { return nil }
            total += b
        }
        if hasPhrase(terms, words) { total += SearchWeight.phrase * Double(words.count) }
        return total * SearchWeight.transcript
    }

    private func momentGroups(_ words: [QueryWord], allowed: [Int32]?, limits: SearchLimits, now: Date) -> [MomentGroup] {
        // Read the postings of the word with the fewest, then check the other words in each of those turns.
        guard let driver = words.min(by: { postingCount($0) < postingCount($1) }) else { return [] }
        var allowedMask: [Bool]?
        if let allowed {
            var mask = [Bool](repeating: false, count: slots.count)
            for s in allowed { mask[Int(s)] = true }
            allowedMask = mask
        }
        var turns: [Int32] = []
        for id in driver.prefixIDs where Int(id) < postings.count { turns += postings[Int(id)] }
        if driver.prefixIDs.count > 1 { turns = Array(Set(turns)) }
        var bySlot: [Int32: [(turn: Int, score: Double)]] = [:]
        for g in turns {
            let slot = turnSlot[Int(g)]
            guard slots[Int(slot)] != nil, allowedMask?[Int(slot)] ?? true, let score = momentScore(turn: Int(g), words) else { continue }
            bySlot[slot, default: []].append((Int(g), score))
        }
        var groups: [(slot: Int32, best: Double, turns: [(turn: Int, score: Double)])] = []
        for (slot, list) in bySlot {
            let lift = recency(slots[Int(slot)]!.start, now: now)
            let sorted = list.map { ($0.turn, $0.score * lift) }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
            groups.append((slot, sorted[0].1, sorted))
        }
        groups.sort { a, b in
            a.best != b.best ? a.best > b.best : slots[Int(a.slot)]!.start > slots[Int(b.slot)]!.start
        }
        return groups.prefix(limits.momentMeetings).map { group in
            let e = slots[Int(group.slot)]!
            let shown = group.turns.prefix(limits.momentsPerMeeting).sorted { $0.turn < $1.turn }
            return MomentGroup(callID: e.id, title: e.title.text, start: e.start,
                               moments: shown.map { moment(e, turn: $0.turn - Int(e.turnBase), score: $0.score, words) },
                               moreCount: group.turns.count - shown.count, score: group.best)
        }
    }

    private func postingCount(_ w: QueryWord) -> Int {
        w.prefixIDs.reduce(0) { $0 + (Int($1) < postings.count ? postings[Int($1)].count : 0) }
    }

    private func moment(_ e: MeetingEntry, turn: Int, score: Double, _ words: [QueryWord]) -> MomentHit {
        let u = e.utterances[turn]
        let spans = SearchTokenizer.tokens(u.text).filter { t in
            guard let id = vocab.id(t.term) else { return false }
            return words.contains { $0.matchesPrefix(id) }
        }.map(\.range)
        return MomentHit(callID: e.id, meetingTitle: e.title.text, meetingStart: e.start, turn: turn,
                         speaker: e.displayNames[u.speakerKey] ?? u.speakerKey, time: u.start,
                         snippet: Snippet.make(u.text, matches: u.text.searchRanges(spans)), score: score)
    }

    // MARK: Decisions and action items

    private func matchOutcomes(_ words: [QueryWord], allowed: [Int32]?, now: Date) -> [OutcomeHit] {
        var out: [OutcomeHit] = []
        for i in allowed ?? slots.indices.map({ Int32($0) }) {
            guard let e = slots[Int(i)] else { continue }
            let lift = recency(e.start, now: now)
            for o in e.outcomes {
                guard let score = allWords(words, [(o.field, SearchWeight.outcome, false)]) else { continue }
                out.append(OutcomeHit(kind: o.kind, callID: e.id, meetingTitle: e.title.text, meetingStart: e.start, position: o.position,
                                      time: o.time, text: SearchText(o.field.text, matches: highlights(o.field, words)), score: score * lift))
            }
        }
        return out.sorted { ($0.score, $0.meetingStart) > ($1.score, $1.meetingStart) }
    }

    /// The summed best weighted match of each word across the fields, with the phrase bonus, or nil when a
    /// word matches none of them.
    private func allWords(_ words: [QueryWord], _ fields: [(IndexedField, Double, Bool)]) -> Double? {
        var total = 0.0
        for w in words {
            var b = 0.0
            for (f, weight, names) in fields { b = max(b, (best(f, w, names: names, typos: names) ?? 0) * weight) }
            if b == 0 { return nil }
            total += b
        }
        let bonus = fields.filter { hasPhrase($0.0.terms, words) }.map(\.1).max() ?? 0
        return total + bonus * SearchWeight.phrase * Double(words.count)
    }

    // MARK: Tasks and chats

    private func matchTasks(_ words: [QueryWord], callIDs: Set<String>?, now: Date) -> [TaskHit] {
        var out: [TaskHit] = []
        for t in tasks {
            if let callIDs, !callIDs.contains(t.item.callID ?? "") { continue }
            var fields = [(t.text, SearchWeight.task, false)]
            if let to = t.to { fields.append((to, SearchWeight.taskDetail, true)) }
            if let title = t.callTitle { fields.append((title, SearchWeight.taskDetail, false)) }
            guard let score = allWords(words, fields) else { continue }
            let c = t.item
            out.append(TaskHit(commitmentID: c.id, text: SearchText(t.text.text, matches: highlights(t.text, words)), to: c.to,
                               callID: c.callID, callTitle: c.callTitle, time: c.at, due: c.due, isDone: c.done != nil,
                               score: score * recency(c.madeAt, now: now)))
        }
        return out.sorted { ($0.score, $1.text.text) > ($1.score, $0.text.text) }
    }

    private func matchChats(_ words: [QueryWord], callIDs: Set<String>?, now: Date) -> [ChatHit] {
        var out: [ChatHit] = []
        for c in chats {
            if let callIDs, !callIDs.contains(c.callID ?? "") { continue }
            let fields = [(c.title, SearchWeight.chatTitle, false)] + c.messages.map { ($0, SearchWeight.chatMessage, false) }
            guard let score = allWords(words, fields) else { continue }
            let message = c.messages.map { m in (m, words.filter { best(m, $0) != nil }.count) }.filter { $0.1 > 0 }
                .max { $0.1 < $1.1 }?.0
            out.append(ChatHit(chatID: c.id, title: SearchText(c.title.text, matches: highlights(c.title, words)),
                               snippet: message.map { Snippet.make($0.text, matches: highlights($0, words)) },
                               updated: c.updated, callID: c.callID, score: score * recency(c.updated, now: now)))
        }
        return out.sorted { ($0.score, $0.updated) > ($1.score, $1.updated) }
    }
}
