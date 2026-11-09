#if os(macOS)
import Foundation

/// One call's capture of the shared screen, as the recorder sees it. Any thread.
public protocol ScreenCapturing: AnyObject {
    /// Starts, or starts again after a pause.
    func start()
    /// Stops for a pause. Nothing is captured until `start`.
    func stop()
    /// Stops for good. After it returns, nothing more is written to the call's folder.
    func close()
    /// Drops the frames after `length` seconds of the recording: the audio was cut there.
    func trim(to length: TimeInterval)
}

/// A picture as the source hands it over. It is valid only inside the callback.
public protocol FramePicture {
    var thumb: FrameThumb? { get }
    /// A copy that lives on after the callback, for the one frame that waits to be kept.
    func held() -> HeldPicture?
}

public protocol HeldPicture: AnyObject {
    /// Writes the picture as a HEIC file. False when the file could not be written.
    func write(to url: URL) -> Bool
}

public enum FrameEvent {
    /// A new picture of the meeting window; `window` names the window it came from.
    case picture(FramePicture, window: String)
    /// The window is there and shows the same picture.
    case idle
}

/// Pictures of the one meeting window, at a slow pace, on one low-priority queue. Never the audio queue.
public protocol FrameSource: AnyObject {
    func start(_ handler: @escaping (FrameEvent) -> Void)
    /// Returns at once; after it, the handler is not called for this start.
    func stop()
    /// Whether the meeting window is on screen now; nil when no meeting window is found.
    var windowOnScreen: Bool? { get }
}

/// Keeps the frames worth keeping of one call: `frames/<offset in ms>.heic` and `frames.json` in the call's folder.
/// The source calls in on its own queue; the recorder calls `start`, `stop`, `close`, and `trim` on the capture
/// queue. One lock orders them, and it is held while a picture is written, so `close` returns only after the last write.
public final class ScreenRecorder: ScreenCapturing, @unchecked Sendable {
    public static let pausedText = "Screen capture paused"
    public static let resumedText = "Screen capture resumed"
    /// The timer that notices a quiet window and a missing one.
    static let tickInterval: TimeInterval = 3
    static let queue = DispatchQueue(label: "com.dwebber.mossad.screen", qos: .utility, autoreleaseFrequency: .workItem)

    private let dir: URL
    private let source: FrameSource
    private let offset: @Sendable () -> TimeInterval
    private let addMarker: @Sendable (TimeInterval, String) -> Void
    /// Reads who shares from the call app. Slow, so it runs once for each new share session, off every capture path.
    private let presenter: (@Sendable () -> String?)?
    private let runPresenter: (@escaping @Sendable () -> Void) -> Void
    private let usesTimer: Bool

    private let lock = NSLock()
    private var selector: FrameSelector
    private var index = FrameIndex()
    private var held: (picture: HeldPicture, window: String)?
    private var liveness: ScreenLiveness?
    private var lastKept: (offset: TimeInterval, window: String?)?
    private var running = false
    private var closed = false
    private var timer: DispatchSourceTimer?

    public init(dir: URL, source: FrameSource, offset: @escaping @Sendable () -> TimeInterval,
                addMarker: @escaping @Sendable (TimeInterval, String) -> Void, presenter: (@Sendable () -> String?)? = nil,
                rules: FrameRules = FrameRules(), usesTimer: Bool = true,
                runPresenter: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        self.dir = dir
        self.source = source
        self.offset = offset
        self.addMarker = addMarker
        self.presenter = presenter
        self.runPresenter = runPresenter
        self.usesTimer = usesTimer
        selector = FrameSelector(rules: rules)
    }

    public func start() {
        let begin = lock.withLock { () -> Bool in
            guard !closed, !running else { return false }
            running = true
            let now = offset()
            if liveness == nil { liveness = ScreenLiveness(at: now) } else { liveness?.restart(at: now) }
            if usesTimer {
                let t = DispatchSource.makeTimerSource(queue: Self.queue)
                t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .seconds(1))
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
            return true
        }
        guard begin else { return }
        source.start { [weak self] event in self?.handle(event) }
    }

    public func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            guard running else { return false }
            running = false
            timer?.cancel()
            timer = nil
            // Nothing comes after the waiting picture, so it stayed.
            keep(selector.finish(at: offset()))
            held = nil
            return true
        }
        if wasRunning { source.stop() }
    }

    public func close() {
        stop()
        lock.withLock { closed = true }
    }

    public func trim(to length: TimeInterval) {
        lock.withLock {
            let cut = index.trim(to: length)
            guard !cut.isEmpty else { return }
            try? index.save(to: dir)
            for f in cut { try? FileManager.default.removeItem(at: index.url(of: f, in: dir)) }
        }
    }

    /// On the source's queue.
    func handle(_ event: FrameEvent) {
        var newSession: String?
        lock.withLock {
            guard running, !closed else { return }
            let now = offset()
            mark(liveness?.frame(at: now))
            switch event {
            case .idle:
                newSession = keep(selector.quiet(at: now))
            case .picture(let picture, let window):
                guard let thumb = picture.thumb else { return }
                let step = selector.frame(thumb, at: now)
                newSession = keep(step)
                if step.hold { held = picture.held().map { ($0, window) } }
            }
        }
        if let newSession { readPresenter(for: newSession) }
    }

    /// On the timer: a window that sends nothing shows the same picture, or is gone.
    func tick() {
        var newSession: String?
        lock.withLock {
            guard running, !closed else { return }
            let now = offset()
            newSession = keep(selector.quiet(at: now))
            mark(liveness?.check(at: now, windowOnScreen: source.windowOnScreen))
        }
        if let newSession { readPresenter(for: newSession) }
    }

    private func mark(_ change: ScreenLiveness.Change?) {
        switch change {
        case .paused(let at): addMarker(at, Self.pausedText)
        case .resumed(let at): addMarker(at, Self.resumedText)
        case nil: break
        }
    }

    /// Writes the held picture when the step says so. Returns the file's name when it starts a new share session.
    @discardableResult
    private func keep(_ step: FrameSelector.Step) -> String? {
        guard let time = step.keepHeldAt, let held else { return nil }
        self.held = nil
        var frame = FrameIndex.Frame(offset: time, file: FrameIndex.fileName(offset: time), window: held.window)
        let url = index.url(of: frame, in: dir)
        do { try FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true) } catch { return nil }
        guard held.picture.write(to: url) else { return nil }
        let isNew = ShareSession.startsNew(offset: time, window: held.window, after: lastKept)
        // The frames of one session share its presenter, once that is read.
        if !isNew { frame.presenter = index.frames.last?.presenter }
        index.insert(frame)
        lastKept = (time, held.window)
        do { try index.save(to: dir) } catch { Log.error("Saving the frames list failed: \(error)") }
        return isNew && presenter != nil ? frame.file : nil
    }

    private func readPresenter(for file: String) {
        guard let presenter else { return }
        runPresenter { [weak self] in
            guard let name = presenter(), let self else { return }
            self.lock.withLock {
                guard !self.closed, let at = self.index.frames.firstIndex(where: { $0.file == file }) else { return }
                // The session's first frame and the ones kept while the name was read.
                for i in at..<self.index.frames.count where self.index.frames[i].presenter == nil { self.index.frames[i].presenter = name }
                try? self.index.save(to: self.dir)
            }
        }
    }
}
#endif
