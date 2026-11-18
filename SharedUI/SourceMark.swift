import SwiftUI

/// "Gemini notes": a small quiet mark on a meeting that Mossad did not record but made from its notes. "From your
/// directory" on a person whom the Gemini people step made.
struct SourceMark: View {
    let text: String
    /// What VoiceOver says; a meeting's source by default.
    var spoken: String?

    var body: some View {
        Text(text)
            .font(.system(size: Rhythm.noteSize, weight: .semibold))
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Palette.fill, in: Capsule())
            .fixedSize()
            .accessibilityLabel(spoken ?? "Made from \(text), not recorded")
    }
}
