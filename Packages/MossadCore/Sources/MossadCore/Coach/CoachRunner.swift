import Foundation

/// Reviews each written call once, oldest first, so every review builds on the profile the earlier ones left.
public actor CoachRunner {
    private let paths: Paths
    private let coach: any Coaching
    private let owner: String
    private let since: Date
    /// "Name, Title" lines for the names in a call; empty without an org chart.
    private let titles: @Sendable ([String]) -> [String]

    /// The meetings as rows of history. The app gives the cache of its Analytics tab, so a run reads only the
    /// meetings that changed.
    private let facts: MeetingFactsCache

    public init(paths: Paths, coach: any Coaching, owner: String, since: Date, titles: @escaping @Sendable ([String]) -> [String] = { _ in [] },
                facts: MeetingFactsCache = MeetingFactsCache(), now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        self.facts = facts
        self.titles = titles
        self.paths = paths
        self.coach = coach
        self.owner = owner
        self.since = since
    }

    /// The owner's voice from the mic track; nil when the track is gone (deleted by retention) or silent.
    private func measureTone(_ r: CallRecord) -> VoiceTone? {
        let keys = Set(r.speakerNames.filter { $0.value == owner }.keys)
        let turns = r.utterances.filter { $0.track == .me && keys.contains($0.speakerKey) }
        do {
            return try VoiceTone.measure(url: paths.callDirectory(r.id).appendingPathComponent(Track.me.fileName), turns: turns)
        } catch {
            return nil
        }
    }

    static func pending(_ records: [CallRecord], owner: String, since: Date, reviewed: Set<String>) -> [CallRecord] {
        records.filter { r in
            // A call where only others spoke still gets a review: whether it needed the owner is worth knowing.
            r.status == .written && r.start >= since && !reviewed.contains(r.id) && !r.utterances.isEmpty
        }.sorted { $0.start < $1.start }
    }

    private let now: @Sendable () -> Date

    /// Lets the owner's "Review again" try a call the coach gave up on.
    public static func forget(_ callID: String, paths: Paths) {
        var ledger = RetryLedger.load(from: paths.coach)
        guard ledger.entries[callID] != nil else { return }
        ledger.clear(callID)
        ledger.save(to: paths.coach)
    }

    /// Reviews every call that is due. A call that fails waits (an hour, six hours, a day) and the run stops there,
    /// so the order holds. After `RetryLedger.maxAttempts` billed failures the call is left out and the later calls
    /// go on, so one call that never works cannot cost a request every hour or hold back every other review.
    @discardableResult
    public func run(onReview: @Sendable (String) async -> Void = { _ in }) async -> Int {
        // A profile that was set aside starts empty; reviews wait until the other device's copy is merged in.
        guard !StoredFile.awaitsMerge(paths.coach.appendingPathComponent(CoachProfile.fileName)) else { return 0 }
        // The coach knows the owner by the name in Settings. A record from before a change of "Your name" has an older
        // name of the owner, and without this the coach would find no line of the owner's in it.
        let identity = OwnerIdentity.read(name: owner, paths: paths)
        let records = ProcessingQueue(paths: paths).allRecords().map(identity.withCurrentName)
        let reviews = records.compactMap { r in CoachReview.load(in: paths.callDirectory(r.id)).map { (callID: r.id, date: r.start, review: $0) } }
        let reviewed = Set(reviews.map(\.callID))
        var profile: CoachProfile
        do { profile = try CoachProfile.load(from: paths.coach) } catch {
            Log.error("The coach profile could not be read: \(error)")
            return 0
        }
        var ledger = RetryLedger.load(from: paths.coach)
        var done = 0
        let pending = Self.pending(records, owner: owner, since: since, reviewed: reviewed)
        guard !pending.isEmpty else { return 0 }
        // A memory from before the advice log gets it one time, from what the reviews of the last 30 days
        // showed, so the first review after the update does not say it once more. It is saved with that review.
        let seed = profile.adviceVersion < CoachSkill.version ? AdviceRules.seed(from: reviews, now: now()) : nil
        if let seed { profile.seed(seed) }
        // Each written meeting as a row of history, for what is usual: read when the first call is ready.
        var history: [MeetingFacts]?
        for r in pending {
            switch ledger.state(r.id, now: now()) {
            case .gaveUp: continue
            case .waiting: return done
            case .ready: break
            }
            if history == nil { history = facts.facts(for: records, owner: owner) }
            do {
                let current = profile, tone = measureTone(r)
                let measured = CoachMeasured(record: r, owner: owner, history: history ?? [], commitments: CommitmentBook.peek(in: paths.commitments)?.visible ?? [])
                let written = try await UsageContext.$callID.withValue(r.id) {
                    try await coach.review(record: r, profile: current, tone: tone, people: titles(Array(Set(r.speakerNames.values)).sorted()), measured: measured)
                }
                var result = CoachLineRules.settle(written, record: r, owner: owner, profile: current, measured: measured)
                // Who each conclusion and each note is about, as a saved person: only on a sure match.
                let saved = CoachPeople.read(paths: paths)
                result.questions = result.questions.map { q in
                    var q = q
                    if let subject = saved.subject(of: q.statement, about: q.about, in: r, firstName: CoachPeople.isCard(q)) {
                        q.person = subject.id
                        q.personName = subject.name
                    }
                    return q
                }
                var ids: [String: String] = [:]
                for p in result.update.people { ids[p.name] = saved.id(of: p.name) }
                if !result.dropped.isEmpty { Log.info("The coach's review of \(r.id) lost \(result.dropped.count) notes. \(result.dropped.joined(separator: "; "))") }
                // Deleted or merged away during the review: no review file, and nothing learned from it.
                guard FileManager.default.fileExists(atPath: paths.callDirectory(r.id).appendingPathComponent(CallRecord.fileName).path) else {
                    Log.info("\(r.id) was removed during its review; the review is dropped")
                    continue
                }
                try result.review.save(in: paths.callDirectory(r.id))
                // Read again before saving: the owner may have added guidance while the review ran. A profile that
                // cannot be read now stops the run; saving the older copy would write the owner's changes away.
                var fresh = try CoachProfile.load(from: paths.coach)
                if let seed, fresh.adviceVersion < CoachSkill.version { fresh.seed(seed) }
                fresh.apply(result.update, review: result.review, callID: r.id, title: r.title, at: r.start, proposal: result.proposal, advice: result.advice,
                            people: ids)
                fresh.ask(result.questions)
                try fresh.save(to: paths.coach)
                profile = fresh
                done += 1
                if ledger.entries[r.id] != nil { ledger.clear(r.id); ledger.save(to: paths.coach) }
                // The kinds and the skill keys only, never the words: how often the model uses "other" says
                // whether the list needs a key.
                let keys = result.advice.map { "\($0.held ? "counted" : $0.shown ? "line" : "full review") \($0.kind.rawValue) \($0.skill.hasPrefix("other:") ? "other" : $0.skill)" }
                Log.info("Coached \(r.id)" + (keys.isEmpty ? ": no line" : ": " + keys.joined(separator: ", ")))
                await onReview(r.id)
            } catch {
                guard !RetryLedger.isUnbilled(error), !(error is UnreadableFile) else {
                    Log.error("Coaching \(r.id) waits: \(error)")
                    return done
                }
                ledger.fail(r.id, reason: Pipeline.failureReason(error), now: now())
                ledger.save(to: paths.coach)
                if ledger.state(r.id, now: now()) == .gaveUp {
                    Log.error("Coaching \(r.id) failed \(RetryLedger.maxAttempts) times; it is left out. Use Review again to try it: \(error)")
                    continue
                }
                Log.error("Coaching \(r.id) failed; it waits before the next try: \(error)")
                return done
            }
        }
        return done
    }
}
