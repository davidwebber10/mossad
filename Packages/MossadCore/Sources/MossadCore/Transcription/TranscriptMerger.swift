import Foundation

/// Combines the "me" and "them" transcripts into one timeline.
public enum TranscriptMerger {
    /// A "me" utterance is speaker bleed when a "them" utterance covers at least this share of it…
    static let minimumOverlap = 0.5
    /// …and says nearly the same words.
    static let minimumSimilarity = 0.8

    public static func merge(me: [Utterance], them: [Utterance]) -> [Utterance] {
        let kept = me.filter { m in !them.contains { isBleed(me: m, them: $0) } }
        return (kept + them).sorted { $0.start < $1.start }
    }

    static func isBleed(me m: Utterance, them t: Utterance) -> Bool {
        let duration = max(m.end - m.start, 0.001)
        let overlap = min(m.end, t.end) - max(m.start, t.start)
        guard overlap / duration >= minimumOverlap else { return false }
        return similarity(m.text, t.text) >= minimumSimilarity
    }

    /// 2·LCS / (|a| + |b|) over normalized words.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return 2 * Double(previous[y.count]) / Double(x.count + y.count)
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
