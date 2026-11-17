import AVFoundation
import Foundation

extension CallImport {
    /// What the phone reads of a handed file. Each value it cannot read is nil: unknown is not empty.
    public struct File: Equatable, Sendable {
        /// The last path component.
        public var name: String
        /// The uniform type, such as "com.apple.m4a-audio".
        public var typeIdentifier: String?
        public var bytes: Int64?
        /// Nil when AVAudioFile cannot read it.
        public var length: TimeInterval?
        /// The creation date in the audio's own metadata.
        public var metadataDate: Date?
        /// The file's creation date.
        public var fileDate: Date?

        public init(name: String, typeIdentifier: String?, bytes: Int64?, length: TimeInterval?, metadataDate: Date?, fileDate: Date?) {
            self.name = name
            self.typeIdentifier = typeIdentifier
            self.bytes = bytes
            self.length = length
            self.metadataDate = metadataDate
            self.fileDate = fileDate
        }
    }

    /// Each value it cannot read is nil. Call it off the main actor: the length and the metadata read the file.
    public static func read(_ url: URL) async -> File {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey])
        return File(
            name: url.lastPathComponent,
            typeIdentifier: values?.contentType?.identifier,
            bytes: values?.fileSize.map(Int64.init),
            length: RoomAudio.length(of: url),
            metadataDate: await metadataDate(of: url),
            fileDate: values?.creationDate)
    }

    private static func metadataDate(of url: URL) async -> Date? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let item = try? await AVURLAsset(url: url).load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }
}
