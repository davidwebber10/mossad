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

/// The step after the call that reads the kept frames: text recognition on each one, at a low priority and never
/// while a call records. A frame with too little text (a grid of faces) is dropped and its file deleted. Each
/// frame is saved to `frames.json` as it is read, so the step goes on where it stopped.
public struct ScreenStep: Sendable {
    let reader: ScreenTextReading
    /// True while a call records: the text recognition waits, so it takes nothing from the call.
    let isRecording: @Sendable () -> Bool
    let wait: @Sendable () async -> Void

    public init(reader: ScreenTextReading, isRecording: @escaping @Sendable () -> Bool = { false },
                wait: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(5)) }) {
        self.reader = reader
        self.isRecording = isRecording
        self.wait = wait
    }

    /// The call's screens, or nil when the call has no frames on disk (then the record keeps what it has).
    /// `known` are the people of the meeting and of the voice library, for the presenter's name.
    public func run(in dir: URL, known: [String]) async -> [SharedScreen]? {
        guard var index = FrameIndex.load(from: dir) else { return nil }
        FrameStore.removeUnlisted(in: dir)
        for frame in index.frames where frame.text == nil {
            while isRecording() { await wait() }
            let url = index.url(of: frame, in: dir), reader = reader
            let read = await Task.detached(priority: .utility) { reader.read(url) }.value
            guard let at = index.frames.firstIndex(where: { $0.file == frame.file }) else { continue }
            if let read, ScreenText.hasEnough(read.text) {
                index.frames[at].text = read.text
                index.frames[at].words = read.words
            } else {
                index.frames.remove(at: at)
                try? FileManager.default.removeItem(at: url)
            }
            do { try index.save(to: dir) } catch { Log.error("Saving the frames list failed: \(error)") }
        }
        return index.screens.map { s in
            var s = s
            s.text = ScreenText.stored(s.text)
            s.presenter = s.presenter.map { PresenterLabel.resolve($0, known: known) }
            return s
        }
    }
}
