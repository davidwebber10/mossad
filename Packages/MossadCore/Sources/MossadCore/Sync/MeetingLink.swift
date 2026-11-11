import CryptoKit
import Foundation

/// What one share link shows. The coach is never part of it.
public struct ShareOptions: Codable, Equatable, Sendable {
    public var summary = true
    public var transcript = true
    public var recording = false
    /// Only on a link from before the share sheet lost its chat switch. A new link has no chat.
    public var chat = false
    /// Days until the link stops working; nil for never.
    public var days: Int? = 30

    public init(summary: Bool = true, transcript: Bool = true, recording: Bool = false, chat: Bool = false, days: Int? = 30) {
        self.summary = summary
        self.transcript = transcript
        self.recording = recording
        self.chat = chat
        self.days = days
    }

    public static let expiryChoices: [Int?] = [7, 30, 90, nil]

    public var showsAnything: Bool { summary || transcript || recording }
}

/// A link the owner made: kept on the Mac so it can be updated or stopped.
public struct MeetingLink: Codable, Equatable, Identifiable, Sendable {
    /// The secret part of the URL. Only the Mac and the people it is sent to have it.
    public var token: String
    public var callID: String
    public var title: String
    public var options: ShareOptions
    public var created: Date
    public var expires: Date?
    /// The meeting is gone and the link must stop; set until the server confirms.
    public var stopping: Bool?
    /// The owner stopped the link and may still undo that: the server is told only after this time.
    public var stopAfter: Date?
    /// The PIN of the link, when it has one. The server keeps only a hash, so this Mac is where the owner reads it.
    /// It is beside the token, which opens more than the PIN does.
    public var pin: String?

    public var id: String { Self.serverID(token) }

    public init(token: String, callID: String, title: String, options: ShareOptions, created: Date, expires: Date? = nil) {
        self.token = token
        self.callID = callID
        self.title = title
        self.options = options
        self.created = created
        self.expires = expires
    }

    public static func newToken() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URL }

    /// The server stores the share under the SHA-256 of the token, so its storage never holds a working link.
    public static func serverID(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func url(on address: URL) -> URL { address.appendingPathComponent(token) }

    public func isExpired(at now: Date = Date()) -> Bool { expires.map { $0 < now } ?? false }

    /// When a link stops working. A link that is sent again with the same choice keeps its date; another choice,
    /// or a link that had expired, counts from now.
    public static func expiry(days: Int?, existing: MeetingLink?, now: Date = Date()) -> Date? {
        guard let days else { return nil }
        if let existing, existing.options.days == days, let kept = existing.expires, kept > now { return kept }
        return now.addingTimeInterval(Double(days) * 86_400)
    }
}

/// What the share sheet holds before its owner clicks Share. Nothing of it is on the server or in the book yet,
/// so closing the sheet creates nothing.
public struct ShareDraft: Equatable, Sendable {
    public var options: ShareOptions
    public var pinOn: Bool
    /// The PIN that the sheet shows while the switch is on: the link's own, or a new random one.
    public private(set) var pin: String

    public init(existing: MeetingLink?, hasRecording: Bool, newPIN: String = SharePIN.random()) {
        options = existing?.options ?? ShareOptions()
        if !hasRecording { options.recording = false }
        pinOn = existing?.pin != nil
        pin = existing?.pin ?? newPIN
    }

    /// The PIN to set with the share, or nil for none.
    public var sentPIN: String? { pinOn ? pin : nil }

    public mutating func makeNewPIN() {
        var next = SharePIN.random()
        while next == pin { next = SharePIN.random() }
        pin = next
    }

    public var canShare: Bool { options.showsAnything }

    public func differs(from link: MeetingLink) -> Bool { options != link.options || sentPIN != link.pin }
}

/// The PIN of a share: 4 digits from the system's random source.
public enum SharePIN {
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%04d", Int.random(in: 0..<10_000, using: &generator))
    }

    public static func isValid(_ text: String) -> Bool { text.utf8.count == 4 && text.utf8.allSatisfy { (48...57).contains($0) } }
}

/// What "Copy link and PIN" copies: the link on one line and the PIN on the next. The PIN is never in the link.
public enum ShareMessage {
    public static func text(url: URL, pin: String?) -> String {
        guard let pin else { return url.absoluteString }
        return "\(url.absoluteString)\nPIN: \(pin)"
    }
}

