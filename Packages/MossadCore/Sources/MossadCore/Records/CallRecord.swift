import Foundation

public enum CallStatus: String, Codable, Sendable {
    case recording, recorded, transcribed, identified, summarized, written, failed
}

public enum Track: String, Codable, Sendable {
    case me, them

    public var fileName: String { "\(rawValue).caf" }
}

/// One recognised word with its time in the track, in seconds.
public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Utterance: Codable, Equatable, Sendable {
    public var track: Track
    public var speakerLabel: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Word times, when the transcriber gave them (older records have none).
    public var words: [Word]?

    /// Key used for speaker naming, e.g. `them:A`.
    public var speakerKey: String { "\(track.rawValue):\(speakerLabel)" }

    public init(track: Track, speakerLabel: String, start: TimeInterval, end: TimeInterval, text: String, words: [Word]? = nil) {
        self.words = words
        self.track = track
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One recording inside a merged meeting: when it ran, and where it begins in the joined audio.
public struct CallPart: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var offset: TimeInterval

    public init(start: Date, end: Date, offset: TimeInterval) {
        self.start = start
        self.end = end
        self.offset = offset
    }
}

/// A line in the transcript for something that happened to the recording, such as a pause.
public struct TranscriptMarker: Codable, Equatable, Sendable {
    /// Seconds into the recording.
    public var offset: TimeInterval
    public var text: String
    /// A moment the owner marked as important during the call.
    public var isBookmark = false
    /// What the owner typed for a bookmark. A separate key, so builds that predate it still read the marker.
    public var note: String?

    public init(offset: TimeInterval, text: String, isBookmark: Bool = false, note: String? = nil) {
        self.offset = offset
        self.text = text
        self.isBookmark = isBookmark
        self.note = note
    }

    /// The marker's line in the transcript, with a bookmark's note after it.
    public var lineText: String {
        guard isBookmark, let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return text }
        return "\(text): \(note)"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(TimeInterval.self, forKey: .offset)
        text = try c.decode(String.self, forKey: .text)
        isBookmark = try c.decodeIfPresent(Bool.self, forKey: .isBookmark) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// A time the owner was muted in the call app, in seconds of the mic track. The mic writes the real samples; silence
/// goes over the span when the recording ends (or when a crashed recording is recovered). `end` is nil while the
/// span is open.
public struct MuteSpan: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval?

    public init(start: TimeInterval, end: TimeInterval?) {
        self.start = start
        self.end = end
    }

    /// The spans as ranges, an open one running to `length`, each cut to the file.
    public static func ranges(_ spans: [MuteSpan], length: TimeInterval) -> [ClosedRange<TimeInterval>] {
        spans.compactMap { span in
            let start = max(0, span.start), end = min(span.end ?? length, length)
            return end > start ? start...end : nil
        }
    }
}

extension CallRecord {
    /// Sets the note of the bookmark within a second of `offset`, or adds a bookmark there. A blank note
    /// clears the note and keeps the bookmark. Returns false when a blank note had no bookmark to clear.
    @discardableResult
    mutating func setBookmarkNote(at offset: TimeInterval, _ note: String, markerText: String) -> Bool {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        if let i = markers.indices.filter({ markers[$0].isBookmark && abs(markers[$0].offset - offset) <= 1 })
            .min(by: { abs(markers[$0].offset - offset) < abs(markers[$1].offset - offset) }) {
            markers[i].note = note
            return true
        }
        guard note != nil else { return false }
        markers.append(TranscriptMarker(offset: offset, text: markerText, isBookmark: true, note: note))
        markers.sort { $0.offset < $1.offset }
        return true
    }

    /// Adds a bookmark at `offset` unless one is already within a second of it.
    @discardableResult
    mutating func addBookmark(at offset: TimeInterval, markerText: String) -> Bool {
        guard !markers.contains(where: { $0.isBookmark && abs($0.offset - offset) <= 1 }) else { return false }
        markers.append(TranscriptMarker(offset: offset, text: markerText, isBookmark: true))
        markers.sort { $0.offset < $1.offset }
        return true
    }
}

/// Everything known about one call; saved as `call.json` in the call's audio directory.
/// Where a meeting's shown title comes from, strongest first.
public enum TitleSource: Sendable { case custom, calendar, generated, platform }

/// Something the meeting decided, with the second of the call when it was made, if known.
public struct Decision: Codable, Equatable, Sendable, Hashable {
    public var text: String
    public var at: TimeInterval?

    private enum CodingKeys: String, CodingKey { case text, at }

    public init(text: String, at: TimeInterval? = nil) {
        self.text = text
        self.at = at
    }

    /// Records saved before decisions had times hold plain strings.
    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text: text)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decode(String.self, forKey: .text), at: try c.decodeIfPresent(TimeInterval.self, forKey: .at))
    }

    /// Text only: an older phone and the deployed Worker read decisions as strings. The times travel beside
    /// them as `decisionTimes`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }

    /// The times in order, or nil when none is known, so records without times stay as they were.
    static func times(of decisions: [Decision]) -> [Double?]? {
        decisions.contains { $0.at != nil } ? decisions.map(\.at) : nil
    }

    /// Gives each decision the time stored at its position, unless it already carries one.
    static func joined(_ decisions: [Decision], _ times: [Double?]?) -> [Decision] {
        guard let times else { return decisions }
        return decisions.enumerated().map { i, d in
            Decision(text: d.text, at: d.at ?? (i < times.count ? times[i] : nil))
        }
    }
}

