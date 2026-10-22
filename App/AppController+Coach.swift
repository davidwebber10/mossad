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

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
