import Foundation
import os

/// Logs to the unified log and to a rotating file in `~/Mossad/Logs`.
public enum Log {
    private static let logger = Logger(subsystem: "com.dwebber.mossad", category: "app")
    private static let queue = DispatchQueue(label: "com.dwebber.mossad.log")
    private static let maxBytes = 5 * 1024 * 1024
    private static let keep = 3
    nonisolated(unsafe) public static var directory: URL = Paths.live.logs

    public static var fileURL: URL { directory.appendingPathComponent("mossad.log") }

    public static func info(_ message: String) { write("INFO", message); logger.info("\(message, privacy: .public)") }
    public static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }
    public static func debug(_ message: String) { write("DEBUG", message); logger.debug("\(message, privacy: .public)") }

    private static func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxBytes else { return }
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let src = directory.appendingPathComponent("mossad.\(i).log")
            let dst = directory.appendingPathComponent("mossad.\(i + 1).log")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        let first = directory.appendingPathComponent("mossad.1.log")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: fileURL, to: first)
    }
}
