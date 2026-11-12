import Foundation

extension SearchIndex {
    /// The search of the Meetings list: the meetings that hold every word of the query somewhere (the title, the
    /// people, the tags and kind, the summary, the decisions, action items, and bookmark notes, or the transcript
    /// and the text on its screens), each with the place that best shows why. The list keeps its own order.
    ///
    /// The place is the title when it holds every word; else the first field that holds every word, in that order;
    /// else the best transcript line that holds every word; else the place that holds the most words. `#tag` and
    /// `@person` narrow the meetings as in the palette.
    public func listMatches(_ query: String) -> [String: ListMatch] {
        let parsed = ParsedQuery(query)
        guard !parsed.isEmpty, !Task.isCancelled else { return [:] }
        if let email = parsed.email, parsed.tag == nil, parsed.person.isEmpty { return emailMatches(email) }
        let words = parsed.words.map { QueryWord($0, in: self) }
        let personWords = parsed.person.map { QueryWord($0, in: self) }
        let list = allowedSlots(tag: parsed.tag, person: personWords) ?? slots.indices.map { Int32($0) }
        var out: [String: ListMatch] = [:]
        guard !words.isEmpty else {
            for i in list {
                guard let e = slots[Int(i)] else { continue }
                out[e.id] = filterMatch(e, tag: parsed.tag, person: personWords)
            }
            return out
        }

        // For each word, the meetings with a transcript turn that holds it.
        var spoken = [[Bool]](repeating: [], count: words.count)
        for (k, w) in words.enumerated() where !w.isShort {
            var mask = [Bool](repeating: false, count: slots.count)
            for id in w.prefixIDs where Int(id) < slotPostings.count {
                for slot in slotPostings[Int(id)] { mask[Int(slot)] = true }
            }
            spoken[k] = mask
        }
        guard !Task.isCancelled else { return [:] }
        let byRarity = words.filter { !$0.isShort }.sorted { postingCount($0) < postingCount($1) }

        for i in list {
            guard let e = slots[Int(i)] else { continue }
            let fields = listFields(e)
            var counts = [Int](repeating: 0, count: fields.count)
            var all = true
            for (k, w) in words.enumerated() {
                var any = !spoken[k].isEmpty && spoken[k][Int(i)]
                for (j, f) in fields.enumerated() where best(f.field, w, names: f.names, typos: f.typos) != nil {
                    counts[j] += 1
                    any = true
                }
                if !any { all = false; break }
            }
            guard all else { continue }
            out[e.id] = place(e, words: words, byRarity: byRarity, fields: fields, counts: counts)
        }
        return Task.isCancelled ? [:] : out
    }

    /// One searchable field of a meeting for the list, strongest first.
    struct ListPlace {
        var field: IndexedField
        var source: ListMatchSource
        var names = false
        var typos = false
        var time: TimeInterval?
    }

    func listFields(_ e: MeetingEntry) -> [ListPlace] {
        var out = [ListPlace(field: e.title, source: .title, typos: true)]
        out += e.otherTitles.map { ListPlace(field: $0, source: .field("Title"), typos: true) }
        out += e.personFields.map { ListPlace(field: $0, source: .field("People"), names: true, typos: true) }
        out += e.tagFields.map { ListPlace(field: $0, source: .field("Tag")) }
        if let kind = e.kindField { out.append(ListPlace(field: kind, source: .field("Kind"))) }
        out += e.summaryFields.map { ListPlace(field: $0, source: .field("Summary")) }
        out += e.outcomes.map { o in
            let label = switch o.kind {
            case .decision: "Decision"
            case .actionItem: "Action item"
            case .bookmark: "Bookmark"
            }
            return ListPlace(field: o.field, source: .field(label), time: o.time)
        }
        return out
    }

