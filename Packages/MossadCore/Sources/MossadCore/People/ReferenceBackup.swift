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

    /// Keeps a copy of one file before its first change, under `name` in the backup folder. True when the copy is
    /// there, or when there is no file to copy.
    @discardableResult
    public static func keep(_ file: URL, as name: String, paths: Paths) -> Bool {
        let copy = folder(paths).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: copy.path) else { return true }
        do {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: copy)
            return true
        } catch {
            Log.error("People: no backup of \(file.lastPathComponent), so it is not changed: \(error)")
            return false
        }
    }
}
