import Foundation

/// Where the owner backs up recordings, as Settings saves it under "storage".
public enum BackupChoice: String, CaseIterable, Sendable {
    /// No backup: recordings stay on this Mac.
    case none = "local"
    /// The owner's own Mossad server.
    case server
    case r2
    case s3

    public var title: String {
        switch self {
        case .none: "None"
        case .server: "Your server"
        case .r2: "Cloudflare R2"
        case .s3: "Amazon S3"
        }
    }

    public var isBucket: Bool { self == .r2 || self == .s3 }

    /// The place new recordings go to.
    public var target: ArchiveKind? {
        switch self {
        case .none: nil
        case .server: .server
        case .r2, .s3: .bucket
        }
    }

    /// The choices to offer. The server is one of them only when a server is connected, or while it is the choice
    /// (the owner disconnected the server and must be able to see what is chosen).
    public static func offered(serverConnected: Bool, current: BackupChoice) -> [BackupChoice] {
        allCases.filter { $0 != .server || serverConnected || current == .server }
    }
}

/// The backup settings that are not secret. The bucket's fields stay after the owner chooses another place, so
/// recordings that are still in the bucket can be played, moved, and deleted.
public struct BackupSettings: Equatable, Sendable {
    public var choice: BackupChoice
    /// `.r2` or `.s3`: which of the two the bucket fields describe, remembered while the choice is another.
    public var bucketKind: BackupChoice?
    public var endpoint: String
    public var bucket: String
    public var region: String
    public var accessKeyID: String

    public init(choice: String, bucketKind: String = "", endpoint: String = "", bucket: String = "", region: String = "", accessKeyID: String = "") {
        self.choice = BackupChoice(rawValue: choice) ?? .none
        self.bucketKind = BackupChoice(rawValue: bucketKind).flatMap { $0.isBucket ? $0 : nil }
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// R2 or S3 for the bucket fields: the choice when it is a bucket, then what was remembered, then the address.
    public var bucketFlavor: BackupChoice {
        if choice.isBucket { return choice }
        if let bucketKind { return bucketKind }
        return URL(string: endpoint)?.host?.hasSuffix("r2.cloudflarestorage.com") == true ? .r2 : .s3
    }

    /// Whether the bucket is described completely, apart from its secret.
    public var hasBucket: Bool {
        URL(string: endpoint)?.host != nil && !bucket.isEmpty && !accessKeyID.isEmpty
    }

    public func bucketConfig(secret: String?) -> S3Config? {
        guard hasBucket, let url = URL(string: endpoint), let secret, !secret.isEmpty else { return nil }
        let r2 = bucketFlavor == .r2
        return S3Config(endpoint: url, bucket: bucket, region: r2 ? "auto" : (region.isEmpty ? "us-east-1" : region), accessKeyID: accessKeyID, secret: secret, pathStyle: r2)
    }
}

/// How many recordings are in each place, for the line under the backup choice.
public struct BackupCounts: Equatable, Sendable {
    /// On the server that is connected.
    public var onServer = 0
    /// On a server that is not the connected one. They cannot play, and their local copies stay.
    public var onOtherServer = 0
    public var inBucket = 0
    /// Written meetings with no backup copy yet.
    public var notBackedUp = 0
    /// Old copies in the bucket that a move has not removed yet.
    public var bucketLeftovers = 0

    /// `serverID` is the connected server's id. `hasRecording` says whether a call has its recording on this Mac:
    /// only such a call can wait for a backup.
    public init(_ records: [CallRecord], serverID: String? = nil, hasRecording: (String) -> Bool = { _ in true }) {
        for r in records {
            let copy = r.archived
            switch copy?.kind {
            case .server:
                if let serverID, copy?.server == serverID { onServer += 1 } else {
                    onOtherServer += 1
                    if r.status == .written, hasRecording(r.id) { notBackedUp += 1 }
                }
            case .bucket: inBucket += 1
            case nil: if r.status == .written, r.cloudKey == nil, hasRecording(r.id) { notBackedUp += 1 }
            }
            bucketLeftovers += r.cloudLeftovers?.filter { $0.kind == .bucket }.count ?? 0
        }
    }
}
