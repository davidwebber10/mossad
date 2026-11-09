import Foundation

/// Reviews each written call once, oldest first, so every review builds on the profile the earlier ones left.
public actor CoachRunner {
    private let paths: Paths
    private let coach: any Coaching
    private let owner: String
    private let since: Date
    /// "Name, Title" lines for the names in a call; empty without an org chart.
    private let titles: @Sendable ([String]) -> [String]

    public init(paths: Paths, coach: any Coaching, owner: String, since: Date, titles: @escaping @Sendable ([String]) -> [String] = { _ in [] },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
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
        let records = ProcessingQueue(paths: paths).allRecords()
        let reviewed = Set(records.map(\.id).filter { CoachReview.load(in: paths.callDirectory($0)) != nil })
        var profile: CoachProfile
        do { profile = try CoachProfile.load(from: paths.coach) } catch {
            Log.error("The coach profile could not be read: \(error)")
            return 0
        }
        var ledger = RetryLedger.load(from: paths.coach)
        var done = 0
        for r in Self.pending(records, owner: owner, since: since, reviewed: reviewed) {
            switch ledger.state(r.id, now: now()) {
            case .gaveUp: continue
            case .waiting: return done
            case .ready: break
            }
            do {
                let current = profile, tone = measureTone(r)
                let result = try await UsageContext.$callID.withValue(r.id) { try await coach.review(record: r, profile: current, tone: tone, people: titles(Array(Set(r.speakerNames.values)).sorted())) }
                // Deleted or merged away during the review: no review file, and nothing learned from it.
                guard FileManager.default.fileExists(atPath: paths.callDirectory(r.id).appendingPathComponent(CallRecord.fileName).path) else {
                    Log.info("\(r.id) was removed during its review; the review is dropped")
                    continue
                }
                try result.review.save(in: paths.callDirectory(r.id))
                // Read again before saving: the owner may have added guidance while the review ran. A profile that
                // cannot be read now stops the run; saving the older copy would write the owner's changes away.
                var fresh = try CoachProfile.load(from: paths.coach)
                fresh.apply(result.update, review: result.review, callID: r.id, title: r.title, at: r.start, proposal: result.proposal)
                fresh.ask(result.questions)
                try fresh.save(to: paths.coach)
                profile = fresh
                done += 1
                if ledger.entries[r.id] != nil { ledger.clear(r.id); ledger.save(to: paths.coach) }
                Log.info("Coached \(r.id)")
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
