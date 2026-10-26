import Foundation

extension AnalyticsReport {
    /// How calls fill the working week (Monday to Friday).
    public struct Workday: Sendable, Equatable {
        public var workdays = 0
        public var hoursPerWorkday = 0.0
        /// Calls that start within 5 minutes of the one before ending, as a share of calls.
        public var backToBackShare: Double?
        public var callFreeDays = 0
        /// The share of the 8:00 to 18:00 hours spent in calls.
        public var coreHoursShare = 0.0
    }

    public struct CommunicationPoint: Sendable, Identifiable {
        public var id: String { callID }
        public var callID: String
        public var date: Date
        public var questionsPerHour: Double
        public var interruptionsPerHour: Double
        public var talkShare: Double?
    }

    /// The owner's turn-taking, per hour of calls, from the transcripts.
    public struct Communication: Sendable {
        public var questionsPerHour: Double?
        public var interruptionsMadePerHour: Double?
        public var interruptionsReceivedPerHour: Double?
        /// The owner's part of the speech in calls with one other person, and with more.
        public var oneOnOneShare: Double?
        public var groupShare: Double?
        public var points: [CommunicationPoint] = []
    }

    public struct Outcomes: Sendable {
        public var itemsPerHour = 0.0
        public var decisionsPerHour = 0.0
        /// Calls with an action item or a decision, as a share of calls.
        public var withOutcomesShare: Double?
        /// Action items the owner owns, and the ones others own.
        public var mine = 0
        public var others = 0
        /// The owner's commitments made in the period, and how many of them are done.
        public var commitmentsMade = 0
        public var commitmentsDone = 0
    }

    static let backToBackGap: TimeInterval = 5 * 60
    static let coreHours = 8..<18

    static func workday(_ records: [CallRecord], interval: DateInterval, calendar: Calendar) -> Workday {
        var w = Workday()
        var day = calendar.startOfDay(for: interval.start)
        var busy: Set<Date> = []
        for r in records { busy.insert(calendar.startOfDay(for: r.start)) }
        var core = 0.0
        while day < interval.end {
            if !calendar.isDateInWeekend(day) {
                w.workdays += 1
                if !busy.contains(day) { w.callFreeDays += 1 }
                let open = calendar.date(bySettingHour: coreHours.lowerBound, minute: 0, second: 0, of: day)!
                let close = calendar.date(bySettingHour: coreHours.upperBound, minute: 0, second: 0, of: day)!
                for r in records {
                    core += max(0, min(r.end, close).timeIntervalSince(max(r.start, open)))
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let workdayRecords = records.filter { !calendar.isDateInWeekend($0.start) }
        let seconds = workdayRecords.reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
        w.hoursPerWorkday = w.workdays > 0 ? seconds / 3600 / Double(w.workdays) : 0
        w.coreHoursShare = w.workdays > 0 ? core / (Double(w.workdays) * Double(coreHours.count) * 3600) : 0
        if !records.isEmpty {
            let back = zip(records, records.dropFirst()).filter { a, b in
                calendar.isDate(a.start, inSameDayAs: b.start) && b.start.timeIntervalSince(a.end) <= backToBackGap
            }.count
            w.backToBackShare = Double(back) / Double(records.count)
        }
        return w
    }

    static func communication(_ records: [CallRecord], owner: String, callSeconds: TimeInterval) -> Communication {
        var c = Communication()
        var questions = 0, made = 0, received = 0
        var one = (mine: 0.0, all: 0.0), group = (mine: 0.0, all: 0.0)
        for r in records {
            let x = Exchange(record: r)
            let others = x.names.subtracting([owner])
            guard x.names.contains(owner) else { continue }
            let q = x.questions(owner), m = x.interruptions(by: owner)
            questions += q
            made += m
            received += others.map { x.interruptions(by: $0, of: owner) }.reduce(0, +)
            let mine = x.speech(owner), all = x.names.map(x.speech).reduce(0, +)
            if others.count == 1 { one.mine += mine; one.all += all } else if others.count > 1 { group.mine += mine; group.all += all }
            let hours = max(r.end.timeIntervalSince(r.start), 1) / 3600
            c.points.append(CommunicationPoint(callID: r.id, date: r.start, questionsPerHour: Double(q) / hours,
                                               interruptionsPerHour: Double(m) / hours, talkShare: all > 0 ? mine / all : nil))
        }
        let hours = callSeconds / 3600
        if hours > 0 {
            c.questionsPerHour = Double(questions) / hours
            c.interruptionsMadePerHour = Double(made) / hours
            c.interruptionsReceivedPerHour = Double(received) / hours
        }
        c.oneOnOneShare = one.all > 0 ? one.mine / one.all : nil
        c.groupShare = group.all > 0 ? group.mine / group.all : nil
        return c
    }

    static func outcomes(_ records: [CallRecord], owner: String, callSeconds: TimeInterval, commitments: [Commitment],
                         interval: DateInterval) -> Outcomes {
        var o = Outcomes()
        let hours = callSeconds / 3600
        let items = records.flatMap(\.actionItems)
        let decisions = records.map(\.decisions.count).reduce(0, +)
        o.itemsPerHour = hours > 0 ? Double(items.count) / hours : 0
        o.decisionsPerHour = hours > 0 ? Double(decisions) / hours : 0
        if !records.isEmpty {
            o.withOutcomesShare = Double(records.filter { !$0.actionItems.isEmpty || !$0.decisions.isEmpty }.count) / Double(records.count)
        }
        o.mine = items.filter { $0.owner == owner }.count
        o.others = items.count - o.mine
        let made = commitments.filter { !$0.deleted && interval.contains($0.madeAt) }
        o.commitmentsMade = made.count
        o.commitmentsDone = made.filter { $0.done != nil }.count
        return o
    }
}
