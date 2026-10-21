import AVFoundation
import CoreAudio
import Foundation

/// A live audio input that delivers buffers until stopped.
public protocol TrackSource: AnyObject {
    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
    /// Called when a running source stops by itself and could not restart.
    func onFailure(_ handler: @escaping () -> Void)
}

public extension TrackSource {
    func onFailure(_ handler: @escaping () -> Void) {}
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
public final class CallRecorder: @unchecked Sendable {
    private let paths: Paths
    private let makeThem: ([AudioObjectID]) -> TrackSource
    private let makeMe: () -> TrackSource
    private let clock: () -> Date
    private let systemAudioAllowed: () -> Bool
    public static let retryInterval: TimeInterval = 10

    private var record: CallRecord?
    private var themSource: TrackSource?
    private var meSource: TrackSource?
    private var themWriter: TrackWriter?
    private var meWriter: TrackWriter?
    private var themProcessIDs: [AudioObjectID] = []
    private var nextThemRetry = Date.distantPast
    private var nextMeRetry = Date.distantPast
    private var loggedNoSystemAudio = false
    public private(set) var isPaused = false
    private var pauseStart: (date: Date, offset: TimeInterval)?
    private var muteStart: (date: Date, offset: TimeInterval)?
    public var isMuted: Bool { muteStart != nil }
    /// Live loudness of each track, for the waveform. Constant objects, so the UI can read them from any thread.
    public let meMeter = LevelMeter()
    public let themMeter = LevelMeter()
    /// Each track's audio for the live transcript; the app sets the handlers.
    public let meSink = AudioSink()
    public let themSink = AudioSink()

    public init(paths: Paths, makeThem: @escaping ([AudioObjectID]) -> TrackSource, makeMe: @escaping () -> TrackSource,
                clock: @escaping () -> Date = Date.init, systemAudioAllowed: @escaping () -> Bool = { true }) {
        self.systemAudioAllowed = systemAudioAllowed
        self.paths = paths
        self.makeThem = makeThem
        self.makeMe = makeMe
        self.clock = clock
    }

    public var isRecording: Bool { record != nil }
    public var currentRecord: CallRecord? { record }

