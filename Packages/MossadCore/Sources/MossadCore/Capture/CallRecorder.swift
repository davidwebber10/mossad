import AVFoundation
import CoreAudio
import Foundation

/// A live audio input that delivers buffers until stopped.
public protocol TrackSource: AnyObject {
    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Records one call: the "them" tap and the "me" mic, each to its own file, plus `call.json`.
public final class CallRecorder: @unchecked Sendable {
    private let paths: Paths
    private let makeThem: ([AudioObjectID]) -> TrackSource
    private let makeMe: () -> TrackSource
    private let clock: () -> Date

    private var record: CallRecord?
    private var themSource: TrackSource?
    private var meSource: TrackSource?
    private var themWriter: TrackWriter?
    private var meWriter: TrackWriter?
    private var themProcessIDs: Set<AudioObjectID> = []

    public init(paths: Paths, makeThem: @escaping ([AudioObjectID]) -> TrackSource, makeMe: @escaping () -> TrackSource,
                clock: @escaping () -> Date = Date.init) {
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
        if isRecording { skip() }
        let id = Self.callID(for: start)
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = CallRecord(id: id, platform: platform, bundleID: bundleID, start: start, end: start, status: .recording)
        try r.save(to: dir)
        record = r

        let themWriter = try TrackWriter(url: dir.appendingPathComponent(Track.them.fileName), startTime: start, clock: clock)
        let meWriter = try TrackWriter(url: dir.appendingPathComponent(Track.me.fileName), startTime: start, clock: clock)
        self.themWriter = themWriter
        self.meWriter = meWriter
        startThem(processIDs)
        let me = makeMe()
        meSource = me
        do {
            try me.start { buffer in try? meWriter.append(buffer) }
        } catch {
            Log.error("Mic capture failed to start: \(error)")
        }
        Log.info("Recording \(id) (\(platform.displayName))")
        return id
    }

    /// Rebuilds the tap when the meeting app's audio processes change (for example a browser audio helper restarts).
    public func updateThemProcesses(_ ids: [AudioObjectID]) {
        guard isRecording, !ids.isEmpty, Set(ids) != themProcessIDs else { return }
        Log.info("Meeting audio processes changed; rebuilding tap")
        themSource?.stop()
        startThem(ids)
    }

    private func startThem(_ ids: [AudioObjectID]) {
        guard let writer = themWriter else { return }
        themProcessIDs = Set(ids)
        let source = makeThem(ids)
        themSource = source
        do {
            try source.start { buffer in try? writer.append(buffer) }
        } catch {
            Log.error("Meeting audio tap failed to start: \(error)")
        }
    }

    /// Stops recording. Returns the saved record, or nil when the call was shorter than the minimum and was deleted.
    public func end(at time: Date, trimTo: Date?) -> CallRecord? {
        guard var r = record else { return nil }
        stopAll()
        let dir = paths.callDirectory(r.id)
        let end = trimTo ?? time
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
        record = nil
    }
}
