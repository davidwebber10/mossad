import Foundation

/// One entry of the log file that `Log` writes: `2026-10-21T16:51:29Z INFO message`.
public struct LogLine: Equatable, Sendable {
    public enum Level: String, Sendable {
        case info = "INFO", error = "ERROR", debug = "DEBUG", other
    }

    public var date: Date?
    public var level: Level
    public var message: String

    public init(date: Date?, level: Level, message: String) {
        self.date = date
        self.level = level
        self.message = message
    }

    /// Lines that do not start with a timestamp belong to the message before them (an error body, for example).
    public static func parse(_ text: String) -> [LogLine] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var result: [LogLine] = []
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = parts.first, let date = try? Date(String(first), strategy: .iso8601) {
                let rest = parts.count > 1 ? String(parts[1]) : ""
                let words = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                if let word = words.first, let level = Level(rawValue: String(word)), level != .other {
                    result.append(LogLine(date: date, level: level, message: words.count > 1 ? String(words[1]) : ""))
                } else {
                    result.append(LogLine(date: date, level: .other, message: rest))
                }
            } else if !result.isEmpty {
                result[result.count - 1].message += "\n" + line
            } else if !line.isEmpty {
                result.append(LogLine(date: nil, level: .other, message: line))
            }
        }
        return result
    }
}