    static func callID(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    @discardableResult
    public func begin(platform: Platform, bundleID: String, processIDs: [AudioObjectID], meetingID: String? = nil, at start: Date) throws -> String {
        // Never delete a call here: close the previous one so it is processed like any other.
        if isRecording, let previous = record { _ = end(at: start, trimTo: nil); Log.info("Closed \(previous.id) for a new call") }
        let id = Self.callID(for: start)
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = CallRecord(id: id, platform: platform, bundleID: bundleID, start: start, end: start, status: .recording)
        r.meetingID = meetingID
        try r.save(to: dir)
        let themWriter: TrackWriter, meWriter: TrackWriter
        do {
            meMeter.reset()
            themMeter.reset()
            themWriter = try TrackWriter(url: dir.appendingPathComponent(Track.them.fileName), startTime: start, clock: clock, meter: themMeter, sink: themSink)
            meWriter = try TrackWriter(url: dir.appendingPathComponent(Track.me.fileName), startTime: start, clock: clock, meter: meMeter, sink: meSink)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        record = r
        self.themWriter = themWriter
        self.meWriter = meWriter
        // The mic first: it is fast, and a slow tap start must not cost David's first words.
        startMe()
        startThem(processIDs)
        Log.info("Recording \(id) (\(platform.displayName))")
        return id
    }

    /// Rebuilds the tap when the meeting app's audio processes change (for example a browser audio helper restarts).
    /// Runs on every detection tick during a call, so a source that failed to start is tried again.
    public func updateThemProcesses(_ ids: [AudioObjectID]) {
        guard isRecording, !isPaused else { return }
        let now = clock()
        if meSource == nil, now >= nextMeRetry { startMe() }
        let ids = ids.isEmpty ? themProcessIDs : ids
        if themSource == nil {
            if now >= nextThemRetry { startThem(ids) } else { themProcessIDs = ids }
        } else if !ids.isEmpty, Set(ids) != Set(themProcessIDs) {
            Log.info("Meeting audio processes changed; rebuilding tap")
            themSource?.stop()
            startThem(ids)
        }
    }

    /// Recreates the tap with the same processes, for example after the default output device changed.
    public func rebuildThem() {
        guard isRecording, !isPaused else { return }
        Log.info("Output device changed; rebuilding tap")
        themSource?.stop()
        startThem(themProcessIDs)
    }

    /// On failure the source stays nil, and the next tick tries again.
    private func startThem(_ ids: [AudioObjectID]) {
        guard let writer = themWriter else { return }
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
        do {
            try source.start { buffer in try? writer.append(buffer) }
            themSource = source
        } catch {
            source.stop()
            nextThemRetry = clock().addingTimeInterval(Self.retryInterval)
            Log.error("Meeting audio tap failed to start: \(error)")
        }
    }

    private func startMe() {
        guard let writer = meWriter else { return }
        let source = makeMe()
        source.onFailure { [weak self, weak source] in
            // Runs on the capture queue. Only the current source counts; the next tick restarts it.
            guard let self, let source, self.meSource === source else { return }
            source.stop()
            self.meSource = nil
            self.nextMeRetry = self.clock().addingTimeInterval(Self.retryInterval)
        }
        do {
            try source.start { buffer in try? writer.append(buffer) }
            meSource = source
        } catch {
            source.stop()
            nextMeRetry = clock().addingTimeInterval(Self.retryInterval)
            Log.error("Mic capture failed to start: \(error)")
        }
    }

    /// Stops recording. Returns the saved record, or nil when the call was shorter than the minimum and was deleted.
    public func end(at time: Date, trimTo: Date?, byPerson: Bool = false) -> CallRecord? {
        guard var r = record else { return nil }
        if let pause = pauseStart {
            r.markers.append(TranscriptMarker(offset: pause.offset, text: "Paused at \(Self.time(pause.date)); the recording ended while paused"))
        } else if byPerson {
            r.markers.append(TranscriptMarker(offset: recordedLength, text: "Recording stopped at \(Self.time(time))"))
        }
        if let mute = muteStart {
            r.markers.append(TranscriptMarker(offset: mute.offset, text: "Muted from \(Self.time(mute.date)) to the end of the recording"))
        }
        pauseStart = nil
        muteStart = nil
        // The app releasing the mic does not mean the call ended: keep any sound on either track after it.
        let lastSound = [themWriter?.lastSound, meWriter?.lastSound].compactMap { $0 }.max().map { r.start.addingTimeInterval($0 + 1) }
        stopAll()
        let dir = paths.callDirectory(r.id)
        let end = trimTo.map { min(time, max($0, lastSound ?? $0)) } ?? time
        guard end.timeIntervalSince(r.start) >= ProcessingQueue.minimumCallDuration else {
            try? FileManager.default.removeItem(at: dir)
            Log.info("Discarded short call \(r.id)")
            return nil
        }
        if trimTo != nil {
            for track in [Track.me, .them] {
                do { try trimAudioFile(dir.appendingPathComponent(track.fileName), to: end.timeIntervalSince(r.start)) } catch {
                    Log.error("Trim \(track.rawValue) failed: \(error)")
                }
            }
        }
        r.end = end
        r.status = .recorded
        do { try r.save(to: dir) } catch { Log.error("Saving \(r.id) failed: \(error)") }
        Log.info("Recorded \(r.id): \(Int(end.timeIntervalSince(r.start))) s")
        return r
    }

    /// Follows the call app's mute button: while muted, the mic track records silence.
    public func setMuted(_ muted: Bool) {
        guard isRecording, muted != isMuted else { return }
        meWriter?.isMuted = muted
        if muted {
            muteStart = (clock(), recordedLength)
            Log.info("Muted in the call; the mic track records silence")
        } else if let mute = muteStart {
            addMarker(at: mute.offset, "Muted from \(Self.time(mute.date)) to \(Self.time(clock())) (\(Self.length(clock().timeIntervalSince(mute.date))))")
            muteStart = nil
            Log.info("Unmuted in the call")
        }
    }

    /// Marks this moment as important. The summary gives it weight, and the player shows it.
    public func bookmark() {
        guard isRecording, !isPaused else { return }
        addMarker(at: recordedLength, "★ Bookmarked at \(Self.time(clock()))", isBookmark: true)
        Log.info("Bookmarked the call")
    }

    private func addMarker(at offset: TimeInterval, _ text: String, isBookmark: Bool = false) {
        guard var r = record else { return }
        r.markers.append(TranscriptMarker(offset: offset, text: text, isBookmark: isBookmark))
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
        themWriter?.pause()
        meWriter?.pause()
        themSource?.stop()
        meSource?.stop()
        themSource = nil
        meSource = nil
        Log.info("Recording paused")
    }

    public func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
        if let pause = pauseStart {
            addMarker(at: pause.offset, "Paused from \(Self.time(pause.date)) to \(Self.time(clock())) (\(Self.length(clock().timeIntervalSince(pause.date))))")
        }
        pauseStart = nil
        themWriter?.resume()
        meWriter?.resume()
        startMe()
        startThem(themProcessIDs)
        Log.info("Recording resumed")
    }

    /// Seconds recorded so far: the longer of the two tracks.
    private var recordedLength: TimeInterval { max(meWriter?.duration ?? 0, themWriter?.duration ?? 0) }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// The invite found while the call runs, so the live call already shows its real title.
    /// Ignored when that call has ended meanwhile; the pipeline matches the calendar again anyway.
    public func setCalendar(title: String, attendees: [String], forCall id: String) {
        guard var r = record, r.id == id else { return }
        r.calendarTitle = title
        r.attendees = attendees
        record = r
        do { try r.save(to: paths.callDirectory(r.id)) } catch { Log.error("Saving \(r.id) failed: \(error)") }
    }

    /// Stops recording and deletes everything for the current call.
    public func skip() {
        guard let r = record else { return }
        stopAll()
        try? FileManager.default.removeItem(at: paths.callDirectory(r.id))
        Log.info("Skipped call \(r.id)")
    }

    private func stopAll() {
        isPaused = false
        themSource?.stop()
        meSource?.stop()
        themWriter?.close()
        meWriter?.close()
        themSource = nil
        meSource = nil
        themWriter = nil
        meWriter = nil
        themProcessIDs = []
        nextThemRetry = .distantPast
        nextMeRetry = .distantPast
        loggedNoSystemAudio = false
        record = nil
    }
}
