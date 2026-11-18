import Foundation
@testable import MossadCore

/// A record with every stored field set to a value that is not its default, for the field table of a move.
func fullRecord(id: String = "20261101-100000") -> CallRecord {
    let start = Date(timeIntervalSince1970: 1_793_520_000)
    var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: start, end: start + 1800, status: .failed)
    r.attempts = 2
    r.nextAttempt = start + 3600
    r.meetingID = "123456789"
    r.calendarTitle = "Weekly sync"
    r.generatedTitle = "Budget talk"
    r.customTitle = "Zebra budget"
    r.plannedStart = start
    r.plannedEnd = start + 1800
    r.attendees = ["Sam Carter"]
    r.invitees = [Invitee(name: "Sam Carter", email: "sam@example.com", personID: "p-sam"),
                  Invitee(name: "Avery Webb", email: "avery@example.com", isSelf: true, personID: "p-owner")]
    r.calendarSeriesID = "series-1"
    r.organizer = Invitee(name: "Sam Carter", email: "sam@example.com", personID: "p-sam")
    let lines = [Utterance(track: .me, speakerLabel: "A", start: 1, end: 4, text: "the zebra crossing is closed"),
                 Utterance(track: .them, speakerLabel: "A", start: 5, end: 9, text: "Then we go around it")]
    r.utterances = lines
    r.meUtterances = [lines[0]]
    r.themUtterances = [lines[1]]
    r.failedStep = .summarized
    r.failureReason = "The notes service did not answer"
    r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
    r.speakerPeople = ["me:A": "p-owner", "them:A": "p-sam"]
    r.unknownSpeakers = ["them:B"]
    r.speakerEmbeddings = ["me:A": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]]
    r.speakerSamples = ["me:A": SpeakerSampleDetail(seconds: 30, quality: 0.8)]
    r.fromInvite = ["them:A"]
    r.summary = "Sam Carter and Speaker B talked about the zebra budget."
    r.topics = [SummaryTopic(title: "Budget", summary: "The zebra budget stays.")]
    r.kind = "Weekly sync"
    r.tags = ["Budget"]
    r.tagsSetByOwner = true
    r.summaryVersion = 3
    r.hasOutcomes = true
    r.actionItems = [ActionItem(owner: "Sam Carter", task: "Send the zebra budget", ownerID: "p-sam")]
    r.decisions = [Decision(text: "Keep the budget", at: 12)]
    r.headline = "The zebra budget stays."
    r.markdownPath = "/Users/made-up/Mossad/Meetings/2026-11-01 1000 - Zebra budget.md"
    r.parts = [CallPart(start: start, end: start + 1800, offset: 0)]
    r.markers = [TranscriptMarker(offset: 12, text: "★", isBookmark: true, note: "Budget")]
    r.cloudKey = "recordings/\(id)/recording.m4a"
    r.cloudSize = 2048
    r.cloudBackend = "server"
    r.cloudServer = "srv-1"
    r.cloudHash = String(repeating: "c", count: 64)
    r.cloudLeftovers = [ArchivedObject(key: "recordings/old.m4a", kind: .server, server: "srv-1")]
    r.transcriptionJobs = ["me": "job-1"]
    r.summaryMissing = true
    r.speakersExpected = 3
    r.muteSpans = [MuteSpan(start: 20, end: 30)]
    r.mutedAudioPending = true
    r.screens = [SharedScreen(offset: 12, file: "000012000.heic", text: "Budget by region")]
    r.screenGaps = [ScreenGap(offset: 20, paused: true)]
    r.source = "geminiNotes"
    r.gemini = GeminiNotesRef(docID: "doc-1", title: "Notes", url: nil, eventID: "evt-1", imported: start, notes: nil)
    r.personHint = PersonHint(name: "Sam Carter", personID: "p-sam")
    r.deletedScreens = ["000020000.heic"]
    r.moveTo = "5e6f7a8b"
    r.inviteUnknown = true
    r.inviteNotSure = true
    r.pauses = [PauseSpan(at: 600, from: start + 600, to: start + 660)]
    r.callMarks = [CallMark(at: 900, time: start + 960, link: "987654321", platform: .zoom, source: .tabs, sure: true)]
    r.cutFrom = "20261101-090000"
    r.firstTitleKey = "08786467415118f4"
    return r
}

/// A written meeting on disk, with the files a call folder can hold and one chat of it.
@discardableResult
func writtenCall(in paths: Paths, id: String = "20261101-100000") throws -> CallRecord {
    let fm = FileManager.default
    try paths.ensureDirectories()
    let dir = paths.callDirectory(id)
    try fm.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)
    let start = Date(timeIntervalSince1970: 1_793_520_000)
    var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: start, end: start + 1800, status: .written)
    r.customTitle = "Zebra budget"
    r.calendarTitle = "Weekly sync"
    r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
    r.unknownSpeakers = ["them:B"]
    for (i, key) in ["me:A", "them:A", "them:B"].enumerated() {
        r.speakerEmbeddings[key] = (0..<8).map { Float(($0 + i) % 8) / 8 }
    }
    r.speakerSamples = ["me:A": SpeakerSampleDetail(seconds: 30, quality: 0.8), "them:A": SpeakerSampleDetail(seconds: 30, quality: 0.8),
                        "them:B": SpeakerSampleDetail(seconds: 30, quality: 0.8)]
    r.utterances = (0..<6).map { (i: Int) -> Utterance in
        let track: Track = i % 2 == 0 ? .me : .them
        let label = i == 5 ? "B" : "A"
        let at = Double(i * 10)
        return Utterance(track: track, speakerLabel: label, start: at, end: at + 8, text: "the zebra crossing is closed")
    }
    r.summary = "Sam Carter and Speaker B agreed that the zebra crossing is closed."
    r.actionItems = [ActionItem(owner: "Speaker B", task: "Find another way")]
    r.screens = [SharedScreen(offset: 12, file: "000012000.heic", text: "A map")]
    let note = paths.meetings.appendingPathComponent("2026-11-01 1000 - Zebra budget.md")
    try Data("# Zebra budget\n".utf8).write(to: note)
    r.markdownPath = note.path
    try r.save(to: dir)
    for name in ["me.caf", "them.caf", "recording.m4a"] { try Data(repeating: 7, count: 4096).write(to: dir.appendingPathComponent(name)) }
    try Data(#"{"frames":[]}"#.utf8).write(to: dir.appendingPathComponent("frames.json"))
    try Data(repeating: 9, count: 512).write(to: dir.appendingPathComponent("frames/000012000.heic"))
    try r.save(to: dir, fileName: Pipeline.previousFileName)
    for name in ["coach.json", "findings.json", "live-points.json"] { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
    var chat = Chat(title: "Zebra budget")
    chat.callID = id
    var answer = ChatMessage(role: .assistant, text: "See [12:04](mossad://call/\(id)?t=724)")
    var request = ChatActionRequest(.addTask)
    request.text = "Find another way"
    answer.actions = [ChatActionRecord(request: request, state: .done, summary: "Task added: Find another way", date: start)]
    chat.messages = [ChatMessage(role: .user, text: "What did we decide?"), answer]
    try ChatStore(directory: paths.chats).save(chat)
    return r
}
