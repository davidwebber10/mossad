import Foundation

/// One person's calls with the owner, in relation to the owner: talk balance, cadence, who leads, cutting in,
/// reply times, shared topics, open items both ways, and how the meetings were rated. Pure.
public struct PersonRelation: Sendable {
    public struct Balance: Sendable, Equatable {
        public var mine: TimeInterval = 0
        public var theirs: TimeInterval = 0
        /// The owner's part of the two, nil when neither spoke.
        public var share: Double? { mine + theirs > 0 ? mine / (mine + theirs) : nil }
    }

    public struct Week: Sendable, Identifiable {
        public var id: Date { start }
        public var start: Date
        public var calls: Int
    }

    public struct Slot: Sendable, Equatable {
        /// 1 is Sunday, as in `Calendar`.
        public var weekday: Int
        public var hour: Int
    }

    public struct Item: Sendable, Identifiable {
        public var id: String { callID + task }
        public var callID: String
        public var title: String
        public var date: Date
        public var task: String
    }

    static let weeks = 26

    public let name: String
    public let calls: Int
    public let seconds: TimeInterval
    public let oneOnOne: Balance?
    public let group: Balance?
    public let weekly: [Week]
    public let averageGapDays: Double?
    public let lastMet: Date?
    public let usualSlot: Slot?
    /// Calls the owner spoke in first, and calls this person did.
    public let ownerFirst: Int
    public let theyFirst: Int
    public let myQuestionsPerHour: Double?
    public let theirQuestionsPerHour: Double?
    /// The owner cutting in on this person, and this person on the owner, per hour together.
    public let iInterruptPerHour: Double?
    public let theyInterruptPerHour: Double?
    /// The usual pause before the owner answers them, and before they answer the owner.
    public let myReply: TimeInterval?
    public let theirReply: TimeInterval?
    public let topics: [String]
    /// Action items this person owns from shared meetings.
    public let theirItems: [Item]
    /// The owner's action items from the 1:1s with this person: in a group, an item is not between the two.
    public let myItems: [Item]
    /// The owner's commitments to this person.
    public let myCommitments: [Commitment]
    public let value: [MeetingValue.Rating: Int]

    /// `personID`: the person's id in `people.json`. With it, a meeting, an item, or a commitment is this person's
    /// by the id; one with no id counts by the name only when `nameIsUnique` (no other saved person has the name).
    /// Without it, everything counts by the name, as before ids.
    public init(name: String, personID: String? = nil, owner: String, records all: [CallRecord], reviews: [String: CoachReview] = [:],
                commitments: [Commitment] = [], nameIsUnique: Bool = false, now: Date = Date(), calendar: Calendar = .current) {
        self.name = name
        func isThem(_ key: String, in r: CallRecord) -> Bool {
            if let personID, let id = r.speakerPeople?[key] { return id == personID }
            return r.speakerNames[key] == name && (personID == nil || nameIsUnique)
        }
        let shared = all.filter { r in r.status == .written && r.speakerNames.keys.contains { isThem($0, in: r) } }.sorted { $0.start < $1.start }
        calls = shared.count
        seconds = shared.reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
        let hours = seconds / 3600

        var one = Balance(), many = Balance()
        var hasOne = false, hasMany = false
        var ownerFirst = 0, theyFirst = 0
        var myQ = 0, theirQ = 0, iCut = 0, theyCut = 0
        var mine: [Double] = [], theirs: [Double] = []
        var tags: [String: Int] = [:]
        var items: [Item] = [], mine1on1: [Item] = []
        var value: [MeetingValue.Rating: Int] = [:]
        for r in shared {
            let x = Exchange(record: r)
            if x.names.subtracting([owner]).count == 1 {
                hasOne = true
                mine1on1 += r.actionItems.filter { $0.owner == owner }.map { Item(callID: r.id, title: r.title, date: r.start, task: $0.task) }
                one.mine += x.speech(owner); one.theirs += x.speech(name)
            } else {
                hasMany = true
                many.mine += x.speech(owner); many.theirs += x.speech(name)
            }
            if x.firstSpeaker == owner { ownerFirst += 1 } else if x.firstSpeaker == name { theyFirst += 1 }
            myQ += x.questions(owner); theirQ += x.questions(name)
            iCut += x.interruptions(by: owner, of: name); theyCut += x.interruptions(by: name, of: owner)
            mine += x.replyGaps(to: name, from: owner); theirs += x.replyGaps(to: owner, from: name)
            for t in Set(r.tags) { tags[t, default: 0] += 1 }
            items += r.actionItems.filter { item in
                if let personID, let id = item.ownerID { return id == personID }
                return item.owner == name && (personID == nil || nameIsUnique)
            }.map { Item(callID: r.id, title: r.title, date: r.start, task: $0.task) }
            if let rating = reviews[r.id]?.value?.rating { value[rating, default: 0] += 1 }
        }
        oneOnOne = hasOne ? one : nil
        group = hasMany ? many : nil
        self.ownerFirst = ownerFirst
        self.theyFirst = theyFirst
        myQuestionsPerHour = hours > 0 ? Double(myQ) / hours : nil
        theirQuestionsPerHour = hours > 0 ? Double(theirQ) / hours : nil
        iInterruptPerHour = hours > 0 ? Double(iCut) / hours : nil
        theyInterruptPerHour = hours > 0 ? Double(theyCut) / hours : nil
        myReply = median(of: mine)
        theirReply = median(of: theirs)
        topics = tags.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map(\.key)
        theirItems = items.reversed()
        myCommitments = commitments.filter { c in
            guard !c.deleted else { return false }
            if let personID {
                // By the id; with none, only the whole name: a first name can be two people.
                if let id = c.toID { return id == personID }
                return nameIsUnique && c.to == name
            }
            return c.to.map { $0 == name || firstWord($0) == firstWord(name) } == true
        }
        self.value = value
        // An item of the owner's that is also a promise to this person, from the same call, shows once: as the promise.
        let promised = myCommitments
        myItems = mine1on1.reversed().filter { item in
            !promised.contains { $0.callID == item.callID && Self.sameTask($0.text, item.task, name: name) }
        }

        lastMet = shared.last?.start
        let gaps = zip(shared, shared.dropFirst()).map { $1.start.timeIntervalSince($0.start) / 86_400 }
        averageGapDays = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        var slots: [Int: Int] = [:]
        for r in shared { slots[calendar.component(.weekday, from: r.start) * 100 + calendar.component(.hour, from: r.start), default: 0] += 1 }
        usualSlot = slots.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { Slot(weekday: $0.key / 100, hour: $0.key % 100) }

        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        weekly = (0..<Self.weeks).reversed().map { back in
            let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek)!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return Week(start: start, calls: shared.filter { $0.start >= start && $0.start < end }.count)
        }
    }
}

extension PersonRelation {
    /// "Send Sam the vendor draft" and "Send the vendor draft": the same words, without the person's name.
    static func sameTask(_ a: String, _ b: String, name: String) -> Bool {
        let theirs = Set(name.lowercased().split(separator: " ").map(String.init))
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)).subtracting(theirs)
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }
}

private func firstWord(_ s: String) -> String { s.split(separator: " ").first.map { $0.lowercased() } ?? s.lowercased() }
