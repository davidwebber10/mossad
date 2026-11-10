import Foundation
#if canImport(Vision)
import Vision
#endif

/// Reads the text on a saved frame.
public protocol ScreenTextReading: Sendable {
    /// The lines of text, top to bottom, and a box for each word. Nil when the picture could not be read.
    func read(_ url: URL) -> (text: String, words: [ScreenWord])?
}

#if canImport(Vision)
/// Text recognition on the device, at the accurate level. Nothing leaves the Mac.
public struct VisionScreenReader: ScreenTextReading {
    public init() {}

    public func read(_ url: URL) -> (text: String, words: [ScreenWord])? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(url: url).perform([request]) } catch { return nil }
        var lines: [String] = []
        var words: [ScreenWord] = []
        for observation in request.results ?? [] {
            guard let best = observation.topCandidates(1).first else { continue }
            let line = best.string
            lines.append(line)
            var found = false
            line.enumerateSubstrings(in: line.startIndex..., options: .byWords) { word, range, _, _ in
                guard let word, let box = try? best.boundingBox(for: range)?.boundingBox else { return }
                words.append(Self.word(word, box))
                found = true
            }
            if !found { words.append(Self.word(line, observation.boundingBox)) }
        }
        return (lines.joined(separator: "\n"), words)
    }

    /// Vision counts from the bottom left; the boxes are kept from the top left, rounded to keep the file small.
    static func word(_ text: String, _ box: CGRect) -> ScreenWord {
        func r(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }
        return ScreenWord(text: text, x: r(box.minX), y: r(1 - box.maxY), width: r(box.width), height: r(box.height))
    }
}
#endif

/// The step after the call that reads the kept frames: text recognition on each one, one at a time, on a queue of
/// the lowest priority. It does not wait for a call to end (the note of one call must not wait for the next call);
/// while a call records it rests between two frames. A frame with too little text (a grid of faces) is dropped and
/// its file deleted. The work is saved to `frames.json` as it goes, so the step goes on where it stopped.
public struct ScreenStep: Sendable {
    public struct Result: Equatable, Sendable {
        public var screens: [SharedScreen]
        public var gaps: [ScreenGap]
    }

    /// A frame that could not be read this often is given up.
    static let maxAttempts = 3
    /// `frames.json` is saved after this many frames, and at the end.
    static let saveEvery = 10
    /// The queues for the text recognition, one frame at a time. A task that waits for one does not raise its
    /// priority. While a call records, the lowest priority; with no call, a low one, so the note does not wait long.
    static let quietQueue = DispatchQueue(label: "com.dwebber.mossad.screen-text", qos: .utility)
    static let callQueue = DispatchQueue(label: "com.dwebber.mossad.screen-text.call", qos: .background)

    let reader: ScreenTextReading
    let isRecording: @Sendable () async -> Bool
    /// The rest between two frames while a call records.
    let rest: @Sendable () async -> Void

    public init(reader: ScreenTextReading, isRecording: @escaping @Sendable () async -> Bool = { false },
                rest: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(2)) }) {
        self.reader = reader
        self.isRecording = isRecording
        self.rest = rest
    }

    /// The same step, which also rests while the gate for heavy work is held (a call records). Other heavy steps
    /// wait at that gate until the call ends; this one only slows down, so a note never waits for the next call.
    public func gated(by gate: HeavyWorkGate) -> ScreenStep {
        let own = isRecording
        return ScreenStep(reader: reader, isRecording: { if await own() { return true }; return await gate.isHeld }, rest: rest)
    }

    private func read(_ url: URL, duringCall: Bool) async -> (text: String, words: [ScreenWord])? {
        let reader = reader
        return await withCheckedContinuation { done in
            (duringCall ? Self.callQueue : Self.quietQueue).async { done.resume(returning: reader.read(url)) }
        }
    }

    /// The call's screens, or nil when the call has no frames on disk (then the record keeps what it has).
    /// `known` are the people of the meeting and of the voice library, for the presenter's name. `existing` are the
    /// record's screens: one whose picture is no longer listed (removed with an old recording) keeps its text.
    /// `deleted` are the screens the owner deleted: an entry of one that is still listed goes, with its picture.
    public func run(in dir: URL, known: [String], existing: [SharedScreen] = [], deleted: Set<String> = []) async -> Result? {
        guard var index = FrameIndex.load(from: dir) else { return nil }
        if index.frames.contains(where: { deleted.contains($0.file) }) {
            index.frames.removeAll { deleted.contains($0.file) }
            do { try index.save(to: dir) } catch { Log.error("Saving the frames list failed: \(error)") }
        }
        FrameStore.removeUnlisted(in: dir)
        /// This run holds its own copy of the list for as long as it reads. A screen that the owner deletes in
        /// that time leaves the list on disk; it must leave this copy too, before the copy is saved over it.
        func save() {
            if let disk = FrameIndex.load(from: dir) {
                let listed = Set(disk.frames.map(\.file))
                index.frames.removeAll { !listed.contains($0.file) }
            }
            do { try index.save(to: dir) } catch { Log.error("Saving the frames list failed: \(error)") }
        }
        var unsaved = 0
        for frame in index.frames where frame.text == nil {
            let duringCall = await isRecording()
            if duringCall { await rest() }
            let url = index.url(of: frame, in: dir)
            let read = await read(url, duringCall: duringCall)
            guard let at = index.frames.firstIndex(where: { $0.file == frame.file }) else { continue }
            if let read {
                if ScreenText.hasEnough(read.text) {
                    index.frames[at].text = read.text
                    index.frames[at].words = read.words
                } else {
                    index.frames.remove(at: at)
                    try? FileManager.default.removeItem(at: url)
                }
            } else {
                // Not read is not "no text": the picture stays for another try, a few times.
                let attempts = (index.frames[at].attempts ?? 0) + 1
                index.frames[at].attempts = attempts
                if attempts >= Self.maxAttempts {
                    index.frames.remove(at: at)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            unsaved += 1
            if unsaved >= Self.saveEvery {
                unsaved = 0
                save()
            }
        }
        // Also with nothing new to save: a delete during the run must not be in the answer.
        save()
        let listed = Set(index.frames.map(\.file))
        var screens = index.screens.map { s in
            var s = s
            s.text = ScreenText.stored(s.text)
            s.presenter = s.presenter.map { PresenterLabel.resolve($0, known: known) }
            return s
        }
        screens += existing.filter { !deleted.contains($0.file) && !listed.contains($0.file) && !FileManager.default.fileExists(atPath: FrameIndex.folder(in: dir).appendingPathComponent($0.file).path) }
        screens.sort { $0.offset < $1.offset }
        return Result(screens: screens, gaps: ScreenGap.shown(index.gaps ?? [], screens: screens))
    }
}
