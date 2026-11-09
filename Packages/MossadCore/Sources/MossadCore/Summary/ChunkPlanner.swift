import Foundation

/// Splits a transcript into parts that fit a small model's context. Parts end between lines, so a speaker's
/// turn stays whole unless the turn alone is too long; then it is split at words, each piece with its speaker.
public enum ChunkPlanner {
    /// A floor, so a large fixed prompt still leaves room for some transcript.
    static let minimumBudget = 256

    /// A safe guess when the model cannot count: about 3 characters to a token.
    static func estimate(_ text: String) -> Int { text.utf8.count / 3 + 1 }

    /// Room kept for the reply: a quarter of the context.
    static func replyReserve(context: Int) -> Int { context / 4 }

    /// Tokens left for transcript after the instructions, the schema, and the reply.
    static func budget(context: Int, fixed: Int, reply: Int) -> Int { max(minimumBudget, context - fixed - reply) }

    static func plan(_ lines: [String], budget: Int, tokens: (String) -> Int) -> [[String]] {
        var parts: [[String]] = []
        var current: [String] = []
        var used = 0
        for line in lines.flatMap({ split($0, budget: budget, tokens: tokens) }) {
            let t = tokens(line)
            if !current.isEmpty, used + t > budget {
                parts.append(current)
                current = []
                used = 0
            }
            current.append(line)
            used += t
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// A line within the budget as it is; a longer one in pieces of whole words, each with the line's
    /// "[HH:MM:SS] Name: " prefix.
    static func split(_ line: String, budget: Int, tokens: (String) -> Int) -> [String] {
        guard tokens(line) > budget else { return [line] }
        let prefix = line.firstMatch(of: #/^\[[0-9:]+\] [^:]{1,80}: /#).map { String($0.output) } ?? ""
        var pieces: [String] = []
        var words: [Substring] = []
        for word in line.dropFirst(prefix.count).split(separator: " ") {
            let candidate = prefix + (words + [word]).joined(separator: " ")
            if !words.isEmpty, tokens(candidate) > budget {
                pieces.append(prefix + words.joined(separator: " "))
                words = []
            }
            words.append(word)
        }
        if !words.isEmpty { pieces.append(prefix + words.joined(separator: " ")) }
        return pieces
    }
}
