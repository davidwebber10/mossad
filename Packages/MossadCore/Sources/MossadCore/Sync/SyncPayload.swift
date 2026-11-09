import CryptoKit
import Foundation

extension JSONEncoder {
    /// Stable bytes for a call record: the same record always hashes the same.
    static let callRecord: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    public static let callRecord: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// The list fields of a meeting, readable without downloading its record.
public struct MeetingFields: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var platform: String
    public var headline: String?
    public var kind: String?
    public var tags: [String]
    public var status: String
}

/// What one meeting uploads to iCloud: the list fields, the record without what only the Mac needs, and the
/// coach review.
public struct SyncPayload: Sendable {
    public let id: String
    public let fields: MeetingFields
    public let record: Data
    public let coach: Data?
    /// The meeting as the server's MCP reads it; only for the server store.
    public let view: Data?
    /// Changes whenever anything uploaded changes.
    public let hash: String

    /// Only finished meetings: a call still recording or processing changes too often to be worth syncing.
    public static func isSyncable(_ r: CallRecord) -> Bool { r.status == .written }

    public init(record r: CallRecord, coach review: CoachReview?, view withView: Bool = false) {
        var slim = r
        // Voice fingerprints, word timings, and the per-track copies are large and only matter on the Mac.
        slim.speakerEmbeddings = [:]
        slim.meUtterances = nil
        slim.themUtterances = nil
        slim.utterances = r.utterances.map { var u = $0; u.words = nil; return u }
        // The pictures of shared screens stay on the Mac, so their list does too.
        slim.screens = nil
        id = r.id
        fields = MeetingFields(title: r.title, start: r.start, end: r.end, platform: r.platform.rawValue, headline: r.headline,
                               kind: r.kind, tags: r.tags, status: r.status.rawValue)
        record = (try? JSONEncoder.callRecord.encode(slim)) ?? Data()
        let coachData = review.flatMap { try? JSONEncoder.callRecord.encode($0) }
        coach = coachData
        let viewData = withView ? try? MeetingView.encoder.encode(MeetingView(r)) : nil
        view = viewData
        hash = SHA256.hash(data: record + (coachData ?? Data()) + (viewData ?? Data())).map { String(format: "%02x", $0) }.joined()
    }
}

/// What this device last uploaded (by record, its hash), and the store's change token.
public struct SyncState: Codable, Equatable, Sendable {
    public static let fileName = "state.json"
    public var uploaded: [String: String] = [:]
    public var changeToken: Data?
    /// Records that a pull could not take, with how many pulls failed, so a record that never works is left behind.
    public var failures: [String: Int]?
    /// Phone recordings that did not import yet, tried again with a growing pause.
    public var recordings: [PendingRecording]?

    public init() {}

    public struct Plan: Sendable {
        public var upload: [SyncPayload]
        public var delete: [String]
    }

    /// New or changed meetings to upload, and uploaded meetings that no longer exist, to delete. `present` is every
    /// call folder that exists: a meeting that is there but not in `payloads` (it is processed again, or its record
    /// cannot be read) is not a deleted meeting.
    public func plan(_ payloads: [SyncPayload], present: Set<String> = []) -> Plan {
        let ids = Set(payloads.map(\.id))
        return Plan(upload: payloads.filter { uploaded[$0.id] != $0.hash },
                    delete: uploaded.keys.filter { !ids.contains($0) && !present.contains($0) && !SharedPayload.isShared($0) }.sorted())
    }

    public static func load(from dir: URL, fileName: String = fileName) throws -> SyncState {
        // The state can be made again from the store, so a file that does not decode is moved aside and the next
        // sync starts clean instead of failing for good.
        try StoredFile.load(SyncState.self, from: dir.appendingPathComponent(fileName)) ?? SyncState()
    }

    public func save(to dir: URL, fileName: String = fileName) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent(fileName), options: .atomic)
    }
}

/// A room recording from the iPhone that this Mac could not import. It is tried again by name with a growing pause
/// for up to 7 days of failures that are about the recording itself; the owner is told after one day.
public struct PendingRecording: Codable, Equatable, Sendable {
    public var name: String
    public var start: Date?
    public var end: Date?
    public var title: String?
    public var firstFailure: Date
    /// The first failure that was not caused on this Mac or by the network; the 7 days count from here.
    public var countedSince: Date?
    public var attempts: Int
    public var next: Date
    public var reason: String
    public var told: Bool?
    public var gaveUp: Bool?
    public var toldGaveUp: Bool?

    var fields: [String: StoredValue] {
        var f: [String: StoredValue] = [:]
        if let start { f["start"] = .date(start) }
        if let end { f["end"] = .date(end) }
        if let title { f["title"] = .string(title) }
        return f
    }
}
