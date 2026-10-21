import Foundation

/// Combines the "me" and "them" transcripts into one timeline.
public enum TranscriptMerger {
    /// A "me" utterance is speaker bleed when a "them" utterance covers at least this share of it…
    static let minimumOverlap = 0.5
    /// …and nearly all of its words appear in what "them" said.
    static let minimumSimilarity = 0.8
    /// Shorter "me" utterances are always kept: a real "yes" matters more than a stray echoed word.
    static let minimumWords = 3

    public static func merge(me: [Utterance], them: [Utterance]) -> [Utterance] {
        let kept = me.filter { !isBleed(me: $0, them: them) }
        return (kept + them).sorted { $0.start < $1.start }
    }

    /// Bleed: "them" speech covers most of the "me" utterance's time, and nearly all of its words
    /// appear, in order, in what "them" said then. Echo cancellation often leaves only a fragment.
    static func isBleed(me m: Utterance, them: [Utterance]) -> Bool {
        let duration = max(m.end - m.start, 0.001)
        let overlapping = them.filter { min(m.end, $0.end) > max(m.start, $0.start) }
        let covered = overlapping.reduce(0) { $0 + min(m.end, $1.end) - max(m.start, $1.start) }
        guard covered / duration >= minimumOverlap else { return false }
        let mine = words(m.text)
        guard mine.count >= minimumWords else { return false }
        // Echo is heard when it is said: only their words said near this time count. A word's time is
        // estimated by its position in the utterance, with a margin for that estimate.
        let theirs = overlapping.flatMap { t -> [String] in
            let w = words(t.text)
            let step = (t.end - t.start) / Double(max(w.count, 1))
            return w.indices.compactMap { i in
                let at = t.start + step * Double(i)
                return at >= m.start - alignmentMargin && at <= m.end + alignmentMargin ? w[i] : nil
            }
        }
        return Double(lcs(mine, theirs)) / Double(mine.count) >= minimumSimilarity
    }

    /// How far an estimated word time may be from the "me" utterance and still count as its echo.
    static let alignmentMargin: TimeInterval = 2

    static func lcs(_ x: [String], _ y: [String]) -> Int {
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[y.count]
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
