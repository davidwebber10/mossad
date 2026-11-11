import XCTest
@testable import MossadCore

final class FakeTranscriber: Transcribing, @unchecked Sendable {
    var result: [Track: [Utterance]] = [:]
    var error: Error?
    var failingTracks: Set<Track> = []
    var delay: Duration = .zero
    private let lock = NSLock()
    private var _calls: [Track] = []
    var calls: [Track] { lock.withLock { _calls } }
    private var _speakers: [Track: Int] = [:]
    /// The speaker count each track was last sent with.
    var speakers: [Track: Int] { lock.withLock { _speakers } }
    func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        try await transcribe(file: file, track: track, speakers: nil, progress: progress)
    }
    func transcribe(file: URL, track: Track, speakers: Int?, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        lock.withLock { _calls.append(track); _speakers[track] = speakers }
        progress(.uploading(nil))
        progress(.uploading(0.5))
        progress(.transcribing)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        if failingTracks.contains(track) { throw Boom() }
        return result[track] ?? []
    }
}

final class FakeSummarizer: Summarizing, @unchecked Sendable {
    var fail = false
    var calls = 0
    var lastTranscript = ""
    var delayOnCall: [Int: Duration] = [:]
    var lastKnownTags: [String] = []
    var title: String?
    func summarize(transcript: String, title: String, knownTags: [String]) async throws -> MeetingSummary {
        lastKnownTags = knownTags
        calls += 1
        let call = calls
        lastTranscript = transcript
        if let delay = delayOnCall[call] { try await Task.sleep(for: delay) }
        if fail { throw SummaryError.malformed }
        return MeetingSummary(summary: "Summary \(call)", actionItems: [ActionItem(owner: "Alex Rivera", task: "send forecast")],
                              decisions: [Decision(text: "Decision \(call)", at: nil)], headline: "Headline \(call)", title: self.title)
    }
}

struct FakeCalendar: CalendarSource {
    var events: [CalendarEventInfo] = []
    func events(from: Date, to: Date) async -> [CalendarEventInfo] { events }
}

struct Boom: Error {}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
}

final class Notifications: @unchecked Sendable {
    var records: [CallRecord] = []
    var steps: [CallRecord] = []
    private let lock = NSLock()
    private var _details: [String] = []
    var details: [String] { lock.withLock { _details } }
    func detail(_ text: String?) { if let text { lock.withLock { _details.append(text) } } }
}

final class PipelineTests: XCTestCase {
    var paths: Paths!
    let transcriber = FakeTranscriber()
    let summarizer = FakeSummarizer()
    var library: VoiceLibrary!
    let notifications = Notifications()
    var notified: [CallRecord] { notifications.records }
    let start = localDate(2026, 10, 20, 14, 30)

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        library = VoiceLibrary(directory: paths.voices)
        transcriber.result = [
            .me: [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Where is the shipment?")],
            .them: [Utterance(track: .them, speakerLabel: "A", start: 11, end: 20, text: "It leaves Friday."),
                    Utterance(track: .them, speakerLabel: "B", start: 21, end: 28, text: "I can book freight.")],
        ]
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func makeRecord(meetingID: String? = nil) throws -> String {
        let id = "20261020-143000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 400), (21, 28, 800)])
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(1800), status: .recorded)
        r.meetingID = meetingID
        try r.save(to: dir)
        return id
    }

