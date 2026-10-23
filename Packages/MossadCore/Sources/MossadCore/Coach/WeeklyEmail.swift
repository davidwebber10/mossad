import Foundation

/// The weekly email goes out once a week, after Monday 8 AM local time, about the week before.
public enum WeeklySchedule {
    static let weekday = 2
    static let hour = 8

    /// The latest Monday 8 AM at or before `now`.
    static func lastSendTime(atOrBefore now: Date, calendar: Calendar) -> Date {
        let components = DateComponents(hour: hour, minute: 0, second: 0, weekday: weekday)
        let next = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)!
        return calendar.date(byAdding: .day, value: -7, to: next)!
    }

    public static func isDue(lastSent: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastSent else { return true }
        return lastSent < lastSendTime(atOrBefore: now, calendar: calendar)
    }

    /// The start of the week the email covers; it ends at the latest send time.
    public static func weekStart(before now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -7, to: lastSendTime(atOrBefore: now, calendar: calendar))!
    }

    public static func weekEnd(before now: Date, calendar: Calendar = .current) -> Date {
        lastSendTime(atOrBefore: now, calendar: calendar)
    }
}

/// What the coach writes about one week.
public struct WeeklyDigest: Codable, Equatable, Sendable {
    public var subject: String
    public var intro: String
    public var improved: [String]
    public var toWork: [String]
    public var focus: String
    /// One quote from the period worth remembering, with where it was said.
    public var bestMoment: String?

    public init(subject: String, intro: String, improved: [String], toWork: [String], focus: String, bestMoment: String? = nil) {
        self.bestMoment = bestMoment
        self.subject = subject
        self.intro = intro
        self.improved = improved
        self.toWork = toWork
        self.focus = focus
    }

    public var text: String { CoachEmailDesign.text(kind: .weekly, period: "", digest: self, facts: nil) }
    public var html: String { CoachEmailDesign.html(kind: .weekly, period: "", digest: self, facts: nil) }
}

public protocol DigestWriting: Sendable {
    func digest(owner: String, reviews: [(title: String, date: Date, review: CoachReview)], profile: CoachProfile,
                kind: CoachEmailKind) async throws -> WeeklyDigest
}

/// Writes the weekly email with Claude from the week's reviews and the profile.
public struct LLMDigestWriter: DigestWriting {
    private let llm: any LanguageModel

    public init(llm: any LanguageModel) {
        self.llm = llm
    }

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared, usage: UsageLog? = nil) {
        self.init(llm: AnthropicModel(apiKey: apiKey, model: model, session: session, usage: usage))
    }

    public func digest(owner: String, reviews: [(title: String, date: Date, review: CoachReview)], profile: CoachProfile,
                       kind: CoachEmailKind) async throws -> WeeklyDigest {
        let period = kind.noun
        let system = """
        You are \(owner)'s communication coach. Write their \(kind == .weekly ? "weekly email" : "month in review email") \
        from your reviews of this \(period)'s calls and your notes on them. It should be a pleasure to read: warm, \
        direct, specific, and short. Name the calls and the moments. \(CoachPrompt.voiceRules(profile.voice, owner: owner))
        subject: at most 8 words, specific to this \(period), no emoji. intro: 2 to 3 sentences on the \(period)'s story. \
        improved: 1 to 3 things that got better, each one sentence with the evidence; never claim a change the reviews \
        do not show. to_work: 1 to 3 things to try next, each one sentence starting with a verb; when meetings rated \
        low, one names the meeting to change and how. focus: one sentence on the agreed focus, how the \(period) went \
        on it, and what to do next; when there is no agreed focus, invite them to accept the proposed one in Mossad. \
        best_moment: the single best quote of the \(period) from \(owner)'s own words in the reviews, in quotation \
        marks, then the meeting and day in parentheses; null when none stands out. \
        \(kind == .monthly ? "This covers a whole month: look for the arc across weeks, not a list of calls." : "") \
        Do not pad: a quiet \(period) gets a short email. Address \(owner) as "you".
        """
        var user = ["## Profile", "Summary: \(profile.summary)", "## The focus\n" + CoachPrompt.focusText(profile)]
        user += profile.patterns.map { "- \($0.name) (\($0.kind.rawValue), \($0.trend.rawValue), seen \($0.seen)): \($0.note)" }
        user.append("\n## This \(period)'s calls")
        for item in reviews {
            let r = item.review
            user.append("### \(item.date.formatted(.dateTime.weekday(.wide).month().day())) \(item.title)\n\(r.headline)\n\(r.overview)")
            if let f = r.focusResult { user.append("Focus result: \(f.outcome.rawValue). \(f.evidence)") }
            if let n = r.lines.didWell { user.append("Did well: \(n.text)") }
            if let n = r.lines.tryNext { user.append("Try next: \(n.text)") }
            if let p = r.focusProgress { user.append("Focus: \(p)") }
            if let card = r.scorecard { user.append("Score: \(card.score)/5. \(card.reason)") }
            if let v = r.value { user.append("Value: \(v.rating.rawValue); \(v.action.rawValue): \(v.suggestion)") }
            if let d = r.delivery { user.append("Delivery: \(CoachPrompt.numbers(d))") }
            user += r.strengths.map { "+ \($0.title): \($0.observation)" }
            user += r.improvements.map { "- \($0.title): \($0.observation)" }
        }
        let schema = Schema.object([
            "subject": Schema.string, "intro": Schema.string,
            "improved": Schema.array(Schema.string), "to_work": Schema.array(Schema.string), "focus": Schema.string,
            "best_moment": Schema.nullableString,
        ])
        let out = try await llm.json(system: system, user: user.joined(separator: "\n"), schema: schema, effort: .medium,
                                     purpose: .weeklyEmail, as: Output.self)
        return WeeklyDigest(subject: out.subject, intro: out.intro, improved: out.improved, toWork: out.to_work, focus: out.focus,
                            bestMoment: out.best_moment?.nonBlank)
    }

    private struct Output: Decodable {
        let subject, intro, focus: String
        let best_moment: String?
        let improved, to_work: [String]
    }
}

