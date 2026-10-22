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

    public init(subject: String, intro: String, improved: [String], toWork: [String], focus: String) {
        self.subject = subject
        self.intro = intro
        self.improved = improved
        self.toWork = toWork
        self.focus = focus
    }

    public var text: String {
        var lines = [intro, ""]
        if !improved.isEmpty { lines += ["What improved:"] + improved.map { "- \($0)" } + [""] }
        if !toWork.isEmpty { lines += ["What to work on:"] + toWork.map { "- \($0)" } + [""] }
        lines += ["Focus for this week: \(focus)"]
        return lines.joined(separator: "\n")
    }

    public var html: String {
        func list(_ title: String, _ items: [String]) -> String {
            items.isEmpty ? "" : "<h3 style=\"margin:20px 0 6px;font-size:15px\">\(title)</h3><ul style=\"margin:0;padding-left:20px\">"
                + items.map { "<li style=\"margin:4px 0\">\(escape($0))</li>" }.joined() + "</ul>"
        }
        return """
        <div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5;color:#1d1d1f;max-width:600px">\
        <p>\(escape(intro))</p>\(list("What improved", improved))\(list("What to work on", toWork))\
        <div style="margin-top:20px;padding:12px 14px;background:#fff4e5;border-radius:10px"><b>Focus for this week:</b> \(escape(focus))</div>\
        </div>
        """
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

public protocol DigestWriting: Sendable {
    func digest(owner: String, reviews: [(title: String, date: Date, review: CoachReview)], profile: CoachProfile) async throws -> WeeklyDigest
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

    public func digest(owner: String, reviews: [(title: String, date: Date, review: CoachReview)], profile: CoachProfile) async throws -> WeeklyDigest {
        let system = """
        You are \(owner)'s communication coach. Write their weekly email from your reviews of this week's calls and \
        your profile of them. Be specific: name the calls and the moments. intro is 2 to 3 sentences on the week. \
        improved lists 1 to 3 things that got better, with the evidence. to_work lists 1 to 3 things to work on, \
        each with a concrete thing to try; when meetings rated low, one item names the meeting to change and how. focus is the one focus for the coming week, in one sentence. subject is a \
        short, specific subject line. Do not pad: if the week had little to say, write less. Address \(owner) as "you".
        """
        var user = ["## Profile", "Summary: \(profile.summary)", "Focus: \(profile.focus)"]
        user += profile.patterns.map { "- \($0.name) (\($0.kind.rawValue), \($0.trend.rawValue), seen \($0.seen)): \($0.note)" }
        user.append("\n## This week's calls")
        for item in reviews {
            let r = item.review
            user.append("### \(item.date.formatted(.dateTime.weekday(.wide).month().day())) \(item.title)\n\(r.headline)\n\(r.overview)")
            if let p = r.focusProgress { user.append("Focus: \(p)") }
            if let v = r.value { user.append("Value: \(v.rating.rawValue); \(v.action.rawValue): \(v.suggestion)") }
            if let d = r.delivery { user.append("Delivery: \(CoachPrompt.numbers(d))") }
            user += r.strengths.map { "+ \($0.title): \($0.observation)" }
            user += r.improvements.map { "- \($0.title): \($0.observation)" }
        }
        let schema = Schema.object([
            "subject": Schema.string, "intro": Schema.string,
            "improved": Schema.array(Schema.string), "to_work": Schema.array(Schema.string), "focus": Schema.string,
        ])
        let out = try await llm.json(system: system, user: user.joined(separator: "\n"), schema: schema, effort: .medium,
                                     purpose: .weeklyEmail, as: Output.self)
        return WeeklyDigest(subject: out.subject, intro: out.intro, improved: out.improved, toWork: out.to_work, focus: out.focus)
    }

    private struct Output: Decodable {
        let subject, intro, focus: String
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

    public static func sendIfDue(paths: Paths, owner: String, to: String, lastSent: Date?, now: Date = Date(),
                                 writer: any DigestWriting, mailer: any Mailing, calendar: Calendar = .current) async -> Date? {
        guard WeeklySchedule.isDue(lastSent: lastSent, now: now, calendar: calendar) else { return nil }
        guard isSingleAddress(to) else {
            Log.error("The weekly email needs exactly one address, your own; nothing was sent")
            return nil
        }
        let start = WeeklySchedule.weekStart(before: now, calendar: calendar), end = WeeklySchedule.weekEnd(before: now, calendar: calendar)
        let reviews = ProcessingQueue(paths: paths).allRecords()
            .filter { $0.start >= start && $0.start < end }
            .compactMap { r in CoachReview.load(in: paths.callDirectory(r.id)).map { (title: r.title, date: r.start, review: $0) } }
        // A week with no coached calls has nothing to say; count it as sent.
        guard !reviews.isEmpty else { return now }
        do {
            let profile = try CoachProfile.load(from: paths.coach)
            let digest = try await writer.digest(owner: owner, reviews: reviews, profile: profile)
            try await mailer.send(to: to.trimmingCharacters(in: .whitespaces), subject: digest.subject, html: digest.html, text: digest.text)
            Log.info("Sent the weekly coaching email for \(reviews.count) calls")
            return now
        } catch {
            Log.error("The weekly coaching email failed: \(error)")
            return nil
        }
    }
}
