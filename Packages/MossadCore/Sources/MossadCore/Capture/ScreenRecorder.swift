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
    /// The window stopped being the meeting's (it closed, or it shows something else now).
    case lost
}

/// Pictures of the one meeting window, at a slow pace, on one low-priority queue. Never the audio queue.
public protocol FrameSource: AnyObject {
    func start(_ handler: @escaping (FrameEvent) -> Void)
    /// Returns at once; after it, the handler is not called for this start.
    func stop()
    /// How the meeting window can be seen now; nil when no meeting window is found.
    var windowSight: WindowSight? { get }
}

/// Keeps the frames worth keeping of one call: `frames/<offset in ms>.heic` and `frames.json` in the call's folder.
/// The source calls in on its own queue; the recorder calls `start`, `stop`, `close`, and `trim` on the capture
/// queue. One lock orders them, and it is held while a picture is written, so `close` returns only after the last write.
public final class ScreenRecorder: ScreenCapturing, @unchecked Sendable {
    /// The timer that notices a quiet window and a missing one.
    static let tickInterval: TimeInterval = 3
    /// While frames are kept, the presenter is read again this often, so a second presenter is not given the first one's name.
    static let presenterInterval: TimeInterval = 60
    static let queue = DispatchQueue(label: "com.dwebber.mossad.screen", qos: .utility, autoreleaseFrequency: .workItem)

    private let dir: URL
    private let source: FrameSource
    private let offset: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    /// The owner's setting. Turned off in a call, the capture ends at the next frame or tick.
    private let isEnabled: @Sendable () -> Bool
    /// Reads who shares from the call app's share indicator. Slow, so it runs off every capture path, at the start
    /// of a share session and then once a minute while frames are kept.
    private let presenter: (@Sendable () -> PresenterRead)?
    private let runPresenter: (@escaping @Sendable () -> Void) -> Void
    private let usesTimer: Bool

    private let lock = NSLock()
    private var selector: FrameSelector
    private var index = FrameIndex()
    private var held: (picture: HeldPicture, window: String, offset: TimeInterval, time: Date)?
    private var liveness: ScreenLiveness?
    private var session = -1
    private var sessionWindow: String?
    /// Set by a pause of the capture: the next kept frame starts a new share session.
    private var sessionEnded = true
    private var presenterAsked: TimeInterval = -.infinity
    /// The session's first read gave no answer: the next read is still the session's own, not a change of presenter.
    private var presenterOpen = false
    /// A covered window with no new picture is a pause, but it ends the share session only after this long.
    static let coverEndsSession: TimeInterval = 300
    private var coverPaused = false
    private var lastPicture: (at: TimeInterval, window: String)?
    private var running = false
    private var closed = false
    private var timer: DispatchSourceTimer?

    public init(dir: URL, source: FrameSource, offset: @escaping @Sendable () -> TimeInterval,
                now: @escaping @Sendable () -> Date = Date.init, isEnabled: @escaping @Sendable () -> Bool = { true },
                presenter: (@Sendable () -> PresenterRead)? = nil, rules: FrameRules = FrameRules(), usesTimer: Bool = true,
                runPresenter: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        self.dir = dir
        self.source = source
        self.offset = offset
        self.now = now
        self.isEnabled = isEnabled
        self.presenter = presenter
        self.runPresenter = runPresenter
        self.usesTimer = usesTimer
        selector = FrameSelector(rules: rules)
    }

