import Foundation
import os

/// Logs to the unified log and to a rotating file in `~/Mossad/Logs`.
public enum Log {
    private static let logger = Logger(subsystem: "com.dwebber.mossad", category: "app")
    private static let queue = DispatchQueue(label: "com.dwebber.mossad.log")
    private static let maxBytes = 5 * 1024 * 1024
    private static let keep = 3
    /// File logging starts when the app sets this; until then only the unified log is used.
    nonisolated(unsafe) public static var directory: URL?

    /// False for a run that only looks, such as a preview for screenshots: its lines stay out of the owner's file.
    nonisolated(unsafe) public static var writesFile = true

    public static var fileURL: URL? { directory?.appendingPathComponent("mossad.log") }

    // The owner's own file gets the full line. The unified log is readable by other tools and by a sysdiagnose, and
    // lines carry meeting titles, people's names, and provider replies, so there the text is private.
    public static func info(_ message: String) { write("INFO", message); logger.info("\(message, privacy: .private)") }
    public static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .private)") }
    public static func debug(_ message: String) { write("DEBUG", message); logger.debug("\(message, privacy: .private)") }

    /// The open log file, used on `queue` only. It stays open between lines: each line used to cost a new date
    /// formatter object, a directory check, a size check, and an open and a close.
    nonisolated(unsafe) private static var descriptor: Int32 = -1
    nonisolated(unsafe) private static var openPath: String?

    private static func write(_ level: String, _ message: String) {
        let line = "\(Date().ISO8601Format()) \(level) \(message)\n"
        guard writesFile, let directory, let fileURL else { return }
        queue.async {
            let path = fileURL.path
            if descriptor >= 0 {
                // Another folder, a file that was deleted or rotated (also by the copy that serves `--mcp`), or a
                // file that is full: open again.
                var open = stat(), onDisk = stat()
                if openPath != path || fstat(descriptor, &open) != 0 || stat(path, &onDisk) != 0
                    || onDisk.st_ino != open.st_ino || onDisk.st_dev != open.st_dev || open.st_size > maxBytes {
                    close(descriptor)
                    descriptor = -1
                }
            }
            if descriptor < 0 {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                rotateIfNeeded(directory: directory, fileURL: fileURL)
                // Append mode: each line lands at the end of the file, also when two processes write.
                descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
                openPath = path
            }
            guard descriptor >= 0 else { return }
            let bytes = Array(line.utf8)
            _ = Darwin.write(descriptor, bytes, bytes.count)
        }
    }

    /// The end of a log file as text, from the first whole line in its last `bytes` bytes. The Log page shows 500
    /// lines; the file can hold 5 MB.
    public static func tail(of url: URL, bytes: Int = 128 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        // The read can start in the middle of a line (or of a character): the lines begin after the first newline.
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return "" }
            data = data[(newline + 1)...]
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for the lines already logged to reach the file.
    public static func flush() { queue.sync {} }

    /// The text without each line that names one of `names`: a call id only as a whole id (not the start of a longer
    /// one, such as "<id>-moved"), any other name (a note's file name) as it is. Pure; an empty name takes nothing.
    public static func withoutLines(_ text: String, naming names: [String]) -> String {
        let wanted = names.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return text }
        let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        func named(_ line: Substring) -> Bool {
            wanted.contains { name in
                var rest = line[...]
                while let r = rest.range(of: name) {
                    let before = r.lowerBound > line.startIndex ? line[line.index(before: r.lowerBound)].unicodeScalars.first : nil
                    let after = r.upperBound < line.endIndex ? line[r.upperBound].unicodeScalars.first : nil
                    // A name that is an id must stand alone; a name with other characters (a file name) is taken as it is.
                    let isID = name.unicodeScalars.allSatisfy(idCharacters.contains)
                    if !isID || (!(before.map(idCharacters.contains) ?? false) && !(after.map(idCharacters.contains) ?? false)) { return true }
                    rest = line[r.upperBound...]
                }
                return false
            }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Substring] = []
        for (i, line) in lines.enumerated() where i == lines.count - 1 || !named(line) { out.append(line) }
        return out.joined(separator: "\n")
    }

    /// Takes every line that names one of `names` out of each log file in `directory` (the file and its rotated
    /// copies), each in one atomic write. In this process's own folder it runs on the writer's queue, so no line is
    /// lost meanwhile; the writer sees the new file by its inode and opens it. True when every file was read and
    /// written, also when nothing had to change.
    @discardableResult
    public static func forget(naming names: [String], in directory: URL) -> Bool {
        let work = { () -> Bool in
            var ok = true
            for name in ["mossad.log"] + (1...keep).map({ "mossad.\($0).log" }) {
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                guard let data = try? Data(contentsOf: url) else { ok = false; continue }
                let text = String(decoding: data, as: UTF8.self)
                let kept = withoutLines(text, naming: names)
                guard kept != text else { continue }
                do { try Data(kept.utf8).write(to: url, options: .atomic) } catch { ok = false }
            }
            return ok
        }
        if Log.directory?.standardizedFileURL == directory.standardizedFileURL { return queue.sync(execute: work) }
        return work()
    }

    private static func rotateIfNeeded(directory: URL, fileURL: URL) {
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
