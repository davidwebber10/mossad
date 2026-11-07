import Foundation

/// The width of a page's list column: the saved width inside the fixed range, and never so wide that the detail
/// column gets less than its minimum. The saved value is kept, so a wide list comes back when the window grows.
public enum ColumnWidth {
    public static func list(saved: Double, range: ClosedRange<Double>, window: Double, sidebar: Double, detailMin: Double) -> Double {
        let upper = max(range.lowerBound, min(range.upperBound, window - sidebar - detailMin))
        guard saved.isFinite else { return range.lowerBound }
        return min(max(saved, range.lowerBound), upper)
    }
}

/// What a double-click on the window's top area does, from System Settings' "Double-click a window's title bar
/// to" (the `AppleActionOnDoubleClick` default).
public enum DoubleClickAction: Equatable, Sendable {
    case zoom, fill, minimize, none

    public init(defaultsValue: String?) {
        switch defaultsValue {
        case "Maximize": self = .zoom
        case "Minimize": self = .minimize
        case "None": self = .none
        // Unset is the system default, Fill since macOS 15.
        default: self = .fill
        }
    }
}

/// Type-to-select in a short list: the next name after the current one that starts with the typed text, wrapping,
/// so the same letter again moves through the names that share it.
public enum TypeSelect {
    public static func next(in names: [String], typed: String, after current: Int?) -> Int? {
        guard !typed.isEmpty, !names.isEmpty else { return nil }
        let start = current.map { $0 + 1 } ?? 0
        return (0..<names.count).lazy.map { (start + $0) % names.count }
            .first { names[$0].lowercased().hasPrefix(typed.lowercased()) }
    }
}
