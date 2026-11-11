import Foundation

/// A share as the owner's server lists it. The fields after `questions` are nil on a server from before the views.
public struct ServerShare: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var created: Date
    public var expires: Date?
    public var views: Int
    public var questions: Int
    public var viewers: Int?
    public var firstView: Date?
    public var lastView: Date?
    public var pin: Bool?
    public var pinLocked: Bool?
    public var wrongPins: Int?
    /// The copy on the server was deleted after the expiry; the row stays for its numbers.
    public var gone: Bool?
    /// Views that the server counted before it counted people and days: they have no people, days, or last view.
    public var earlierViews: Int?
    /// When the server set the PIN, in its milliseconds.
    public var pinSet: Int64?
    /// When too many wrong PINs locked the share.
    public var lockedAt: Date?

    public init(id: String, title: String, created: Date, expires: Date?, views: Int, questions: Int, viewers: Int?, firstView: Date?, lastView: Date?,
                pin: Bool?, pinLocked: Bool?, wrongPins: Int?, gone: Bool?, earlierViews: Int? = nil, pinSet: Int64? = nil, lockedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.created = created
        self.expires = expires
        self.views = views
        self.questions = questions
        self.viewers = viewers
        self.firstView = firstView
        self.lastView = lastView
        self.pin = pin
        self.pinLocked = pinLocked
        self.wrongPins = wrongPins
        self.gone = gone
        self.earlierViews = earlierViews
        self.pinSet = pinSet
        self.lockedAt = lockedAt
    }

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.init(id: id, title: json["title"] as? String ?? "", created: Self.date(json["created"]) ?? .distantPast, expires: Self.date(json["expires"]),
                  views: (json["views"] as? NSNumber)?.intValue ?? 0, questions: (json["questions"] as? NSNumber)?.intValue ?? 0,
                  viewers: (json["viewers"] as? NSNumber)?.intValue, firstView: Self.date(json["firstView"]), lastView: Self.date(json["lastView"]),
                  pin: json["pin"] as? Bool, pinLocked: json["pinLocked"] as? Bool, wrongPins: (json["wrongPins"] as? NSNumber)?.intValue, gone: json["gone"] as? Bool,
                  earlierViews: (json["earlierViews"] as? NSNumber)?.intValue, pinSet: (json["pinSet"] as? NSNumber)?.int64Value, lockedAt: Self.date(json["lockedAt"]))
    }

    /// The server writes its own times with milliseconds, and keeps an expiry as the app sent it, without.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
    }
}

/// One share's numbers: the days with views, and the visitors by country and by kind of device.
public struct ShareDetail: Equatable, Sendable {
    public struct Day: Equatable, Identifiable, Sendable {
        /// "2026-11-05", a day in the owner's time zone.
        public var day: String
        public var views: Int
        public var viewers: Int
        public var id: String { day }

        public init(day: String, views: Int, viewers: Int) {
            self.day = day
            self.views = views
            self.viewers = viewers
        }
    }

    public struct Count: Equatable, Identifiable, Sendable {
        public var name: String
        public var count: Int
        public var id: String { name }

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public var share: ServerShare
    public var days: [Day]
    public var countries: [Count]
    public var devices: [Count]

    public init(share: ServerShare, days: [Day], countries: [Count], devices: [Count]) {
        self.share = share
        self.days = days
        self.countries = countries
        self.devices = devices
    }

    init?(_ json: [String: Any]) {
        guard let share = (json["share"] as? [String: Any]).flatMap(ServerShare.init) else { return nil }
        func counts(_ key: String, _ name: String) -> [Count] {
            (json[key] as? [[String: Any]] ?? []).compactMap { c in
                (c[name] as? String).map { Count(name: $0, count: (c["viewers"] as? NSNumber)?.intValue ?? 0) }
            }
        }
        let days = (json["days"] as? [[String: Any]] ?? []).compactMap { d in
            (d["day"] as? String).map { Day(day: $0, views: (d["views"] as? NSNumber)?.intValue ?? 0, viewers: (d["viewers"] as? NSNumber)?.intValue ?? 0) }
        }
        self.init(share: share, days: days, countries: counts("countries", "country"), devices: counts("devices", "device"))
    }

    private static func dayStyle(_ calendar: Calendar) -> Date.ISO8601FormatStyle {
        var style = Date.ISO8601FormatStyle().year().month().day()
        style.timeZone = calendar.timeZone
        return style
    }

    public static func date(of day: String, calendar: Calendar = .current) -> Date? {
        try? Date(day, strategy: dayStyle(calendar))
    }

