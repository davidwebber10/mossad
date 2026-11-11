import Foundation

/// One budget for each read of an older call: the first fill, a call that is due again after a change (a voice
/// named, a prompt of a later build), and a person's calls after "Keep a read" is on again. A new call is not in it:
/// it gets the usual step, about a cent, also when the budget is used up.
///
/// The rules, all here and tested:
/// - The budget is $1 in each 30 days, across launches: the spends are kept on disk with their dates. A rename
///   costs nothing, because the stamp of a call holds ids, not names.
/// - The first fill starts only when its estimate fits the budget. Above it, or with a price that is not known,
///   nothing is sent until the owner's yes in Settings > Coach.
/// - The owner's yes holds for 30 days and for that model only. With a known price it gives a cap (the estimate and
///   a quarter, $5 at most); with an unknown price it gives a number of calls.
/// - The fill is done only when no older call is due. A call that is left out for good is not due.
public struct PersonaBudget: Codable, Equatable, Sendable {
    static let fileName = "_budget.json"
    public static let cap = 1.0
    public static let windowDays = 30.0
    public static let maxApprovedCap = 5.0

    public struct Spend: Codable, Equatable, Sendable {
        public var date: Date
        public var dollars: Double
        public var calls: Int
    }

    public struct Approval: Codable, Equatable, Sendable {
        public var date: Date
        public var model: String
        /// Dollars, with a known price.
        public var cap: Double?
        /// Calls left, with an unknown price.
        public var calls: Int?
    }

    /// Why older calls wait, for the one line in Settings > Coach.
    public enum Wait: Equatable, Sendable {
        /// The people do not have their ids yet: nothing to say to the owner.
        case people
        case overEstimate(calls: Int, dollars: Double)
        case unknownPrice(calls: Int, model: String)
        case capReached(calls: Int, spent: Double, cap: Double)

        /// The line, or nil when there is nothing to tell.
        public var text: String? {
            switch self {
            case .people: nil
            case .overEstimate(let calls, let dollars):
                String(format: "Reading your %d older calls once would cost about $%.2f, more than the $%.2f that Mossad spends by itself in 30 days.", calls, dollars, PersonaBudget.cap)
            case .unknownPrice(let calls, let model):
                "Mossad does not know the price of \(model), so it does not read your \(calls) older calls by itself."
            case .capReached(let calls, let spent, let cap):
                String(format: "%d older calls wait: $%.2f of $%.2f for older calls in 30 days is spent. New calls are still read.", calls, spent, cap)
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// No older call is due.
        case done
        /// Read older calls: within these dollars (nil: no dollar limit, a free model or the owner's count) and this
        /// many calls at most (nil: no count).
        case read(dollars: Double?, calls: Int?)
        case wait(Wait)
    }

    public var spends: [Spend] = []
    public var approval: Approval?
    /// The first fill passed its estimate once: later older calls only need room in the budget.
    public var started = false

    public init() {}

    /// The usage log keeps whole seconds: a start in the same second as a request must count that request.
    public static func second(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970).rounded(.down)) }

    public func spent(now: Date) -> Double {
        spends.filter { now.timeIntervalSince($0.date) < Self.windowDays * 86_400 }.reduce(0) { $0 + $1.dollars }
    }

    /// The owner's yes, when it is for this model and still holds.
    public func approval(for model: String, now: Date) -> Approval? {
        guard let a = approval, a.model == model, now.timeIntervalSince(a.date) < Self.windowDays * 86_400 else { return nil }
        return a
    }

