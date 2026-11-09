import Foundation

/// The transcription models that run on this Mac. The raw value is the id saved in settings, so it never changes.
public enum LocalModel: String, CaseIterable, Sendable {
    case parakeetV3 = "parakeet-tdt-v3"
    case parakeetV2 = "parakeet-tdt-v2"

    public var name: String {
        switch self {
        case .parakeetV3: "Parakeet TDT v3"
        case .parakeetV2: "Parakeet TDT v2 (English only)"
        }
    }

    /// Size, speed, languages, and one weakness, one short sentence each.
    public var note: String {
        switch self {
        case .parakeetV3:
            "Free, and the audio never leaves this Mac. About 300 times faster than real time. Weaker on product names. The models download once, about 1 GB."
        case .parakeetV2:
            "Free, and the audio never leaves this Mac. A download of about 500 MB, once. About 300 times faster than real time. English only, a little more accurate in English than v3. Weaker on product names."
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
