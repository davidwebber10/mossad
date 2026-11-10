import Foundation

/// Joins recordings of one meeting (split by a restart, or picked by the person) into one record.
public enum MeetingMerge {
    /// Recordings of the same meeting link this close together are one meeting that was interrupted.
    public static let continuationGap: TimeInterval = 120

    /// The earliest record absorbs the others. Times move by each part's place in the joined audio, and
    /// speaker labels of later parts get the part's number in the joined meeting ("A" becomes "A2"), so two
    /// different people who were both "A" stay apart. `durations` is each record's audio length, by record ID.
    /// What was made from the old audio is cleared: the archive key (the joined recording is a new file), a
    /// transcription job, and the summary.
    public static func combine(_ records: [CallRecord], durations: [String: TimeInterval]) -> CallRecord {
        let sorted = records.sorted { $0.start < $1.start }
        var merged = sorted[0]
        merged.utterances = []
        merged.speakerNames = [:]
        merged.unknownSpeakers = []
        merged.speakerEmbeddings = [:]
        merged.parts = []
        merged.markers = []
        merged.cloudKey = nil
        merged.cloudSize = nil
        merged.transcriptionJobs = nil
        merged.summaryMissing = nil
        var screens: [SharedScreen] = []
        var gaps: [ScreenGap] = []
        var me: [Utterance]? = [], them: [Utterance]? = []
        var offset: TimeInterval = 0
        for r in sorted {
            // A record that was merged before holds several parts, and its labels carry their numbers already.
            let before = merged.parts.count
            func label(_ l: String) -> String { partLabel(l, movedBy: before) }
            func move(_ u: Utterance) -> Utterance {
                var u = u
                u.speakerLabel = label(u.speakerLabel)
                u.start += offset
                u.end += offset
                u.words = u.words?.map { Word(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
                return u
            }
            func key(_ k: String) -> String {
                guard let colon = k.firstIndex(of: ":") else { return label(k) }
                return String(k[...colon]) + label(String(k[k.index(after: colon)...]))
            }
            merged.utterances += r.utterances.map(move)
            me = me.flatMap { list in r.meUtterances.map { list + $0.map(move) } }
            them = them.flatMap { list in r.themUtterances.map { list + $0.map(move) } }
            for (k, name) in r.speakerNames { merged.speakerNames[key(k)] = name }
            merged.unknownSpeakers += r.unknownSpeakers.map(key)
            for (k, e) in r.speakerEmbeddings { merged.speakerEmbeddings[key(k)] = e }
            // A record that was itself merged keeps its own parts.
            let own = r.parts.isEmpty ? [CallPart(start: r.start, end: r.end, offset: 0)] : r.parts
            merged.parts += own.map { CallPart(start: $0.start, end: $0.end, offset: $0.offset + offset) }
            merged.markers += r.markers.map { TranscriptMarker(offset: $0.offset + offset, text: $0.text, isBookmark: $0.isBookmark, note: $0.note) }
            // The same move as `FrameIndex.moved`, so each screen still names its picture.
            let sessions = (screens.compactMap(\.session).max() ?? -1) + 1
            screens += (r.screens ?? []).map { s in
                var s = s
                s.offset += offset
                if offset != 0 { s.file = FrameIndex.fileName(offset: s.offset) }
                s.session = s.session.map { $0 + sessions }
                return s
            }
            gaps += (r.screenGaps ?? []).map { ScreenGap(offset: $0.offset + offset, paused: $0.paused) }
            if merged.meetingID == nil { merged.meetingID = r.meetingID }
            if merged.calendarTitle == nil {
                merged.calendarTitle = r.calendarTitle
                merged.plannedStart = r.plannedStart
                merged.plannedEnd = r.plannedEnd
            }
            for a in r.attendees where !merged.attendees.contains(a) { merged.attendees.append(a) }
            offset += durations[r.id] ?? r.end.timeIntervalSince(r.start)
        }
        merged.utterances.sort { $0.start < $1.start }
        merged.screens = records.contains { $0.screens != nil } ? screens : nil
        merged.screenGaps = gaps.isEmpty ? nil : gaps
        // The joined frames have new names; the old names of deleted ones mean nothing there.
        merged.deletedScreens = nil
        merged.meUtterances = me
        merged.themUtterances = them
        merged.end = sorted.map(\.end).max() ?? merged.end
        // The summary and the note are written again for the whole meeting.
        merged.summary = nil
        merged.headline = nil
        merged.topics = []
        merged.kind = nil
        merged.hasOutcomes = nil
        merged.actionItems = []
        merged.decisions = []
        merged.status = .identified
        merged.attempts = 0
        merged.nextAttempt = nil
        merged.failedStep = nil
        merged.failureReason = nil
        return merged
    }

    /// "A" in the first part stays "A"; in part 3 it is "A3". A label that has a part number already ("A2", from an
    /// earlier merge) moves by the parts in front of it.
    static func partLabel(_ label: String, movedBy parts: Int) -> String {
        let digits = label.reversed().prefix { $0.isNumber }.count
        let name = String(label.dropLast(digits))
        // A label that is only a number is a name, not a part number.
        guard !name.isEmpty else { return parts == 0 ? label : "\(label)-\(parts + 1)" }
        let part = (Int(label.suffix(digits)) ?? 1) + parts
        return part == 1 ? name : "\(name)\(part)"
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
