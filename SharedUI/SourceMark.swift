import SwiftUI

/// "Gemini notes": a small quiet mark on a meeting that Mossad did not record but made from its notes.
struct SourceMark: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Rhythm.noteSize, weight: .semibold))
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Palette.fill, in: Capsule())
            .fixedSize()
            .accessibilityLabel("Made from \(text), not recorded")
    }
}