    private func place(_ e: MeetingEntry, words: [QueryWord], byRarity: [QueryWord], fields: [ListPlace], counts: [Int]) -> ListMatch {
        let title = SearchText(e.title.text, matches: highlights(e.title, words, typos: true))
        if counts[0] == words.count { return ListMatch(title: title) }
        if let j = fields.indices.dropFirst().first(where: { counts[$0] == words.count }) {
            return fieldMatch(title, fields[j], words)
        }
        // The line that holds every word with the best score, the earliest on a tie, among the lines of the rarest word.
        let base = Int(e.turnBase)
        if let rarest = byRarity.first {
            var bestTurn: (g: Int, score: Double)?
            for g in turns(of: rarest, in: e) {
                if let s = momentScore(turn: g, words), s > (bestTurn?.score ?? -1) { bestTurn = (g, s) }
            }
            if let (g, _) = bestTurn { return turnMatch(title, e, turn: g - base, words) }
        }
        // No one place holds every word: show where the words that the title lacks are.
        let missing = words.filter { best(e.title, $0, typos: true) == nil }
        let held = fields.indices.dropFirst().map { j in
            (j, missing.filter { best(fields[j].field, $0, names: fields[j].names, typos: fields[j].typos) != nil }.count)
        }
        if let (j, _) = held.first(where: { $0.1 == missing.count }) { return fieldMatch(title, fields[j], words) }
        let rarestMissing = byRarity.first { w in missing.contains { $0.text == w.text } && !turns(of: w, in: e).isEmpty }
        let candidates = rarestMissing.map { turns(of: $0, in: e) } ?? []
        if let g = candidates.first(where: { momentScore(turn: $0, missing) != nil }) { return turnMatch(title, e, turn: g - base, words) }
        if let (j, n) = held.max(by: { ($0.1, -$0.0) < ($1.1, -$1.0) }), n > 0 { return fieldMatch(title, fields[j], words) }
        if let g = candidates.first { return turnMatch(title, e, turn: g - base, words) }
        return ListMatch(title: title)
    }

    /// The meeting's turns that hold a word, in time order, from the postings, which are in turn order.
    func turns(of w: QueryWord, in e: MeetingEntry) -> [Int] {
        let lo = e.turnBase, hi = e.turnBase + Int32(e.utterances.count)
        var out: [Int] = []
        for id in w.prefixIDs where Int(id) < postings.count {
            let list = postings[Int(id)]
            var a = 0, b = list.count
            while a < b {
                let mid = (a + b) / 2
                if list[mid] < lo { a = mid + 1 } else { b = mid }
            }
            while a < list.count, list[a] < hi { out.append(Int(list[a])); a += 1 }
        }
        return w.prefixIDs.count > 1 ? Array(Set(out)).sorted() : out
    }

    private func fieldMatch(_ title: SearchText, _ p: ListPlace, _ words: [QueryWord]) -> ListMatch {
        let text = Snippet.make(p.field.text, matches: highlights(p.field, words, names: p.names, typos: p.typos),
                                length: ListSearch.snippetLength)
        return ListMatch(title: title, source: p.source, context: text, time: p.time)
    }

    private func turnMatch(_ title: SearchText, _ e: MeetingEntry, turn: Int, _ words: [QueryWord]) -> ListMatch {
        let u = e.utterances[turn]
        let ranges = SearchTokenizer.tokens(u.text).filter { t in vocab.id(t.term).map { id in words.contains { $0.matchesPrefix(id) } } ?? false }
        let snippet = Snippet.make(u.text, matches: u.text.searchRanges(ranges.map(\.range)), length: ListSearch.snippetLength)
        return ListMatch(title: title, source: .transcript(speaker: e.displayNames[u.speakerKey] ?? u.speakerKey), context: snippet, time: u.start)
    }

    /// A query of only `#tag` or `@person`: the tag or the person that let the meeting in.
    private func filterMatch(_ e: MeetingEntry, tag: String?, person: [QueryWord]) -> ListMatch {
        let title = SearchText(e.title.text)
        if !person.isEmpty, let f = e.personFields.first(where: { f in person.allSatisfy { best(f, $0, names: true, typos: true) != nil } }) {
            return ListMatch(title: title, source: .field("People"),
                             context: SearchText(f.text, matches: highlights(f, person, names: true, typos: true)))
        }
        if let tag, let f = e.tagFields.first(where: { SearchTokenizer.key($0.text).hasPrefix(tag) }) {
            return ListMatch(title: title, source: .field("Tag"), context: SearchText(f.text, matches: [f.text.startIndex..<f.text.endIndex]))
        }
        return ListMatch(title: title)
    }

    private func emailMatches(_ email: String) -> [String: ListMatch] {
        var out: [String: ListMatch] = [:]
        for case let e? in slots where e.emails.contains(email) {
            let shown = e.personFields.first { SearchIndex.normalizedEmail($0.text) == email }?.text ?? email
            out[e.id] = ListMatch(title: SearchText(e.title.text), source: .field("People"),
                                  context: SearchText(shown, matches: [shown.startIndex..<shown.endIndex]))
        }
        return out
    }
}
