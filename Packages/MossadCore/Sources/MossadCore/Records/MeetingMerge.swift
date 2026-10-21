import Foundation

/// Joins recordings of one meeting (split by a restart, or picked by the person) into one record.
public enum MeetingMerge {
    /// Recordings of the same meeting link this close together are one meeting that was interrupted.
    public static let continuationGap: TimeInterval = 120

    /// The earliest record absorbs the others. Times move by each part's place in the joined audio, and
    /// speaker labels of later parts get the part number ("A" becomes "A2"), so two different people who
    /// were both "A" stay apart. `durations` is each record's audio length, by record ID.
    public static func combine(_ records: [CallRecord], durations: [String: TimeInterval]) -> CallRecord {
        let sorted = records.sorted { $0.start < $1.start }
        var merged = sorted[0]
        merged.utterances = []
        merged.speakerNames = [:]
        merged.unknownSpeakers = []
        merged.speakerEmbeddings = [:]
        merged.parts = []
        var me: [Utterance]? = [], them: [Utterance]? = []
        var offset: TimeInterval = 0
        for (index, r) in sorted.enumerated() {
            let suffix = index == 0 ? "" : "\(index + 1)"
            func move(_ u: Utterance) -> Utterance {
                var u = u
                u.speakerLabel += suffix
                u.start += offset
                u.end += offset
                u.words = u.words?.map { Word(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
                return u
            }
            func key(_ k: String) -> String { k + suffix }
            merged.utterances += r.utterances.map(move)
            me = me.flatMap { list in r.meUtterances.map { list + $0.map(move) } }
            them = them.flatMap { list in r.themUtterances.map { list + $0.map(move) } }
            for (k, name) in r.speakerNames { merged.speakerNames[key(k)] = name }
            merged.unknownSpeakers += r.unknownSpeakers.map(key)
            for (k, e) in r.speakerEmbeddings { merged.speakerEmbeddings[key(k)] = e }
            // A record that was itself merged keeps its own parts.
            let own = r.parts.isEmpty ? [CallPart(start: r.start, end: r.end, offset: 0)] : r.parts
            merged.parts += own.map { CallPart(start: $0.start, end: $0.end, offset: $0.offset + offset) }
            if merged.meetingID == nil { merged.meetingID = r.meetingID }
            if merged.calendarTitle == nil { merged.calendarTitle = r.calendarTitle }
            for a in r.attendees where !merged.attendees.contains(a) { merged.attendees.append(a) }
            offset += durations[r.id] ?? r.end.timeIntervalSince(r.start)
        }
        merged.utterances.sort { $0.start < $1.start }
        merged.meUtterances = me
        merged.themUtterances = them
        merged.end = sorted.map(\.end).max() ?? merged.end
        // The summary and the note are written again for the whole meeting.
        merged.summary = nil
        merged.headline = nil
        merged.actionItems = []
        merged.decisions = []
        merged.status = .identified
        merged.attempts = 0
        merged.nextAttempt = nil
        merged.failedStep = nil
        merged.failureReason = nil
        return merged
    }

    public struct PartBreak: Equatable, Sendable {
        public var offset: TimeInterval
        public var text: String
    }

    /// The lines shown where a later part begins: a short gap reads as a resumed recording.
    public static func partBreaks(_ r: CallRecord) -> [PartBreak] {
        guard r.parts.count > 1 else { return [] }
        return r.parts.indices.dropFirst().map { i in
            let part = r.parts[i]
            let gap = max(0, part.start.timeIntervalSince(r.parts[i - 1].end))
            let time = part.start.formatted(date: .omitted, time: .standard)
            let text = gap <= continuationGap
                ? "Recording resumed at \(time), \(Int(gap.rounded())) s later"
                : "Joined with a recording from \(part.start.formatted(date: .abbreviated, time: .shortened))"
            return PartBreak(offset: part.offset, text: text)
        }
    }
}
