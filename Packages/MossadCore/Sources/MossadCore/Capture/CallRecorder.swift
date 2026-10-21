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
    public func begin(platform: Platform, bundleID: String, processIDs: [AudioObjectID], at start: Date) throws -> String {
        // Never delete a call here: close the previous one so it is processed like any other.
        if isRecording, let previous = record { _ = end(at: start, trimTo: nil); Log.info("Closed \(previous.id) for a new call") }
        let id = Self.callID(for: start)
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = CallRecord(id: id, platform: platform, bundleID: bundleID, start: start, end: start, status: .recording)
        try r.save(to: dir)
        let themWriter: TrackWriter, meWriter: TrackWriter
        do {
            themWriter = try TrackWriter(url: dir.appendingPathComponent(Track.them.fileName), startTime: start, clock: clock)
            meWriter = try TrackWriter(url: dir.appendingPathComponent(Track.me.fileName), startTime: start, clock: clock)
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
        guard isRecording else { return }
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
        guard isRecording else { return }
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
    public func end(at time: Date, trimTo: Date?) -> CallRecord? {
        guard var r = record else { return nil }
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

    /// Stops recording and deletes everything for the current call.
    public func skip() {
        guard let r = record else { return }
        stopAll()
        try? FileManager.default.removeItem(at: paths.callDirectory(r.id))
        Log.info("Skipped call \(r.id)")
    }

    private func stopAll() {
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
