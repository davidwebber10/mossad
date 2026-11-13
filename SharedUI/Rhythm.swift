import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The reading rhythm: text sizes, the gaps between lines, rows, blocks, and sections, the reading measure, and the
/// page layout under a band. Every reading view takes its sizes and gaps from here; a literal gap in a view is a
/// defect. The steps grow so each level reads as its own: a row's second line is closer than the next line of
/// text, which is closer than the next row, then the next block, then the next section.
enum Rhythm {
    // MARK: Text

    /// Text that is read: a summary, a decision, an action item, a chat answer.
    #if os(iOS)
    static let readingSize: CGFloat = 15
    static let secondarySize: CGFloat = 13
    #else
    static let readingSize: CGFloat = 14
    static let secondarySize: CGFloat = 12
    #endif
    /// The space between the lines of reading text.
    static let readingLineGap: CGFloat = 5
    /// The one sentence that leads a page, such as "In one line".
    static let leadSize: CGFloat = 16
    /// Text under or beside reading text: an owner, an address, a caption, a time.
    static let secondaryLineGap: CGFloat = 3
    /// The smallest text: a step under an answer, a chip.
    static let noteSize: CGFloat = 11

    /// Interface text that is scanned, not read: a list row's title, a setting, a control's label.
    #if os(iOS)
    static let bodySize: CGFloat = 15
    #else
    static let bodySize: CGFloat = 13
    #endif
    /// A group's heading inside a page, and a small figure.
    static let headingSize: CGFloat = 15
    /// A page's second heading (`TextRole.lede`).
    static let ledeSize = TextRole.lede.size
    /// A large number in a row of figures.
    static let figureSize: CGFloat = 20
    /// A page title (`TextRole.title`) and the display size (`TextRole.display`).
    static let titleSize = TextRole.title.size
    static let displaySize = TextRole.display.size

    static var reading: Font { .system(size: readingSize) }
    static var secondary: Font { .system(size: secondarySize) }
    static var body: Font { .system(size: bodySize) }
    static var note: Font { .system(size: noteSize) }

    // MARK: Gaps

    /// A row and its own second line (a task and its owner), so the two read as a pair.
    static let pairGap: CGFloat = 4
    /// Between the small parts of one item: a label over its control, a row of chips over the next, a heading over
    /// its list.
    static let itemGap: CGFloat = 8
    /// Between the rows of a list. At least about 60% of a line's pitch more than the line gap, so a wrapped row
    /// never reads as two rows.
    static let rowGap: CGFloat = 14
    /// Between the blocks of one section: paragraphs, a list after a paragraph.
    static let blockGap: CGFloat = 14
    /// Between the groups of one section or card: a card's header and its body, two cards side by side.
    static let groupGap: CGFloat = 20
    /// Between the sections of a page.
    static let sectionGap: CGFloat = 28
    /// Between a section's label column and its content.
    static let labelGap = Detail.labelGap

    // MARK: Lists

    /// A row of the list column: its padding above and below, and at its sides.
    static let listRowPadding: CGFloat = 10
    static let listRowInset: CGFloat = 10
    /// A group header of a list (a day): the room above it, less for the first, and the pair gap to its first row.
    static let listHeaderTop = rowGap
    static let listHeaderTopFirst: CGFloat = 10
    static let listHeaderBottom = pairGap

    // MARK: Measure and layout

    /// The widest line of reading text.
    static let measure: CGFloat = 680
    /// A tab's reading content: the label column, its gap, and the measure. It sits centered under the tabs.
    static var readingWidth: CGFloat { Detail.labelGutter + measure }
    /// A tab whose content needs room (charts, a grid of screens): today's column.
    static let wideWidth = Detail.columnMax
    /// A band (title, lanes, player) stretches with the window up to this, so lanes stay readable on a wide display.
    static let bandMax: CGFloat = 1600
    /// The page's side gutter, for the band and the content.
    static let gutter = Detail.gutter
    /// Under the tabs that hang from the band, before a tab's content.
    static let tabContentTop: CGFloat = 32
    /// After the last section, so it does not sit on the window's edge.
    static let pageBottom = Space.xxl

    // MARK: Baselines

    /// How far to move a section label down so its baseline meets the first line of content set at `size`.
    static func labelOffset(toContent size: CGFloat, weight: PlatformFont.Weight = .regular) -> CGFloat {
        let label = PlatformFont.systemFont(ofSize: TextRole.label.size, weight: .semibold)
        let content = PlatformFont.systemFont(ofSize: size, weight: weight)
        return max(0, (content.ascender - label.ascender).rounded(.toNearestOrAwayFromZero))
    }

    /// From the middle of a line's capitals down to its baseline, to center a mark on the first line of a row.
    static func capHalf(_ size: CGFloat) -> CGFloat { PlatformFont.systemFont(ofSize: size).capHeight / 2 }

    /// The distance from a line's top to the middle of its capitals, to center a mark (a ring, a bar) on a line.
    static func capCenter(_ size: CGFloat) -> CGFloat {
        let font = PlatformFont.systemFont(ofSize: size)
        return font.ascender - font.capHeight / 2
    }
}

#if canImport(AppKit)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif

extension View {
    /// Reading text: the size and the line gap.
    func readingText() -> some View { font(Rhythm.reading).lineSpacing(Rhythm.readingLineGap) }

    /// Secondary text: the size and its line gap. The color stays with the caller.
    func secondaryText() -> some View { font(Rhythm.secondary).lineSpacing(Rhythm.secondaryLineGap) }

    /// The small-caps label of a section.
    func sectionLabel() -> some View { textRole(.label).foregroundStyle(Palette.secondary) }
}
