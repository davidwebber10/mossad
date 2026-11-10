import Foundation

extension MeetingPrep {
    // MARK: Open items

    /// The action items of `r` that belong in this meeting and are not known to be closed: the owner's first, then
    /// the invited people's, then the ones with no owner, each group in the meeting's order.
    ///
    /// An item of a person who is not invited is left out. An action item has no state of its own, so only the
    /// owner's tasks say what is closed: an item whose task from this call is done or deleted is left out, and an
    /// item whose task is open carries it. `names` are the invited people with a name.
    static func openItems(of r: CallRecord, owner: String, names: [String], directory: PersonDirectory, commitments: [Commitment]) -> [Item] {
        let tasks = commitments.filter { $0.callID == r.id }
        var groups: [[Item]] = [[], [], []]
        for (i, item) in r.actionItems.enumerated() {
            let written = item.owner?.nonBlank
            let theirs = written.map { w in names.contains { PersonDirectory.isForm(w, of: $0) } } ?? false
            // "Dana" is the owner unless a Dana is invited too.
            let mine = written.map { w in
                PeopleDuplicates.normalized(w) == PeopleDuplicates.normalized(owner) || (!theirs && PersonDirectory.isForm(w, of: owner))
            } ?? false
            guard written == nil || mine || theirs else { continue }
            var task: Commitment?
            if written == nil || mine {
                let same = tasks.filter { sameTask($0.text, item.task) }
                task = same.first { $0.done == nil && !$0.deleted }
                if task == nil, !same.isEmpty { continue }
            }
            groups[mine ? 0 : written == nil ? 2 : 1].append(
                Item(id: "\(r.id).\(i)", task: item.task, owner: written, person: mine ? nil : written.flatMap { directory.link(for: $0, in: names) },
                     isOwners: mine, callID: r.id, at: task?.at, commitment: task))
        }
        return groups.flatMap { $0 }
    }

    /// Gives each item with no moment the line of the call that says it, when one does.
    static func withMoments(_ items: [Item], in r: CallRecord) -> [Item] {
        guard items.contains(where: { $0.at == nil }) else { return items }
        let lines = r.utterances.map { keywords($0.text) }
        return items.map { item in
            guard item.at == nil else { return item }
            var item = item
            item.at = moment(of: item.task, in: r.utterances, words: lines)
            return item
        }
    }

    /// A task needs this many words that count, and this part of them in one line, before the line is its moment.
    static let momentWords = 3
    static let momentCover = 0.7
    /// A long turn plays from this long before the first of the task's words, so the sentence is heard whole.
    static let momentLead: TimeInterval = 2

    /// Where the line that holds most of the task's words begins; the first of equal lines. With word times, where
    /// the task's words begin inside that line. Nil when no line holds enough of them: no moment is better than a
    /// wrong one. `words` are the lines' `keywords`.
    static func moment(of task: String, in lines: [Utterance], words: [Set<String>]) -> TimeInterval? {
        let wanted = keywords(task)
        guard wanted.count >= momentWords else { return nil }
        var best: (line: Utterance, shared: Int)?
        for (line, has) in zip(lines, words) {
            let shared = wanted.intersection(has).count
            guard shared >= momentWords, Double(shared) / Double(wanted.count) >= momentCover, shared > (best?.shared ?? 0) else { continue }
            best = (line, shared)
        }
        guard let line = best?.line else { return nil }
        guard let first = line.words?.first(where: { !wanted.isDisjoint(with: keywords($0.text)) }) else { return line.start }
        return max(line.start, first.start - momentLead)
    }

    // MARK: Promises

    /// The owner's open tasks for the people of this meeting, oldest first: the ones promised to one of them, and
    /// the ones promised to nobody by name in a meeting of this series. `shown` are already on the page as items.
    static func promises(_ commitments: [Commitment], names: [String], series: Set<String>, shown: Set<UUID>) -> [Commitment] {
        commitments.filter { c in
            guard !c.deleted, c.done == nil, !shown.contains(c.id) else { return false }
            if let to = c.to?.nonBlank { return names.contains { PersonDirectory.isForm(to, of: $0) } }
            return c.callID.map(series.contains) ?? false
        }
        .sorted { ($0.madeAt, $0.text) < ($1.madeAt, $1.text) }
    }

    // MARK: Words

    private static let smallWords: Set<String> = [
        "the", "a", "an", "to", "for", "of", "and", "or", "with", "by", "on", "in", "at", "from", "that", "this", "it", "is", "be", "will",
        "our", "my", "your", "their", "his", "her", "about", "up", "out", "over", "we", "i", "you",
    ]

    /// The words of a task that count, each cut to a stem so "sends" and "sending" are "send".
    static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !smallWords.contains($0) }.map(stem))
    }

    private static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "ed", "s"] where w.count - suffix.count >= 3 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count))
            break
        }
        return w.count >= 4 && w.hasSuffix("e") ? String(w.dropLast()) : w
    }

    /// Whether an action item and a task say the same thing: the same words, or one holds three in four of the
    /// other's and at least two. The summary and the task finder write one promise in two wordings.
    static func sameTask(_ a: String, _ b: String) -> Bool {
        let x = keywords(a), y = keywords(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let shared = x.intersection(y).count
        return shared >= 2 && Double(shared) / Double(min(x.count, y.count)) >= 0.75
    }
}
