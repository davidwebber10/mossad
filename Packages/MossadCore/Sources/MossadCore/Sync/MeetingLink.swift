import CryptoKit
import Foundation

/// What one share link shows. The coach is never part of it.
public struct ShareOptions: Codable, Equatable, Sendable {
    public var summary = true
    public var transcript = true
    public var recording = false
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
    public var decisions: [Decision]?
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

    public func link(for callID: String) -> MeetingLink? { links.first { $0.callID == callID && !$0.isExpired() } }

    public mutating func put(_ link: MeetingLink) {
        links.removeAll { $0.token == link.token }
        links.insert(link, at: 0)
    }

    public mutating func remove(_ token: String) { links.removeAll { $0.token == token } }

    public static func load(from dir: URL) -> ShareBook {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return ShareBook() }
        return (try? JSONDecoder.callRecord.decode(ShareBook.self, from: data)) ?? ShareBook()
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

    public struct ShareStats: Equatable, Sendable {
        public var views: Int
        public var questions: Int
    }

    /// Views and chat questions per link, by server ID.
    public func shareStats() async throws -> [String: ShareStats] {
        let data = try await send(connection.request("api/shares"))
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["shares"] as? [[String: Any]] ?? []
        return Dictionary(list.compactMap { s in
            (s["id"] as? String).map { ($0, ShareStats(views: (s["views"] as? Int) ?? 0, questions: (s["questions"] as? Int) ?? 0)) }
        }, uniquingKeysWith: { a, _ in a })
    }
}
