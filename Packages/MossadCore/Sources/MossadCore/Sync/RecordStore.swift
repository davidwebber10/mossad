import Foundation

/// A small field value that both stores keep as is: CloudKit as a typed field, the server as JSON.
public enum StoredValue: Sendable, Equatable {
    case string(String)
    case date(Date)
    case strings([String])

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var date: Date? { if case .date(let d) = self { d } else { nil } }
}

/// One synced record: a meeting, a chat, the owner's notes on a review, the coach's memory, the commitments,
/// or a room recording from the phone.
public struct StoredRecord: Sendable {
    public var name: String
    public var type: String
    public var fields: [String: StoredValue]
    /// The blobs to upload: asset key to the file that holds it.
    public var files: [String: URL]

    public init(name: String, type: String, fields: [String: StoredValue] = [:], files: [String: URL] = [:]) {
        self.name = name
        self.type = type
        self.fields = fields
        self.files = files
    }
}

/// A record that changed in the store. Its assets are read only when needed, so the Mac does not download its
/// own meetings again.
public struct ChangedRecord: Sendable {
    public var name: String
    public var type: String
    public var fields: [String: StoredValue]
    public var assetKeys: [String]
    /// Files the store already has here (CloudKit downloads them with the change).
    var localFiles: [String: URL] = [:]
}

public struct StoreChanges: Sendable {
    public var modified: [ChangedRecord]
    public var deleted: [(name: String, type: String)]
    public var token: Data?
    public var more: Bool
    /// Records the store could not send in this page. The pull counts them like records it could not read.
    public var failed: [(name: String, error: any Error)] = []
}

/// Where synced records live: iCloud's private database, or the owner's own server.
public protocol RecordStore: Sendable {
    /// The sync state file for this store, so switching stores starts clean.
    var stateFileName: String { get }
    /// Whether meetings also upload the view the remote MCP reads.
    var wantsMeetingView: Bool { get }
    func prepare() async throws
    /// Returns the names that were saved.
    func save(_ records: [StoredRecord]) async throws -> Set<String>
    /// Returns the names that are gone now, including ones that were already gone.
    func delete(_ names: [String]) async throws -> Set<String>
    /// The changes after `token` (nil for all), in order. A store with nothing yet returns no changes.
    func changes(since token: Data?) async throws -> StoreChanges
    /// The data of one asset of a changed record, or nil when it has none.
    func data(_ record: ChangedRecord, _ key: String) async throws -> Data?
    /// Removes records the Mac imported (room recordings), without waiting.
    func discard(_ names: [String]) async
    /// The same record, read again by name for a later try; nil when the store no longer has it.
    func refetch(_ record: ChangedRecord) async throws -> ChangedRecord?
}

extension RecordStore {
    public func refetch(_ record: ChangedRecord) async throws -> ChangedRecord? { record }
    public var stateFileName: String { SyncState.fileName }
    public var wantsMeetingView: Bool { false }
}
