import Foundation

/// One place where a recording is cut: a second of the recording's own timeline (paused time left out), and the
/// link of the call that starts there, when known. `titleKey`: the `CallMark.titleKey` of the change that the cut is
/// at, when its marks had one (the later part's first title).
public struct Cut: Codable, Equatable, Sendable {
    public var at: TimeInterval
    public var link: String?
    public var titleKey: String?

    public init(at: TimeInterval, link: String?, titleKey: String? = nil) {
        self.at = at
        self.link = link
        self.titleKey = titleKey
    }
}

/// What each part of a cut recording holds. Pure.
public enum CutRecord {
    /// `divided`: by time, with the offsets of a later part moved back by its start. `same`: the original's value in
    /// each part. `first`: the original's value in the first part only. `cleared`: the pipeline makes it again for
    /// each part. `special`: a rule of its own (the id, the times, the status, the link, and `cutFrom`).
    public enum Rule: String, Sendable { case divided, same, first, cleared, special }

    /// Every stored field of `CallRecord` (its JSON key) and its rule. A field with no rule fails
    /// `CutRecordTests.testEveryFieldOfARecordHasARule`, which lists the fields by reflection.
    public static let fields: [String: Rule] = {
        var f: [String: Rule] = [:]
        // `firstTitleKey`: the original's in the first part; a later part's is its cut's title key (`Cut.titleKey`, else the
        // mark at the cut), else nil.
        for k in ["id", "start", "end", "status", "meetingID", "cutFrom", "firstTitleKey"] { f[k] = .special }
        for k in ["markers", "muteSpans", "screens", "screenGaps", "deletedScreens", "parts", "callMarks", "pauses"] { f[k] = .divided }
        // The owner's own title and tags; tags the model gave are made again.
        for k in ["customTitle", "tags", "tagsSetByOwner"] { f[k] = .first }
        // The code of the call's own title is taken before any mark: the first part's.
        f["titleLink"] = .first
        // A notes-only meeting, a phone call, and a call whose mute silence is still to be written are refused, so
        // `source`, `personHint`, and `mutedAudioPending` hold their plain values. A recording marked for another profile is
        // cut only by its marks, and each part keeps the mark and is held for the owner.
        for k in ["platform", "bundleID", "source", "personHint", "mutedAudioPending", "moveTo"] { f[k] = .same }
        // The lines, the voices, the summary and all from it, the invite, the titles, the backup, the jobs, the failure.
        for k in ["attempts", "nextAttempt", "calendarTitle", "generatedTitle", "plannedStart", "plannedEnd", "attendees", "invitees",
                  "calendarSeriesID", "organizer", "utterances", "meUtterances", "themUtterances", "failedStep", "failureReason",
                  "inviteUnknown", "inviteNotSure", "speakerNames", "speakerPeople", "unknownSpeakers", "speakerEmbeddings",
                  "speakerSamples", "fromInvite", "summary", "topics", "kind", "summaryVersion", "hasOutcomes", "actionItems",
                  "decisions", "decisionTimes", "headline", "markdownPath", "cloudKey", "cloudSize", "cloudBackend", "cloudServer",
                  "cloudHash", "cloudLeftovers", "transcriptionJobs", "summaryMissing", "gemini",
                  // The owner's number of speakers was for the whole recording, not for one part of it.
                  "speakersExpected",
                  // A part is never cut again (`cutFrom`).
                  "cutChecked", "inviteChecked"] { f[k] = .cleared }
        return f
    }()