    /// What to do about older calls. `price` is nil when the model is free (on the Mac or the owner's server); `known`
    /// is false when a cloud model has no list price.
    public func decide(backlog: Int, estimate: Double, priceKnown: Bool, free: Bool, model: String, referencesReady: Bool, now: Date) -> Decision {
        guard backlog > 0 else { return .done }
        guard referencesReady else { return .wait(.people) }
        if free { return .read(dollars: nil, calls: nil) }
        let yes = approval(for: model, now: now)
        guard priceKnown else {
            if let left = yes?.calls, left > 0 { return .read(dollars: nil, calls: left) }
            return .wait(.unknownPrice(calls: backlog, model: model))
        }
        let cap = max(Self.cap, yes?.cap ?? 0)
        if !started, estimate > cap { return .wait(.overEstimate(calls: backlog, dollars: estimate)) }
        // In cents of a cent, so the same spends give the same room on each launch.
        let left = ((cap - spent(now: now)) * 10_000).rounded(.down) / 10_000
        guard left > 0 else { return .wait(.capReached(calls: backlog, spent: spent(now: now), cap: cap)) }
        return .read(dollars: left, calls: nil)
    }

    /// A round of older calls cost this much.
    public mutating func record(dollars: Double, calls: Int, now: Date) {
        started = true
        if dollars > 0 || calls > 0 { spends.append(Spend(date: now, dollars: dollars, calls: calls)) }
        spends.removeAll { now.timeIntervalSince($0.date) >= Self.windowDays * 86_400 * 2 }
        if let left = approval?.calls { approval?.calls = max(0, left - calls) }
    }

    /// The owner's yes in Settings > Coach.
    public mutating func approve(model: String, estimate: Double, priceKnown: Bool, backlog: Int, now: Date) {
        approval = priceKnown
            ? Approval(date: now, model: model, cap: min(Self.maxApprovedCap, max(Self.cap, (estimate * 1.25 * 100).rounded(.up) / 100)), calls: nil)
            : Approval(date: now, model: model, cap: nil, calls: backlog)
        started = true
    }

    public static func load(from dir: URL) -> PersonaBudget {
        (try? Data(contentsOf: dir.appendingPathComponent(fileName))).flatMap { try? JSONDecoder.coach.decode(PersonaBudget.self, from: $0) } ?? PersonaBudget()
    }

    public func save(to dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        } catch {
            Log.error("The budget of the reads could not be saved: \(error)")
        }
    }
}

/// One run of the persona step in the app: new calls first, with the usual step; then older calls within the
/// budget, newest first; then the sentences, within the room that is left. Never while a call is recorded.
public enum PersonaBacklog {
    public struct Outcome: Sendable, Equatable {
        public var newCalls = PersonaRunner.Report()
        public var olderCalls = PersonaRunner.Report()
        public var decision: PersonaBudget.Decision = .done
        /// The line for Settings > Coach, or nil.
        public var note: String?
    }

    /// The due calls in two groups: new (from `since`, never read) and older (the rest that is due).
    public static func split(_ records: [CallRecord], ledger: PersonaLedger, since: Date, saved: CoachPeople, owner: String) -> (new: [CallRecord], older: [CallRecord]) {
        let due = PersonaRunner.due(records, ledger: ledger, since: nil, saved: saved, owner: owner)
        let new = due.filter { $0.start >= since && !ledger.wasRead($0.id) }
        let ids = Set(new.map(\.id))
        return (new, due.filter { !ids.contains($0.id) })
    }

