import Foundation

/// When a release of the top card answers it: past the threshold, or a quick flick toward it. Else the card
/// springs back.
public enum DeckRelease {
    public static let threshold = 110.0

    public static func verdict(x: Double, predicted: Double, threshold: Double = threshold) -> FindingVerdict? {
        let flick = abs(predicted) > threshold * 2.4 && abs(x) > threshold * 0.35 && (predicted > 0) == (x > 0)
        guard abs(x) >= threshold || flick else { return nil }
        return x > 0 ? .yes : .no
    }
}

/// A two-finger swipe on the trackpad over the deck, read from the phases of the scroll events. An event is
/// never taken before the direction is known, so a scroll up or down gets each of its events, the first one too.
/// Only a swipe that starts sideways over the part of the deck that shows moves the card. The end of a swipe
/// also goes to the page, so its scroll is never left half open, and the glide after it does not scroll the page.
public struct ScrollSwipe: Equatable, Sendable {
    public enum Phase: Sendable { case none, began, changed, ended, cancelled }

    public struct Event: Sendable {
        public var phase: Phase
        public var momentum: Phase
        /// Already in the direction of the fingers.
        public var dx: Double
        public var dy: Double
        /// Over the part of the deck that shows.
        public var inside: Bool

        public init(phase: Phase = .none, momentum: Phase = .none, dx: Double = 0, dy: Double = 0, inside: Bool = true) {
            self.phase = phase
            self.momentum = momentum
            self.dx = dx
            self.dy = dy
            self.inside = inside
        }
    }

    public enum Effect: Equatable, Sendable {
        case move(Double)
        case release(x: Double, speed: Double)
        case cancel
    }

    public enum Outcome: Equatable, Sendable {
        /// The page gets the event, with what it does to the card, if anything.
        case pass(Effect? = nil)
        /// The card's: the page does not get it.
        case take(Effect?)

        public static let pass = Outcome.pass(nil)
        public var taken: Bool { if case .take = self { true } else { false } }
        public var effect: Effect? {
            switch self {
            case .pass(let e), .take(let e): e
            }
        }
    }

    private enum State: Equatable { case idle, page, undecided, sideways }

    private var state = State.idle
    private var total = (x: 0.0, y: 0.0)
    private var moves: [Double] = []
    private var glide = false

    public init() {}

    public static func == (a: ScrollSwipe, b: ScrollSwipe) -> Bool {
        a.state == b.state && a.total == b.total && a.moves == b.moves && a.glide == b.glide
    }

    public mutating func handle(_ e: Event) -> Outcome {
        if e.momentum != .none {
            guard glide else { return .pass }
            if e.momentum == .ended || e.momentum == .cancelled { glide = false }
            return .take(nil)
        }
        switch e.phase {
        case .none:
            return .pass
        case .began:
            glide = false
            total = (e.dx, e.dy)
            moves = e.dx == 0 ? [] : [e.dx]
            state = e.inside ? .undecided : .page
            return .pass
        case .changed:
            switch state {
            case .idle, .page:
                return .pass
            case .undecided:
                total.x += e.dx
                total.y += e.dy
                if e.dx != 0 { moves.append(e.dx) }
                guard abs(total.x) + abs(total.y) > 3 else { return .pass }
                guard abs(total.x) > abs(total.y) * 1.3 else {
                    state = .page
                    return .pass
                }
                state = .sideways
                return .take(.move(total.x))
            case .sideways:
                total.x += e.dx
                total.y += e.dy
                if e.dx != 0 { moves.append(e.dx) }
                return .take(.move(total.x))
            }
        case .ended, .cancelled:
            let was = state
            state = .idle
            guard was == .sideways else { return .pass }
            if e.phase == .cancelled { return .pass(.cancel) }
            glide = true
            let last = moves.suffix(4)
            return .pass(.release(x: total.x, speed: last.isEmpty ? 0 : last.reduce(0, +) / Double(last.count)))
        }
    }
}
