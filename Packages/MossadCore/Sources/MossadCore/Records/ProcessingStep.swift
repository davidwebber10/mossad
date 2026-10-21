import Foundation

/// The pipeline step a call is in, for progress text such as "Identifying speakers, step 2 of 4".
public enum ProcessingStep: Int, CaseIterable, Sendable {
    case transcribing = 1, identifying, summarizing, writing

    /// The step that runs next for a call with this status; nil when no step is running.
    public init?(status: CallStatus) {
        switch status {
        case .recorded: self = .transcribing
        case .transcribed: self = .identifying
        case .identified: self = .summarizing
        case .summarized: self = .writing
        case .recording, .written, .failed: return nil
        }
    }

    public var title: String {
        switch self {
        case .transcribing: "Transcribing"
        case .identifying: "Identifying speakers"
        case .summarizing: "Writing summary"
        case .writing: "Writing note"
        }
    }

    public static var total: Int { allCases.count }
}