    /// The parts of `r`, one for each id, cut at `cuts` (taken in time order). `length` is the recording's length
    /// in seconds of its own timeline.
    public static func parts(of r: CallRecord, at cuts: [Cut], ids: [String], length: TimeInterval) -> [CallRecord] {
        let cuts = cuts.sorted { $0.at < $1.at }
        precondition(ids.count == cuts.count + 1, "one id for each part")
        let borders = [0] + cuts.map(\.at) + [length]
        return ids.indices.map { k in
            let from = borders[k], to = borders[k + 1], last = k == ids.count - 1
            func inside(_ offset: TimeInterval) -> Bool { offset >= from && (last || offset < to) }
            var p = r
            p.id = ids[k]
            p.status = .recorded
            p.cutFrom = r.cutFrom ?? r.id
            p.meetingID = k == 0 ? r.meetingID : cuts[k - 1].link
            p.firstTitleKey = k == 0 ? r.firstTitleKey
                : cuts[k - 1].titleKey ?? r.callMarks?.first { $0.at == cuts[k - 1].at && $0.titleKey != nil }?.titleKey
            p.start = k == 0 ? r.start : wallTime(of: from, in: r, afterPauses: true)
            p.end = last ? r.end : wallTime(of: to, in: r, afterPauses: false)

            p.markers = r.markers.filter { inside($0.offset) }.map { var m = $0; m.offset -= from; return m }
            p.muteSpans = r.muteSpans.compactMap { s in
                let start = max(s.start, from)
                let end = s.end.map { last ? $0 : min($0, to) } ?? (last ? nil : to)
                guard start < (end ?? .infinity), last || start < to else { return nil }
                return MuteSpan(start: start - from, end: end.map { $0 - from })
            }
            p.screens = nonEmpty(r.screens?.filter { inside($0.offset) }.map { s in
                var s = s
                s.offset -= from
                if from != 0 { s.file = FrameIndex.fileName(offset: s.offset) }
                return s
            })
            p.screenGaps = nonEmpty(r.screenGaps?.filter { inside($0.offset) }.map { ScreenGap(offset: $0.offset - from, paused: $0.paused) })
            p.deletedScreens = nonEmpty(r.deletedScreens?.compactMap { name in
                // A name that holds no offset is kept in each part: it only keeps a deleted screen away.
                guard let offset = frameOffset(name) else { return name }
                guard inside(offset) else { return nil }
                return from == 0 ? name : FrameIndex.fileName(offset: offset - from)
            })
            p.parts = dividedParts(r.parts, from: from, to: to, last: last, length: length)
            // A pause exactly on a border lies between two parts: their times already leave it out.
            // A record that knows its pauses gives each part a list, empty when it has none.
            p.pauses = r.pauses?.filter { $0.at > from || (k == 0 && $0.at == 0) }
                .filter { $0.at < to || (last && $0.at == to) }
                .map { var s = $0; s.at -= from; return s }
            // A part never holds a mark at its own start: that is the mark of its own cut, and it would cut it again.
            p.callMarks = nonEmpty(r.callMarks?.filter { $0.at > from && (last || $0.at < to) }.map { var m = $0; m.at -= from; return m })

            if k > 0 {
                p.customTitle = nil
                p.tagsSetByOwner = nil
                p.titleLink = nil
            }
            if k > 0 || r.tagsSetByOwner != true { p.tags = [] }
            clearDerived(&p)
            return p
        }
    }

    /// The meeting that a page of `id` shows once `id` was cut: its first part. Nil when `id` was not cut.
    public static func firstPart(of id: String, in records: [CallRecord]) -> String? {
        records.filter { $0.cutFrom == id }.min { ($0.start, $0.id) < ($1.start, $1.id) }?.id
    }

    /// The reason the cut is refused, in plain words; nil when it may run. The checks that need the disk (a call in
    /// work, a move that started, a merge or a cut in progress) are the pipeline's.
    /// `holdingMarked`: the cut by the marks, which holds each part of a recording marked for another profile.
    public static func refusal(_ r: CallRecord, cuts: [Cut], length: TimeInterval, hasTracks: Bool, holdingMarked: Bool = false) -> String? {
        if r.status == .recording { return "The call records now." }
        if r.source != nil { return "A meeting made from notes has no recording to cut." }
        if r.platform == .phoneCall { return "A phone call is not cut." }
        if r.mutedAudioPending { return "The silence of a mute is not written yet." }
        // Only the cut by the marks holds each part for the owner; the command never cuts a marked recording.
        if r.moveTo != nil, !holdingMarked { return "The meeting is marked for another profile." }
        if !hasTracks { return "The two tracks of the recording are not on this Mac." }
        if cuts.isEmpty { return "No cut time was given." }
        let times = cuts.map(\.at).sorted()
        if let bad = times.first(where: { $0 <= 0 || $0 >= length }) {
            return "The time \(Int(bad)) s is not inside the audio of \(Int(length)) s."
        }
        let borders = [0] + times + [length]
        for i in 0..<(borders.count - 1) where borders[i + 1] - borders[i] < ProcessingQueue.minimumCallDuration {
            return "A part would be shorter than \(Int(ProcessingQueue.minimumCallDuration)) s."
        }
        return nil
    }

