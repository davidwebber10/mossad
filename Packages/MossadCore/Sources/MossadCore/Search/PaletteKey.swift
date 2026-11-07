import Foundation

/// The keys the Mac's search palette takes before its field does, from the key code, so they work whatever
/// holds the keyboard focus inside the window. Any other key goes to the field.
public enum PaletteKey: Equatable, Sendable {
    case move(Int)
    case nextGroup(backward: Bool)
    case open(transcript: Bool)
    case close

    /// `composing` is true while an input method has marked text: its keys then belong to it.
    public init?(keyCode: UInt16, shift: Bool, command: Bool, option: Bool, control: Bool, composing: Bool) {
        guard !composing, !option, !control else { return nil }
        switch keyCode {
        case 125 where !command: self = .move(1)
        case 126 where !command: self = .move(-1)
        case 48 where !command: self = .nextGroup(backward: shift)
        case 36, 76: self = .open(transcript: command)
        case 53 where !command: self = .close
        default: return nil
        }
    }
}
