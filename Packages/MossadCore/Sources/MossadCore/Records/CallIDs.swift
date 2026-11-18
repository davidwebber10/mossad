import Foundation

/// A call's id from its start, and the free id the recorder and the cut give: one rule on the Mac and the iPhone.
public enum CallIDs {
    public static func callID(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// The ID has one-second resolution in local time, so the hour that repeats when daylight time ends (or a clock
    /// change) can give the ID of an older call. That call's folder is never reused, nor the id of a part of a cut
    /// recording that is being made (`<id>.cutting`).
    public static func freeID(for date: Date, in paths: Paths) -> String {
        let base = callID(for: date)
        var id = base, n = 2
        func taken(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: paths.callDirectory(id).path)
                || FileManager.default.fileExists(atPath: paths.audio.appendingPathComponent(id + Pipeline.cuttingSuffix).path)
        }
        while taken(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }
}
