import MossadCore
import SwiftUI

/// A chat answer's Markdown as real blocks (`ChatBlocks`): headings, paragraphs, lists with hanging indents, quotes
/// from a transcript with the speaker and the time, code, and tables. Inline links, bold, italics, and code keep
/// working; a link to a moment is a small chip, and mossad:// links open the meeting. A half-written answer keeps
/// its form, so it reads the same while it streams.
struct ChatMarkdown: View {
    let text: String
    var bodyFont: Font = .body
    /// mossad:// time links as small chips, as the chats on the Mac show them.
    var timeChips = false
    /// The meeting a chat is about: a bare "[12:04]" becomes a chip to that moment.
    var callID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatBlocks.parse(ChatBlocks.linkTimes(text, callID: callID)).enumerated()), id: \.offset) { i, block in
                view(block, first: i == 0)
            }
        }
        .tint(Palette.accent)
    }

    @ViewBuilder
    private func view(_ block: ChatBlock, first: Bool) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s)).font(bodyFont).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(inline(s)).font(headingFont(level)).foregroundStyle(Palette.ink)
                .padding(.top, first ? 0 : 6)
                .accessibilityAddTraits(.isHeader)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker).font(bodyFont).monospacedDigit().foregroundStyle(Palette.tertiary)
                            .frame(minWidth: ordered ? 16 : 8, alignment: .trailing)
                        Text(inline(item.text)).font(bodyFont).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 20)
                }
            }
        case .quote(let q):
            QuoteBlock(quote: q, bodyFont: bodyFont, text: inline(q.text))
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(codeFont).foregroundStyle(Palette.ink).textSelection(.enabled).fixedSize()
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .table(let header, let rows):
            TableBlock(header: header.map(inline), rows: rows.map { $0.map(inline) }, bodyFont: bodyFont)
        case .rule:
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        #if os(iOS)
        level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : bodyFont.weight(.semibold)
        #else
        .system(size: level == 1 ? 17 : level == 2 ? 15 : 13.5, weight: .semibold)
        #endif
    }

    private var codeFont: Font {
        #if os(iOS)
        .footnote.monospaced()
        #else
        .system(size: 12, design: .monospaced)
        #endif
    }

    private func inline(_ s: String) -> AttributedString {
        var text = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].backgroundColor = Palette.fill
        }
        return timeChips ? Self.chips(text) : text
    }

    /// Text cannot draw a capsule inside a line, so a chip is the link on a tint with no-break spaces each side, so
    /// it never splits.
    private static func chips(_ s: AttributedString) -> AttributedString {
        var out = AttributedString()
        for run in s.runs {
            var piece = AttributedString(s[run.range])
            if let url = run.link, url.scheme == "mossad", isMoment(url) {
                piece = AttributedString("\u{00A0}") + piece + AttributedString("\u{00A0}")
                piece.link = url
                piece.backgroundColor = Palette.accentTint
                piece.foregroundColor = Palette.accent
                #if os(iOS)
                piece.font = .footnote.monospacedDigit().weight(.medium)
                #else
                piece.font = .system(size: 11, weight: .medium).monospacedDigit()
                #endif
            }
            out += piece
        }
        return out
    }

    /// A link to a moment (`?t=`) is a chip; a link to a whole meeting stays a link, as its text is the title.
    static func isMoment(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "t" } == true
    }
}

/// A line quoted from a transcript: a quiet block with who said it and the time as a chip that opens the moment.
private struct QuoteBlock: View {
    let quote: ChatQuote
    let bodyFont: Font
    let text: AttributedString
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(Palette.accent.opacity(0.45)).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                if quote.speaker != nil || quote.time != nil {
                    HStack(spacing: 6) {
                        if let speaker = quote.speaker {
                            Text(speaker).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                        }
                        if let time = quote.time {
                            TimeChip(time: time) { if let link = quote.link.flatMap(URL.init(string:)) { openURL(link) } }
                                .disabled(quote.link == nil)
                        }
                    }
                }
                Text(text).font(bodyFont).foregroundStyle(Palette.ink).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10).padding(.trailing, 12).padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The time of a moment as a small capsule.
struct TimeChip: View {
    let time: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(time).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Palette.accentTint, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play from \(time)")
    }
}

/// A Markdown table: the header on a hairline, then the rows, scrolling sideways when it is wide.
private struct TableBlock: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let bodyFont: Font

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                        Text(h).font(bodyFont.weight(.semibold)).foregroundStyle(Palette.secondary)
                    }
                }
                Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { i in
                            Text(i < row.count ? row[i] : "").font(bodyFont).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}
