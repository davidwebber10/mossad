import Foundation

/// Reviews each written call once, oldest first, so every review builds on the profile the earlier ones left.
public actor CoachRunner {
    /// A call where the owner spoke less than this gives the coach nothing to work with.
    static let minimumOwnerSeconds: TimeInterval = 60

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

    static func pending(_ records: [CallRecord], owner: String, since: Date, reviewed: Set<String>) -> [CallRecord] {
        records.filter { r in
            r.status == .written && r.start >= since && !reviewed.contains(r.id)
                && DeliveryStats(record: r, owner: owner).talkSeconds >= minimumOwnerSeconds
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
                let current = profile
                let result = try await UsageContext.$callID.withValue(r.id) { try await coach.review(record: r, profile: current) }
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
