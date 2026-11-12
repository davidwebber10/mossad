import Foundation

/// The audio of a card's moment that the findings deck started. It stops when a card is answered, when that card is
/// no longer on top, and when the deck closes (not inside a meeting). A pause of the player forgets the card. Audio the deck did not start (the owner's own play in the meeting) is
/// never stopped by the deck.
public struct DeckPlayback: Equatable, Sendable {
    public private(set) var card: String?
    /// False inside a meeting, where the audio is the meeting's own player and the owner may read along elsewhere.
    public var stopsOnClose = true

    public init(stopsOnClose: Bool = true) {
        self.stopsOnClose = stopsOnClose
    }

    public mutating func started(_ id: String) { card = id }

    public mutating func paused() { card = nil }

    /// Whether to stop now that a card was answered: any answer ends the moment, so the next card starts quiet.
    public mutating func answered(_ id: String) -> Bool { take() }

    public mutating func topChanged(to id: String?) -> Bool {
        guard card != nil, card != id else { return false }
        return take()
    }

    public mutating func closed() -> Bool {
        guard stopsOnClose else {
            card = nil
            return false
        }
        return take()
    }

    private mutating func take() -> Bool {
        defer { card = nil }
        return card != nil
    }
}
