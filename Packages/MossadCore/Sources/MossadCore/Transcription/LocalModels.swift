import Foundation

/// The transcription models that run on this Mac. The raw value is the id saved in settings, so it never changes.
public enum LocalModel: String, CaseIterable, Sendable {
    case parakeetV3 = "parakeet-tdt-v3"
    case parakeetV2 = "parakeet-tdt-v2"
    case appleSpeech = "apple-speech"

    public var name: String {
        switch self {
        case .parakeetV3: "Parakeet TDT v3"
        case .parakeetV2: "Parakeet TDT v2 (English only)"
        case .appleSpeech: "Apple Speech"
        }
    }

    /// Size, speed, languages, and one weakness, one short sentence each.
    public var note: String {
        switch self {
        case .parakeetV3:
            "Free, and the audio never leaves this Mac. About 300 times faster than real time. Weaker on product names. The models download once, about 1 GB."
        case .parakeetV2:
            "Free, and the audio never leaves this Mac. A download of about 500 MB, once. About 300 times faster than real time. English only, a little more accurate in English than v3. Weaker on product names."
        case .appleSpeech:
            "Free, and the audio never leaves this Mac. Nothing to download beyond the speech files macOS keeps itself. About 60 times faster than real time. US English only. Less proven on real calls than Parakeet."
        }
    }

    public var info: ModelInfo { ModelInfo(id: rawValue, name: name) }

    /// The model for a saved id; the first one when the id is empty or no longer in the list.
    public init(id: String) {
        self = LocalModel(rawValue: id) ?? .parakeetV3
    }
}

/// One recognized word and where it sits in the track, in seconds.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Why a local model could not run. The text is what the owner reads, so it says what to do.
public enum LocalModelError: Error, Equatable, LocalizedError {
    case modelMissing(LocalModel)
    case notSupported(LocalModel)
    case assetNotInstalled(LocalModel)

    public var model: LocalModel {
        switch self {
        case .modelMissing(let m), .notSupported(let m), .assetNotInstalled(let m): m
        }
    }

    public var message: String {
        switch self {
        case .modelMissing: "Its model files are missing or did not download. Mossad tries the download again on the next try."
        case .notSupported: "This Mac can't run this model. Choose another local model in Settings › AI."
        case .assetNotInstalled: "The language files for it did not install. Mossad tries again on the next try, or choose another model."
        }
    }

    public var errorDescription: String? { "\(model.name): \(message)" }
}

/// Picks which download fractions to log: the first one, then each new tenth.
struct DownloadSteps {
    private var last = -1

    mutating func next(_ fraction: Double) -> Int? {
        let tenth = Int((min(max(fraction, 0), 1) * 10).rounded(.down)) * 10
        guard tenth > last else { return nil }
        last = tenth
        return tenth
    }
}

/// A piece of recognized text with the time it covers, when the engine gives one: a word, part of a word, or
/// punctuation. A piece that starts with a space starts a new word.
public struct TimedPiece: Equatable, Sendable {
    public var text: String
    public var start: Double?
    public var end: Double?

    public init(text: String, start: Double?, end: Double?) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Turns the pieces engines give into whole words with times, so every local model yields the same words.
enum TimedText {
    static func words(_ pieces: [TimedPiece]) -> [TimedWord] {
        var words: [TimedWord] = []
        var boundary = true
        for piece in pieces {
            if piece.text.first?.isWhitespace == true { boundary = true }
            let tokens = piece.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let total = Double(tokens.reduce(0) { $0 + $1.count })
            var cursor = piece.start
            for (i, token) in tokens.enumerated() {
                var start: Double?, end: Double?
                if let s = piece.start, let e = piece.end, let c = cursor {
                    start = c
                    end = c + (e - s) * Double(token.count) / max(total, 1)
                    cursor = end
                }
                let isNew = i > 0 || boundary
                let hasLetters = token.contains { $0.isLetter || $0.isNumber }
                if !words.isEmpty, !isNew || !hasLetters {
                    words[words.count - 1].text += token
                    if let end { words[words.count - 1].end = max(words[words.count - 1].end, end) }
                } else if hasLetters {
                    let fallback = words.last?.end ?? 0
                    words.append(TimedWord(text: token, start: start ?? fallback, end: end ?? fallback))
                }
            }
            if !piece.text.isEmpty { boundary = piece.text.last?.isWhitespace == true }
        }
        return words
    }
}
