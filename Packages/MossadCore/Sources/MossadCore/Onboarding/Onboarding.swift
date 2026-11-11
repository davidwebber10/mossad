import Foundation

/// The setup steps a new owner walks through, in order.
public enum OnboardingStep: String, CaseIterable, Codable, Sendable, Identifiable {
    case welcome, you, permissions, ai, calendars, google, check, sync, done

    public var id: String { rawValue }
    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .you: "You"
        case .permissions: "Permissions"
        case .ai: "AI"
        case .calendars: "Calendars"
        case .google: "Google"
        case .check: "Check"
        case .sync: "iPhone and sync"
        case .done: "Done"
        }
    }

    /// The notes need the owner's name, so only that step has no Skip.
    public var isSkippable: Bool { self != .you }

    public var next: OnboardingStep? { Self.allCases.firstIndex(of: self).flatMap { Self.allCases.dropFirst($0 + 1).first } }
    public var previous: OnboardingStep? {
        Self.allCases.firstIndex(of: self).flatMap { $0 > 0 ? Self.allCases[$0 - 1] : nil }
    }

    /// Whether what the app knows already covers this step. Steps that only inform are satisfied once seen.
    public func isSatisfied(by facts: OnboardingFacts) -> Bool {
        switch self {
        case .welcome, .sync, .done: false
        case .google: facts.googleConnected
        case .you: !facts.ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .permissions: OnboardingPermissions.required.allSatisfy(facts.granted.contains)
        case .ai: facts.transcriptionKeySet != false && facts.aiKeySet
        case .calendars: facts.granted.contains(.calendars) && facts.chosenCalendars > 0
        case .check: facts.micHeard == true && facts.systemAudioHeard == true
        }
    }
}

/// What a step shows in the rail.
public enum OnboardingStepState: String, Sendable {
    /// Not reached yet.
    case upcoming
    /// The step on screen, not yet satisfied.
    case current
    case done
    /// Seen and left without what it asks for.
    case needsYou
    case skipped
}

/// What the app knows about the owner's setup, read fresh each time the rail draws.
public struct OnboardingFacts: Equatable, Sendable {
    public var ownerName: String
    public var granted: Set<PermissionKind>
    /// Nil when the chosen transcription needs no key (the local model).
    public var transcriptionKeySet: Bool?
    public var aiKeySet: Bool
    public var chosenCalendars: Int
    /// Nil until the check ran.
    public var micHeard: Bool?
    public var systemAudioHeard: Bool?
    /// A Google sign-in is saved. Optional: Mossad works without it.
    public var googleConnected: Bool

    public init(ownerName: String = "", granted: Set<PermissionKind> = [], transcriptionKeySet: Bool? = false, aiKeySet: Bool = false,
                chosenCalendars: Int = 0, micHeard: Bool? = nil, systemAudioHeard: Bool? = nil, googleConnected: Bool = false) {
        self.googleConnected = googleConnected
        self.ownerName = ownerName
        self.granted = granted
        self.transcriptionKeySet = transcriptionKeySet
        self.aiKeySet = aiKeySet
        self.chosenCalendars = chosenCalendars
        self.micHeard = micHeard
        self.systemAudioHeard = systemAudioHeard
    }
}

/// Where the owner is in setup, saved after each step so a quit resumes at the same step.
public struct OnboardingProgress: Codable, Equatable, Sendable {
    public private(set) var current: OnboardingStep
    public private(set) var seen: Set<OnboardingStep>
    public private(set) var skipped: Set<OnboardingStep>
    public private(set) var completed: Bool

    public init(current: OnboardingStep = .welcome) {
        self.current = current
        seen = []
        skipped = []
        completed = false
    }

    public func canContinue(facts: OnboardingFacts) -> Bool {
        current != .you || OnboardingStep.you.isSatisfied(by: facts)
    }

    /// Continue: the step counts as seen, and the next one opens.
    public mutating func advance() {
        seen.insert(current)
        skipped.remove(current)
        if let next = current.next { current = next }
    }

    /// Skip: false for a step that cannot be skipped.
    @discardableResult
    public mutating func skip() -> Bool {
        guard current.isSkippable else { return false }
        seen.insert(current)
        skipped.insert(current)
        if let next = current.next { current = next }
        return true
    }

    public mutating func back() {
        if let previous = current.previous { current = previous }
    }

    public mutating func jump(to step: OnboardingStep) {
        current = step
    }

    public mutating func finish() {
        seen.insert(.done)
        completed = true
    }

    public mutating func restart() {
        self = OnboardingProgress()
    }

