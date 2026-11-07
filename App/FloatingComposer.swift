import SwiftUI

/// The canvas's composer, on the Chat page and in a meeting's chat: a 46 pt glass field with a quiet 1 pt ring,
/// a floating shadow, and a solid accent send circle. Send stays solid when there is nothing to send, as the canvas
/// draws it; the caller's send ignores an empty question.
struct FloatingComposer<Leading: View>: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var hasLeading = false
    let send: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Detail.composerHeight / 2, style: .continuous)
        HStack(alignment: .bottom, spacing: 10) {
            leading
            TextField(prompt, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...6)
                .padding(.vertical, 8)
                .frame(minHeight: Detail.composerSend)
                .focused(focused)
                .onSubmit(send)
            Button(action: send) {
                IconImage(.send, size: 14)
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: Detail.composerSend, height: Detail.composerSend)
                    .background(Palette.accentFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
        }
        .padding(.leading, hasLeading ? 12 : 18).padding(.trailing, 6).padding(.vertical, 6)
        .frame(minHeight: Detail.composerHeight)
        .background(.ultraThinMaterial, in: shape)
        .chromeGlass(in: shape, shadow: .floating)
    }
}

extension FloatingComposer where Leading == EmptyView {
    init(prompt: String, text: Binding<String>, focused: FocusState<Bool>.Binding, send: @escaping () -> Void) {
        self.init(prompt: prompt, text: text, focused: focused, send: send) { EmptyView() }
    }
}

extension View {
    /// Floats the composer centered at the bottom of the page, 16 pt up, as the canvas places it.
    func floatingComposer(_ composer: some View) -> some View {
        overlay(alignment: .bottom) {
            composer
                .frame(maxWidth: Detail.composerWidth)
                .padding(.horizontal, Detail.gutter).padding(.bottom, Space.l).padding(.top, 6)
                .frame(maxWidth: .infinity)
        }
    }
}