public struct CallRecord: Codable, Equatable, Sendable {
    public var id: String
    public var platform: Platform
    public var bundleID: String
    public var start: Date
    public var end: Date
    public var status: CallStatus
    public var attempts = 0
    public var nextAttempt: Date?
    /// The meeting's ID from its link (Meet code, Zoom number, Teams meeting ID), when the call ran in a browser.
    public var meetingID: String?
    public var calendarTitle: String?
    /// Named by the model: provisional during the call, then replaced by the summary's. Kept apart from
    /// `calendarTitle` because Analytics counts a meeting with a calendar title as scheduled.
    public var generatedTitle: String?
    /// Set by the owner; wins over every other source and no summary replaces it.
    public var customTitle: String?
    /// When the calendar invite planned the meeting; nil for a call with no invite, and in records from before
    /// this was saved. The meeting's Analytics tab reads a late start and an overrun from them.
    public var plannedStart: Date?
    public var plannedEnd: Date?
    public var attendees: [String] = []
    /// The invited people with the name and the address apart, when the calendar gave them. `attendees` has one
    /// text for each; this has both, so the address can say who a name is. Nil in records from before it.
    public var invitees: [Invitee]?
    /// The id of the calendar series the invite belongs to, when the calendar said (Google). Nil for a single event.
    public var calendarSeriesID: String?
    /// Who sent the invite, when the calendar said (Google).
    public var organizer: Invitee?
    public var utterances: [Utterance] = []
    /// Per-track results, kept so a failed track does not force the other one to be transcribed again.
    public var meUtterances: [Utterance]?
    public var themUtterances: [Utterance]?
    /// The step that failed when `status` is `.failed`.
    public var failedStep: CallStatus?
    /// Short text for the last error, such as "AssemblyAI key missing"; nil once a step succeeds.
    public var failureReason: String?
    /// Speaker key (`me:A`, `them:B`) → person name. The name is a label: `speakerPeople` says who it is.
    public var speakerNames: [String: String] = [:]
    /// Speaker key → the id of the person in `people.json`, on a sure match only. Nil in records from before ids,
    /// and a key with no id is a label that no saved person surely is. An older build drops this when it saves the
    /// record; the next refresh finds the ids again from the labels.
    public var speakerPeople: [String: String]?
    public var unknownSpeakers: [String] = []
    /// Voice fingerprints per speaker key, kept so a speaker named later can be learned.
    public var speakerEmbeddings: [String: [Float]] = [:]
    /// How much clear speech each fingerprint was made from and how good it is, per speaker key. Nil in records
    /// from before it; a voice named later is learned with these numbers.
    public var speakerSamples: [String: SpeakerSampleDetail]?
    /// Speaker keys whose name came from the invite and not yet from the owner or a second call, for the quiet mark
    /// "Named from the invite". Nil when there are none.
    public var fromInvite: [String]?
    /// Markdown; older records hold plain sentences.
    public var summary: String?
    public var topics: [SummaryTopic] = []
    public var kind: String?
    /// Short topic tags, such as "Databricks" or "Budget", spelled the same across meetings.
    public var tags: [String] = []
    /// True once the owner changed the tags, so a new summary keeps them. Builds that predate this ignore the key.
    public var tagsSetByOwner: Bool?
    /// Which build's summary format this record holds; nil before the field. See `SummaryBackfill.currentVersion`.
    public var summaryVersion: Int?
    /// False for a meeting that only shares information; nil for records from before this field.
    public var hasOutcomes: Bool?
    public var actionItems: [ActionItem] = []
    public var decisions: [Decision] = [] {
        didSet { decisionTimes = Decision.times(of: decisions) }
    }
    /// The seconds each decision was made, in the order of `decisions`; nil when none is known. Stored beside
    /// the text so `decisions` stays an array of strings in call.json for builds that predate times.
    public private(set) var decisionTimes: [Double?]?
    /// One sentence, at most about 140 characters.
    public var headline: String?
    public var markdownPath: String?
    /// The recordings joined into this meeting, oldest first; empty for a single recording.
    public var parts: [CallPart] = []
    /// Pauses and stops by the person, shown in the transcript.
    public var markers: [TranscriptMarker] = []
    /// Where the recording is archived in the bucket, once uploaded.
    public var cloudKey: String?
    /// The size in bytes of the recording that was uploaded to `cloudKey`. A local recording of another size is
    /// not in the cloud (a merge made a new one), so it is uploaded again and kept until then.
    public var cloudSize: Int64?
    /// The place `cloudKey` is in, as an `ArchiveKind`. Nil is the bucket (Cloudflare R2 or Amazon S3), as before
    /// places had names; "server" is the owner's own server.
    public var cloudBackend: String?
    /// For a recording on a server: the id of that server. A recording on another server than the connected one
    /// does not count as backed up.
    public var cloudServer: String?
    /// The SHA-256 of the recording that was uploaded, when the place checked it.
    public var cloudHash: String?
    /// Older copies of the recording in a backup. They go once the recording as it is now is safe: after a move to
    /// another place is checked, or after a merge made a new recording.
    public var cloudLeftovers: [ArchivedObject]?
    /// The transcription service's job per track ("me", "them") while it runs, so a restart polls that job
    /// instead of paying for a new one.
    public var transcriptionJobs: [String: String]?
    /// True when the note was written without a summary after the summary failed; a later run tries again.
    public var summaryMissing: Bool?
    /// How many people spoke, when the person said so for a new transcription.
    public var speakersExpected: Int?
    /// When the owner was muted in the call app; silence goes over these spans in the mic track.
    public var muteSpans: [MuteSpan] = []
    /// True while the mic track still holds what was said in a mute span. Nothing may transcribe, upload, or play the
    /// track until `MutedAudio.apply` wrote the silence and cleared this.
    public var mutedAudioPending = false
    /// The kept frames of screens shared in the call, with their text. Nil for a call with no screen capture.
    public var screens: [SharedScreen]?
    /// Pauses of the screen capture next to a share session, shown as lines of the transcript.
    public var screenGaps: [ScreenGap]?
    /// Where the meeting came from when it was not recorded: "geminiNotes" for a meeting made from its Gemini notes,
    /// with no audio. Nil for a recording.
    public var source: String?
    /// The meeting's "Notes by Gemini" document: the source of a notes-only meeting, or a second source of a recorded
    /// one. Nil when there is none.
    public var gemini: GeminiNotesRef?
    /// The file names of screens the owner deleted. The text step drops them from `frames.json` if they are still
    /// there (a failed save, a run that was reading at that moment), so a deleted screen never comes back.
    public var deletedScreens: [String]?

