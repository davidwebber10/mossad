import Foundation

enum Titles {
    static let limit = 60

    /// One line, no quotes or closing full stop, cut at a word within the limit.
    static func clean(_ raw: String) -> String {
        var t = raw.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’ "))
        while t.hasSuffix(".") { t.removeLast() }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’ "))
        guard t.count > limit else { return t }
        let cut = String(t.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space])
        }
        return cut
    }
}

/// A provisional title for a call that is still running, from its first minutes of live transcript.
/// The summary's title replaces it after the call.
public struct LiveTitler: Sendable {
    private let llm: any LanguageModel

    public init(llm: any LanguageModel) { self.llm = llm }

    static let system = """
    You name meetings from the start of a transcript. Write a title of at most \(Titles.limit) characters that \
    names the topic; for a meeting of two or three people, add who it was with, by first name, such as \
    "Freight model review with Dana". No quotes, no full stop.
    """

    /// Nil when the transcript is empty, the request fails, or the model gives a blank title.
    public func title(transcript: String) async -> String? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        struct Output: Decodable { let title: String }
        let schema = Schema.object(["title": Schema.string])
        do {
            let out = try await llm.json(system: Self.system, user: "Transcript so far:\n\(transcript)", schema: schema,
                                         effort: .low, purpose: .summary, as: Output.self)
            return Titles.clean(out.title).nonBlank
        } catch {
            Log.error("Live title failed: \(error)")
            return nil
        }
    }
}
