import Foundation

/// The Google step's Check: one small read for each part that is on, so each API that is off or each box that was
/// unticked shows on its own line.
public enum GoogleCheck {
    public struct Report: Equatable, Sendable {
        /// The Google account, from the primary calendar's name.
        public var account: String?
        /// The title of one event that was read, to show that it works.
        public var event: String?
        /// Each part that is on: nil when it works, else why not.
        public var parts: [GoogleScope: GoogleError?]

        public init(account: String? = nil, event: String? = nil, parts: [GoogleScope: GoogleError?]) {
            self.account = account
            self.event = event
            self.parts = parts
        }

        public var passed: Bool { parts.values.allSatisfy { $0 == nil } }
        /// The first failure, in the order of the parts.
        public var firstError: GoogleError? { GoogleScope.allCases.lazy.compactMap { self.parts[$0] ?? nil }.first }
    }

    public static func run(session: GoogleSession, scopes: Set<GoogleScope>, now: Date = Date()) async -> Report {
        var report = Report(parts: [:])
        for scope in GoogleScope.allCases where scopes.contains(scope) {
            do {
                switch scope {
                case .calendar:
                    let data = try await session.get(GoogleCalendarAPI.eventsURL(from: now.addingTimeInterval(-30 * 86_400), to: now.addingTimeInterval(30 * 86_400), max: 1), scope: .calendar)
                    let page = try GoogleCalendarAPI.page(data)
                    report.account = page.account
                    report.event = page.events.first?.title
                    if let account = page.account { await session.setAccount(account) }
                case .docs:
                    // A document that cannot exist: an API that is on says "not found" (or "bad request"); an API that is
                    // off says so. Only then is the part known to work.
                    let (status, body) = try await session.probe(GeminiDoc.url(documentID: "mossad-check-no-such-document"), scope: .docs)
                    if status != 404, status != 400, status != 200 { throw GoogleError.from(status: status, body: body, scope: .docs) }
                case .directory:
                    _ = try await session.get(GooglePeopleAPI.directoryURL(pageSize: 1), scope: .directory)
                case .contacts:
                    _ = try await session.get(GooglePeopleAPI.contactsURL(pageSize: 1), scope: .contacts)
                }
                report.parts[scope] = .some(nil)
            } catch {
                let g = GoogleError.from(error)
                Log.error("Google check: \(scope.rawValue) failed (\(g.logText))")
                report.parts[scope] = .some(g)
            }
        }
        return report
    }
}