    public func start() {
        let begin = lock.withLock { () -> Bool in
            guard !closed, !running, isEnabled() else { return false }
            running = true
            let at = offset()
            if liveness == nil { liveness = ScreenLiveness(at: at) } else { liveness?.restart(at: at) }
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
        if halt(forGood: false) { source.stop() }
    }

    public func close() {
        if halt(forGood: true) { source.stop() }
    }

    /// Under the lock: ends the running capture. Returns whether the source must be stopped.
    private func halt(forGood: Bool) -> Bool {
        lock.withLock { haltLocked(forGood: forGood) }
    }

    private func haltLocked(forGood: Bool, keepWaiting: Bool = true) -> Bool {
        if forGood { closed = true }
        guard running else { return false }
        running = false
        timer?.cancel()
        timer = nil
        // Nothing comes after the waiting picture, so it stayed. Not when the owner turned the capture off: the
        // newest picture is the one the owner wanted to stop.
        let last = selector.finish(at: offset())
        if keepWaiting { keep(last) } else if last.keepHeldAt != nil { selector.keepFailed() }
        held = nil
        // The owner's pause ends the share session too.
        sessionEnded = true
        return true
    }

    public func trim(to length: TimeInterval) {
        lock.withLock {
            let cut = index.trim(to: length)
            let gaps = index.gaps?.filter { $0.offset <= length }
            guard !cut.isEmpty || gaps != index.gaps else { return }
            index.gaps = gaps
            try? index.save(to: dir)
            for f in cut { try? FileManager.default.removeItem(at: index.url(of: f, in: dir)) }
        }
    }

    /// The setting was turned off: stop now, not at the end of the call. What was kept until now stays.
    private func endIfTurnedOff() -> Bool {
        guard !isEnabled() else { return false }
        Log.info("Capture shared screens was turned off; the screen capture of this call ends")
        return haltLocked(forGood: true, keepWaiting: false)
    }

    /// On the source's queue.
    func handle(_ event: FrameEvent) {
        var ask: (file: String, start: Bool)?
        var stopSource = false
        lock.withLock {
            guard running, !closed else { return }
            if endIfTurnedOff() { stopSource = true; return }
            let at = offset()
            switch event {
            case .idle:
                ask = keep(selector.quiet(at: at))
            case .lost:
                if selector.dropUnconfirmed() { held = nil }
            case .picture(let picture, let window):
                // What one window proved about drawing while covered does not hold for another.
                if let last = lastPicture, last.window != window { liveness?.newWindow() }
                mark(liveness?.frame(at: at))
                guard let thumb = picture.thumb else { return }
                let step = selector.frame(thumb, at: at)
                ask = keep(step)
                // A pause from cover ends the session only when no picture came for minutes.
                if coverPaused, let last = lastPicture, at - last.at >= Self.coverEndsSession { sessionEnded = true }
                coverPaused = false
                lastPicture = (at, window)
                if step.hold {
                    held = picture.held().map { ($0, window, at, now()) }
                    // A picture that could not be copied is no candidate.
                    if held == nil { _ = selector.dropUnconfirmed() }
                }
            }
        }
        if stopSource { source.stop() }
        if let ask { readPresenter(for: ask.file, start: ask.start) }
    }

    /// On the timer: a window that sends nothing shows the same picture, or is gone.
    func tick() {
        var ask: (file: String, start: Bool)?
        var stopSource = false
        lock.withLock {
            guard running, !closed else { return }
            if endIfTurnedOff() { stopSource = true; return }
            let at = offset()
            // The window first: when it is no longer the meeting's (or its page moved), the source sends `.lost`
            // next, and a picture that waits must not be kept by this check.
            let sight = source.windowSight
            if sight != nil { ask = keep(selector.quiet(at: at)) }
            mark(liveness?.check(at: at, sight: sight))
        }
        if stopSource { source.stop() }
        if let ask { readPresenter(for: ask.file, start: ask.start) }
    }

    /// Pauses of the capture are kept with the frames. The text step shows the ones next to a share session.
    private func mark(_ change: ScreenLiveness.Change?) {
        let gap: ScreenGap
        switch change {
        case .paused(let at, let covered):
            gap = ScreenGap(offset: at, paused: true)
            // A window that is gone ends the share session. A covered one may only be behind the owner's notes.
            if covered { coverPaused = true } else { sessionEnded = true }
        case .resumed(let at): gap = ScreenGap(offset: at, paused: false)
        case nil: return
        }
        index.gaps = (index.gaps ?? []) + [gap]
        do { try index.save(to: dir) } catch { Log.error("Saving the frames list failed: \(error)") }
    }

    /// Writes the held picture when the step says so. Returns the file to read the presenter for, if it is time.
    @discardableResult
    private func keep(_ step: FrameSelector.Step) -> (file: String, start: Bool)? {
        guard let at = step.keepHeldAt else { return nil }
        guard let held else {
            selector.keepFailed()
            return nil
        }
        self.held = nil
        let isNew = sessionEnded || held.window != sessionWindow
        var frame = FrameIndex.Frame(offset: at, file: FrameIndex.fileName(offset: at), window: held.window,
                                     time: held.time.addingTimeInterval(at - held.offset), session: isNew ? session + 1 : session)
        let url = index.url(of: frame, in: dir)
        try? FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true)
        guard held.picture.write(to: url) else {
            // Not kept: the same picture is tried again when it comes again.
            selector.keepFailed()
            return nil
        }
        if isNew {
            session += 1
            sessionWindow = held.window
            sessionEnded = false
        } else {
            // The frames of one session share its presenter, as it was last read.
            frame.presenter = index.frames.last { $0.session == session }?.presenter
        }
        index.insert(frame)
        do { try index.save(to: dir) } catch { Log.error("Saving the frames list failed: \(error)") }
        if isNew { presenterOpen = true }
        guard presenter != nil, presenterOpen || at - presenterAsked >= Self.presenterInterval else { return nil }
        presenterAsked = at
        return (frame.file, presenterOpen)
    }

    /// The name the app shows now belongs to the frames from `file` on. The first answer of a session is that
    /// session's name, for all of its frames. Later, a different name (or a complete read with none) means another
    /// person shares now: those frames become a session of their own, so no frame carries a name that was read for
    /// someone else. A read with no answer (the app was busy) changes nothing; the next kept frame asks again.
    private func readPresenter(for file: String, start: Bool) {
        guard let presenter else { return }
        runPresenter { [weak self] in
            let read = presenter()
            guard let self else { return }
            self.lock.withLock {
                let name: String?
                switch read {
                case .unknown:
                    self.presenterAsked = -.infinity
                    return
                case .name(let found): name = found
                case .none: name = nil
                }
                guard !self.closed, let at = self.index.frames.firstIndex(where: { $0.file == file }),
                      let number = self.index.frames[at].session else { return }
                if start {
                    // Only while this is still the session's first answer.
                    if number == self.session { self.presenterOpen = false }
                    for i in self.index.frames.indices where self.index.frames[i].session == number { self.index.frames[i].presenter = name }
                } else {
                    guard name != self.index.frames[at].presenter else { return }
                    for i in at..<self.index.frames.count where (self.index.frames[i].session ?? -1) >= number {
                        if self.index.frames[i].session == number { self.index.frames[i].presenter = name }
                        self.index.frames[i].session = (self.index.frames[i].session ?? number) + 1
                    }
                    self.session += 1
                }
                try? self.index.save(to: self.dir)
            }
        }
    }
}
#endif
