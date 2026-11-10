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

/// A moment the capture of the shared screen stopped having a live picture (`paused`), or had one again.
public struct ScreenGap: Codable, Equatable, Sendable {
    public static let pausedText = "Screen capture paused"
    public static let resumedText = "Screen capture resumed"
    /// How near a share session a pause must be to show in the transcript.
    static let reach: TimeInterval = 60

    public var offset: TimeInterval
    public var paused: Bool

    public init(offset: TimeInterval, paused: Bool) {
        self.offset = offset
        self.paused = paused
    }

    public var text: String { paused ? Self.pausedText : Self.resumedText }

    /// The gaps worth a line in the transcript: a pause inside or next to a share session, with the return that
    /// follows it. A window that the owner left while nobody shared anything says nothing about a shared screen.
    public static func shown(_ gaps: [ScreenGap], screens: [SharedScreen]) -> [ScreenGap] {
        let sessions = ShareSession.group(screens)
        var out: [ScreenGap] = []
        var showNext = false
        for gap in gaps.sorted(by: { $0.offset < $1.offset }) {
            if gap.paused {
                showNext = sessions.contains { gap.offset >= $0.start - reach && gap.offset <= $0.end + reach }
                if showNext { out.append(gap) }
            } else if showNext {
                out.append(gap)
                showNext = false
            }
        }
        return out
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
        /// The time of day the frame shows. The offset cannot give it: it leaves out pauses and the time between
        /// the parts of a joined meeting.
        public var time: Date?
        /// The share session's number, set while capturing: a new one for each window and after each pause of the capture.
        public var session: Int?
        /// How often the text could not be read. After a few tries the frame is given up.
        public var attempts: Int?

        public init(offset: TimeInterval, file: String, window: String? = nil, presenter: String? = nil,
                    text: String? = nil, words: [ScreenWord]? = nil, time: Date? = nil, session: Int? = nil) {
            self.offset = offset
            self.file = file
            self.window = window
            self.presenter = presenter
            self.text = text
            self.words = words
            self.time = time
            self.session = session
        }
    }

    public var frames: [Frame]
    /// When the capture had no live picture, and when it had one again. Shown only next to a share session.
    public var gaps: [ScreenGap]?

    public init(frames: [Frame] = [], gaps: [ScreenGap]? = nil) {
        self.frames = frames
        self.gaps = gaps
    }

    public static func fileName(offset: TimeInterval) -> String {
        "\(Int((max(0, offset) * 1000).rounded())).heic"
    }

    public static func folder(in dir: URL) -> URL { dir.appendingPathComponent(folder) }

    public func url(of frame: Frame, in dir: URL) -> URL { Self.folder(in: dir).appendingPathComponent(frame.file) }

    /// Nil when the call has no frames file (no screen capture, or the frames were removed).
    public static func load(from dir: URL, fileName: String = fileName) -> FrameIndex? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FrameIndex.self, from: data)
    }

    public func save(to dir: URL, fileName: String = fileName) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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

    /// The same frames `seconds` later, as part of a joined meeting. Each file gets the name of its new offset, and
    /// each session a number after `sessions`, so the sessions of two parts stay apart.
    public func moved(by seconds: TimeInterval, sessionsFrom sessions: Int = 0) -> FrameIndex {
        guard seconds != 0 || sessions != 0 else { return self }
        return FrameIndex(frames: frames.map { f in
            var f = f
            f.offset += seconds
            if seconds != 0 { f.file = Self.fileName(offset: f.offset) }
            f.session = f.session.map { $0 + sessions }
            return f
        }, gaps: gaps?.map { ScreenGap(offset: $0.offset + seconds, paused: $0.paused) })
    }

    /// The first session number that is free after this index's own.
    public var nextSession: Int { (frames.compactMap(\.session).max() ?? -1) + 1 }

    /// The record's list: only frames whose text was read.
    public var screens: [SharedScreen] {
        frames.compactMap { f in
            f.text.map { SharedScreen(offset: f.offset, file: f.file, text: $0, presenter: f.presenter, window: f.window, time: f.time, session: f.session) }
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
            let moved = index.moved(by: offset, sessionsFrom: joined.nextSession)
            if let gaps = moved.gaps { joined.gaps = (joined.gaps ?? []) + gaps }
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
