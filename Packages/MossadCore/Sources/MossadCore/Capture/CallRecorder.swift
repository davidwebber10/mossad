#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import AVFoundation
import CoreAudio
import Foundation

/// A live audio input that sends buffers into a feed until stopped. After `stop` returns it sends nothing more.
public protocol TrackSource: AnyObject {
    func start(_ feed: AudioFeed) throws
    func stop()
    /// Called when a running source stops by itself and could not restart.
    func onFailure(_ handler: @escaping () -> Void)
    /// True when the source records all system audio, not only the call app's.
    var isGlobal: Bool { get }
}

public extension TrackSource {
    func onFailure(_ handler: @escaping () -> Void) {}
    var isGlobal: Bool { false }
}

/// The one serial queue for capture work: starting, stopping, and trimming can wait on Core Audio,
/// so none of it runs on the main thread. Every CallRecorder call and every source restart goes through it.
public enum CaptureQueue {
    public static let queue = DispatchQueue(label: "com.dwebber.mossad.capture", qos: .userInitiated)
    static let operations: OperationQueue = {
        let q = OperationQueue()
        q.underlyingQueue = queue
        return q
    }()
}

/// Records one call: the "them" tap and the "me" mic, each to its own file, plus `call.json`.
/// Everything runs on `CaptureQueue.queue`, except the members marked "any thread".
public final class CallRecorder: @unchecked Sendable {
    private let paths: Paths
    private let makeThem: ([AudioObjectID]) -> TrackSource
    private let makeMe: () -> TrackSource
    private let clock: () -> Date
    private let captureClock: CaptureClock
    private let systemAudioAllowed: () -> Bool
    private let micAllowed: () -> Bool
    private let freeBytes: () -> Int64?
    public static let retryInterval: TimeInterval = 10
    /// A source that sends nothing this long is restarted. It can start on a new device and stay silent; a tap sends
    /// buffers even when the call is quiet, so silence from it is never "nothing".
    public static let stallLimit: TimeInterval = 10
    /// After `CaptureHealth.stallRestartLimit` restarts in a row, a silent source is restarted this often.
    static let slowStallLimit: TimeInterval = 60
    /// A tap of all system audio is rebuilt this often, to get back to the call app's own audio.
    static let processTapRetryInterval: TimeInterval = 30
    /// The mute state comes from a poll, so an unmute is seen late. Without a later "still muted" report, the span
    /// ends this long before the unmute was seen: better some muted seconds kept than the owner's first words lost.
    public static let unmuteLead: TimeInterval = 3

    /// One track: its writer, and the feed that carries audio from the audio thread to it.
    private final class Line {
        let writer: TrackWriter
        let feed: AudioFeed
        var startedAt: TimeInterval = 0
        var stallRestarts = 0
        var rejectedLogged = 0
        init(writer: TrackWriter, clock: CaptureClock, label: String) {
            self.writer = writer
            feed = AudioFeed(label: label, clock: clock) { writer.ingest($0) }
        }
    }

    private var record: CallRecord?
    private var themSource: TrackSource?
    private var meSource: TrackSource?
    // The app reads the durations on the main thread, so the lines sit behind a lock.
    private let lineLock = NSLock()
    private var lines: (me: Line?, them: Line?) = (nil, nil)
    private var me: Line? { lineLock.withLock { lines.me } }
    private var them: Line? { lineLock.withLock { lines.them } }
    private var themProcessIDs: [AudioObjectID] = []
    private var nextThemRetry = Date.distantPast
    private var nextMeRetry = Date.distantPast
    private var nextProcessTapRetry = Date.distantPast
    private var themGlobalSince: Date?
    private var markedGlobal = false
    private var loggedNoSystemAudio = false
    public private(set) var isPaused = false
    private var pauseStart: (date: Date, offset: TimeInterval)?
    /// Wall time the finished pauses took: the files leave it out.
    private var pausedTotal: TimeInterval = 0
    private var muteStart: (date: Date, offset: TimeInterval)?
    private var lastSeenMuted: TimeInterval?
    public var isMuted: Bool { muteStart != nil }
    private var healthFrom = Date.distantPast
    private var nextHealthCheck = Date.distantPast
    private var told: Set<String> = []
    /// A problem that loses one side of the call, told once per call, on the capture queue. Set it before the first call.
    public var onProblem: (@Sendable (CaptureProblem, Platform) -> Void)?
    /// Live loudness of each track, for the waveform. Constant objects, so the UI can read them from any thread.
    public let meMeter = LevelMeter()
    public let themMeter = LevelMeter()
    /// Each track's audio for the live transcript; the app sets the handlers.
    public let meSink = AudioSink()
    public let themSink = AudioSink()

