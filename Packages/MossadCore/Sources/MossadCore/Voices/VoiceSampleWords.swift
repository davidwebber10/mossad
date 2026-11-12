import Foundation

/// The Voice tab's words for a sample: where it came from and how clear it is. Words only; nothing here takes
/// part in recognizing a voice.
extension VoiceSample.Origin {
    public var words: String {
        switch kind {
        case Self.ownerNamed.kind: "You named this voice"
        case Self.ownerEnrollment.kind: "Your voice on the microphone"
        case Self.migrated.kind: "From the older voice library"
        case "autoMatch": score.map { String(format: "Matched by voice (%.2f)", $0) } ?? "Matched by voice"
        default: "Learned from a call"
        }
    }
}

extension VoiceSample {
    /// Clear from 0.75, good from 0.5, else weak; nil for a sample with no quality.
    public static func qualityWord(_ quality: Double?) -> String? {
        guard let quality else { return nil }
        return quality >= 0.75 ? "Clear" : quality >= 0.5 ? "Good" : "Weak"
    }
}
