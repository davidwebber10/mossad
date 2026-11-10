import Foundation

extension MeetingPrep {
    // MARK: Names

    /// The people of an invite who have a name: a saved person's, or the name the invite wrote.
    struct Invite {
        let names: [String]
        /// True when every entry is a name, so the invite says who is not invited. An address of nobody saved
        /// can be anyone.
        let complete: Bool

        init(_ invited: [Invited]) {
            names = invited.compactMap { $0.person ?? ($0.written.contains("@") ? nil : $0.written) }
            complete = !invited.isEmpty && names.count == invited.count
        }

        func has(_ full: String) -> Bool {
            let key = PeopleDuplicates.normalized(full)
            return names.contains { PeopleDuplicates.normalized($0) == key || PersonDirectory.isForm($0, of: full) || PersonDirectory.isForm(full, of: $0) }
        }
    }

    /// Everyone with a name in a meeting: the voices with names and the invited people.
    static func names(in r: CallRecord, owner: String, directory: PersonDirectory) -> [String] {
        var seen: Set<String> = []
        let voices = r.speakerNames.values.filter { !$0.hasPrefix("Speaker ") }.sorted()
        let invited = r.attendees.compactMap { directory.link(for: $0) ?? ($0.contains("@") ? nil : $0) }
        return (voices + invited + [owner]).filter { seen.insert(PeopleDuplicates.normalized($0)).inserted }
    }

    /// The full name that a name as written ("Sam") stands for. It is read among the people of its own meeting
    /// first: "Sam" in a meeting with Sam Reed is Sam Reed, whoever is invited now. With two who fit, nobody.
    /// When the meeting gives no answer (it is gone, or nobody in it fits): a name of two words or more is
    /// itself, and a first name is the one saved person who has it.
    static func resolve(_ written: String, among call: [String], directory: PersonDirectory) -> String? {
        let fits = call.filter { PersonDirectory.isForm(written, of: $0) }
        if fits.count == 1 { return fits[0] }
        guard fits.isEmpty, !written.contains("@"), !written.hasPrefix("Speaker ") else { return nil }
        if written.split(whereSeparator: \.isWhitespace).count > 1 { return written }
        let saved = directory.people.map(\.name).filter { PersonDirectory.isForm(written, of: $0) }
        return saved.count == 1 ? saved[0] : nil
    }

    // MARK: Action items