    public init(id: String, platform: Platform, bundleID: String, start: Date, end: Date, status: CallStatus) {
        self.id = id
        self.platform = platform
        self.bundleID = bundleID
        self.start = start
        self.end = end
        self.status = status
    }

    public var titleSource: TitleSource {
        if customTitle != nil { .custom } else if calendarTitle != nil { .calendar } else if generatedTitle != nil { .generated } else { .platform }
    }

    public var title: String { customTitle ?? calendarTitle ?? generatedTitle ?? "\(platform.displayName) call" }

    /// Takes the invite's title, people, and planned times. An all-day event plans no time of day.
    public mutating func setInvite(_ event: CalendarEventInfo) {
        // A later match of the same event from a source that does not say (the Mac's copy) keeps what Google said.
        let same = calendarTitle == event.title && plannedStart == (event.isAllDay ? nil : event.start)
        calendarTitle = event.title
        attendees = event.attendees
        invitees = event.participants.isEmpty ? nil : event.participants
        calendarSeriesID = event.seriesID ?? (same ? calendarSeriesID : nil)
        organizer = event.organizer ?? (same ? organizer : nil)
        plannedStart = event.isAllDay ? nil : event.start
        plannedEnd = event.isAllDay ? nil : event.end
    }

    /// Every marker line of the transcript in time order: pauses, stops, and where a merged part begins.
    public var transcriptMarkers: [TranscriptMarker] {
        (recordingMarkers + screenMarkers).sorted { $0.offset < $1.offset }
    }

