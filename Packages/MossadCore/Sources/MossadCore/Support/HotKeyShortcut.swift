import Foundation

/// A system-wide shortcut as the owner sets it in Settings: a key by its position (the Mac's virtual key code) and
/// the modifiers. Pure, so the saved form, the symbols, and the combinations it may not take are tested here; the
/// app turns it into a Carbon hot key.
public struct HotKeyShortcut: Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Option-Command-M: the quick panel.
    public static let askDefault = HotKeyShortcut(keyCode: 0x2E, modifiers: [.option, .command])
    /// Control-Option-B: a bookmark of the call's moment. Fixed.
    public static let bookmark = HotKeyShortcut(keyCode: 0x0B, modifiers: [.control, .option])

    // MARK: Saved form

    /// "10:46": the modifiers, then the key code.
    public var saved: String { "\(modifiers.rawValue):\(keyCode)" }

    public init?(saved: String) {
        let parts = saved.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), let k = UInt32(parts[1]), Self.keyNames[k] != nil else { return nil }
        self.init(keyCode: k, modifiers: Modifiers(rawValue: m & 15))
    }

    // MARK: Words

    /// "⌥⌘M", in the order macOS draws them.
    public var symbols: String {
        let marks: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return marks.filter { modifiers.contains($0.0) }.map(\.1).joined() + (Self.keyNames[keyCode] ?? "?")
    }

    /// "Option-Command-M", for VoiceOver and for sentences.
    public var spoken: String {
        let words: [(Modifiers, String)] = [(.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
        return (words.filter { modifiers.contains($0.0) }.map(\.1) + [Self.keyNames[keyCode] ?? "?"]).joined(separator: "-")
    }

    // MARK: Rules

    public enum Problem: Equatable, Sendable {
        case needsModifier, bookmark, mossad, system, unknownKey
        /// The system refused to register it.
        case taken

        public var message: String {
            switch self {
            case .needsModifier: "Use Command, Option, or Control with the key."
            case .bookmark: "Control-Option-B bookmarks a moment of the call. Choose another."
            case .mossad: "Mossad uses this shortcut in its window. Choose another."
            case .system: "macOS or other apps use this shortcut. Choose another."
            case .unknownKey: "Mossad cannot use this key. Choose another."
            case .taken: "Another app or macOS uses this shortcut. Choose another."
            }
        }
    }

    /// Why it cannot be the shortcut; nil when it can. A system-wide shortcut takes the keys from every app, so
    /// Command alone with a key (each app's own menus) is refused, as are Mossad's own and the bookmark's.
    public var problem: Problem? {
        guard Self.keyNames[keyCode] != nil else { return .unknownKey }
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else { return .needsModifier }
        if self == Self.bookmark { return .bookmark }
        if Self.mossad.contains(self) { return .mossad }
        if modifiers.isSubset(of: [.command, .shift]) || Self.system.contains(self) { return .system }
        return nil
    }

    /// The window's own menu keys that a system-wide shortcut would take from it.
    static let mossad: Set<HotKeyShortcut> = [
        .init(keyCode: 0x28, modifiers: [.command]), .init(keyCode: 0x28, modifiers: [.command, .shift]),
        .init(keyCode: 0x28, modifiers: [.command, .option]), .init(keyCode: 0x0B, modifiers: [.command, .option]),
        .init(keyCode: 0x2D, modifiers: [.command]), .init(keyCode: 0x0F, modifiers: [.command]),
        .init(keyCode: 0x01, modifiers: [.command, .shift]),
    ]

    /// macOS's own: Spotlight and input sources, Force Quit, Lock Screen, full screen, the emoji viewer.
    static let system: Set<HotKeyShortcut> = [
        .init(keyCode: 0x31, modifiers: [.control]), .init(keyCode: 0x31, modifiers: [.option, .command]),
        .init(keyCode: 0x31, modifiers: [.control, .command]), .init(keyCode: 0x31, modifiers: [.control, .option]),
        .init(keyCode: 0x35, modifiers: [.option, .command]), .init(keyCode: 0x0C, modifiers: [.control, .command]),
        .init(keyCode: 0x03, modifiers: [.control, .command]), .init(keyCode: 0x30, modifiers: [.control]),
    ]

    /// The keys by their US layout names.
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [:]
        let letters: [(UInt32, String)] = [
            (0x00, "A"), (0x01, "S"), (0x02, "D"), (0x03, "F"), (0x04, "H"), (0x05, "G"), (0x06, "Z"), (0x07, "X"),
            (0x08, "C"), (0x09, "V"), (0x0B, "B"), (0x0C, "Q"), (0x0D, "W"), (0x0E, "E"), (0x0F, "R"), (0x10, "Y"),
            (0x11, "T"), (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"), (0x16, "6"), (0x17, "5"), (0x18, "="),
            (0x19, "9"), (0x1A, "7"), (0x1B, "-"), (0x1C, "8"), (0x1D, "0"), (0x1E, "]"), (0x1F, "O"), (0x20, "U"),
            (0x21, "["), (0x22, "I"), (0x23, "P"), (0x24, "Return"), (0x25, "L"), (0x26, "J"), (0x27, "'"), (0x28, "K"),
            (0x29, ";"), (0x2A, "\\"), (0x2B, ","), (0x2C, "/"), (0x2D, "N"), (0x2E, "M"), (0x2F, "."), (0x30, "Tab"),
            (0x31, "Space"), (0x32, "`"), (0x33, "Delete"), (0x35, "Esc"),
            (0x7B, "←"), (0x7C, "→"), (0x7D, "↓"), (0x7E, "↑"),
        ]
        for (code, name) in letters { names[code] = name }
        let functions: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, code) in functions.enumerated() { names[code] = "F\(i + 1)" }
        return names
    }()
}
