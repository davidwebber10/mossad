import Foundation

/// Reads who shares the screen from the labels a call app shows. Only a label that names the person counts.
public enum PresenterLabel {
    /// Each pattern is the whole label of a share indicator. A sentence that only holds such words (a chat line,
    /// a slide's title) does not fit.
    static let patterns = [
        #"^You are viewing (.+?)['’]s? (?:screen|application|window|whiteboard)\.?$"#,
        #"^Viewing (.+?)['’]s? (?:screen|application|window)\.?$"#,
        #"^(.+?) is (?:presenting|sharing|sharing (?:their|a|the) (?:screen|window|tab))\.?$"#,
        #"^(.+?) has started (?:screen sharing|presenting|sharing)\.?$"#,
        #"^Content shared by (.+?)\.?$"#,
        #"^Shared by (.+?)\.?$"#,
        #"^(.+?) \((?:Presenting|Presentation)\)$"#,
    ]

    public static func name(in labels: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for label in labels {
                let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let range = NSRange(text.startIndex..., in: text)
                guard text.count <= 120, let match = regex.firstMatch(in: text, range: range),
                      let found = Range(match.range(at: 1), in: text) else { continue }
                let name = text[found].trimmingCharacters(in: .whitespacesAndNewlines)
                if isName(name) { return name }
            }
        }
        return nil
    }

    /// True when a label may name a presenter, so the walk can skip all other text.
    public static func mayName(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("present") || l.contains("viewing") || l.contains("sharing") || l.contains("shared by")
    }

    /// The owner's own share is not someone's name, and a name is a few words.
    static func isName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard !name.isEmpty, name.count <= 60, name.split(separator: " ").count <= 5 else { return false }
        let notNames: Set<String> = ["you", "your", "someone", "a participant", "participant", "nobody", "no one", "stop", "share", "start",
                                     "who", "this", "that", "it", "he", "she", "they", "everyone", "anyone", "the host", "host"]
        // A name starts with a capital letter, and each of its words is a word, not a number.
        return !notNames.contains(lower) && name.first?.isUppercase == true
            && name.split(separator: " ").allSatisfy { $0.contains(where: \.isLetter) }
    }

    /// The known person this name is, in that person's own spelling: the same name without case, or the one known
    /// person whose first and last name it gives. Otherwise the name as the app showed it.
    public static func resolve(_ name: String, known: [String]) -> String {
        let key = name.lowercased()
        if let same = known.first(where: { $0.lowercased() == key }) { return same }
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let first = parts.first, let last = parts.last else { return name }
        let fits = known.filter { k in
            let p = k.lowercased().split(separator: " ")
            return p.count >= 2 && p.first == first && p.last == last
        }
        return fits.count == 1 ? fits[0] : name
    }
}
