import Foundation

/// The block structure of a summary. Inline Markdown such as `**bold**` stays in the strings for the UI to render.
public enum SummaryBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(String)
    case bullets([String])

    public static func parse(_ markdown: String) -> [SummaryBlock] {
        var blocks: [SummaryBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)) }
            paragraph = []
            bullets = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !paragraph.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else {
                if !bullets.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