    /// The wall time of second `t` of the recording: the start of its recording (one part of a joined meeting) plus
    /// the time since then, with each pause before it. `afterPauses` counts a pause exactly at `t` too.
    static func wallTime(of t: TimeInterval, in r: CallRecord, afterPauses: Bool) -> Date {
        var base = r.start, origin: TimeInterval = 0
        if r.parts.count > 1 {
            let candidates = r.parts.filter { afterPauses ? $0.offset <= t : $0.offset < t }
            if let part = candidates.max(by: { $0.offset < $1.offset }) ?? r.parts.min(by: { $0.offset < $1.offset }) {
                base = part.start
                origin = part.offset
            }
        }
        let paused = (r.pauses ?? []).filter { $0.at >= origin && (afterPauses ? $0.at <= t : $0.at < t) }
            .reduce(0.0) { $0 + max(0, ($1.to ?? r.end).timeIntervalSince($1.from)) }
        return base + (t - origin) + paused
    }

    /// The recordings of a joined meeting that lie in one part, each with its wall times from its own start. One
    /// recording is no joined meeting.
    static func dividedParts(_ parts: [CallPart], from: TimeInterval, to: TimeInterval, last: Bool, length: TimeInterval) -> [CallPart] {
        guard parts.count > 1 else { return [] }
        let sorted = parts.sorted { $0.offset < $1.offset }
        var out: [CallPart] = []
        for (i, p) in sorted.enumerated() {
            let pEnd = i + 1 < sorted.count ? sorted[i + 1].offset : max(length, to)
            let lo = max(p.offset, from), hi = last ? pEnd : min(pEnd, to)
            guard lo < hi else { continue }
            let start = p.start + (lo - p.offset)
            let end = (last && i == sorted.count - 1) || hi == pEnd ? p.end : min(p.end, p.start + (hi - p.offset))
            out.append(CallPart(start: start, end: end, offset: lo - from))
        }
        return out.count > 1 ? out : []
    }

    /// The offset in a frame's file name (`<ms>.heic`), or nil.
    static func frameOffset(_ name: String) -> TimeInterval? {
        guard name.hasSuffix(".heic"), let ms = Int(name.dropLast(5)) else { return nil }
        return TimeInterval(ms) / 1000
    }

    private static func nonEmpty<T>(_ list: [T]?) -> [T]? {
        guard let list, !list.isEmpty else { return nil }
        return list
    }

    /// Everything the pipeline makes again for each part, at its default.
    private static func clearDerived(_ p: inout CallRecord) {
        let blank = CallRecord(id: p.id, platform: p.platform, bundleID: p.bundleID, start: p.start, end: p.end, status: .recorded)
        p.attempts = blank.attempts
        p.nextAttempt = nil
        p.calendarTitle = nil
        p.generatedTitle = nil
        p.plannedStart = nil
        p.plannedEnd = nil
        p.attendees = []
        p.invitees = nil
        p.calendarSeriesID = nil
        p.organizer = nil
        p.utterances = []
        p.meUtterances = nil
        p.themUtterances = nil
        p.failedStep = nil
        p.failureReason = nil
        p.inviteUnknown = nil
        p.inviteNotSure = nil
        p.inviteChecked = nil
        p.speakerNames = [:]
        p.speakerPeople = nil
        p.unknownSpeakers = []
        p.speakerEmbeddings = [:]
        p.speakerSamples = nil
        p.fromInvite = nil
        p.summary = nil
        p.topics = []
        p.kind = nil
        p.summaryVersion = nil
        p.hasOutcomes = nil
        p.actionItems = []
        p.decisions = []
        p.headline = nil
        p.markdownPath = nil
        p.cloudKey = nil
        p.cloudSize = nil
        p.cloudBackend = nil
        p.cloudServer = nil
        p.cloudHash = nil
        p.cloudLeftovers = nil
        p.transcriptionJobs = nil
        p.summaryMissing = nil
        p.gemini = nil
        p.speakersExpected = nil
        p.cutChecked = nil
    }
}
