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
    /// Changes whenever anything uploaded changes.
    public let hash: String

    /// Only finished meetings: a call still recording or processing changes too often to be worth syncing.
    public static func isSyncable(_ r: CallRecord) -> Bool { r.status == .written }

    public init(record r: CallRecord, coach review: CoachReview?) {
        var slim = r
        // Voice fingerprints, word timings, and the per-track copies are large and only matter on the Mac.
        slim.speakerEmbeddings = [:]
        slim.meUtterances = nil
        slim.themUtterances = nil
        slim.utterances = r.utterances.map { var u = $0; u.words = nil; return u }
        id = r.id
        fields = MeetingFields(title: r.title, start: r.start, end: r.end, platform: r.platform.rawValue, headline: r.headline,
                               kind: r.kind, tags: r.tags, status: r.status.rawValue)
        record = (try? JSONEncoder.callRecord.encode(slim)) ?? Data()
        let coachData = review.flatMap { try? JSONEncoder.callRecord.encode($0) }
        coach = coachData
        hash = SHA256.hash(data: record + (coachData ?? Data())).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the Mac last uploaded (by meeting, its hash), and on the phone the CloudKit change token.
public struct SyncState: Codable, Equatable, Sendable {
    public static let fileName = "state.json"
    public var uploaded: [String: String] = [:]
    public var changeToken: Data?

    public init() {}

    public struct Plan: Sendable {
        public var upload: [SyncPayload]
        public var delete: [String]
    }

    /// New or changed meetings to upload, and uploaded meetings that no longer exist, to delete.
    public func plan(_ payloads: [SyncPayload]) -> Plan {
        let ids = Set(payloads.map(\.id))
        return Plan(upload: payloads.filter { uploaded[$0.id] != $0.hash },
                    delete: uploaded.keys.filter { !ids.contains($0) && !SharedPayload.isShared($0) }.sorted())
    }

    public static func load(from dir: URL) throws -> SyncState {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return SyncState() }
        return try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