    /// The marker lines without the shared screens, for views that show a screen as more than a line.
    public var recordingMarkers: [TranscriptMarker] {
        (markers + MeetingMerge.partBreaks(self).map { TranscriptMarker(offset: $0.offset, text: $0.text) }).sorted { $0.offset < $1.offset }
    }

    public static let fileName = "call.json"

    /// Whether this record is the call that records now, which began at `since` (nil when nothing records). The
    /// saved start has whole seconds and the recorder's has fractions, so they agree within 2 s.
    public func isLive(recordingSince since: Date?) -> Bool {
        guard status == .recording, let since else { return false }
        return abs(start.timeIntervalSince(since)) < 2
    }

    public func save(to dir: URL, fileName: String = CallRecord.fileName) throws {
        let encoder = JSONEncoder()
        // Not pretty-printed: a record holds every word with its times, three times over, and the line breaks and
        // the indent were about half of the file. Each step and each edit writes the whole file. Any JSON reader
        // (older builds, the iPhone, `--mcp`) reads both forms.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: dir.appendingPathComponent(fileName), options: .atomic)
    }

    public static func load(from dir: URL, fileName: String = fileName) throws -> CallRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CallRecord.self, from: Data(contentsOf: dir.appendingPathComponent(fileName)))
    }
}

extension CallRecord {
    // Fields added over time are missing from older call.json files, so each one falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), platform: try c.decode(Platform.self, forKey: .platform),
                  bundleID: try c.decode(String.self, forKey: .bundleID), start: try c.decode(Date.self, forKey: .start),
                  end: try c.decode(Date.self, forKey: .end), status: try c.decode(CallStatus.self, forKey: .status))
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttempt = try c.decodeIfPresent(Date.self, forKey: .nextAttempt)
        meetingID = try c.decodeIfPresent(String.self, forKey: .meetingID)
        calendarTitle = try c.decodeIfPresent(String.self, forKey: .calendarTitle)
        generatedTitle = try c.decodeIfPresent(String.self, forKey: .generatedTitle)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        plannedStart = try c.decodeIfPresent(Date.self, forKey: .plannedStart)
        plannedEnd = try c.decodeIfPresent(Date.self, forKey: .plannedEnd)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        invitees = try c.decodeIfPresent([Invitee].self, forKey: .invitees)
        calendarSeriesID = try c.decodeIfPresent(String.self, forKey: .calendarSeriesID)
        organizer = try c.decodeIfPresent(Invitee.self, forKey: .organizer)
        utterances = try c.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
        meUtterances = try c.decodeIfPresent([Utterance].self, forKey: .meUtterances)
        themUtterances = try c.decodeIfPresent([Utterance].self, forKey: .themUtterances)
        failedStep = try c.decodeIfPresent(CallStatus.self, forKey: .failedStep)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        speakerPeople = try c.decodeIfPresent([String: String].self, forKey: .speakerPeople)
        unknownSpeakers = try c.decodeIfPresent([String].self, forKey: .unknownSpeakers) ?? []
        speakerEmbeddings = try c.decodeIfPresent([String: [Float]].self, forKey: .speakerEmbeddings) ?? [:]
        speakerSamples = try c.decodeIfPresent([String: SpeakerSampleDetail].self, forKey: .speakerSamples)
        fromInvite = try c.decodeIfPresent([String].self, forKey: .fromInvite)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        decisions = Decision.joined(try c.decodeIfPresent([Decision].self, forKey: .decisions) ?? [],
                                    try c.decodeIfPresent([Double?].self, forKey: .decisionTimes))
        decisionTimes = Decision.times(of: decisions)
        topics = try c.decodeIfPresent([SummaryTopic].self, forKey: .topics) ?? []
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        hasOutcomes = try c.decodeIfPresent(Bool.self, forKey: .hasOutcomes)
        tagsSetByOwner = try c.decodeIfPresent(Bool.self, forKey: .tagsSetByOwner)
        summaryVersion = try c.decodeIfPresent(Int.self, forKey: .summaryVersion)
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        markdownPath = try c.decodeIfPresent(String.self, forKey: .markdownPath)
        parts = try c.decodeIfPresent([CallPart].self, forKey: .parts) ?? []
        markers = try c.decodeIfPresent([TranscriptMarker].self, forKey: .markers) ?? []
        cloudKey = try c.decodeIfPresent(String.self, forKey: .cloudKey)
        cloudSize = try c.decodeIfPresent(Int64.self, forKey: .cloudSize)
        cloudBackend = try c.decodeIfPresent(String.self, forKey: .cloudBackend)
        cloudServer = try c.decodeIfPresent(String.self, forKey: .cloudServer)
        cloudHash = try c.decodeIfPresent(String.self, forKey: .cloudHash)
        cloudLeftovers = try c.decodeIfPresent([ArchivedObject].self, forKey: .cloudLeftovers)
        transcriptionJobs = try c.decodeIfPresent([String: String].self, forKey: .transcriptionJobs)
        summaryMissing = try c.decodeIfPresent(Bool.self, forKey: .summaryMissing)
        speakersExpected = try c.decodeIfPresent(Int.self, forKey: .speakersExpected)
        muteSpans = try c.decodeIfPresent([MuteSpan].self, forKey: .muteSpans) ?? []
        mutedAudioPending = try c.decodeIfPresent(Bool.self, forKey: .mutedAudioPending) ?? false
        screens = try c.decodeIfPresent([SharedScreen].self, forKey: .screens)
        screenGaps = try c.decodeIfPresent([ScreenGap].self, forKey: .screenGaps)
        deletedScreens = try c.decodeIfPresent([String].self, forKey: .deletedScreens)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        gemini = try c.decodeIfPresent(GeminiNotesRef.self, forKey: .gemini)
    }
}

