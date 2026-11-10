import Foundation

/// The two jobs the owner picks a provider for. Setup and Settings both use these words, so a job has one name.
public enum ProviderJob: Sendable {
    case transcription, notes

    public var title: String {
        switch self {
        case .transcription: "Transcription"
        case .notes: "Notes"
        }
    }

    /// What the provider does with the owner's calls.
    public var detail: String {
        switch self {
        case .transcription: "Turns each call's audio into the transcript."
        case .notes: "Writes the summary, the action items, and the coach's notes, and answers in Chat."
        }
    }
}
