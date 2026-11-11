import Foundation

/// The copies of the files that the move to ids changes, as they were before their first change:
/// `Backups/people-references/` in the data folder. A copy is made once and never replaced, so it stays the state
/// of before the move.
public enum ReferenceBackup {
    public static func folder(_ paths: Paths) -> URL { paths.backups.appendingPathComponent("people-references") }

    /// Keeps a copy of a call's record before its first change. False when the copy could not be made: then the
    /// record is not changed.
    @discardableResult
    public static func keep(record dir: URL, paths: Paths) -> Bool {
        keep(dir.appendingPathComponent(CallRecord.fileName), as: "calls/\(dir.lastPathComponent).json", paths: paths)
    }

    /// Keeps a copy of a note before it is written again: under its file name in `notes/`.
    @discardableResult
    public static func keep(note path: String, paths: Paths) -> Bool {
        let url = URL(fileURLWithPath: path)
        return keep(url, as: "notes/\(url.lastPathComponent)", paths: paths)
    }

    /// Takes away the copy of a call's record: for a meeting that the owner deleted.
    public static func forget(callID: String, paths: Paths) {
        try? FileManager.default.removeItem(at: folder(paths).appendingPathComponent("calls/\(callID).json"))
    }

    /// Keeps a copy of one file before its first change, under `name` in the backup folder. True when the copy is
    /// there, or when there is no file to copy.
    @discardableResult
    public static func keep(_ file: URL, as name: String, paths: Paths) -> Bool {
        let copy = folder(paths).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: copy.path) else { return true }
        do {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A copy is made under another name and then moved into place, so a stop in the middle never leaves a
            // part of a file that counts as the backup.
            let part = copy.deletingLastPathComponent().appendingPathComponent(".\(copy.lastPathComponent).\(UUID().uuidString).part")
            defer { try? FileManager.default.removeItem(at: part) }
            try FileManager.default.copyItem(at: file, to: part)
            try FileManager.default.moveItem(at: part, to: copy)
            return true
        } catch {
            Log.error("People: no backup of \(file.lastPathComponent), so it is not changed: \(error)")
            return false
        }
    }
}