    public init(paths: Paths, makeThem: @escaping ([AudioObjectID]) -> TrackSource, makeMe: @escaping () -> TrackSource,
                clock: @escaping () -> Date = Date.init, captureClock: CaptureClock = .host,
                systemAudioAllowed: @escaping () -> Bool = { true }, micAllowed: @escaping () -> Bool = { true },
                freeBytes: (() -> Int64?)? = nil) {
        self.systemAudioAllowed = systemAudioAllowed
        self.micAllowed = micAllowed
        self.freeBytes = freeBytes ?? {
            (try? paths.audio.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        }
        self.paths = paths
        self.makeThem = makeThem
        self.makeMe = makeMe
        self.clock = clock
        self.captureClock = captureClock
    }

    public var isRecording: Bool { record != nil }
    /// Started by hand for an in-person meeting: detection neither ends it nor taps a call app for it.
    public private(set) var isManual = false

    /// Records the room through the mic until the person stops it.
    public func beginManual(at start: Date) throws -> String {
        let id = try begin(platform: .inPerson, bundleID: "", processIDs: [], at: start)
        isManual = true
        return id
    }
    public var currentRecord: CallRecord? { record }

    public static func callID(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// The ID has one-second resolution in local time, so the hour that repeats when daylight time ends (or a clock
    /// change) can give the ID of an older call. That call's folder is never reused.
    private func freeCallID(for date: Date) -> String {
        let base = Self.callID(for: date)
        var id = base, n = 2
        while FileManager.default.fileExists(atPath: paths.callDirectory(id).path) {
            id = "\(base)-\(n)"
            n += 1
        }
        if id != base { Log.error("A call \(base) exists already; this one is saved as \(id)") }
        return id
    }

    @discardableResult
    public func begin(platform: Platform, bundleID: String, processIDs: [AudioObjectID], meetingID: String? = nil, at start: Date) throws -> String {
        // Never delete a call here: close the previous one so it is processed like any other.
        // The detector sends a mute change only once, so a mute that is on carries over to the new call.
        let stillMuted = isRecording && isMuted
        if isRecording, let previous = record { _ = end(at: start, trimTo: nil); Log.info("Closed \(previous.id) for a new call") }
        let id = freeCallID(for: start)
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = CallRecord(id: id, platform: platform, bundleID: bundleID, start: start, end: start, status: .recording)
        r.meetingID = meetingID
        let themWriter: TrackWriter, meWriter: TrackWriter
        do {
            try r.save(to: dir)
            meMeter.reset()
            themMeter.reset()
            themWriter = try TrackWriter(url: dir.appendingPathComponent(Track.them.fileName), startTime: start, clock: clock,
                                         captureClock: captureClock, meter: themMeter, sink: themSink)
            meWriter = try TrackWriter(url: dir.appendingPathComponent(Track.me.fileName), startTime: start, clock: clock,
                                       captureClock: captureClock, meter: meMeter, sink: meSink)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        record = r
        let lines = (me: Line(writer: meWriter, clock: captureClock, label: "me"), them: Line(writer: themWriter, clock: captureClock, label: "them"))
        lineLock.withLock { self.lines = lines }
        pausedTotal = 0
        told = []
        healthFrom = clock()
        nextHealthCheck = .distantPast
        // The mic first: it is fast, and a slow tap start must not cost David's first words.
        startMe()
        // In a room there is no call app to tap; the them track stays empty.
        if platform != .inPerson { startThem(processIDs) }
        Log.info("Recording \(id) (\(platform.displayName))")
        if stillMuted { setMuted(true) }
        // A missing permission or a full disk is told now, not after the call.
        checkHealth(manual: platform == .inPerson)
        return id
    }

    /// Rebuilds the tap when the meeting app's audio processes change (for example a browser audio helper restarts).
    /// Runs on every detection tick during a call, so a source that failed to start, or sends nothing, is tried again.
    public func updateThemProcesses(_ ids: [AudioObjectID]) {
        guard isRecording, !isPaused, !isManual else { return }
        checkThem(ids)
        checkMic()
    }

    private func checkThem(_ ids: [AudioObjectID]) {
        guard let line = them else { return }
        let now = clock()
        let ids = ids.isEmpty ? themProcessIDs : ids
        guard let source = themSource else {
            if now >= nextThemRetry { startThem(ids) } else { themProcessIDs = ids }
            return
        }
        if !ids.isEmpty, Set(ids) != Set(themProcessIDs) {
            Log.info("Meeting audio processes changed; rebuilding tap")
            source.stop()
            startThem(ids)
        } else if isStalled(line) {
            line.stallRestarts += 1
            Log.error("The call audio tap sent no audio for \(Int(Self.stallLimit)) s; rebuilding it (\(line.stallRestarts) in a row)")
            source.stop()
            startThem(ids)
        } else if source.isGlobal, !ids.isEmpty, now >= nextProcessTapRetry {
            // A tap that fell back to all system audio must not stay for the call.
            Log.info("Recording all system audio; trying the call app's own audio again")
            source.stop()
            startThem(ids)
        }
        if themSource?.isGlobal == true, !markedGlobal, let since = themGlobalSince, now.timeIntervalSince(since) >= CaptureHealth.grace {
            markedGlobal = true
            Log.error("The call app's own audio cannot be tapped; the call track has all system audio")
            addMarker(at: recordedLength, "The call audio includes every sound the Mac played from \(Self.time(since))")
        }
    }

    /// True when the source sent nothing since it started, or for `stallLimit`. Audio since the start clears the count.
    private func isStalled(_ line: Line) -> Bool {
        let last = line.feed.lastPush ?? -.infinity
        if last > line.startedAt { line.stallRestarts = 0 }
        let limit = line.stallRestarts >= CaptureHealth.stallRestartLimit ? Self.slowStallLimit : Self.stallLimit
        return captureClock.now() - max(last, line.startedAt) > limit
    }

    /// Starts a mic that failed to start, restarts one that sent nothing for `stallLimit`, and checks the recording's
    /// health. Runs on each detection tick during a call, and on its own timer during an in-person recording.
    public func checkMic() {
        guard isRecording, !isPaused, let line = me else { return }
        if let source = meSource {
            if isStalled(line) {
                line.stallRestarts += 1
                Log.error("The mic sent no audio for \(Int(Self.stallLimit)) s; restarting it (\(line.stallRestarts) in a row)")
                source.stop()
                meSource = nil
                startMe()
            }
        } else if clock() >= nextMeRetry {
            startMe()
        }
        checkHealth(manual: isManual)
    }

    /// Recreates the tap with the same processes, for example after the default output device changed.
    public func rebuildThem() {
        guard isRecording, !isPaused, !isManual else { return }
        Log.info("Output device changed; rebuilding tap")
        themSource?.stop()
        startThem(themProcessIDs)
    }

    /// On failure the source stays nil, and the next tick tries again.
    private func startThem(_ ids: [AudioObjectID]) {
        guard let line = them else { return }
        themProcessIDs = ids
        themSource = nil
        // Without the permission, creating a tap can stall in Core Audio. Wait for the permission instead.
        guard systemAudioAllowed() else {
            if !loggedNoSystemAudio { Log.error("System Audio Recording is not allowed; the other side is not recorded") }
            loggedNoSystemAudio = true
            nextThemRetry = clock().addingTimeInterval(Self.retryInterval)
            return
        }
        let source = makeThem(ids)
        line.startedAt = captureClock.now()
        line.feed.beginSegment()
        do {
            try source.start(line.feed)
            themSource = source
            if source.isGlobal {
                if themGlobalSince == nil { themGlobalSince = clock() }
                nextProcessTapRetry = clock().addingTimeInterval(Self.processTapRetryInterval)
            } else {
                themGlobalSince = nil
            }
        } catch {
            source.stop()
            nextThemRetry = clock().addingTimeInterval(Self.retryInterval)
            Log.error("Meeting audio tap failed to start: \(error)")
        }
    }

    private func startMe() {
        guard let line = me else { return }
        let source = makeMe()
        source.onFailure { [weak self, weak source] in
            // Runs on the capture queue. Only the current source counts; the next tick restarts it.
            guard let self, let source, self.meSource === source else { return }
            source.stop()
            self.meSource = nil
            self.nextMeRetry = self.clock().addingTimeInterval(Self.retryInterval)
        }
        line.startedAt = captureClock.now()
        line.feed.beginSegment()
        do {
            try source.start(line.feed)
            meSource = source
        } catch {
            source.stop()
            nextMeRetry = clock().addingTimeInterval(Self.retryInterval)
            Log.error("Mic capture failed to start: \(error)")
        }
    }

    // MARK: Health

    /// Tells the owner, once per call and kind, when the recording loses one side of the call.
    private func checkHealth(manual: Bool) {
        guard let r = record, !isPaused, let me else { return }
        let now = clock()
        guard now >= nextHealthCheck else { return }
        nextHealthCheck = now.addingTimeInterval(5)
        for (line, name) in [(me, "mic"), (them, "call audio tap")] {
            guard let line, line.feed.rejected > line.rejectedLogged else { continue }
            line.rejectedLogged = line.feed.rejected
            Log.error("The \(name) sent \(line.rejectedLogged) buffers that Mossad could not read")
        }
        let problems = CaptureHealth.problems(
            elapsed: now.timeIntervalSince(healthFrom), micAllowed: micAllowed(), systemAudioAllowed: systemAudioAllowed(),
            freeBytes: freeBytes(), me: health(me, running: meSource != nil),
            them: manual ? nil : them.map { health($0, running: themSource != nil) })
        for problem in problems where told.insert(problem.kind).inserted {
            Log.error("\(problem.title). \(problem.message)")
            onProblem?(problem, r.platform)
        }
    }

    private func health(_ line: Line, running: Bool) -> TrackHealth {
        let errors = line.writer.writeErrors
        return TrackHealth(running: running, heardSignal: line.feed.hasHeardSignal, hasSound: line.writer.lastSound != nil,
                           writeErrors: errors.count, firstError: errors.first, stallRestarts: line.stallRestarts)
    }

    // MARK: End

    /// Ends the call when the app quits: runs `end` on the capture queue and waits for it, at most `timeout`.
    /// Call it from any thread but the capture queue. Nil when nothing was recording, the call was too short, or the
    /// wait timed out (the audio is on disk then, and the next launch recovers the call).
    @discardableResult
    public func endForQuit(at time: Date = Date(), timeout: TimeInterval = 5) -> CallRecord? {
        let result = QuitResult()
        let done = DispatchSemaphore(value: 0)
        CaptureQueue.queue.async {
            result.set(self.end(at: time, trimTo: nil, byPerson: true))
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            Log.error("The recording did not close within \(Int(timeout)) s; the next launch recovers it")
            return nil
        }
        return result.value
    }

    private final class QuitResult: @unchecked Sendable {
        private let lock = NSLock()
        private var record: CallRecord?
        var value: CallRecord? { lock.withLock { record } }
        func set(_ r: CallRecord?) { lock.withLock { record = r } }
    }

    /// Stops recording. Returns the saved record, or nil when the call was shorter than the minimum and was deleted.
    public func end(at time: Date, trimTo: Date?, byPerson: Bool = false) -> CallRecord? {
        guard var r = record else { return nil }
        if let pause = pauseStart {
            r.markers.append(TranscriptMarker(offset: pause.offset, text: "Paused at \(Self.time(pause.date)); the recording ended while paused"))
            pausedTotal += max(0, time.timeIntervalSince(pause.date))
        } else if byPerson {
            r.markers.append(TranscriptMarker(offset: recordedLength, text: "Recording stopped at \(Self.time(time))"))
        }
        if let mute = muteStart {
            r.markers.append(TranscriptMarker(offset: mute.offset, text: "Muted from \(Self.time(mute.date)) to the end of the recording"))
        }
        let paused = pausedTotal
        // Sources first, then what is still in the feeds, so the writers have every sample before they close.
        let (lastSound, meLength) = stopAll()
        let dir = paths.callDirectory(r.id)
        // File seconds from here on: the paused time is not in the files.
        let wallEnd = max(0, time.timeIntervalSince(r.start) - paused)
        var length = wallEnd
        if let trimTo {
            // The app releasing the mic does not mean the call ended: keep any sound on either track after it.
            let trim = max(0, trimTo.timeIntervalSince(r.start) - paused)
            length = min(wallEnd, max(trim, lastSound.map { $0 + 1 } ?? trim))
        }
        let end = r.start.addingTimeInterval(length + paused)
        guard end.timeIntervalSince(r.start) >= ProcessingQueue.minimumCallDuration else {
            try? FileManager.default.removeItem(at: dir)
            Log.info("Discarded short call \(r.id)")
            return nil
        }
        // A mute still on runs to the end of the mic track.
        if let open = r.muteSpans.indices.last, r.muteSpans[open].end == nil { r.muteSpans[open].end = max(meLength, r.muteSpans[open].start) }
        let muted = MuteSpan.ranges(r.muteSpans, length: meLength)
        for track in [Track.me, .them] {
            let silence = track == .me ? muted : []
            guard trimTo != nil || !silence.isEmpty else { continue }
            do { try rewriteAudioFile(dir.appendingPathComponent(track.fileName), keep: trimTo == nil ? nil : length, silence: silence) } catch {
                Log.error("Finishing \(track.rawValue) (trim, muted spans) failed: \(error)")
            }
        }
        r.end = end
        r.status = .recorded
        do { try r.save(to: dir) } catch { Log.error("Saving \(r.id) failed: \(error)") }
        Log.info("Recorded \(r.id): \(Int(end.timeIntervalSince(r.start))) s")
        return r
    }

    /// Follows the call app's mute button. The mic track keeps the real samples while the call runs, because the mute
    /// state is read by a poll and comes late; `end` writes silence over the muted spans. A span runs from the first
    /// "muted" to the last one: call this with true on each poll that still sees "muted", so the time between that
    /// poll and the unmute, which nobody saw, is kept.
    public func setMuted(_ muted: Bool) {
        guard isRecording, let line = me else { return }
        let position = line.writer.position
        if muted {
            guard muteStart == nil else {
                lastSeenMuted = position
                return
            }
            muteStart = (clock(), position)
            lastSeenMuted = nil
            line.writer.isMuted = true
            edit { $0.muteSpans.append(MuteSpan(start: position, end: nil)) }
            Log.info("Muted in the call; the muted time is silenced when the call ends")
        } else if let mute = muteStart {
            let end = lastSeenMuted ?? position - Self.unmuteLead
            let text = "Muted from \(Self.time(mute.date)) to \(Self.time(clock())) (\(Self.length(clock().timeIntervalSince(mute.date))))"
            muteStart = nil
            lastSeenMuted = nil
            line.writer.isMuted = false
            edit { r in
                if let open = r.muteSpans.indices.last, r.muteSpans[open].end == nil {
                    // A mute shorter than the unknown time silences nothing.
                    if end > r.muteSpans[open].start { r.muteSpans[open].end = end } else { r.muteSpans.remove(at: open) }
                }
                r.markers.append(TranscriptMarker(offset: mute.offset, text: text))
            }
            Log.info("Unmuted in the call")
        }
    }

    /// Marks this moment as important. The summary gives it weight, and the player shows it.
    /// Returns the bookmark's offset, so a note can be added to it, or nil when nothing was marked.
    @discardableResult
    public func bookmark() -> TimeInterval? {
        guard isRecording, !isPaused else { return nil }
        let offset = recordedLength
        addMarker(at: offset, "★ Bookmarked at \(Self.time(clock()))", isBookmark: true)
        Log.info("Bookmarked the call")
        return offset
    }

    /// Sets the note of the bookmark at `offset`; a blank note clears it and keeps the bookmark.
    /// Returns false when no call is being recorded, so the caller can edit the saved call instead.
    @discardableResult
    public func setBookmarkNote(at offset: TimeInterval, _ note: String) -> Bool {
        guard var r = record else { return false }
        guard r.setBookmarkNote(at: offset, note, markerText: "★ Bookmarked at \(Self.time(clock()))") else { return true }
        record = r
        do { try r.save(to: paths.callDirectory(r.id)) } catch { Log.error("Saving \(r.id) failed: \(error)") }
        return true
    }

    private func addMarker(at offset: TimeInterval, _ text: String, isBookmark: Bool = false) {
        edit { $0.markers.append(TranscriptMarker(offset: offset, text: text, isBookmark: isBookmark)) }
    }

    /// Changes the live record and saves it.
    private func edit(_ change: (inout CallRecord) -> Void) {
        guard var r = record else { return }
        change(&r)
        record = r
        do { try r.save(to: paths.callDirectory(r.id)) } catch { Log.error("Saving \(r.id) failed: \(error)") }
    }

    static func length(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
    }

    /// Stops both sources but keeps the files open. The paused time is left out of both tracks.
    public func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pauseStart = (clock(), recordedLength)
        themSource?.stop()
        meSource?.stop()
        themSource = nil
        meSource = nil
        // What the sources sent before the pause belongs in the files; a paused writer takes nothing.
        for line in [me, them] {
            line?.feed.flush()
            line?.writer.pause()
        }
        Log.info("Recording paused")
    }

    public func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
        if let pause = pauseStart {
            pausedTotal += max(0, clock().timeIntervalSince(pause.date))
            addMarker(at: pause.offset, "Paused from \(Self.time(pause.date)) to \(Self.time(clock())) (\(Self.length(clock().timeIntervalSince(pause.date))))")
        }
        pauseStart = nil
        them?.writer.resume()
        me?.writer.resume()
        // The sources get their start time again before a problem counts.
        healthFrom = clock()
        startMe()
        if !isManual { startThem(themProcessIDs) }
        Log.info("Recording resumed")
    }

    /// Seconds in the call track so far: where a new live session's audio starts in it. Any thread.
    public var themDuration: TimeInterval { them?.writer.duration ?? 0 }
    /// Seconds in the mic track so far: where a room recording's new live session starts in it. Any thread.
    public var meDuration: TimeInterval { me?.writer.duration ?? 0 }

    /// Where the recording is now, in file seconds. Both tracks share one timeline; the paused time is left out.
    private var recordedLength: TimeInterval { max(0, me?.writer.position ?? 0) }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// The invite found while the call runs, so the live call already shows its real title.
    /// Ignored when that call has ended meanwhile; the pipeline matches the calendar again anyway.
    public func setCalendar(title: String, attendees: [String], forCall id: String) {
        guard record?.id == id else { return }
        edit {
            $0.calendarTitle = title
            $0.attendees = attendees
        }
    }

    /// A provisional title from the live transcript. Ignored when that call has ended or already has a generated one.
    public func setGeneratedTitle(_ title: String, forCall id: String) {
        guard let r = record, r.id == id, r.generatedTitle == nil else { return }
        edit { $0.generatedTitle = title }
    }

    /// Stops recording and deletes everything for the current call.
    public func skip() {
        guard let r = record else { return }
        _ = stopAll()
        try? FileManager.default.removeItem(at: paths.callDirectory(r.id))
        Log.info("Skipped call \(r.id)")
    }

    /// Stops the sources, writes what the feeds still hold, and closes the files. Returns where the last sound on
    /// either track ended and the mic track's length, in file seconds.
    private func stopAll() -> (lastSound: TimeInterval?, meLength: TimeInterval) {
        themSource?.stop()
        meSource?.stop()
        let lines = lineLock.withLock {
            let current = self.lines
            self.lines = (nil, nil)
            return current
        }
        for (line, name) in [(lines.me, "mic"), (lines.them, "call audio")] {
            guard let line else { continue }
            line.feed.close()
            line.writer.close()
            if line.feed.dropped > 0 {
                Log.error("The \(name) track lost \(line.feed.dropped) frames: the disk was too slow for the recording")
            }
            let errors = line.writer.writeErrors
            if errors.count > 0 { Log.error("The \(name) track had \(errors.count) failed writes: \(errors.first ?? "")") }
        }
        let lastSound = [lines.them?.writer.lastSound, lines.me?.writer.lastSound].compactMap { $0 }.max()
        isPaused = false
        pauseStart = nil
        pausedTotal = 0
        muteStart = nil
        lastSeenMuted = nil
        themSource = nil
        meSource = nil
        themProcessIDs = []
        nextThemRetry = .distantPast
        nextMeRetry = .distantPast
        nextProcessTapRetry = .distantPast
        themGlobalSince = nil
        markedGlobal = false
        loggedNoSystemAudio = false
        record = nil
        isManual = false
        return (lastSound, lines.me?.writer.duration ?? 0)
    }
}
#endif
