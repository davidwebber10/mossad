import Foundation

/// Combines the "me" and "them" transcripts into one timeline.
public enum TranscriptMerger {
    /// A "me" utterance is speaker bleed when a "them" utterance covers at least this share of it…
    static let minimumOverlap = 0.5
    /// …and nearly all of its words appear in what "them" said.
    static let minimumSimilarity = 0.8
    /// Shorter "me" utterances are always kept: a real "yes" matters more than a stray echoed word.
    static let minimumWords = 3

    /// A mic voice that talks this share of its time while the call audio has sound is the speakers' echo.
    static let echoLabelOverlap = 0.8
    /// Above this share of sound in the call audio (a fan, music) the timeline cannot tell anything apart.
    static let maximumSoundCoverage = 0.9

    public static func merge(me: [Utterance], them: [Utterance], themSound: SoundTimeline? = nil) -> [Utterance] {
        let echo = themSound.map { echoLabels(me: me, themSound: $0) } ?? []
        let kept = me.filter { !echo.contains($0.speakerLabel) && !isBleed(me: $0, them: them) }
        return (kept + them).sorted { $0.start < $1.start }
    }

    /// Mic speaker labels that are the other side heard through the speakers. Decided per label, not per
    /// utterance: the owner's own backchannels often fall during their speech, and short echoed replies
    /// ("Yeah.") are often missing from their transcript, so words cannot match them. The owner, the label
    /// with the most speech while the call audio is quiet, is never dropped.
    static func echoLabels(me: [Utterance], themSound: SoundTimeline) -> Set<String> {
        guard themSound.coverage <= maximumSoundCoverage else { return [] }
        var talk: [String: (total: TimeInterval, overlap: TimeInterval)] = [:]
        for u in me {
            let length = max(0, u.end - u.start)
            talk[u.speakerLabel, default: (0, 0)].total += length
            talk[u.speakerLabel, default: (0, 0)].overlap += min(length, themSound.sound(from: u.start, to: u.end))
        }
        // Most quiet-time speech wins; on a tie (the call audio never stops), the one who talks most.
        func rank(_ t: (total: TimeInterval, overlap: TimeInterval)) -> (TimeInterval, TimeInterval) { (t.total - t.overlap, t.total) }
        guard let owner = talk.max(by: { rank($0.value) < rank($1.value) })?.key else { return [] }
        return Set(talk.filter { $0.key != owner && $0.value.total > 0 && $0.value.overlap / $0.value.total >= echoLabelOverlap }.keys)
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
        // With word times on both sides, a word is echo only if they said it at the same moment.
        if let myWords = m.words, overlapping.allSatisfy({ $0.words != nil }) {
            let x = timedWords(myWords)
            let y = overlapping.flatMap { timedWords($0.words!) }
            let matched = lcs(x, y) { $0.text == $1.text && abs($0.start - $1.start) <= echoDelay }
            return Double(matched) / Double(max(x.count, 1)) >= minimumSimilarity
        }
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

    /// Echo reaches the mic within a fraction of a second of the original word.
    static let echoDelay: TimeInterval = 0.5

    static func timedWords(_ w: [Word]) -> [Word] {
        w.flatMap { word in words(word.text).map { Word(text: $0, start: word.start, end: word.end) } }
    }

    static func lcs(_ x: [String], _ y: [String]) -> Int { lcs(x, y, ==) }

    static func lcs<T>(_ x: [T], _ y: [T], _ same: (T, T) -> Bool) -> Int {
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count {
                current[j] = same(x[i - 1], y[j - 1]) ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[y.count]
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
