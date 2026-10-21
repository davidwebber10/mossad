import Foundation

/// Transcript order for reading: a long line is cut where another speaker cuts in, using word times,
/// so a short "Yeah." appears where it was said and not after the whole statement.
public enum Transcript {
    public static func interleaved(_ utterances: [Utterance]) -> [Utterance] {
        var result: [Utterance] = []
        for u in utterances {
            guard let words = u.words, words.count > 1 else { result.append(u); continue }
            let cuts = utterances.filter { $0.speakerKey != u.speakerKey && $0.start > u.start && $0.start < u.end }.map(\.start).sorted()
            guard !cuts.isEmpty else { result.append(u); continue }
            var piece: [Word] = []
            var next = cuts.makeIterator()
            var cut = next.next()
            for w in words {
                while let c = cut, w.start >= c {
                    if !piece.isEmpty { result.append(line(u, piece)) }
                    piece = []
                    cut = next.next()
                }
                piece.append(w)
            }
            if !piece.isEmpty { result.append(line(u, piece)) }
        }
        // Stable for equal starts: the original order wins.
        return result.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    private static func line(_ u: Utterance, _ words: [Word]) -> Utterance {
        var piece = u
        piece.start = words.first!.start
        piece.end = words.last!.end
        piece.text = words.map(\.text).joined(separator: " ")
        piece.words = words
        return piece
    }
}