/// The mark on a link that the owner opens from the app, so the server keeps the owner's own visits out of the
/// count: "<unix seconds>.<hex HMAC-SHA256 of "mossad-owner-view\n<seconds>" with the owner secret>". It lasts five
/// minutes and gives nothing but that.
public enum OwnerMark {
    public static func make(secret: String, expires: Int) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("mossad-owner-view\n\(expires)".utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return "\(expires).\(mac.map { String(format: "%02x", $0) }.joined())"
    }

    public static func url(_ link: URL, secret: String, now: Date = Date()) -> URL {
        var c = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "owner", value: make(secret: secret, expires: Int(now.timeIntervalSince1970) + 300))]
        return c.url ?? link
    }
}

/// The copy of a meeting that a link shows: only the parts the owner turned on.
public struct SharedMeeting: Codable, Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var people: [String]
    public var owner: String
    public var summary: String?
    public var topics: [MeetingView.Topic]?
    public var decisions: [String]?
    public var decisionTimes: [Double?]?
    public var actionItems: [MeetingView.Item]?
    public var lines: [MeetingView.Line]?
    public var audio: Bool
    public var chat: Bool
    public var expires: Date?
    public var timeZone: String?
    public var model: String?

    public init(_ view: MeetingView, owner: String, options o: ShareOptions, expires: Date?, model: String?) {
        title = view.title
        start = view.start
        end = view.end
        people = view.people
        self.owner = owner
        if o.summary {
            summary = view.summary
            topics = view.topics
            decisions = view.decisions
            decisionTimes = view.decisionTimes
            actionItems = view.actionItems
        }
        if o.transcript { lines = view.lines }
        audio = o.recording
        // The chat answers from what is shared, so it needs something to read.
        chat = o.chat && (o.summary || o.transcript)
        self.expires = expires
        timeZone = view.timeZone
        self.model = model
    }

    /// `expires` must be present as null for "never", so the encoder writes it by hand.
    public func encoded() throws -> Data {
        var json = try JSONSerialization.jsonObject(with: MeetingView.encoder.encode(self)) as? [String: Any] ?? [:]
        if expires == nil { json["expires"] = NSNull() }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}

/// The owner's links, in `~/Mossad/Shares/shares.json`.
public struct ShareBook: Codable, Equatable, Sendable {
    public static let fileName = "shares.json"
    public var links: [MeetingLink] = []

    public init(links: [MeetingLink] = []) { self.links = links }

    public func link(for callID: String) -> MeetingLink? { links.first { $0.callID == callID && !$0.isExpired() && $0.stopping != true } }

    /// Marks every link of a meeting that is gone, so each is stopped on the server, now or on a later try.
    public mutating func markStopping(callID: String) {
        for i in links.indices where links[i].callID == callID {
            links[i].stopping = true
            links[i].stopAfter = nil
        }
    }

    /// Marks one link that its owner stopped. The mark is saved at once, so a quit before `after` still stops it.
    public mutating func markStopping(token: String, after: Date) {
        for i in links.indices where links[i].token == token {
            links[i].stopping = true
            links[i].stopAfter = after
        }
    }

    public mutating func undoStop(token: String) {
        for i in links.indices where links[i].token == token {
            links[i].stopping = nil
            links[i].stopAfter = nil
        }
    }

    /// The marked links whose undo time is over: these the server is told to stop.
    public func dueStops(now: Date = Date()) -> [MeetingLink] {
        links.filter { $0.stopping == true && ($0.stopAfter.map { $0 <= now } ?? true) }
    }

    public mutating func put(_ link: MeetingLink) {
        links.removeAll { $0.token == link.token }
        links.insert(link, at: 0)
    }

    public mutating func remove(_ token: String) { links.removeAll { $0.token == token } }

    /// An unreadable file is moved aside (see `StoredFile`), so the links in it are kept for the owner.
    public static func load(from dir: URL) -> ShareBook {
        (try? loadChecked(from: dir)) ?? ShareBook()
    }

    public static func loadChecked(from dir: URL) throws -> ShareBook {
        try StoredFile.load(ShareBook.self, from: dir.appendingPathComponent(fileName), decoder: .callRecord, recovery: .local) ?? ShareBook()
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.callRecord.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension ServerClient {
    /// Puts the copy on the server, and the recording when the link shows it.
    public func putShare(_ link: MeetingLink, meeting: SharedMeeting, audio: URL?) async throws {
        try await send(connection.request("api/shares/\(link.id)", method: "PUT"), body: meeting.encoded())
        if meeting.audio, let audio {
            var request = connection.request("api/shares/\(link.id)/audio", method: "PUT")
            request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
            try await send(request, file: audio)
        }
    }

    public func deleteShare(_ link: MeetingLink) async throws {
        try await send(connection.request("api/shares/\(link.id)", method: "DELETE"))
    }
}