    /// The action items of `r` for the page, and how many were left off.
    ///
    /// Every item shows, with its owner as the meeting wrote it. Only one kind is left off, and counted: an item
    /// of a person who is surely someone else than the invited people, which needs an invite of names only and
    /// an owner the meeting can name. "Sam and Jo", "Team", or an owner on an invite of addresses stays.
    ///
    /// An action item has no state of its own. The owner's tasks from this call give one: each task says the
    /// state of the one item that is most like it. A deleted task says nothing.
    ///
    /// Order: the owner's open items, the owner's with no known state, the other items in the meeting's order,
    /// and the owner's done items last.
    static func items(of r: CallRecord, owner: String, invite: Invite, directory: PersonDirectory, commitments: [Commitment]) -> (items: [Item], absent: Int) {
        let call = names(in: r, owner: owner, directory: directory)
        let ownerKey = PeopleDuplicates.normalized(owner)
        var absent = 0
        var items: [Item] = []
        for (i, item) in r.actionItems.enumerated() {
            let written = item.owner?.nonBlank
            let full = written.flatMap { resolve($0, among: call, directory: directory) }
            let mine = full.map { PeopleDuplicates.normalized($0) == ownerKey } ?? false
            if let full, !mine, invite.complete, !invite.has(full) {
                absent += 1
                continue
            }
            items.append(Item(id: "\(r.id).\(i)", task: item.task, owner: written, person: mine ? nil : written.flatMap { directory.link(for: $0, in: call) },
                              isOwners: mine, state: nil, callID: r.id, at: nil, atIsExact: false, commitment: nil))
        }
        // The best pair first, and each task and each item one time: one short task is not the state of every
        // longer item that holds its words.
        let tasks = commitments.filter { $0.callID == r.id && !$0.deleted }
        var pairs: [(item: Int, task: Int, likeness: Double)] = []
        for i in items.indices where items[i].isOwners || items[i].owner == nil {
            for (t, task) in tasks.enumerated() {
                let l = likeness(items[i].task, task.text)
                if l >= sameTask { pairs.append((i, t, l)) }
            }
        }
        var usedItems: Set<Int> = [], usedTasks: Set<Int> = []
        for pair in pairs.sorted(by: { ($0.likeness, $1.item, $1.task) > ($1.likeness, $0.item, $0.task) })
            where !usedItems.contains(pair.item) && !usedTasks.contains(pair.task) {
            usedItems.insert(pair.item)
            usedTasks.insert(pair.task)
            let task = tasks[pair.task]
            // The owner promised it, so it is the owner's, also when the summary named no owner.
            items[pair.item].isOwners = true
            items[pair.item].state = task.done == nil ? .open : .done
            items[pair.item].commitment = task
            items[pair.item].at = task.at
            items[pair.item].atIsExact = task.at != nil
        }
        func rank(_ item: Item) -> Int {
            switch (item.isOwners, item.state) {
            case (true, .open): 0
            case (true, nil): 1
            case (true, .done): 3
            default: 2
            }
        }
        return (items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element), absent)
    }

    /// Gives each item with no moment the line of the call that holds its words, when one does.
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
    /// A long turn plays from this long before the task's words, so the sentence is heard whole.
    static let momentLead: TimeInterval = 2

    /// Where the line that holds most of the task's words begins. Of equal lines the later one: a topic comes up
    /// before someone takes the task. With word times, the shortest stretch of that line that holds enough of
    /// the words, so a word of the topic early in a long turn does not start it there. Nil when no line holds
    /// enough of them: no moment is better than a wrong one. `words` are the lines' `keywords`.
    static func moment(of task: String, in lines: [Utterance], words: [Set<String>]) -> TimeInterval? {
        let wanted = keywords(task)
        guard wanted.count >= momentWords else { return nil }
        let needed = max(momentWords, Int((Double(wanted.count) * momentCover).rounded(.up)))
        var best: (line: Utterance, shared: Int)?
        for (line, has) in zip(lines, words) {
            let shared = wanted.intersection(has).count
            guard shared >= needed, shared >= (best?.shared ?? 0) else { continue }
            best = (line, shared)
        }
        guard let line = best?.line else { return nil }
        guard let timed = line.words, let start = shortestStretch(of: timed, with: wanted, needed: needed) else { return line.start }
        return max(line.start, start - momentLead)
    }

    /// The start of the shortest run of words that holds `needed` different words of `wanted`.
    static func shortestStretch(of words: [Word], with wanted: Set<String>, needed: Int) -> TimeInterval? {
        let stems = words.map { w in keywords(w.text).first { wanted.contains($0) } }
        var counts: [String: Int] = [:]
        var left = 0
        var best: (start: TimeInterval, length: TimeInterval)?
        for right in words.indices {
            guard let stem = stems[right] else { continue }
            counts[stem, default: 0] += 1
            while counts.count >= needed {
                // The run begins at a word of the task.
                while stems[left] == nil { left += 1 }
                let length = words[right].end - words[left].start
                if best.map({ length < $0.length }) ?? true { best = (words[left].start, length) }
                if let first = stems[left] {
                    counts[first] = counts[first]! - 1
                    if counts[first] == 0 { counts[first] = nil }
                }
                left += 1
            }
        }
        return best?.start
    }

    // MARK: Promises

    /// The owner's open tasks for the people of this meeting, oldest first: the ones promised to one of them, and
    /// the ones promised to nobody by name in a meeting of this series. The name is read in the task's own
    /// meeting (`resolve`), so "Sam" from a meeting with another Sam is not the invited one. `used` are on the
    /// page as action items, and `keep` were marked done on the page and stay.
    static func promises(_ commitments: [Commitment], invite: Invite, calls: [String: CallRecord], series: Set<String>, used: Set<UUID>, keep: Set<UUID>,
                         owner: String, directory: PersonDirectory) -> [Commitment] {
        commitments.filter { c in
            guard !c.deleted, c.done == nil || keep.contains(c.id), !used.contains(c.id) else { return false }
            guard let to = c.to?.nonBlank else { return c.callID.map(series.contains) ?? false }
            let call = c.callID.flatMap { calls[$0] }.map { names(in: $0, owner: owner, directory: directory) } ?? []
            return resolve(to, among: call, directory: directory).map(invite.has) ?? false
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

    /// A word of four letters keeps its "e": "note" is not "not".
    private static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "ed", "s"] where w.count - suffix.count >= 3 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count))
            break
        }
        return w.count >= 5 && w.hasSuffix("e") ? String(w.dropLast()) : w
    }

    /// An action item and a task are the same thing at this likeness or more. The summary and the task finder
    /// write one promise in two wordings.
    static let sameTask = 0.6

    /// How alike two tasks are, from 0 to 1: the words they share over all of their words. Measured against all
    /// the words, a short task is not like every longer one that holds it.
    static func likeness(_ a: String, _ b: String) -> Double {
        let x = keywords(a), y = keywords(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}
