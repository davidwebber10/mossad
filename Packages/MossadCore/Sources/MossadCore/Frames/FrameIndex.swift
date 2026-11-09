import Foundation

/// One recognized piece of text on a frame and where it is: a box in parts of the picture (0 to 1), from the top left.
public struct ScreenWord: Codable, Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// `frames.json` in a call's folder: the kept frames of the shared screen, in time order. The pictures are in
/// `frames/<offset in ms>.heic`. Offsets are seconds of the recording, which leave out paused time, as markers do.
public struct FrameIndex: Codable, Equatable, Sendable {
    public static let fileName = "frames.json"
    public static let folder = "frames"

    public struct Frame: Codable, Equatable, Sendable {
        public var offset: TimeInterval
        /// The file's name inside `frames/`.
        public var file: String
        /// The window the frame came from, so a change of window starts a new share session.
        public var window: String?
        /// Who shared, as the call app showed it when this session began; nil when it showed no name.
        public var presenter: String?
        /// The text on the frame, once it was read after the call.
        public var text: String?
        public var words: [ScreenWord]?

        public init(offset: TimeInterval, file: String, window: String? = nil, presenter: String? = nil,
                    text: String? = nil, words: [ScreenWord]? = nil) {
            self.offset = offset
            self.file = file
            self.window = window
            self.presenter = presenter
            self.text = text
            self.words = words
        }
    }

    public var frames: [Frame]

    public init(frames: [Frame] = []) {
        self.frames = frames
    }

    public static func fileName(offset: TimeInterval) -> String {
        "\(Int((max(0, offset) * 1000).rounded())).heic"
    }

    public static func folder(in dir: URL) -> URL { dir.appendingPathComponent(folder) }

    public func url(of frame: Frame, in dir: URL) -> URL { Self.folder(in: dir).appendingPathComponent(frame.file) }

    /// Nil when the call has no frames file (no screen capture, or the frames were removed).
    public static func load(from dir: URL, fileName: String = fileName) -> FrameIndex? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(FrameIndex.self, from: data)
    }

    public func save(to dir: URL, fileName: String = fileName) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent(fileName), options: .atomic)
    }

    /// Adds a frame in time order. A frame at the same millisecond replaces the older one.
    public mutating func insert(_ frame: Frame) {
        frames.removeAll { $0.file == frame.file }
        let at = frames.firstIndex { $0.offset > frame.offset } ?? frames.count
        frames.insert(frame, at: at)
    }

    /// Drops the frames after `length` seconds and returns them, so their files can go too.
    @discardableResult
    public mutating func trim(to length: TimeInterval) -> [Frame] {
        let cut = frames.filter { $0.offset > length }
        frames.removeAll { $0.offset > length }
        return cut
    }

    /// The same frames `seconds` later, as part of a joined meeting. Each file gets the name of its new offset.
    public func moved(by seconds: TimeInterval) -> FrameIndex {
        guard seconds != 0 else { return self }
        return FrameIndex(frames: frames.map { f in
            var f = f
            f.offset += seconds
            f.file = Self.fileName(offset: f.offset)
            return f
        })
    }

    /// The record's list: only frames whose text was read.
    public var screens: [SharedScreen] {
        frames.compactMap { f in
            f.text.map { SharedScreen(offset: f.offset, file: f.file, text: $0, presenter: f.presenter, window: f.window) }
        }
    }
}

/// The frame files of a call on disk.
public enum FrameStore {
    /// Drops the frames after `length` seconds: the audio was cut there.
    public static func trim(in dir: URL, to length: TimeInterval) {
        guard var index = FrameIndex.load(from: dir) else { return }
        let cut = index.trim(to: length)
        guard !cut.isEmpty else { return }
        try? index.save(to: dir)
        for f in cut { try? FileManager.default.removeItem(at: index.url(of: f, in: dir)) }
    }

    /// Removes the pictures and their index. The record keeps the text.
    public static func remove(in dir: URL) {
        try? FileManager.default.removeItem(at: FrameIndex.folder(in: dir))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(FrameIndex.fileName))
    }

    public static func hasFrames(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(FrameIndex.fileName).path)
    }

    /// Pictures that the index does not list: a quit between the picture and the index, or a merge that was undone.
    public static func removeUnlisted(in dir: URL) {
        let listed = Set(FrameIndex.load(from: dir)?.frames.map(\.file) ?? [])
        let folder = FrameIndex.folder(in: dir)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where !listed.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
    }

    static let mergedFileName = "frames.merged.json"

    /// First half of a merge: copies the later parts' pictures into the first part's folder under the names of
    /// their new offsets, and saves the joined index beside the old one. Nothing of the old state changes, so an
    /// undone merge only has to call `undoJoin`.
    public static func join(_ dirs: [URL], offsets: [TimeInterval]) throws {
        guard let target = dirs.first, dirs.contains(where: hasFrames) else { return }
        var joined = FrameIndex()
        let fm = FileManager.default
        try fm.createDirectory(at: FrameIndex.folder(in: target), withIntermediateDirectories: true)
        for (dir, offset) in zip(dirs, offsets) {
            guard let index = FrameIndex.load(from: dir) else { continue }
            let moved = index.moved(by: offset)
            for (old, new) in zip(index.frames, moved.frames) {
                let from = index.url(of: old, in: dir), to = moved.url(of: new, in: target)
                if from != to, fm.fileExists(atPath: from.path) {
                    try? fm.removeItem(at: to)
                    try fm.copyItem(at: from, to: to)
                }
                joined.insert(new)
            }
        }
        try joined.save(to: target, fileName: mergedFileName)
    }

    /// Second half, once the merged record is in place: the joined index takes the old one's place.
    public static func finishJoin(in target: URL) {
        let merged = target.appendingPathComponent(mergedFileName)
        guard FileManager.default.fileExists(atPath: merged.path) else { return }
        _ = try? FileManager.default.replaceItemAt(target.appendingPathComponent(FrameIndex.fileName), withItemAt: merged)
        removeUnlisted(in: target)
    }

    public static func undoJoin(in target: URL) {
        let merged = target.appendingPathComponent(mergedFileName)
        guard FileManager.default.fileExists(atPath: merged.path) else { return }
        try? FileManager.default.removeItem(at: merged)
        removeUnlisted(in: target)
    }
}
