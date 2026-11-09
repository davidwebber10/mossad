import AVFoundation
import XCTest
@testable import MossadCore

/// A clock a test can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// Keeps the job the pipeline hands it, like a batch service, and can wait for the test.
final class JobTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var _resumed: [Track: String] = [:]
    private var _hold = true
    var resumed: [Track: String] { lock.withLock { _resumed } }
    func release() { lock.withLock { _hold = false } }

    func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        let jobs = TranscriptionJob.store
        if let saved = jobs?.saved { lock.withLock { _resumed[track] = saved } } else { await jobs?.save("job-\(track.rawValue)") }
        while lock.withLock({ _hold }) { try await Task.sleep(for: .milliseconds(10)) }
        return [Utterance(track: track, speakerLabel: "A", start: 0, end: 5, text: "Hello from \(track.rawValue).")]
    }
}

extension PipelineTests {
    func pipeline(clock: TestClock, calendar: FakeCalendar = FakeCalendar(), discarded: Notifications? = nil) -> Pipeline {
        let notifications = notifications
        return Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                        calendar: calendar, summarizer: summarizer, notify: { notifications.records.append($0) },
                        now: { clock.now }, ownerName: "David Webber",
                        onStep: { notifications.steps.append($0) }, onDetail: { _, text in notifications.detail(text) },
                        onDiscard: { discarded?.records.append($0) })
    }

    // MARK: One pipeline for the life of the app

    func testNewSettingsReachThePipelineWithoutANewOne() async throws {
        transcriber.error = Boom()
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        XCTAssertEqual(try load(id).status, .recorded)

        let good = FakeTranscriber()
        good.result = transcriber.result
        p.configure(Pipeline.Configuration(transcriber: good, summarizer: summarizer, ownerName: "David Webber"))
        await p.retry(id)
        XCTAssertEqual(try load(id).status, .written)
        XCTAssertEqual(good.calls.count, 2)
    }

    /// The owner leaves Settings while a call is transcribed, then the hourly run starts: one transcription only.
    func testACallInFlightIsNotProcessedAgainAfterASettingsChange() async throws {
        transcriber.delay = .milliseconds(200)
        let id = try makeRecord()
        let p = pipeline()
        let first = Task { await p.process(id) }
        while transcriber.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        p.configure(Pipeline.Configuration(transcriber: transcriber, summarizer: summarizer, ownerName: "David Webber"))
        await p.runPending()
        await first.value
        XCTAssertEqual(transcriber.calls.count, 2, "each track one time")
        XCTAssertEqual(summarizer.calls, 1)
        XCTAssertEqual(try load(id).status, .written)
    }

    // MARK: Transcription jobs

    func testTheTranscriptionJobIsSavedAndARestartPollsTheSameJob() async throws {
        let id = try makeRecord()
        let slow = JobTranscriber()
        let first = Pipeline(paths: paths, transcriber: slow, library: library, embeddings: ToneEmbeddingProvider(),
                             calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in })
        let run = Task { await first.process(id) }
        while (try? load(id).transcriptionJobs)??.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try load(id).transcriptionJobs, ["me": "job-me", "them": "job-them"])
        run.cancel()
        await run.value

        // The app quit during the wait. A new pipeline reads the jobs from the record.
        let again = JobTranscriber()
        again.release()
        let second = Pipeline(paths: paths, transcriber: again, library: library, embeddings: ToneEmbeddingProvider(),
                              calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in })
        await second.process(id)
        XCTAssertEqual(again.resumed, [.me: "job-me", .them: "job-them"])
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertNil(r.transcriptionJobs)
    }

    // MARK: Summary that failed

    func testAMeetingWrittenWithoutItsSummarySaysSoAndGetsItLater() async throws {
        let clock = TestClock(start.addingTimeInterval(3600))
        summarizer.fail = true
        let id = try makeRecord()
        let p = pipeline(clock: clock)
        for _ in 1...3 { await p.process(id) }
        var r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.summaryMissing, true)
        XCTAssertNotNil(r.failureReason)

        // The provider works again, but a day has not passed.
        summarizer.fail = false
        await p.runPending()
        XCTAssertNil(try load(id).summary)

        clock.advance(86_400 + 60)
        await p.runPending()
        r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertNotNil(r.summary)
        XCTAssertNil(r.summaryMissing)
        XCTAssertNil(r.failureReason)
        XCTAssertTrue(try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8).contains("## Summary"))
    }

    func testAMissingSummaryIsTriedOnlyOnceADayWhileTheProviderStillFails() async throws {
        let clock = TestClock(start.addingTimeInterval(3600))
        summarizer.fail = true
        let id = try makeRecord()
        let p = pipeline(clock: clock)
        for _ in 1...3 { await p.process(id) }
        let after = summarizer.calls
        clock.advance(86_400 + 60)
        await p.runPending()
        await p.runPending()
        XCTAssertEqual(summarizer.calls, after + 1)
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.summaryMissing, true)
    }

    /// A refused key is not the call's fault and is not billed: wait, do not count attempts.
    func testARefusedKeyWaitsWithoutUsingAttempts() async throws {
        final class Refusing: Summarizing, @unchecked Sendable {
            func summarize(transcript: String, title: String, knownTags: [String]) async throws -> MeetingSummary {
                throw SummaryError.http(401, "invalid x-api-key")
            }
        }
        let id = try makeRecord()
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: Refusing(), notify: { _ in })
        for _ in 1...5 { await p.process(id) }
        let r = try load(id)
        XCTAssertEqual(r.status, .identified)
        XCTAssertEqual(r.attempts, 0)
        XCTAssertNotNil(r.failureReason)
    }

    // MARK: Quiet runs and owner edits

    func testAQuietRunThatAQuitInterruptedStaysQuiet() async throws {
        let id = try makeRecord()
        await pipeline().process(id)
        notifications.records = []
        var r = try load(id)
        XCTAssertNil(r.calendarTitle)
        // What a quit during the quiet backfill leaves: the record from before, and the meeting in the summary step.
        try r.save(to: paths.callDirectory(id), fileName: Pipeline.quietFileName)
        r.status = .identified
        try r.save(to: paths.callDirectory(id))

        let event = CalendarEventInfo(title: "Another title", start: start, end: start.addingTimeInterval(1800), attendees: ["Sam Carter"], text: "", isAllDay: false)
        await pipeline(calendar: FakeCalendar(events: [event])).runPending()
        r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertNil(r.calendarTitle, "no new calendar match")
        XCTAssertTrue(notified.isEmpty, "no notification")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(id).appendingPathComponent(Pipeline.quietFileName).path))
    }

    func testSkippedVoicesAndARenameMadeDuringTheSummaryStay() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        summarizer.delayOnCall[1] = .milliseconds(300)
        let id = try makeRecord()
        let p = pipeline()
        let run = Task { await p.process(id) }
        while summarizer.calls < 1 { try await Task.sleep(for: .milliseconds(10)) }
        await p.dismissSpeakers(callID: id, keys: ["them:B"])
        await p.renamePerson("Alex Rivera", to: "Alex R. Rivera")
        await run.value
        let r = try load(id)
        XCTAssertEqual(r.status, .written)
        XCTAssertFalse(r.unknownSpeakers.contains("them:B"))
        XCTAssertEqual(r.speakerNames["them:A"], "Alex R. Rivera")
        XCTAssertTrue(try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8).contains("Alex R. Rivera"))
    }

    func testTheArchiveKeySetDuringARunStays() async throws {
        summarizer.delayOnCall[2] = .milliseconds(300)
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        let run = Task { await p.regenerateSummary(id) }
        while summarizer.calls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let saved = await p.setCloudKey(callID: id, key: "calls/\(id)/recording.m4a", size: 42)
        XCTAssertTrue(saved)
        await run.value
        let r = try load(id)
        XCTAssertEqual(r.summary, "Summary 2")
        XCTAssertEqual(r.cloudKey, "calls/\(id)/recording.m4a")
        XCTAssertEqual(r.cloudSize, 42)
    }

    // MARK: Merge

    /// Sound in a part of an audio file, as its largest sample.
    private func peak(_ url: URL, from: Double, to: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(from * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount((to - from) * rate))!
        try file.read(into: buffer)
        return (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
    }

    func testAMergeWithAPartThatHasNoRecordingMakesTheRecordingFromTheTracks() async throws {
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        // The second call failed: it has its tracks and no recording.
        let second = try makeSecondPart(after: first, gap: 600, meetingID: nil)
        var failed = try load(second)
        failed.status = .failed
        failed.failedStep = .recorded
        try failed.save(to: paths.callDirectory(second))

        let merged = await p.merge(callIDs: [first, second])
        XCTAssertEqual(merged, first)
        let recording = Recording.url(in: paths.callDirectory(first))
        XCTAssertEqual(try audioDuration(recording), 50, accuracy: 0.5)
        XCTAssertGreaterThan(try peak(recording, from: 31, to: 37), 0.01, "the second part has sound, not silence")
    }

    func testAMergedMeetingIsNotMarkedAsArchivedAndItsPartsAreHandedBack() async throws {
        let discarded = Notifications()
        let clock = TestClock(start.addingTimeInterval(7200))
        let first = try makeRecord()
        let p = pipeline(clock: clock, discarded: discarded)
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 600, meetingID: nil)
        await p.process(second)
        await p.setCloudKey(callID: first, key: "calls/\(first)/recording.m4a", size: 10)
        await p.setCloudKey(callID: second, key: "calls/\(second)/recording.m4a", size: 10)

        await p.merge(callIDs: [first, second])
        let r = try load(first)
        XCTAssertNil(r.cloudKey, "the joined recording is a new file")
        XCTAssertEqual(discarded.records.map(\.id), [second])
        XCTAssertEqual(discarded.records.first?.cloudKey, "calls/\(second)/recording.m4a", "so its bucket object can go")
    }

    func testAMergeIsRefusedWhenAPartsAudioIsOnlyInTheArchive() async throws {
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 600, meetingID: nil)
        await p.process(second)
        await p.setCloudKey(callID: second, key: "calls/\(second)/recording.m4a", size: 10)
        for name in ["me.caf", "them.caf", Recording.fileName] {
            try FileManager.default.removeItem(at: paths.callDirectory(second).appendingPathComponent(name))
        }
        let merged = await p.merge(callIDs: [first, second])
        XCTAssertNil(merged)
        XCTAssertEqual(try load(second).status, .written)
        XCTAssertEqual(try load(first).parts.count, 0)
    }

    /// A crash after the tracks were replaced and before the merged record was saved: the next run undoes the
    /// merge, so the parts are not joined a second time.
    func testAMergeStoppedBeforeItsRecordWasSavedIsUndone() async throws {
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 3, meetingID: nil)
        await p.process(second)
        let dir = paths.callDirectory(first), fm = FileManager.default
        let before = try load(first)
        for name in ["me.caf", "them.caf"] {
            try fm.moveItem(at: dir.appendingPathComponent(name), to: dir.appendingPathComponent("premerge-" + name))
            try writeSegments(dir.appendingPathComponent(name), total: 50, [(0, 10, 200)])
        }
        try writeSegments(dir.appendingPathComponent("joined-recording.m4a"), total: 1, [])
        try Pipeline.MergePlan(ids: [first, second], phase: .replacing, had: ["me.caf", "them.caf", Recording.fileName]).save(in: dir)

        await pipeline().runPending()

        XCTAssertEqual(try audioDuration(dir.appendingPathComponent("me.caf")), 30, accuracy: 0.1)
        XCTAssertEqual(try audioDuration(dir.appendingPathComponent("them.caf")), 30, accuracy: 0.1)
        XCTAssertEqual(try load(first), before)
        XCTAssertEqual(try load(second).status, .written, "the second meeting is whole")
        let left = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("premerge-") || $0.hasPrefix("joined-") || $0 == "merge.json" }
        XCTAssertEqual(left, [])
    }

    /// A crash after the merged record was saved: the next run finishes, and the part does not stay as a second meeting.
    func testAMergeStoppedAfterItsRecordWasSavedIsFinished() async throws {
        let discarded = Notifications()
        let first = try makeRecord()
        let p = pipeline()
        await p.process(first)
        let second = try makeSecondPart(after: first, gap: 3, meetingID: nil)
        await p.process(second)
        let secondNote = try XCTUnwrap(try load(second).markdownPath)
        let dir = paths.callDirectory(first), fm = FileManager.default
        var merged = MeetingMerge.combine([try load(first), try load(second)], durations: [first: 30, second: 20])
        merged.status = .identified
        try merged.save(to: dir, fileName: Pipeline.MergePlan.recordFile)
        try fm.copyItem(at: dir.appendingPathComponent("me.caf"), to: dir.appendingPathComponent("premerge-me.caf"))
        try Pipeline.MergePlan(ids: [first, second], phase: .saved, had: ["me.caf", "them.caf", Recording.fileName]).save(in: dir)

        await pipeline(clock: TestClock(start.addingTimeInterval(7200)), discarded: discarded).runPending()

        let r = try load(first)
        XCTAssertEqual(r.parts.count, 2)
        XCTAssertEqual(r.status, .written, "the joined meeting got its summary and note")
        XCTAssertFalse(fm.fileExists(atPath: paths.callDirectory(second).path))
        XCTAssertFalse(fm.fileExists(atPath: secondNote))
        XCTAssertEqual(discarded.records.map(\.id), [second])
        let left = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("premerge-") || $0 == "merge.json" || $0 == "call.merged.json" }
        XCTAssertEqual(left, [])
    }

    // MARK: Review fixes

    /// A failed call kept its job. "Transcribe again" with a speaker count must start its own job.
    func testTranscribeAgainDoesNotResumeAJobFromBefore() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        var r = try load(id)
        r.transcriptionJobs = ["me": "old-me", "them": "old-them"]
        try r.save(to: paths.callDirectory(id))
        let jobs = JobTranscriber()
        jobs.release()
        p.configure(Pipeline.Configuration(transcriber: jobs, summarizer: summarizer, ownerName: "David Webber"))
        await p.transcribeAgain(id, speakers: 3)
        XCTAssertEqual(jobs.resumed, [:], "no old job was resumed")
        XCTAssertEqual(try load(id).status, .written)
    }

    func testDeleteGivesBackTheRecordAsItWasOnDisk() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.setCloudKey(callID: id, key: "calls/\(id)/recording.m4a", size: 10)
        let removed = await p.remove(callID: id)
        XCTAssertEqual(removed?.cloudKey, "calls/\(id)/recording.m4a")
        let again = await p.remove(callID: id)
        XCTAssertNil(again)
    }
}