public protocol Mailing: Sendable {
    func send(to: String, subject: String, html: String, text: String) async throws
}

public enum MailError: Error, CustomStringConvertible {
    case http(Int, String)

    public var description: String {
        switch self {
        case .http(let code, let body): "Resend HTTP \(code): \(body)"
        }
    }
}

/// Sends email through Resend with the owner's own API key.
public struct ResendMailer: Mailing {
    static let endpoint = URL(string: "https://api.resend.com/emails")!

    private let apiKey: String
    private let from: String
    private let session: URLSession

    public init(apiKey: String, from: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.from = from
        self.session = session
    }

    func request(to: String, subject: String, html: String, text: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["from": from, "to": [to], "subject": subject, "html": html, "text": text])
        return request
    }

    public func send(to: String, subject: String, html: String, text: String) async throws {
        let (data, response) = try await session.data(for: request(to: to, subject: subject, html: html, text: text))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MailError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
    }
}

/// Sends the weekly email when it is due. It only ever goes to the owner: one address, typed in Settings,
/// never one taken from a meeting. Returns the time to store as "last sent", or nil to try again later.
public enum WeeklyEmail {
    /// One plain address such as me@example.com: no lists, no display names, no separators.
    public static func isSingleAddress(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).wholeMatch(of: /[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+/) != nil
    }

    public static func sendIfDue(kind: CoachEmailKind = .weekly, paths: Paths, owner: String, to: String, lastSent: Date?, now: Date = Date(),
                                 writer: any DigestWriting, mailer: any Mailing, calendar: Calendar = .current) async -> Date? {
        let due = kind == .weekly ? WeeklySchedule.isDue(lastSent: lastSent, now: now, calendar: calendar)
            : MonthlySchedule.isDue(lastSent: lastSent, now: now, calendar: calendar)
        guard due else { return nil }
        guard isSingleAddress(to) else {
            Log.error("The coaching email needs exactly one address, your own; nothing was sent")
            return nil
        }
        let range = kind == .weekly
            ? DateInterval(start: WeeklySchedule.weekStart(before: now, calendar: calendar), end: WeeklySchedule.weekEnd(before: now, calendar: calendar))
            : MonthlySchedule.range(before: now, calendar: calendar)
        let reviews = ProcessingQueue(paths: paths).allRecords()
            .filter { $0.start >= range.start && $0.start < range.end }
            .compactMap { r in CoachReview.load(in: paths.callDirectory(r.id)).map { (title: r.title, date: r.start, review: $0) } }
        // A period with no coached calls has nothing to say; count it as sent.
        guard !reviews.isEmpty else { return now }
        do {
            let profile = try CoachProfile.load(from: paths.coach)
            let digest = try await writer.digest(owner: owner, reviews: reviews, profile: profile, kind: kind)
            let facts = EmailFacts.gather(paths: paths, owner: owner, range: range, now: now, calendar: calendar)
            let period = CoachEmailDesign.periodLabel(kind, range, calendar: calendar)
            try await mailer.send(to: to.trimmingCharacters(in: .whitespaces), subject: digest.subject,
                                  html: CoachEmailDesign.html(kind: kind, period: period, digest: digest, facts: facts),
                                  text: CoachEmailDesign.text(kind: kind, period: period, digest: digest, facts: facts))
            Log.info("Sent the \(kind.rawValue) coaching email for \(reviews.count) calls")
            return now
        } catch {
            Log.error("The \(kind.rawValue) coaching email failed: \(error)")
            return nil
        }
    }
}
