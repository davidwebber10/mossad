import Foundation
import MossadCore

extension AppController {
    /// How far back the coach starts when it is turned on, so it has some history to build on.
    static let coachBackfillDays = 14.0

    func turnOnCoach() {
        if coachSince == 0 { coachSince = Date().addingTimeInterval(-Self.coachBackfillDays * 86_400).timeIntervalSince1970 }
        runCoach()
    }

    var coachProfile: CoachProfile { (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile() }

    func coachReview(_ callID: String) -> CoachReview? { CoachReview.load(in: paths.callDirectory(callID)) }

    /// Reviews the calls that are due, one at a time, then sends the weekly email when it is due.
    func runCoach() {
        guard coachEnabled, !coaching, let llm = languageModel else { return }
        coaching = true
        let runner = CoachRunner(paths: paths, coach: LLMCoach(llm: llm, ownerName: ownerName), owner: ownerName,
                                 since: Date(timeIntervalSince1970: coachSince))
        Task {
            await runner.run { _ in await MainActor.run { self.coachVersion += 1 } }
            coaching = false
            syncToICloud()
            await sendCoachEmail()
        }
    }

    /// `now` sends last week's email even when this week's was sent already.
    func sendCoachEmail(now: Bool = false) async {
        guard coachEnabled, coachEmailEnabled || now, let to = coachEmailTo.nonEmpty, coachEmailFrom.nonEmpty != nil,
              let llm = languageModel, let secret = keychain.get(mailProvider.key) else { return }
        let last = now || coachLastEmail == 0 ? nil : Date(timeIntervalSince1970: coachLastEmail)
        if let sent = await WeeklyEmail.sendIfDue(paths: paths, owner: ownerName, to: to, lastSent: last,
                                                  writer: LLMDigestWriter(llm: llm), mailer: mailSettings.mailer(mailProvider, secret: secret)) {
            coachLastEmail = sent.timeIntervalSince1970
        }
    }
}

extension AppController {
    /// Saves a 👍 or 👎 on one point. A note goes to the coach as a reply, so it can learn from it.
    func rateCoachPoint(callID: String, point: CoachPoint, agree: Bool, note: String?) async throws {
        let dir = paths.callDirectory(callID)
        guard var review = CoachReview.load(in: dir), let record = try? CallRecord.load(from: dir) else { return }
        let feedback = CoachFeedback(agree: agree, note: note?.nonEmpty)
        review.feedback[point.title] = feedback
        try review.save(in: dir)
        var profile = coachProfile
        profile.remember(feedback, on: point, callID: callID, title: record.title)
        try profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
        if let note = feedback.note {
            try await replyToCoach(callID: callID, message: "About your point “\(point.title)”: \(note)")
        }
    }

    /// Sends a reply to the coach about one review; the answer joins the review's thread, and any new
    /// guidance joins the profile.
    func replyToCoach(callID: String, message: String) async throws {
        guard let llm = languageModel else { throw MissingAPIKey(service: aiProvider.displayName) }
        let dir = paths.callDirectory(callID)
        guard let review = CoachReview.load(in: dir), let record = try? CallRecord.load(from: dir) else { return }
        let answer = try await UsageContext.$callID.withValue(callID) {
            try await CoachResponder(llm: llm, ownerName: ownerName).respond(to: message, review: review, record: record, profile: coachProfile)
        }
        // Read again: a rating may have landed while the coach answered.
        var latest = CoachReview.load(in: dir) ?? review
        latest.thread += [ChatMessage(role: .user, text: message), ChatMessage(role: .assistant, text: answer.reply)]
        try latest.save(in: dir)
        var profile = coachProfile
        profile.updateGuidance(add: answer.add, remove: answer.remove, at: Date())
        profile.updateFacts(add: answer.addFacts, remove: answer.removeFacts)
        try profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
    }

    func addCoachFact(_ kind: CoachFact.Kind, _ text: String) {
        var profile = coachProfile
        profile.updateFacts(add: [CoachFact(kind: kind, text: text)], remove: [])
        try? profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
    }

    func removeCoachFact(_ text: String) {
        var profile = coachProfile
        profile.updateFacts(add: [], remove: [text])
        try? profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
    }

    func removeCoachGuidance(_ text: String) {
        var profile = coachProfile
        profile.updateGuidance(add: [], remove: [text], at: Date())
        try? profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
    }
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
