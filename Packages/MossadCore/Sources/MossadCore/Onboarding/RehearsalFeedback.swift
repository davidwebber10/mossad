import Foundation

/// The owner's notes from a rehearsal of setup, in `feedback.md`: one entry per note, tagged with the step and time,
/// so they can be read back later in order.
public enum RehearsalFeedback {
    static let header = "# Mossad Rehearsal feedback\n"

    /// "## <step> · <ISO time>\n<text>\n".
    public static func entry(step: String, text: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return "## \(step) · \(formatter.string(from: date))\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// Adds an entry, starting the file with its heading the first time. An empty note saves nothing.
    public static func append(step: String, text: String, at date: Date = Date(), to file: URL, timeZone: TimeZone = .current) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let addition = "\n" + entry(step: step, text: text, at: date, timeZone: timeZone)
        guard fm.fileExists(atPath: file.path) else {
            try Data((header + addition).utf8).write(to: file, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(addition.utf8))
    }
}
