import Foundation

/// Where a call is in processing, for the progress card: the step, each track's part of the transcription,
/// and an overall estimate. Shown, never saved.
public struct ProcessingProgress: Equatable, Sendable {
    public enum TrackState: Equatable, Sendable {
        /// The share of the file sent, when the service reports it.
        case uploading(Double?)
        case queued, transcribing, done
        /// No speech in the track, or no track.
        case skipped
    }

    public var step: ProcessingStep
    public var started: Date
    public var stepStarted: Date
    public var tracks: [Track: TrackState] = [:]
    /// The sub-step, such as "Finding the calendar invite".
    public var detail: String?

    public init(step: ProcessingStep, started: Date) {
        self.step = step
        self.started = started
        stepStarted = started
    }

    /// Where each step ends on the overall bar. Transcription is most of the wait; the summary is next.
    static let stepEnds: [Double] = [0.7, 0.78, 0.95, 1]

    /// An estimate from 0 to 1. Only the upload reports real progress, so the rest moves by sub-step.
    public var fraction: Double {
        let i = step.rawValue - 1
        let begin = i == 0 ? 0 : Self.stepEnds[i - 1]
        let end = Self.stepEnds[i]
        guard step == .transcribing else { return begin + (end - begin) * (detail == nil ? 0.1 : 0.5) }
        let active = tracks.values.filter { $0 != .skipped }
        guard !active.isEmpty else { return 0.02 }
        let share = active.map { state -> Double in
            switch state {
            case .uploading(let f): 0.4 * (f ?? 0)
            case .queued: 0.45
            case .transcribing: 0.6
            case .done, .skipped: 1
            }
        }.reduce(0, +) / Double(active.count)
        return begin + (end - begin) * share
    }

    /// The uploading track that is furthest behind, for the one-line text in the list and the menu.
    public var slowestUpload: Track? {
        func sent(_ t: Track) -> Double? { if case .uploading(let f) = tracks[t] { f ?? 0 } else { nil } }
        return [Track.me, .them].filter { sent($0) != nil }.min { sent($0)! < sent($1)! }
    }

    /// "Uploading your mic · 42%", "AssemblyAI is transcribing the call audio".
    public func trackLine(_ track: Track, service: String, room: Bool) -> String? {
        let name = track == .me ? (room ? "the room audio" : "your mic") : "the call audio"
        switch tracks[track] {
        case .uploading(let f?): return "Uploading \(name) · \(Int((f * 100).rounded(.down)))%"
        case .uploading(nil): return "Uploading \(name)"
        case .queued: return "Waiting in \(service)'s queue"
        case .transcribing: return "\(service) is transcribing \(name)"
        case .done: return "\(name.prefix(1).uppercased() + name.dropFirst()) is transcribed"
        case .skipped, nil: return nil
        }
    }
}
