import Foundation

/// Reviews each written call once, oldest first, so every review builds on the profile the earlier ones left.
public actor CoachRunner {
    private let paths: Paths
    private let coach: any Coaching
    private let owner: String
    private let since: Date

    public init(paths: Paths, coach: any Coaching, owner: String, since: Date) {
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

    /// Reviews every call that is due. Stops at the first failure so the order holds; the next run retries it.
    @discardableResult
    public func run(onReview: @Sendable (String) async -> Void = { _ in }) async -> Int {
        let records = ProcessingQueue(paths: paths).allRecords()
        let reviewed = Set(records.map(\.id).filter { CoachReview.load(in: paths.callDirectory($0)) != nil })
        var profile: CoachProfile
        do { profile = try CoachProfile.load(from: paths.coach) } catch {
            Log.error("The coach profile could not be read: \(error)")
            return 0
        }
        var done = 0
        for r in Self.pending(records, owner: owner, since: since, reviewed: reviewed) {
            do {
                let current = profile, tone = measureTone(r)
                let result = try await UsageContext.$callID.withValue(r.id) { try await coach.review(record: r, profile: current, tone: tone) }
                try result.review.save(in: paths.callDirectory(r.id))
                profile.apply(result.update, review: result.review, callID: r.id, title: r.title, at: r.start)
                try profile.save(to: paths.coach)
                done += 1
                Log.info("Coached \(r.id)")
                await onReview(r.id)
            } catch {
                Log.error("Coaching \(r.id) failed: \(error)")
                break
            }
        }
        return done
    }
}