    public func state(of step: OnboardingStep, facts: OnboardingFacts) -> OnboardingStepState {
        if step == .done { return completed ? .done : step == current ? .current : .upcoming }
        // A step already covered shows done even before the owner reaches it; one that only informs, once seen.
        if step.isSatisfied(by: facts) || (step.onlyInforms && seen.contains(step) && step != current) { return .done }
        if step == current { return .current }
        if skipped.contains(step) { return .skipped }
        return seen.contains(step) ? .needsYou : .upcoming
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// The saved progress, or a fresh start when there is none or it cannot be read.
    public static func resume(from data: Data?) -> OnboardingProgress {
        data.flatMap { try? JSONDecoder().decode(OnboardingProgress.self, from: $0) } ?? OnboardingProgress()
    }
}

extension OnboardingStep {
    /// Steps with nothing to set: seen is done.
    /// The Google step is optional too: seen is done.
    var onlyInforms: Bool { self == .welcome || self == .sync || self == .google }
}

public enum Onboarding {
    /// The real app opens setup only for a new install: not after setup finished, not for someone with meetings,
    /// and never in a UI preview unless asked. The Rehearsal app always opens into it.
    public static func opensAtLaunch(finished: Bool, hasMeetings: Bool, preview: Bool, forced: Bool, rehearsal: Bool) -> Bool {
        if forced || rehearsal { return true }
        return !finished && !hasMeetings && !preview
    }

    /// "About $0.93 for each hour of meetings, billed to your own accounts." The amount is the one Settings shows.
    public static func costLine(_ cost: HourCost) -> String {
        switch cost.headline {
        case "Free": "Free: these choices bill nothing."
        case "Not known": "The cost is not known: the notes model has no list price."
        case let amount: "\(amount) for each hour of meetings, billed to your own accounts."
        }
    }
}

/// Which permissions setup asks for, and in what order.
public enum OnboardingPermissions {
    /// Without these there is no recording worth writing up.
    public static let required: [PermissionKind] = [.microphone, .systemAudio]

    public static func isRequired(_ kind: PermissionKind) -> Bool { required.contains(kind) }

    /// Microphone, System audio, Calendars, Accessibility, Notifications, then each browser in the order given.
    public static func ordered(_ kinds: [PermissionKind]) -> [PermissionKind] {
        let fixed: [PermissionKind] = [.microphone, .systemAudio, .calendars, .accessibility, .notifications]
        let browsers = kinds.filter { if case .automation = $0 { true } else { false } }
        return fixed.filter(kinds.contains) + browsers
    }

    /// One line for each missing permission, saying what will not work. Browsers share one line.
    public static func whatWillNotWork(missing: [PermissionKind]) -> [String] {
        var lines: [String] = []
        for line in ordered(missing).map(consequence) where !lines.contains(line) { lines.append(line) }
        return lines
    }

    /// What does not work while one permission is missing.
    public static func consequence(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Without Microphone, your own side of the call is not recorded."
        case .systemAudio: "Without System audio recording, Mossad cannot hear the other people on the call."
        case .calendars: "Without Calendars, calls are not named from their invite and attendees are not listed."
        case .accessibility: "Without Accessibility, Mossad cannot read call window titles, so some calls are not detected."
        case .notifications: "Without Notifications, Mossad cannot tell you when new voices need names."
        case .automation: "Without Automation, Google Meet calls in the browser are not detected."
        case .screenCapture: "Without Screen Recording, shared screens are not captured."
        }
    }

    /// One line on what each permission is for. Setup and Settings both show it.
    public static func purpose(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Records your side of the call."
        case .systemAudio: "Records the other people, from the call app's audio. Nothing else on your Mac."
        case .calendars: "Names each call from its invite and lists who was there."
        case .accessibility: "Reads call window titles, to notice when a Zoom or Teams call starts."
        case .notifications: "Tells you when a new voice needs a name. Nothing during calls."
        case .automation: "Reads the meeting link in the browser tab, to notice Google Meet calls."
        case .screenCapture: "Keeps frames of screens that people share in a call."
        }
    }

    /// The words on the one control that gets a permission; nil when it is allowed. macOS asks once, and for
    /// Accessibility and Screen Recording it never asks: those need its Settings list.
    public static func action(_ kind: PermissionKind, _ state: PermissionState) -> String? {
        switch state {
        case .granted: nil
        case .notAsked: kind == .accessibility || kind == .screenCapture ? "Open Settings…" : "Allow…"
        case .needsApp: "Open the browser"
        case .denied: "Open Settings…"
        }
    }
}