    /// `spent(since)` reads the persona spend in the usage log from a time on. `rounds` bounds one run.
    public static func run(runner: PersonaRunner, paths: Paths, owner: String, model: String, service: UsageEvent.Service, since: Date, referencesReady: Bool,
                           callsPerRound: Int = 10, rounds: Int = 30, now: @escaping @Sendable () -> Date = Date.init,
                           spent: @escaping @Sendable (Date) -> Double, isLive: @escaping @Sendable () async -> Bool) async -> Outcome {
        var out = Outcome()
        // Nothing before the people have their ids: a call read before them would be read again after.
        guard referencesReady else { out.decision = .wait(.people); return out }
        let price = PersonaFill.price(service: service, model: model)
        let dir = PersonaStore(paths: paths).directory
        let owner = owner
        func groups() -> (new: [CallRecord], older: [CallRecord]) {
            split(PersonaRunner.records(paths: paths, owner: owner), ledger: PersonaLedger.load(from: dir), since: since, saved: CoachPeople.read(paths: paths), owner: owner)
        }

        // New calls: the usual step, a cent each, never stopped by the budget of older calls.
        let new = Set(groups().new.map(\.id))
        if !new.isEmpty {
            out.newCalls = await runner.run(since: nil, only: new, callLimit: callsPerRound, writeLimit: 0, isLive: isLive, price: price.cost)
        }

        var budget = PersonaBudget.load(from: dir)
        var older = groups().older
        let estimate = PersonaRunner.estimate(paths: paths, owner: owner, since: nil, only: Set(older.map(\.id)), price: price.cost).dollars
        out.decision = budget.decide(backlog: older.count, estimate: estimate, priceKnown: price.known, free: service == .local, model: model,
                                     referencesReady: referencesReady, now: now())
        var room: Double? = nil
        var round = 0
        let phase = PersonaBudget.second(now())
        while case .read(let dollars, let calls) = out.decision, round < rounds, !older.isEmpty {
            round += 1
            if await isLive() { break }
            // Each round's cost is the growth of the log from one start of the phase: rounds in one second count once.
            let base = spent(phase)
            room = dollars
            let limit = min(callsPerRound, calls ?? callsPerRound)
            let report = await runner.run(since: nil, only: Set(older.map(\.id)), callLimit: limit, newestFirst: true, writeLimit: 0, isLive: isLive,
                                          canSpend: { cost in dollars.map { spent(phase) - base + cost <= $0 } ?? true }, price: price.cost)
            out.olderCalls.calls += report.calls
            out.olderCalls.handled += report.handled
            out.olderCalls.requests += report.requests
            out.olderCalls.stopped = report.stopped
            budget.record(dollars: spent(phase) - base, calls: report.handled, now: now())
            budget.save(to: dir)
            older = groups().older
            out.decision = budget.decide(backlog: older.count, estimate: 0, priceKnown: price.known, free: service == .local, model: model,
                                         referencesReady: referencesReady, now: now())
            // A run that took up no call stops: the cap, an error, or a call that started.
            if report.stopped != nil || report.handled == 0 { break }
        }
        if older.isEmpty { out.decision = .done }
        let cap = max(PersonaBudget.cap, budget.approval(for: model, now: now())?.cap ?? 0)
        if !older.isEmpty, out.olderCalls.stopped == "the cap" {
            out.decision = .wait(.capReached(calls: older.count, spent: budget.spent(now: now()), cap: cap))
        }

        // The sentences of each person whose evidence changed, 5 people at most. After a round of older calls they
        // count against the room that the budget has left.
        if !(await isLive()) {
            let base = spent(phase)
            let left = room == nil ? nil : max(0, cap - budget.spent(now: now()))
            let write = await runner.run(since: nil, only: [], isLive: isLive, canSpend: { cost in left.map { spent(phase) - base + cost <= $0 } ?? true },
                                         price: price.cost)
            out.newCalls.people += write.people
            out.newCalls.requests += write.requests
            if left != nil {
                budget.record(dollars: spent(phase) - base, calls: 0, now: now())
                budget.save(to: dir)
            }
        }
        if case .wait(let w) = out.decision { out.note = w.text }
        return out
    }

    /// The owner's yes for the older calls that wait.
    public static func approve(paths: Paths, owner: String, model: String, service: UsageEvent.Service, since: Date, now: Date = Date()) {
        let dir = PersonaStore(paths: paths).directory
        let price = PersonaFill.price(service: service, model: model)
        let older = split(PersonaRunner.records(paths: paths, owner: owner), ledger: PersonaLedger.load(from: dir), since: since, saved: CoachPeople.read(paths: paths),
                          owner: owner).older
        let estimate = PersonaRunner.estimate(paths: paths, owner: owner, since: nil, only: Set(older.map(\.id)), price: price.cost).dollars
        var budget = PersonaBudget.load(from: dir)
        budget.approve(model: model, estimate: estimate, priceKnown: price.known, backlog: older.count, now: now)
        budget.save(to: dir)
    }
}
