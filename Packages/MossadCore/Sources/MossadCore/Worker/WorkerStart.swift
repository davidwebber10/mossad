import Foundation

/// The order of a worker's start, as one runner that `WorkerEntry` follows: the refusal, the app in front (nothing
/// of the folder is touched before it is known), the root folder for the lock file and nothing else, the folder
/// lock, and only then the folder, the log, a proof's call, the settings, the watch, and the run.
public enum WorkerStart {
    public enum Step: String, CaseIterable, Sendable {
        case refuse, foreground, makeRoot, lock, prepare, proofCall, settings, watch, run
    }

    public struct Steps {
        public var refusal: () -> String?
        public var foreground: () -> Bool
        public var makeRoot: () -> Void
        public var lock: () -> Bool
        public var prepare: () -> Void
        public var proofCall: () -> Void
        public var setupDone: () -> Bool
        public var watch: () -> Void
        public var run: () -> Void

        public init(refusal: @escaping () -> String?, foreground: @escaping () -> Bool, makeRoot: @escaping () -> Void,
                    lock: @escaping () -> Bool, prepare: @escaping () -> Void, proofCall: @escaping () -> Void,
                    setupDone: @escaping () -> Bool, watch: @escaping () -> Void, run: @escaping () -> Void) {
            self.refusal = refusal
            self.foreground = foreground
            self.makeRoot = makeRoot
            self.lock = lock
            self.prepare = prepare
            self.proofCall = proofCall
            self.setupDone = setupDone
            self.watch = watch
            self.run = run
        }
    }

    public struct Stop: Equatable, Sendable {
        public let exit: WorkerLaunch.Exit
        public let at: Step
        public let refusal: String?
    }

    /// Runs the steps in order. Nil: the worker runs; else the exit and the step that stopped it.
    public static func run(_ s: Steps) -> Stop? {
        if let why = s.refusal() { return Stop(exit: .refused, at: .refuse, refusal: why) }
        guard s.foreground() else { return Stop(exit: .noForeground, at: .foreground, refusal: nil) }
        s.makeRoot()
        guard s.lock() else { return Stop(exit: .lockNotHeld, at: .lock, refusal: nil) }
        s.prepare()
        s.proofCall()
        guard s.setupDone() else { return Stop(exit: .setupNotDone, at: .settings, refusal: nil) }
        s.watch()
        s.run()
        return nil
    }
}
