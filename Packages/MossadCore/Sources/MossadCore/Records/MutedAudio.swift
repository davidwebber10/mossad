import AVFoundation
import Foundation

/// The last step of mute: the mic track keeps the real samples while a call runs (the mute state comes late), and
/// silence goes over the mute spans when the recording ends. Until that worked, the call must not be processed.
public enum MutedAudio {
    public static let failureReason = "Muted parts could not be silenced"

    public struct NotSilenced: LocalizedError {
        public let underlying: String
        public var errorDescription: String? { "\(MutedAudio.failureReason): \(underlying)" }
    }

    /// Writes silence over the record's mute spans in its mic track and clears `mutedAudioPending`. A span still
    /// open (a crash while muted) runs to the end of the track. Safe to run again. On failure it throws and the
    /// record stays pending.
    public static func apply(to r: inout CallRecord, in dir: URL) throws {
        guard !r.muteSpans.isEmpty else {
            r.mutedAudioPending = false
            return
        }
        let url = dir.appendingPathComponent(Track.me.fileName)
        // No mic track, nothing that was said while muted.
        guard FileManager.default.fileExists(atPath: url.path) else {
            r.mutedAudioPending = false
            return
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let length = Double(file.length) / file.fileFormat.sampleRate
            if let open = r.muteSpans.indices.last, r.muteSpans[open].end == nil { r.muteSpans[open].end = max(length, r.muteSpans[open].start) }
            try silenceAudioFile(url, spans: MuteSpan.ranges(r.muteSpans, length: length))
            r.mutedAudioPending = false
        } catch {
            r.mutedAudioPending = true
            throw NotSilenced(underlying: error.localizedDescription)
        }
    }

    /// Marks a call whose muted parts are still in the track: failed at the first step, so no build transcribes it.
    public static func hold(_ r: inout CallRecord) {
        r.mutedAudioPending = true
        r.status = .failed
        r.failedStep = .recorded
        r.failureReason = failureReason
    }
}
