import SwiftUI

extension View {
    /// A page's content under its toolbar row: at most `width` inside the page gutter, centered past it, so a wide
    /// window never leaves the right side empty. Narrower than that, it fills the column as before. The widths are
    /// `Rhythm.readingWidth` for reading pages, `wideWidth` for charts, `tableMax` for tables, `gridMax` for grids.
    func pageColumn(_ width: CGFloat, top: CGFloat = Detail.bodyTop, bottom: CGFloat = Rhythm.pageBottom) -> some View {
        frame(maxWidth: width, alignment: .leading)
            .padding(.horizontal, Rhythm.gutter)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
