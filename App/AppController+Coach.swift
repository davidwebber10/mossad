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
            await writePersonBriefs(PersonBriefWriter.due(profile: coachProfile, records: meetings, owner: ownerName))
            coaching = false
            syncToICloud()
            await sendCoachEmail()
        }
    }

    /// The coach's read on each person, written one at a time; the profile is read fresh before each save
    /// because a review may have changed it meanwhile.
    func writePersonBriefs(_ names: [String]) async {
        guard !names.isEmpty, let llm = languageModel else { return }
        let writer = PersonBriefWriter(llm: llm, ownerName: ownerName), records = meetings
        for name in names {
            do {
                let brief = try await writer.brief(for: name, records: records, profile: coachProfile)
                var profile = coachProfile
                var person = profile.people[name] ?? CoachPerson(note: "", calls: 0, lastSeen: brief.updated)
                person.brief = brief
                profile.people[name] = person
                try profile.save(to: paths.coach)
                coachVersion += 1
            } catch {
                Log.error("The coach's read on a person failed: \(error)")
            }
        }
        Log.info("The coach updated its read on \(names.count) \(names.count == 1 ? "person" : "people")")
        syncToICloud()
    }

    /// Once: the coach's first questions, from the last 30 days of calls.
    func runQuestionPass() {
        guard coachEnabled, !UserDefaults.standard.bool(forKey: "coachQuestionPass2026"), let llm = languageModel else { return }
        UserDefaults.standard.set(true, forKey: "coachQuestionPass2026")
        let pass = CoachQuestionPass(llm: llm, ownerName: ownerName), records = meetings, paths = paths
        Task {
            do {
                var profile = try CoachProfile.load(from: paths.coach)
                let questions = try await pass.questions(records: records, profile: profile)
                // Another review may have saved the profile meanwhile.
                profile = try CoachProfile.load(from: paths.coach)
                profile.ask(questions)
                try profile.save(to: paths.coach)
                Log.info("The coach has \(questions.count) questions for you")
                coachVersion += 1
                syncToICloud()
            } catch {
                Log.error("The coach's first questions failed: \(error)")
                UserDefaults.standard.set(false, forKey: "coachQuestionPass2026")
            }
        }
    }

    /// `now` sends the last period's email even when it was sent already.
    func sendCoachEmail(_ kind: CoachEmailKind? = nil, now: Bool = false) async {
        guard coachEnabled, let to = coachEmailTo.nonEmpty, coachEmailFrom.nonEmpty != nil,
              let llm = languageModel, let secret = keychain.get(mailProvider.key) else { return }
        let mailer = mailSettings.mailer(mailProvider, secret: secret), writer = LLMDigestWriter(llm: llm)
        if (kind == nil && coachEmailEnabled) || kind == .weekly {
            let last = now || coachLastEmail == 0 ? nil : Date(timeIntervalSince1970: coachLastEmail)
            if let sent = await WeeklyEmail.sendIfDue(kind: .weekly, paths: paths, owner: ownerName, to: to, lastSent: last, writer: writer, mailer: mailer) {
                coachLastEmail = sent.timeIntervalSince1970
            }
        }
        if (kind == nil && coachMonthlyEmail) || kind == .monthly {
            let last = now || coachLastMonthEmail == 0 ? nil : Date(timeIntervalSince1970: coachLastMonthEmail)
            if let sent = await WeeklyEmail.sendIfDue(kind: .monthly, paths: paths, owner: ownerName, to: to, lastSent: last, writer: writer, mailer: mailer) {
                coachLastMonthEmail = sent.timeIntervalSince1970
            }
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

    func acceptFocus(_ id: UUID, plan: String?) {
        var profile = coachProfile
        profile.acceptFocus(id, plan: plan, at: Date())
        try? profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
    }

    func answerQuestion(_ id: UUID, _ status: CoachQuestion.Status, note: String?) {
        var profile = coachProfile
        profile.answer(id, status, note: note, at: Date())
        try? profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
    }

    func dismissFocus(_ id: UUID) {
        var profile = coachProfile
        profile.dismissFocus(id, at: Date())
        try? profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
    }

    func setCoachVoice(_ voice: CoachVoice) {
        var profile = coachProfile
        profile.voice = voice
        try? profile.save(to: paths.coach)
        coachVersion += 1
        syncToICloud()
    }

    /// Deletes this call's review and runs the coach, which reviews it again in the current format.
    func reviewAgain(_ callID: String) {
        try? FileManager.default.removeItem(at: paths.callDirectory(callID).appendingPathComponent(CoachReview.fileName))
        coachVersion += 1
        runCoach()
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
