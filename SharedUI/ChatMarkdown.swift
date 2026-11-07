import SwiftUI

/// A chat answer's Markdown as real blocks: paragraphs, bullet and numbered lists with hanging indents, and
/// headings. Inline links, bold, and italics keep working; mossad:// links open the meeting.
struct ChatMarkdown: View {
    let text: String
    var bodyFont: Font = .body
    /// mossad:// time links as quiet chips, as the chats on the Mac show them.
    var timeChips = false

    enum Block: Equatable {
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case heading(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s):
                    Text(inline(s)).font(bodyFont).lineSpacing(3)
                case .heading(let s):
                    Text(inline(s)).font(bodyFont.weight(.semibold)).padding(.top, 4)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(bodyFont).foregroundStyle(.secondary)
                        Text(inline(s)).font(bodyFont).lineSpacing(3)
                    }
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(n).font(bodyFont).foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(s)).font(bodyFont).lineSpacing(3)
                    }
                }
            }
        }
        .tint(.accentColor)
    }

    private func inline(_ s: String) -> AttributedString {
        let text = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return timeChips ? Self.chips(text) : text
    }

    /// Text cannot draw a capsule inside a line, so a chip is the link on the fill with no-break spaces each side, so it never splits.
    private static func chips(_ s: AttributedString) -> AttributedString {
        var out = AttributedString()
        for run in s.runs {
            var piece = AttributedString(s[run.range])
            if let url = run.link, url.scheme == "mossad", isMoment(url) {
                piece = AttributedString("\u{00A0}\u{00A0}") + piece + AttributedString("\u{00A0}\u{00A0}")
                piece.link = url
                piece.backgroundColor = Palette.fill
                piece.foregroundColor = Palette.secondary
                #if os(iOS)
                // Dynamic Type on the phone; the Mac canvas sets the chip at 11 pt.
                piece.font = .footnote.monospacedDigit()
                #else
                piece.font = .system(size: 11).monospacedDigit()
                #endif
            }
            out += piece
        }
        return out
    }

    /// A link to a moment (`?t=`) is a chip; a link to a whole meeting stays a link, as its text is the title.
    private static func isMoment(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "t" } == true
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); out.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); out.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else if line.hasPrefix("#") {
                flush(); out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }
}