    func pipeline(calendar: FakeCalendar = FakeCalendar(), voiceFingerprints: Bool = true) -> Pipeline {
        let notifications = notifications
        let later = start.addingTimeInterval(3600)
        return Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                        calendar: calendar, summarizer: summarizer, notify: { notifications.records.append($0) },
                        now: { later }, ownerName: "Avery Lane", voiceFingerprints: voiceFingerprints,
                        onStep: { notifications.steps.append($0) }, onDetail: { _, text in notifications.detail(text) })
    }

    /// Back-to-back meetings: the encodes and the voice fingerprints of the last call wait while the next one records.
    func testProcessorHeavyStepsWaitWhileACallRecords() async throws {
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = true
            var recording: Bool {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }
        let call = Flag()
        let gate = HeavyWorkGate(pollInterval: .milliseconds(20)) { call.recording }
        let notifications = notifications
        let later = start.addingTimeInterval(3600)
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { later }, ownerName: "Avery Lane",
                         onDetail: { _, text in notifications.detail(text) }, heavy: gate)
        let run = Task { await p.process(id) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(transcriber.calls, [], "nothing is encoded or sent while the call records")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("upload-me.m4a").path))
        XCTAssertEqual(try CallRecord.load(from: dir).status, .recorded)
        XCTAssertTrue(notifications.details.contains("Waiting for the current call to end"))
        call.recording = false
        await run.value
        XCTAssertEqual(try CallRecord.load(from: dir).status, .written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path))
    }

    /// Back-to-back meetings: once the transcripts are back, the join of the two tracks and the voices run while the
    /// next call records, at the lowest priority, so the note does not wait for that call to end. The recording waits.
    func testTheJoinAndTheVoicesRunWhileACallRecords() async throws {
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        var r = try CallRecord.load(from: dir)
        r.meUtterances = transcriber.result[.me]
        r.themUtterances = transcriber.result[.them]
        try r.save(to: dir)
        let lines = LogLines()
        let gate = HeavyWorkGate(pollInterval: .seconds(3600), isCallRecording: { true }, log: { lines.add($0) })
        let notifications = notifications
        let later = start.addingTimeInterval(3600)
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { later }, ownerName: "Avery Lane",
                         onDetail: { _, text in notifications.detail(text) }, heavy: gate)
        await p.process(id)
        let done = try CallRecord.load(from: dir)
        XCTAssertEqual(done.status, .written)
        XCTAssertFalse(done.utterances.isEmpty)
        XCTAssertFalse(done.speakerNames.isEmpty || done.speakerEmbeddings.isEmpty)
        XCTAssertFalse(notifications.details.contains("Waiting for the current call to end"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: dir).path), "the recording encode waits")
        XCTAssertEqual(lines.all.filter { $0.hasPrefix("During a call:") }.count, 2, lines.all.joined(separator: "\n"))
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("During a call: joining the two tracks of \(id) took ") })
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("During a call: voice identification of \(id) took ") })
    }

    /// "Process now": one click and every step of that call runs while the next call records, the encodes too.
    func testProcessNowRunsEveryStepOfThatCallDuringACall() async throws {
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        let lines = LogLines()
        final class Waiting: @unchecked Sendable { let lock = NSLock(); var seen = false }
        let waiting = Waiting()
        let gate = HeavyWorkGate(pollInterval: .seconds(3600), isCallRecording: { true }, log: { lines.add($0) })
        let notifications = notifications
        let later = start.addingTimeInterval(3600)
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { later }, ownerName: "Avery Lane",
                         onDetail: { _, text in notifications.detail(text) },
                         onProgress: { _, p in if p?.waitsForCall == true { waiting.lock.withLock { waiting.seen = true } } }, heavy: gate)
        let run = Task { await p.process(id) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transcriber.calls, [], "the upload encode waits")
        XCTAssertEqual(gate.waiting, [id])
        XCTAssertTrue(waiting.lock.withLock { waiting.seen }, "the card knows the call waits")
        gate.release(id)
        await run.value
        XCTAssertEqual(try CallRecord.load(from: dir).status, .written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path), "the recording is made during the call")
        XCTAssertEqual(gate.waiting, [])
        XCTAssertFalse(gate.isReleased(id), "a written call leaves the list")
        let during = lines.all.filter { $0.hasPrefix("During a call:") }
        XCTAssertTrue(during.contains { $0.contains("the upload encode of \(id)") }, during.joined(separator: "\n"))
        XCTAssertTrue(during.contains { $0.contains("the recording encode of \(id)") }, during.joined(separator: "\n"))
    }

    /// Both tracks wait for their upload encode. After "Process now" the card shows the tracks again, not the old
    /// waiting line.
    func testTheWaitingLineGoesWhenTheStepGoesOn() async throws {
        let id = try makeRecord()
        final class Last: @unchecked Sendable { let lock = NSLock(); var progress: ProcessingProgress? }
        let last = Last()
        transcriber.delay = .milliseconds(600)
        let gate = HeavyWorkGate(pollInterval: .seconds(3600), isCallRecording: { true }, log: { _ in })
        let later = start.addingTimeInterval(3600)
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { later }, ownerName: "Avery Lane",
                         onProgress: { _, p in last.lock.withLock { last.progress = p } }, heavy: gate)
        let run = Task { await p.process(id) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(last.lock.withLock { last.progress?.detail }, "Waiting for the current call to end")
        gate.release(id)
        try await Task.sleep(for: .milliseconds(400))
        let now = last.lock.withLock { last.progress }
        XCTAssertEqual(now?.step, .transcribing)
        XCTAssertNil(now?.detail, "the track lines show again")
        XCTAssertEqual(now?.waitsForCall, false)
        await run.value
    }

    func testADeletedCallLeavesTheReleasedList() async throws {
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        var r = try CallRecord.load(from: dir)
        r.status = .failed
        try r.save(to: dir)
        let gate = HeavyWorkGate(isCallRecording: { true }, log: { _ in })
        gate.release(id)
        let later = start.addingTimeInterval(3600)
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { later }, heavy: gate)
        let deleted = await p.delete(callID: id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(gate.isReleased(id))
    }

    /// The note of the last call does not wait for the next call to end: only its recording does.
    func testANoteIsWrittenWhileACallRecordsAndItsRecordingIsMadeLater() async throws {
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var recording: Bool {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }
        let call = Flag()
        let gate = HeavyWorkGate(pollInterval: .milliseconds(20)) { call.recording }
        let later = start.addingTimeInterval(3600)
        // The next call starts when the summary is done.
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { later }, ownerName: "Avery Lane",
                         onStep: { if $0.status == .summarized { call.recording = true } }, heavy: gate)
        await p.process(id)
        XCTAssertEqual(try CallRecord.load(from: dir).status, .written)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: dir).path))
        XCTAssertEqual(Recording.missing(audioRoot: paths.audio).map(\.lastPathComponent), [id])
        Recording.backfill(audioRoot: paths.audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path))
        XCTAssertEqual(Recording.missing(audioRoot: paths.audio), [])
    }

    /// The encode of the recording takes seconds, and the owner can edit the call in that time. The note once kept
    /// the old title and the old file name, while the record had the new one.
    func testAnEditDuringTheRecordingEncodeIsInTheNoteAndInTheRecord() async throws {
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let p = pipeline()
        await p.setRecordingMaker { dir in
            started.signal()
            proceed.wait()
            Recording.makeIfMissing(in: dir)
        }
        let run = Task { await p.process(id) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                started.wait()
                c.resume()
            }
        }
        await p.setTitle(callID: id, "Budget review")
        await p.setTags(callID: id, ["Freight"])
        proceed.signal()
        await run.value
        let r = try CallRecord.load(from: dir)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.customTitle, "Budget review")
        XCTAssertEqual(r.tags, ["Freight"])
        let notes = try FileManager.default.contentsOfDirectory(atPath: paths.meetings.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(notes.count, 1, "one note, under the new name")
        XCTAssertTrue(notes[0].contains("Budget review"))
        XCTAssertEqual(r.markdownPath, paths.meetings.appendingPathComponent(notes[0]).path)
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("title: Budget review") || note.contains("title: \"Budget review\""), note.prefix(300).description)
        XCTAssertTrue(note.contains("Freight"))
        XCTAssertEqual(note, MarkdownWriter.render(r), "the note is the record's own content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: dir).path))
    }

    func testTheGateIsOpenWhenNothingSaysACallRecords() async {
        let gate = HeavyWorkGate()
        let held = await gate.isHeld
        XCTAssertFalse(held)
        let plan = await gate.waitForClearance(.recordingEncode, callID: "a")
        XCTAssertEqual(plan, .run)
    }

    /// A call held because its muted parts could not be silenced is tried again by the pipeline's regular run. The
    /// silence is written before anything is sent to transcription.
    func testAHeldCallIsSilencedAndThenProcessed() async throws {
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        var r = try CallRecord.load(from: dir)
        r.muteSpans = [MuteSpan(start: 2, end: 6)]
        MutedAudio.hold(&r)
        try r.save(to: dir)
        await pipeline().runPending()
        let done = try CallRecord.load(from: dir)
        XCTAssertEqual(done.status, .written)
        XCTAssertFalse(done.mutedAudioPending)
        XCTAssertNil(done.failureReason)
        XCTAssertEqual(try AudioSamples.read(dir.appendingPathComponent("me.caf"), from: 2, to: 6).map(abs).max(), 0)
        XCTAssertGreaterThan(try AudioSamples.read(dir.appendingPathComponent("me.caf"), from: 0, to: 1.9).map(abs).max() ?? 0, 0.1)
    }

    /// While the silence cannot be written, nothing is transcribed: not by the regular run and not by Retry.
    func testACallWithMutedPartsStillInItIsNeverTranscribed() async throws {
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        var r = try CallRecord.load(from: dir)
        r.muteSpans = [MuteSpan(start: 2, end: 6)]
        r.mutedAudioPending = true
        try r.save(to: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir.appendingPathComponent("me.caf").path)
        let p = pipeline()
        await p.process(id)
        await p.runPending()
        await p.retry(id)
        XCTAssertEqual(transcriber.calls, [])
        let held = try CallRecord.load(from: dir)
        XCTAssertEqual(held.status, .failed)
        XCTAssertEqual(held.failedStep, .recorded)
        XCTAssertEqual(held.failureReason, MutedAudio.failureReason)
        XCTAssertTrue(held.mutedAudioPending)
        XCTAssertEqual(held.attempts, 0, "waiting for the silence uses no attempts")
        // The disk has room again.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("me.caf").path)
        await p.runPending()
        XCTAssertEqual(try CallRecord.load(from: dir).status, .written)
    }

    func testAMicVoiceNamedLikeSomeoneOnTheCallIsTheirEcho() async throws {
        // Alex Rivera is known; his voice (400 Hz) is on the call audio and also leaks into the mic as me:B.
        // The owner barely speaks (only while the call audio plays), so the echo label has the most quiet-time
        // speech and the echo filter keeps it as the owner. Only its name gives it away.
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        transcriber.result[.me] = [
            Utterance(track: .me, speakerLabel: "A", start: 21, end: 22, text: "Okay."),
            Utterance(track: .me, speakerLabel: "B", start: 11, end: 20, text: "It leaves Friday."),
            Utterance(track: .me, speakerLabel: "B", start: 29, end: 32, text: "Right, it leaves Friday."),
        ]
        let id = try makeRecord()
        let dir = paths.callDirectory(id)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 34, [(21, 22, 200), (11, 20, 400), (29, 32, 400)])
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertFalse(r.utterances.contains { $0.speakerKey == "me:B" })
        XCTAssertNil(r.speakerNames["me:B"])
        XCTAssertEqual(r.speakerNames["them:A"], "Alex Rivera")
    }

    func testRegenerateSummaryWritesANewSummaryForAFinishedMeeting() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).summary, "Summary 1")
        await p.regenerateSummary(id)
        let r = try load(id)
        XCTAssertEqual(r.summary, "Summary 2")
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(transcriber.calls.count, 2, "no new transcription")
    }

    /// A transcript that came back wrong is made again from the audio, and the old one is kept for one undo.
    func testTranscribeAgainKeepsThePreviousOneAndUsesTheSpeakerCount() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertTrue(Pipeline.canTranscribeAgain(paths.callDirectory(id)))
        let started = await p.transcribeAgain(id, speakers: 4)
        XCTAssertTrue(started)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.summary, "Summary 2")
        XCTAssertEqual(transcriber.calls.count, 4, "both tracks again")
        // On a call the owner is on the mic, so the call audio holds the other three.
        XCTAssertEqual(transcriber.speakers[.them], 3)
        XCTAssertNil(transcriber.speakers[.me])
        XCTAssertTrue(Pipeline.hasPreviousTranscript(paths.callDirectory(id)))
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id), fileName: Pipeline.previousFileName).summary, "Summary 1")
    }

    func testTranscribeAgainInARoomSendsTheCountWithTheMic() async throws {
        let id = try makeRecord()
        var r = try load(id)
        r.platform = .inPerson
        try r.save(to: paths.callDirectory(id))
        let p = pipeline()
        await p.process(id)
        _ = await p.transcribeAgain(id, speakers: 12)
        XCTAssertEqual(transcriber.speakers[.me], 12)
    }

    func testRestorePreviousTranscriptBringsBackTheOldOne() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        _ = await p.transcribeAgain(id, speakers: nil)
        let restored = await p.restorePreviousTranscript(id)
        XCTAssertTrue(restored)
        let r = try load(id)
        XCTAssertEqual(r.summary, "Summary 1")
        XCTAssertEqual(r.status, .written)
        XCTAssertFalse(Pipeline.hasPreviousTranscript(paths.callDirectory(id)))
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("Summary 1"))
    }

    func testTranscribeAgainNeedsTheAudioTracks() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        let dir = paths.callDirectory(id)
        for t in [Track.me, .them] { try FileManager.default.removeItem(at: dir.appendingPathComponent(t.fileName)) }
        XCTAssertFalse(Pipeline.canTranscribeAgain(dir))
        let started = await p.transcribeAgain(id, speakers: 3)
        XCTAssertFalse(started)
        XCTAssertEqual(try load(id).summary, "Summary 1")
        XCTAssertFalse(Pipeline.hasPreviousTranscript(dir))
    }

    /// Naming a voice someone who is saved already, by name or by email, adds to that person.
    func testNamingAVoiceForASavedPersonUsesThatPerson() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        try library.setEmail("arivera@example.com", for: "Alex Rivera")
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        let keys = try load(id).unknownSpeakers
        XCTAssertGreaterThanOrEqual(keys.count, 1)
        await p.applyNames(callID: id, names: [keys[0]: "alex rivera"])
        XCTAssertEqual(try load(id).speakerNames[keys[0]], "Alex Rivera")
        if keys.count > 1 {
            await p.applyNames(callID: id, names: [keys[1]: "Al R"], emails: [keys[1]: "ARivera@example.com"])
            XCTAssertEqual(try load(id).speakerNames[keys[1]], "Alex Rivera")
        }
        XCTAssertEqual(library.profiles.filter { $0.name.lowercased().hasPrefix("al") }.map(\.name), ["Alex Rivera"])
    }

    func testSetTagsCleansThemAndRewritesTheNote() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.setTags(callID: id, ["Budget", " budget ", "", "Databricks"])
        let r = try load(id)
        XCTAssertEqual(r.tags, ["Budget", "Databricks"])
        let note = try String(contentsOfFile: XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("tags: [\"Budget\", \"Databricks\"]"))
    }

    func testABookmarkNoteIsEditedAddedAndClearedAfterTheCall() async throws {
        let id = try makeRecord()
        var r = try load(id)
        r.markers = [TranscriptMarker(offset: 52, text: "★ Bookmarked at 2:31 PM", isBookmark: true)]
        try r.save(to: paths.callDirectory(id))
        let p = pipeline()
        await p.process(id)
        await p.setBookmarkNote(callID: id, offset: 52.4, note: "Send Sam the plan")
        var markers = try load(id).markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].note, "Send Sam the plan")
        let note = try String(contentsOfFile: XCTUnwrap(try load(id).markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("(★ Bookmarked at 2:31 PM: Send Sam the plan)"), note)
        await p.setBookmarkNote(callID: id, offset: 600, note: "Decision on freight")
        markers = try load(id).markers
        XCTAssertEqual(markers.count, 2)
        XCTAssertTrue(markers[1].isBookmark)
        XCTAssertEqual(markers[1].offset, 600)
        XCTAssertEqual(markers[1].note, "Decision on freight")
        await p.setBookmarkNote(callID: id, offset: 52, note: "  ")
        markers = try load(id).markers
        XCTAssertEqual(markers.count, 2)
        XCTAssertNil(markers[0].note)
    }

    func testAddBookmarkAfterTheCallAddsOneWithoutANoteAndNotTwiceAtOneMoment() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        let added = await p.addBookmark(callID: id, offset: 90)
        XCTAssertTrue(added)
        var markers = try load(id).markers.filter(\.isBookmark)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].offset, 90)
        XCTAssertNil(markers[0].note)
        let again = await p.addBookmark(callID: id, offset: 90.6)
        XCTAssertFalse(again)
        markers = try load(id).markers.filter(\.isBookmark)
        XCTAssertEqual(markers.count, 1)
        await p.setBookmarkNote(callID: id, offset: 90, note: "Send Sam the plan")
        XCTAssertEqual(try load(id).markers.filter(\.isBookmark).first?.note, "Send Sam the plan")
    }

    func testOwnerEditsMadeWhileTheCallIsProcessingSurviveTheRun() async throws {
        let id = try makeRecord()
        var r = try load(id)
        r.markers = [TranscriptMarker(offset: 52, text: "★ Bookmarked at 2:31 PM", isBookmark: true)]
        try r.save(to: paths.callDirectory(id))
        summarizer.delayOnCall[1] = .milliseconds(500)
        let p = pipeline()
        let run = Task { await p.process(id) }
        try await Task.sleep(for: .milliseconds(200))
        await p.setBookmarkNote(callID: id, offset: 52, note: "Send Sam the plan")
        await p.setTitle(callID: id, "Dana and Sam sync")
        await p.setTags(callID: id, ["Freight"])
        await run.value
        let done = try load(id)
        XCTAssertEqual(done.status, .written)
        XCTAssertEqual(done.markers.first?.note, "Send Sam the plan")
        XCTAssertEqual(done.customTitle, "Dana and Sam sync")
        XCTAssertEqual(done.tags, ["Freight"])
        let note = try String(contentsOfFile: XCTUnwrap(done.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("Send Sam the plan"), note)
        XCTAssertTrue(note.contains("Dana and Sam sync"), note)
    }

    func testOwnerEditsSurviveAStepThatFails() async throws {
        let id = try makeRecord()
        var r = try load(id)
        r.markers = [TranscriptMarker(offset: 52, text: "★ Bookmarked at 2:31 PM", isBookmark: true)]
        try r.save(to: paths.callDirectory(id))
        transcriber.error = Boom()
        transcriber.delay = .milliseconds(400)
        let p = pipeline()
        let run = Task { await p.process(id) }
        try await Task.sleep(for: .milliseconds(150))
        await p.setBookmarkNote(callID: id, offset: 52, note: "Send Sam the plan")
        await p.setTitle(callID: id, "Dana and Sam sync")
        await run.value
        let failed = try load(id)
        XCTAssertEqual(failed.attempts, 1)
        XCTAssertEqual(failed.markers.first?.note, "Send Sam the plan")
        XCTAssertEqual(failed.customTitle, "Dana and Sam sync")
    }

    func testTheSummaryGetsTheBookmarkNotes() async throws {
        let id = try makeRecord()
        var r = try load(id)
        r.markers = [TranscriptMarker(offset: 52, text: "★ Bookmarked at 2:31 PM", isBookmark: true, note: "Check the Acme quote")]
        try r.save(to: paths.callDirectory(id))
        XCTAssertTrue(MarkdownWriter.transcript(r).contains("(★ Bookmarked at 2:31 PM: Check the Acme quote)"))
    }

    func testTheSummaryGetsTheTagsOfEarlierMeetings() async throws {
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        await p.setTags(callID: first, ["Freight"])
        await p.regenerateSummary(first)
        XCTAssertEqual(summarizer.lastKnownTags, ["Freight"])
    }

    func testBackfillIsQuietButANormalRunNotifies() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(notified.count, 1)
        XCTAssertFalse(try load(id).unknownSpeakers.isEmpty)
        var r = try load(id)
        r.summaryVersion = nil
        try r.save(to: paths.callDirectory(id))
        notifications.records = []
        let ok = await p.backfill(id)
        XCTAssertTrue(ok)
        XCTAssertTrue(notified.isEmpty)
        await p.regenerateSummary(id)
        XCTAssertEqual(notified.count, 1)
    }

    func testAnOverlappingProcessCallDoesNotMakeAQuietRunNotify() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.summaryVersion = nil
        try r.save(to: paths.callDirectory(id))
        notifications.records = []
        summarizer.delayOnCall = [2: .milliseconds(600)]
        let backfill = Task { await p.backfill(id) }
        while summarizer.calls < 2 { try await Task.sleep(for: .milliseconds(20)) }
        await p.process(id)
        _ = await backfill.value
        XCTAssertTrue(notified.isEmpty)
    }

    func testAFailedQuietSummaryPutsTheMeetingBackAsWritten() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.summaryVersion = nil
        try r.save(to: paths.callDirectory(id))
        summarizer.fail = true
        let ok = await p.backfill(id)
        XCTAssertFalse(ok)
        r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.summary, "Summary 1")
        XCTAssertNil(r.nextAttempt)
        XCTAssertNil(r.failureReason)
        XCTAssertEqual(r.attempts, 0)
    }

    func testBackfillKeepsTheCalendarTitleAndAttendees() async throws {
        let id = try makeRecord(meetingID: "abc-defg-hij")
        var r = try load(id)
        r.status = .identified
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 5, text: "Hello")]
        r.calendarTitle = "Kept title"
        r.attendees = ["Sam Park"]
        try r.save(to: paths.callDirectory(id))
        let other = FakeCalendar(events: [CalendarEventInfo(title: "Other", start: start, end: start.addingTimeInterval(1800),
                                                            attendees: ["Dana Lee"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)])
        let p = pipeline(calendar: other)
        await p.process(id)
        XCTAssertEqual(try load(id).calendarTitle, "Other")
        r = try load(id)
        r.calendarTitle = "Kept title"
        r.attendees = ["Sam Park"]
        r.summaryVersion = nil
        try r.save(to: paths.callDirectory(id))
        _ = await p.backfill(id)
        r = try load(id)
        XCTAssertEqual(r.calendarTitle, "Kept title")
        XCTAssertEqual(r.attendees, ["Sam Park"])
    }

    func testRestoreKeepsTheOwnersTitleTagsAndBookmarks() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        _ = await p.transcribeAgain(id, speakers: nil)
        var r = try load(id)
        r.customTitle = "Mine"
        r.tags = ["Freight"]
        r.tagsSetByOwner = true
        r.markers = [TranscriptMarker(offset: 12, text: "Bookmark", isBookmark: true, note: "Check")]
        try r.save(to: paths.callDirectory(id))
        let restored = await p.restorePreviousTranscript(id)
        XCTAssertTrue(restored)
        r = try load(id)
        XCTAssertEqual(r.customTitle, "Mine")
        XCTAssertEqual(r.tags, ["Freight"])
        XCTAssertEqual(r.tagsSetByOwner, true)
        XCTAssertEqual(r.markers.first?.note, "Check")
    }

    func testBackfillKeepsOwnerTagsAndTitleAndAddsAGeneratedTitle() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.setTags(callID: id, ["Mine"])
        await p.setTitle(callID: id, "My title")
        summarizer.title = "Generated"
        let ok = await p.backfill(id)
        XCTAssertTrue(ok)
        let r = try load(id)
        XCTAssertEqual(r.tags, ["Mine"])
        XCTAssertEqual(r.customTitle, "My title")
        XCTAssertEqual(r.generatedTitle, "Generated")
        XCTAssertEqual(r.status, .written)
    }

    /// Meetings from before the tagsSetByOwner flag keep their tags too.
    func testBackfillKeepsTagsOfAnOldMeetingAndReportsAFailure() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.tags = ["Freight"]
        r.tagsSetByOwner = nil
        r.summaryVersion = nil
        try r.save(to: paths.callDirectory(id))
        var ok = await p.backfill(id)
        XCTAssertTrue(ok)
        XCTAssertEqual(try load(id).tags, ["Freight"])
        XCTAssertEqual(try load(id).summaryVersion, SummaryBackfill.currentVersion)
        r = try load(id)
        r.summaryVersion = nil
        try r.save(to: paths.callDirectory(id))
        summarizer.fail = true
        ok = await p.backfill(id)
        XCTAssertFalse(ok)
    }

    /// A backfill that fails and is retried by the next backfill still keeps the old tags.
    func testBackfillRetryAfterAFailureKeepsTags() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.tags = ["Freight"]
        r.tagsSetByOwner = nil
        r.summaryVersion = nil
        try r.save(to: paths.callDirectory(id))
        summarizer.fail = true
        let ok = await p.backfill(id)
        XCTAssertFalse(ok)
        XCTAssertEqual(try load(id).status, .written)
        summarizer.fail = false
        let retried = await p.backfill(id)
        XCTAssertTrue(retried)
        let after = try load(id)
        XCTAssertEqual(after.status, .written)
        XCTAssertEqual(after.tags, ["Freight"])
    }

    /// The progress card gets every step in order, the upload percent, and nil when processing ends.
    func testProgressReportsEachStepAndTheUpload() async throws {
        let id = try makeRecord()
        let seen = Locked<[ProcessingProgress?]>([])
        let notifications = notifications
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: summarizer, notify: { notifications.records.append($0) },
                         ownerName: "Avery Lane", onProgress: { _, progress in seen.withLock { $0.append(progress) } })
        await p.process(id)
        let all = seen.withLock { $0 }
        XCTAssertEqual(all.compactMap { $0?.step }.reduce(into: [ProcessingStep]()) { if $0.last != $1 { $0.append($1) } },
                       [.transcribing, .identifying, .summarizing, .writing])
        XCTAssertTrue(all.contains { $0?.tracks[.me] == .uploading(0.5) })
        XCTAssertNil(all.last!)
    }

    func testDetailsDescribeEachSubStep() async throws {
        // Like the real service, the transcription takes a moment after its stage updates.
        transcriber.delay = .milliseconds(50)
        let id = try makeRecord()
        await pipeline().process(id)
        let details = notifications.details
        for expected in ["Uploading", "AssemblyAI is transcribing", "Joining the two tracks", "Identifying speakers",
                         "Finding the calendar invite", "Claude is writing the summary", "Writing the note"] {
            XCTAssertTrue(details.contains { $0.contains(expected) }, "missing \(expected) in \(details)")
        }
    }

    func testOnStepReportsEachSavedStep() async throws {
        let id = try makeRecord()
        await pipeline().process(id)
        let statuses = notifications.steps.map(\.status)
        XCTAssertEqual(statuses.filter { $0 != .recorded }, [.transcribed, .identified, .summarized, .written])
        XCTAssertEqual(notifications.steps.last, try load(id))
    }

    func testOnStepReportsAFailedAttempt() async throws {
        transcriber.error = Boom()
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertEqual(notifications.steps.last?.attempts, 1)
    }

    func testFailureReasonForAMissingKey() async throws {
        transcriber.error = MissingAPIKey(service: "AssemblyAI")
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertEqual(try load(id).failureReason, "AssemblyAI key missing")
    }

    func testFailureReasonIsSetAndClearedOnSuccess() async throws {
        transcriber.error = TranscriptionError.http(401, "Unauthorized")
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).failureReason, "invalid API key")
        transcriber.error = nil
        await p.retry(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertNil(r.failureReason)
    }

    func testFailureReasonText() {
        XCTAssertEqual(Pipeline.failureReason(MissingAPIKey(service: "Anthropic")), "Anthropic key missing")
        XCTAssertEqual(Pipeline.failureReason(SummaryError.http(401, "x")), "invalid API key")
        XCTAssertEqual(Pipeline.failureReason(TranscriptionError.http(500, "x")), "AssemblyAI error 500")
        XCTAssertEqual(Pipeline.failureReason(SummaryError.http(529, "x")), "Anthropic error 529")
        XCTAssertEqual(Pipeline.failureReason(SummaryError.refused), "Claude refused to summarize this transcript")
        XCTAssertEqual(Pipeline.failureReason(URLError(.notConnectedToInternet)), "no network connection")
        XCTAssertEqual(Pipeline.failureReason(Boom()), "unexpected error")
    }

    func testWithoutVoiceFingerprintsNoVoiceIsStoredOrMatched() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        let id = try makeRecord()
        await pipeline(voiceFingerprints: false).process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.speakerNames, ["me:A": "Avery Lane"])
        XCTAssertEqual(r.speakerEmbeddings, [:])
        XCTAssertEqual(library.profiles.map(\.name), ["Alex Rivera"])
        XCTAssertTrue(notified.isEmpty)
    }

    func load(_ id: String) throws -> CallRecord { try CallRecord.load(from: paths.callDirectory(id)) }

    func testDropsAMicVoiceHeardOnlyWhileTheCallAudioPlays() async throws {
        // The them track (from makeRecord) has sound at 11–20 s and 21–28 s.
        transcriber.result[.me]!.append(Utterance(track: .me, speakerLabel: "B", start: 22, end: 23, text: "Yeah."))
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertFalse(try load(id).utterances.contains { $0.track == .me && $0.speakerLabel == "B" })
    }

    func testRenamePersonUpdatesEveryMeetingAndItsNote() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.speakerNames["them:A"] = "jo@example.com"
        r.actionItems = [ActionItem(owner: "jo@example.com", task: "send the forecast")]
        r.summary = "jo@example.com will send the forecast."
        try r.save(to: paths.callDirectory(id))

        let changed = await p.renamePerson("jo@example.com", to: "Jo Lee")
        XCTAssertEqual(changed, 1)
        r = try load(id)
        XCTAssertEqual(r.speakerNames["them:A"], "Jo Lee")
        XCTAssertEqual(r.actionItems.first?.owner, "Jo Lee")
        XCTAssertEqual(r.summary, "Jo Lee will send the forecast.")
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("Jo Lee"))
        XCTAssertFalse(note.contains("jo@example.com"))
    }

    func testRenamePersonLeavesOtherTextAloneForPlainNames() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.speakerNames["them:A"] = "Jo"
        r.summary = "Jo said Joe would call."
        try r.save(to: paths.callDirectory(id))
        await p.renamePerson("Jo", to: "Jo Lee")
        r = try load(id)
        XCTAssertEqual(r.speakerNames["them:A"], "Jo Lee")
        XCTAssertEqual(r.summary, "Jo said Joe would call.", "a short name can be part of other words")
    }

    func testSkipRemovesTheVoiceFromTheNameRequest() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).unknownSpeakers, ["them:A", "them:B"])
        await p.dismissSpeakers(callID: id, keys: ["them:B"])
        XCTAssertEqual(try load(id).unknownSpeakers, ["them:A"])
        XCTAssertEqual(try load(id).skippedSpeakers, ["them:B"])
    }

    func testTheLiveTranscriptIsRemovedOnceTheFullOneStarts() async throws {
        let id = try makeRecord()
        let live = paths.callDirectory(id).appendingPathComponent(LiveTranscript.fileName)
        try LiveTranscript().save(to: live)
        await pipeline().process(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    func testASkippedVoiceCanBeAskedForAgainOrNamed() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.dismissSpeakers(callID: id, keys: ["them:A", "them:B"])
        await p.restoreSpeakers(callID: id, keys: ["them:B"])
        XCTAssertEqual(try load(id).unknownSpeakers, ["them:B"])
        XCTAssertEqual(try load(id).skippedSpeakers, ["them:A"])
        await p.applyNames(callID: id, names: ["them:A": "Jo"])
        XCTAssertEqual(try load(id).skippedSpeakers, [])
    }

    /// A second written recording of the same meeting, `gap` seconds after the first one ended.
    func makeSecondPart(after firstID: String, gap: TimeInterval, meetingID: String?) throws -> String {
        let first = try load(firstID)
        let start = first.end.addingTimeInterval(gap)
        let id = "20261020-153000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 20, [(0, 8, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 20, [(9, 18, 400)])
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(20), status: .recorded)
        r.meetingID = meetingID
        try r.save(to: dir)
        return id
    }

    func testMergeJoinsMeetingsIntoTheEarliestOne() async throws {
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 600, meetingID: nil)
        await p.process(second)
        let firstNote = try XCTUnwrap(try load(first).markdownPath)
        let secondNote = try XCTUnwrap(try load(second).markdownPath)

        let merged = await p.merge(callIDs: [second, first])

        XCTAssertEqual(merged, first)
        let r = try load(first)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.parts.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(second).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondNote))
        XCTAssertEqual(try audioDuration(paths.callDirectory(first).appendingPathComponent("me.caf")), 50, accuracy: 0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory(first)).path))
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertEqual(r.markdownPath, firstNote)
        XCTAssertTrue(note.contains("Joined with a recording from"), note)
    }

    /// A call held back because its muted parts could not be silenced must not be joined: the joined audio would
    /// carry the muted speech into the recording, the archive, and a later transcription.
    func testMergeRefusesACallWhoseMutedPartsAreNotSilencedYet() async throws {
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 600, meetingID: nil)
        await p.process(second)
        var held = try load(second)
        held.mutedAudioPending = true
        try held.save(to: paths.callDirectory(second))

        let merged = await p.merge(callIDs: [first, second])

        XCTAssertNil(merged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory(second).path))
    }

    func testARecordingSplitByARestartContinuesOnItsOwn() async throws {
        let first = try makeRecord(meetingID: "abc-defg-hij")
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 3, meetingID: "abc-defg-hij")
        await p.process(second)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(second).path))
        let r = try load(first)
        XCTAssertEqual(r.parts.count, 2)
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("Recording resumed at"), note)
    }

    func testDifferentMeetingsAreNotJoinedOnTheirOwn() async throws {
        let first = try makeRecord(meetingID: "abc-defg-hij")
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 3, meetingID: "xyz-wxyz-xyz")
        await p.process(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory(second).path))
    }

    func testWritingTheNoteAlsoMakesTheRecording() async throws {
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory(id)).path))
    }

    func testDeleteRemovesTheNoteAndTheAudio() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        let note = try XCTUnwrap(try load(id).markdownPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note))
        let deleted = await p.delete(callID: id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(id).path))
    }

    func testDeleteRefusesACallThatIsStillInProgress() async throws {
        let id = try makeRecord()
        let deleted = await pipeline().delete(callID: id)
        XCTAssertFalse(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory(id).path))
    }

    func testCalendarMatchUsesTheCallsMeetingID() async throws {
        let id = try makeRecord(meetingID: "abc-defg-hij")
        func event(_ title: String, _ code: String) -> CalendarEventInfo {
            CalendarEventInfo(title: title, start: start, end: start.addingTimeInterval(1800), attendees: [],
                              text: "https://meet.google.com/\(code)", isAllDay: false)
        }
        await pipeline(calendar: FakeCalendar(events: [event("Other meeting", "xyz-wxyz-xyz")])).process(id)
        XCTAssertNil(try load(id).calendarTitle)
    }

    func testSetTitleRenamesTheNoteAndKeepsOneFile() async throws {
        let id = try makeRecord()
        summarizer.title = "Freight model review"
        let p = pipeline()
        await p.process(id)
        let first = try XCTUnwrap(try load(id).markdownPath)
        XCTAssertTrue(first.hasSuffix("Freight model review.md"))
        await p.setTitle(callID: id, "Dana and Sam sync")
        let r = try load(id)
        XCTAssertEqual(r.customTitle, "Dana and Sam sync")
        XCTAssertEqual(r.title, "Dana and Sam sync")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(r.markdownPath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.meetings.path).count, 1)
        await p.setTitle(callID: id, "  ")
        let cleared = try load(id)
        XCTAssertNil(cleared.customTitle)
        XCTAssertEqual(cleared.title, "Freight model review")
        XCTAssertTrue(try XCTUnwrap(cleared.markdownPath).hasSuffix("Freight model review.md"))
    }

    func testANewSummaryNeverReplacesACustomTitleOrClearsAGeneratedOne() async throws {
        let id = try makeRecord()
        summarizer.title = "First title"
        let p = pipeline()
        await p.process(id)
        await p.setTitle(callID: id, "Mine")
        summarizer.title = "Second title"
        await p.regenerateSummary(id)
        var r = try load(id)
        XCTAssertEqual(r.customTitle, "Mine")
        XCTAssertEqual(r.generatedTitle, "Second title")
        summarizer.title = nil
        await p.regenerateSummary(id)
        r = try load(id)
        XCTAssertEqual(r.generatedTitle, "Second title")
    }

    func testHappyPathWritesMarkdownAndNotifiesUnknowns() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        let id = try makeRecord()
        let calendar = FakeCalendar(events: [CalendarEventInfo(title: "Weekly Ops Sync", start: start, end: start.addingTimeInterval(1800),
                                                               attendees: ["Alex Rivera", "Amy Lee"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)])
        await pipeline(calendar: calendar).process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.speakerNames["me:A"], "Avery Lane")
        XCTAssertEqual(r.speakerNames["them:A"], "Alex Rivera")
        XCTAssertEqual(r.unknownSpeakers, ["them:B"])
        XCTAssertEqual(r.calendarTitle, "Weekly Ops Sync")
        XCTAssertEqual(r.summary, "Summary 1")
        XCTAssertEqual(r.actionItems, [ActionItem(owner: "Alex Rivera", task: "send forecast")])
        XCTAssertEqual(r.decisions.map(\.text), ["Decision 1"])
        XCTAssertEqual(r.headline, "Headline 1")
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(md.contains("[00:00:11] Alex Rivera: It leaves Friday."))
        XCTAssertTrue(md.contains("Speaker A: I can book freight."))
        XCTAssertTrue(r.markdownPath!.hasPrefix(paths.meetings.path))
        XCTAssertEqual(notified.map(\.id), [id])
        XCTAssertTrue(summarizer.lastTranscript.contains("Alex Rivera: It leaves Friday."))
    }

    func testNoNotificationWhenAllSpeakersKnown() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        try library.add([0, 0, 0, 1], to: "Amy Lee")
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertEqual(try load(id).status, .written)
        XCTAssertTrue(notified.isEmpty)
    }

    func testTranscriptionFailureKeepsAudioAndRetries() async throws {
        transcriber.error = Boom()
        let id = try makeRecord()
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .recorded)
        XCTAssertEqual(r.attempts, 1)
        XCTAssertNotNil(r.nextAttempt)
        for f in ["me.caf", "them.caf"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory(id).appendingPathComponent(f).path))
        }
        XCTAssertTrue(notified.isEmpty)
    }

    func testSummaryFailureStillWritesTranscript() async throws {
        summarizer.fail = true
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).status, .identified)
        await p.process(id)
        XCTAssertEqual(try load(id).status, .identified)
        await p.process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertNil(r.summary)
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertFalse(md.contains("## Summary"))
        XCTAssertTrue(md.contains("## Transcript"))
    }

    func testRunPendingProcessesDueRecords() async throws {
        let id = try makeRecord()
        await pipeline().runPending()
        XCTAssertEqual(try load(id).status, .written)
    }

    func testApplyNamesRewritesFileAndLearnsVoices() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).unknownSpeakers, ["them:A", "them:B"])
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"])
        let r = try load(id)
        XCTAssertEqual(r.unknownSpeakers, [])
        XCTAssertEqual(r.summary, "Summary 2")
        XCTAssertEqual(r.decisions.map(\.text), ["Decision 2"])
        XCTAssertEqual(r.headline, "Headline 2")
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(md.contains("Amy Lee: I can book freight."))
        XCTAssertEqual(library.bestMatch([0, 0, 0, 1])?.name, "Amy Lee")
        XCTAssertEqual(library.bestMatch([0, 1, 0, 0])?.name, "Alex Rivera")
    }

    func testNamingReplacesSpeakerLettersAtOnceBeforeTheNewSummary() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        let letters = MarkdownWriter.displayNames(r)
        let a = try XCTUnwrap(letters["them:A"]), b = try XCTUnwrap(letters["them:B"])
        r.summary = "\(a) and \(b) agreed. \(a)'s plan stands."
        r.topics = [SummaryTopic(title: "Freight", summary: "\(b) books it.")]
        r.decisions = [Decision(text: "\(a) owns freight", at: 12)]
        r.actionItems = [ActionItem(owner: a, task: "book freight"), ActionItem(owner: nil, task: "ask \(b) for dates")]
        try r.save(to: paths.callDirectory(id))
        summarizer.delayOnCall[2] = .milliseconds(400)
        let naming = Task { await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"]) }
        try await Task.sleep(for: .milliseconds(150))
        let early = try load(id)
        XCTAssertEqual(early.summary, "Alex Rivera and Amy Lee agreed. Alex Rivera's plan stands.")
        XCTAssertEqual(early.topics.first?.summary, "Amy Lee books it.")
        XCTAssertEqual(early.decisions, [Decision(text: "Alex Rivera owns freight", at: 12)])
        XCTAssertEqual(early.actionItems.map(\.owner), ["Alex Rivera", nil])
        XCTAssertEqual(early.actionItems.last?.task, "ask Amy Lee for dates")
        await naming.value
        XCTAssertEqual(try load(id).summary, "Summary 2")
    }

    func testApplyNamesStoresEmailsOnTheProfiles() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"],
                           emails: ["them:A": " alex@example.com ", "them:B": ""])
        XCTAssertEqual(library.name(forEmail: "ALEX@example.com"), "Alex Rivera")
        XCTAssertEqual(library.profiles.first { $0.name == "Amy Lee" }?.email, nil)
    }

    func testApplyNamesStoresAnEmailWithoutAVoice() async throws {
        let id = try makeRecord()
        let p = pipeline(voiceFingerprints: false)
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:B": "Amy Lee"], emails: ["them:B": "amy@example.com"])
        XCTAssertEqual(library.name(forEmail: "amy@example.com"), "Amy Lee")
        XCTAssertEqual(try load(id).speakerNames["them:B"], "Amy Lee")
    }

    func testOverlappingNameSavesKeepBothNames() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        summarizer.delayOnCall[2] = .milliseconds(300)
        async let first: Void = p.applyNames(callID: id, names: ["them:A": "Alex Rivera"])
        try await Task.sleep(for: .milliseconds(50))
        await p.applyNames(callID: id, names: ["them:B": "Amy Lee"])
        _ = await first
        let r = try load(id)
        XCTAssertEqual(r.speakerNames["them:A"], "Alex Rivera")
        XCTAssertEqual(r.speakerNames["them:B"], "Amy Lee")
        XCTAssertEqual(r.summary, "Summary 3")
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(md.contains("Alex Rivera: It leaves Friday.") && md.contains("Amy Lee: I can book freight."))
    }

    func testUnreadableTrackIsAFailureNotAnEmptyTrack() async throws {
        let id = try makeRecord()
        try Data(repeating: 7, count: 4096).write(to: paths.callDirectory(id).appendingPathComponent("me.caf"))
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertEqual(r.status, .recorded)
        XCTAssertEqual(r.attempts, 1)
    }

    func testMissingKeyDoesNotUseUpAttempts() async throws {
        transcriber.error = MissingAPIKey(service: "AssemblyAI")
        let id = try makeRecord()
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertEqual(r.attempts, 0)
        // Tried again at the next run (launch or hourly), with no backoff delay.
        XCTAssertEqual(ProcessingQueue(paths: paths).pending(now: start).map(\.id), [id])
    }

    func testConcurrentProcessOfOneCallRunsOnce() async throws {
        transcriber.delay = .milliseconds(200)
        let id = try makeRecord()
        let p = pipeline()
        async let a: Void = p.process(id)
        async let b: Void = p.process(id)
        _ = await (a, b)
        XCTAssertEqual(transcriber.calls.count, 2)
        XCTAssertEqual(notified.count, 1)
    }

    func testCompletedTrackIsNotTranscribedAgain() async throws {
        transcriber.failingTracks = [.me]
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).status, .recorded)
        transcriber.failingTracks = []
        await p.process(id)
        XCTAssertEqual(try load(id).status, .written)
        XCTAssertEqual(transcriber.calls.filter { $0 == .them }.count, 1)
        XCTAssertEqual(transcriber.calls.filter { $0 == .me }.count, 2)
    }

    func testNearEmptyTrackIsNotUploaded() async throws {
        let id = try makeRecord()
        try writeSegments(paths.callDirectory(id).appendingPathComponent("me.caf"), total: 0.5, [])
        await pipeline().process(id)
        XCTAssertEqual(transcriber.calls, [.them])
        XCTAssertEqual(try load(id).status, .written)
    }

    func testGivesUpAfterMaxAttemptsAndRetryResumes() async throws {
        transcriber.error = Boom()
        let id = try makeRecord()
        let p = pipeline()
        for _ in 0..<Pipeline.maxAttempts { await p.process(id) }
        var r = try load(id)
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(r.failedStep, .recorded)
        XCTAssertTrue(ProcessingQueue(paths: paths).pending(now: .distantFuture).isEmpty)
        transcriber.error = nil
        await p.retry(id)
        r = try load(id)
        XCTAssertEqual(r.status, .written)
    }
}