    /// Every day from the first day with a view through `end`, so a day with no view is a gap in the chart and
    /// not a missing bar. At most the last 90 days.
    public static func filled(_ days: [Day], through end: Date = Date(), calendar: Calendar = .current) -> [Day] {
        guard let first = days.first.flatMap({ date(of: $0.day, calendar: calendar) }) else { return [] }
        let known = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let style = dayStyle(calendar)
        let last = max(end, days.last.flatMap { date(of: $0.day, calendar: calendar) } ?? end)
        var out: [Day] = []
        var day = first
        while day <= last {
            let name = day.formatted(style)
            out.append(known[name] ?? Day(day: name, views: 0, viewers: 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Array(out.suffix(90))
    }

    public static func deviceName(_ device: String) -> String {
        switch device {
        case "computer": "Computer"
        case "phone": "Phone"
        case "tablet": "Tablet"
        default: "Other apps"
        }
    }

    public static func countryName(_ code: String, locale: Locale = Locale(identifier: "en_US")) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }
}

/// One line of the Shares page: the link that this Mac holds, joined with what the server counts for it.
public struct ShareRow: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        case live
        case expired
        /// This Mac holds the link, and the server no longer has it.
        case missing
    }

    public enum PIN: Equatable, Sendable {
        case off
        case on(String)
        /// The server asks for a PIN that this Mac does not hold (it was set on another Mac).
        case unknown
        /// Too many wrong PINs: the page is locked until the owner makes a new one.
        case locked
    }

    /// The server's id of the share: the SHA-256 of the link's token.
    public var id: String
    /// Nil for a share that another Mac made: this Mac cannot build its link.
    public var link: MeetingLink?
    /// Nil when the server could not be asked, or is from before the list.
    public var remote: ServerShare?
    public var title: String
    public var created: Date
    public var expires: Date?
    public var state: State
    public var pin: PIN

    public func url(on address: URL) -> URL? { link?.url(on: address) }

    /// What the copy action copies: the link, with the PIN on the next line when this Mac holds it.
    public func copyText(on address: URL) -> String? {
        guard let url = url(on: address) else { return nil }
        if case .on(let pin) = pin { return ShareMessage.text(url: url, pin: pin) }
        return url.absoluteString
    }

    public var copyTitle: String { if case .on = pin { "Copy link and PIN" } else { "Copy link" } }

    public func expiryText(now: Date = Date()) -> String { Self.expiryText(expires, now: now) }

    public static func expiryText(_ expires: Date?, now: Date = Date()) -> String {
        guard let expires else { return "Never expires" }
        let left = expires.timeIntervalSince(now)
        if left <= 0 { return "Expired" }
        if left < 3600 { return "Expires in \(count(max(1, Int(left / 60)), "minute"))" }
        if left < 86_400 { return "Expires in \(count(Int(left / 3600), "hour"))" }
        return "Expires in \(count(Int((left / 86_400).rounded()), "day"))"
    }

    /// The views that the server counted with their people and days; the earlier ones are not in it.
    public var countedViews: Int {
        guard let remote else { return 0 }
        return max(0, remote.views - (remote.earlierViews ?? 0))
    }

    private var earlierViews: Int { remote?.earlierViews ?? 0 }

    /// "12 views by 5 people"; "12 views" from a server that does not count visitors; "41 views before the server
    /// update" when only those are known; nil when nothing is known.
    public var viewsText: String? {
        guard let remote else { return nil }
        if countedViews == 0, earlierViews > 0 { return "\(Self.count(earlierViews, "view")) before the server update" }
        let views = Self.count(countedViews, "view")
        guard let viewers = remote.viewers, countedViews > 0 else { return views }
        return "\(views) by \(viewers == 1 ? "1 person" : "\(viewers) people")"
    }

    /// "41 more views before the server update", beside newer views; nil when there are none, or nothing newer.
    public var earlierViewsText: String? {
        guard earlierViews > 0, countedViews > 0 else { return nil }
        return "\(earlierViews) more \(earlierViews == 1 ? "view" : "views") before the server update"
    }

    public func lastViewedText(now: Date = Date()) -> String? {
        guard let remote, remote.viewers != nil else { return nil }
        guard let last = remote.lastView else { return earlierViews > 0 ? nil : "Not viewed yet" }
        return "Last viewed \(Self.ago(last, now: now))"
    }