/// A meeting's Gemini notes document, as Mossad read it.
public struct GeminiNotesRef: Codable, Equatable, Sendable {
    /// The Google Doc's id, which makes each document one import.
    public var docID: String
    public var title: String
    public var url: URL?
    /// The calendar event the document was attached to.
    public var eventID: String?
    public var imported: Date
    /// Gemini's own notes as plain text, for a meeting with no transcript of its own.
    public var notes: String?

    public init(docID: String, title: String, url: URL?, eventID: String?, imported: Date, notes: String?) {
        self.docID = docID
        self.title = title
        self.url = url
        self.eventID = eventID
        self.imported = imported
        self.notes = notes
    }
}

extension CallRecord {
    public static let geminiNotesSource = "geminiNotes"

    /// A meeting made from its Gemini notes: no audio, no voices, and nobody's numbers by time.
    public var isNotesOnly: Bool { source == Self.geminiNotesSource }

    /// Whether the owner was in the meeting. A recording: yes. A notes-only meeting: yes when the owner has a line,
    /// else not known (nil), never "no": the owner can listen without a word.
    public var ownerPresent: Bool? {
        guard isNotesOnly else { return true }
        return utterances.contains { $0.track == .me } ? true : nil
    }

    /// The words the lists show for a meeting that was not recorded; nil for a recording.
    public var sourceLabel: String? { isNotesOnly ? "Gemini notes" : nil }
}

extension CallRecord {
    /// Voices with lines but no name that the call no longer asks about, in order of first line. Skips keep no
    /// list of their own, so a skip made before this existed shows here too.
    public var skippedSpeakers: [String] {
        var keys: [String] = []
        for u in utterances where speakerNames[u.speakerKey] == nil && !unknownSpeakers.contains(u.speakerKey)
            && !keys.contains(u.speakerKey) { keys.append(u.speakerKey) }
        return keys
    }

    /// Swaps labels such as "Speaker A" for names in the summary, topics, decisions, and action items. Whole
    /// words only, so "Speaker A" never matches inside "Speaker AB".
    mutating func replaceSpeakerLabels(_ labels: [String: String]) {
        guard !labels.isEmpty else { return }
        func swap(_ text: String) -> String {
            labels.reduce(text) { text, pair in
                text.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: pair.key))\\b", with: NSRegularExpression.escapedTemplate(for: pair.value),
                                          options: .regularExpression)
            }
        }
        summary = summary.map(swap)
        topics = topics.map { SummaryTopic(title: swap($0.title), summary: swap($0.summary)) }
        decisions = decisions.map { Decision(text: swap($0.text), at: $0.at) }
        actionItems = actionItems.map { item in
            var item = item
            // A label that becomes a name is no longer the label its id was found from.
            if let owner = item.owner, let name = labels[owner] { item.owner = name; item.ownerID = nil }
            item.task = swap(item.task)
            return item
        }
    }
}
