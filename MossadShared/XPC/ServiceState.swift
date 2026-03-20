import Foundation

public enum RecordingState: String, Codable {
    case idle
    case detecting
    case recording
    case paused
}

public struct ServiceSnapshot: Codable {
    public var recordingState: RecordingState
    public var currentConversationId: String?
    public var currentMeetingTitle: String?
    public var currentPlatform: String?
    public var elapsedSeconds: Int?
    public var speakerCount: Int?

    public init(
        recordingState: RecordingState = .idle,
        currentConversationId: String? = nil,
        currentMeetingTitle: String? = nil,
        currentPlatform: String? = nil,
        elapsedSeconds: Int? = nil,
        speakerCount: Int? = nil
    ) {
        self.recordingState = recordingState
        self.currentConversationId = currentConversationId
        self.currentMeetingTitle = currentMeetingTitle
        self.currentPlatform = currentPlatform
        self.elapsedSeconds = elapsedSeconds
        self.speakerCount = speakerCount
    }

    public func encoded() -> Data { try! JSONEncoder().encode(self) }
    public static func decoded(from data: Data) -> ServiceSnapshot? { try? JSONDecoder().decode(ServiceSnapshot.self, from: data) }
}