    /// "Locked 2 days ago by too many wrong PINs"; nil for a share that is not locked.
    public func lockedText(now: Date = Date()) -> String? {
        guard pin == .locked else { return nil }
        guard let at = remote?.lockedAt else { return "Locked by too many wrong PINs" }
        return "Locked \(Self.ago(at, now: now)) by too many wrong PINs"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(count(Int(s / 60), "minute")) ago" }
        if s < 86_400 { return "\(count(Int(s / 3600), "hour")) ago" }
        if s < 14 * 86_400 { return "\(count(Int(s / 86_400), "day")) ago" }
        return "on \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private static func count(_ n: Int, _ unit: String) -> String { n == 1 ? "1 \(unit)" : "\(n) \(unit)s" }
}

public enum ShareRows {
    /// The rows of the Shares page: the shares that work first, the newest at the top, then the ones that do not.
    /// `remote` is nil when the server could not be asked: the rows then come from this Mac alone.
    public static func make(links: [MeetingLink], remote: [ServerShare]?, now: Date = Date()) -> [ShareRow] {
        let listed = Dictionary((remote ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [ShareRow] = []
        var seen = Set<String>()
        for link in links where link.stopping != true {
            let r = listed[link.id]
            seen.insert(link.id)
            let expired = link.isExpired(at: now) || (r?.expires.map { $0 < now } ?? false) || r?.gone == true
            let state: ShareRow.State = expired ? .expired : (remote != nil && r == nil ? .missing : .live)
            rows.append(ShareRow(id: link.id, link: link, remote: r, title: link.title, created: link.created, expires: r.map(\.expires) ?? link.expires,
                                 state: state, pin: pin(link: link, remote: r)))
        }
        let held = Set(links.map(\.id))
        for r in remote ?? [] where !seen.contains(r.id) && !held.contains(r.id) {
            let expired = (r.expires.map { $0 < now } ?? false) || r.gone == true
            rows.append(ShareRow(id: r.id, link: nil, remote: r, title: r.title, created: r.created, expires: r.expires, state: expired ? .expired : .live,
                                 pin: pin(link: nil, remote: r)))
        }
        return rows.sorted { a, b in
            if (a.state == .live) != (b.state == .live) { return a.state == .live }
            return a.created > b.created
        }
    }

    /// The server is what counts: a PIN that it does not have is no PIN, whatever this Mac remembers, and a PIN that
    /// it set at another time than this Mac knows is not this Mac's. With no answer, the PIN of this Mac stands:
    /// unknown is not false, and the person who gets the link needs the PIN.
    private static func pin(link: MeetingLink?, remote: ServerShare?) -> ShareRow.PIN {
        guard let remote, let on = remote.pin else { return link?.pin.map { .on($0) } ?? .off }
        guard on else { return .off }
        if remote.pinLocked == true { return .locked }
        if let held = link?.pinSet, let set = remote.pinSet, held != set { return .unknown }
        return link?.pin.map { .on($0) } ?? .unknown
    }
}

extension ServerClient {
    public struct ShareList: Equatable, Sendable {
        public var shares: [ServerShare]
        /// The server is new, and its database is from before the views: the owner must run the migration.
        public var needsMigration: Bool
    }

    /// Every share on the server, with its numbers.
    public func shares() async throws -> ShareList {
        let data = try await send(connection.request("api/shares"))
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return ShareList(shares: (body["shares"] as? [[String: Any]] ?? []).compactMap(ServerShare.init), needsMigration: body["migrate"] as? Bool == true)
    }

    public func shareDetail(shareID: String) async throws -> ShareDetail {
        let data = try await newer { try await send(connection.request("api/shares/\(shareID)")) }
        guard let detail = (try JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(ShareDetail.init) else {
            throw ServerError.http(200, "The server sent numbers that Mossad cannot read.")
        }
        return detail
    }

    /// Sets the PIN of a share. The PIN goes in the body of the request, never in its address; the server keeps a
    /// hash. Answers the PIN and the time the server set it, which an older server does not send.
    @discardableResult
    public func setPIN(shareID: String, pin: String) async throws -> (pin: String, pinSet: Int64?) {
        let body = try JSONSerialization.data(withJSONObject: ["pin": pin])
        let data = try await newer { try await send(connection.request("api/shares/\(shareID)/pin", method: "PUT"), body: body) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["pin"] as? String ?? pin, (json?["pinSet"] as? NSNumber)?.int64Value)
    }

    public func removePIN(shareID: String) async throws {
        _ = try await newer { try await send(connection.request("api/shares/\(shareID)/pin", method: "DELETE")) }
    }

    /// Changes when a share expires; nil for never. The server answers 410 when the copy of an expired share is gone.
    public func setExpiry(shareID: String, expires: Date?) async throws {
        let value: Any = expires.map { $0.formatted(.iso8601) } ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: ["expires": value])
        _ = try await newer { try await send(connection.request("api/shares/\(shareID)", method: "PATCH"), body: body) }
    }

    public func deleteShare(shareID: String) async throws {
        try await send(connection.request("api/shares/\(shareID)", method: "DELETE"))
    }

    /// A call that only the newer server has: an older one answers 404, and a newer one whose database was not
    /// updated answers 503.
    private func newer(_ call: () async throws -> Data) async throws -> Data {
        do { return try await call() } catch ServerError.http(let code, let message)
            where (code == 404 && message == "Not found.") || (code == 503 && message.contains("database")) {
            throw ServerError.needsUpdate
        }
    }
}
