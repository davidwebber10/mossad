import MossadCore
import SwiftUI

/// A page's own search: its text, whether the field is out, and a count that asks the field to take the focus.
/// The field shows while it is out or holds text, so a search set from elsewhere (a tag click) shows too.
struct ListSearchState: Equatable {
    var query = ""
    var isOpen = false
    var focusTick = 0

    var isShown: Bool { isOpen || !query.isEmpty }
    var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    mutating func open() {
        isOpen = true
        focusTick += 1
    }

    mutating func close() {
        isOpen = false
        query = ""
    }
}

/// The magnifying glass beside a list's title: a quiet mark, like the filter's, that brings the field down under
/// the title. Command-F does the same while it is on screen (see `AppController.find`).
struct ListSearchToggle: View {
    @EnvironmentObject var controller: AppController
    @Binding var state: ListSearchState
    @State private var hovering = false

    var body: some View {
        let active = !state.trimmed.isEmpty
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if state.isShown { state.close() } else { state.open() }
            }
        } label: {
            IconImage(.search, size: 14)
                .foregroundStyle(active ? Palette.accent : hovering || state.isShown ? Palette.ink : Palette.secondary)
                .frame(width: 28, height: 24)
                .background(Capsule().fill(active ? Palette.accentTint : hovering || state.isShown ? Palette.fill : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(state.isShown ? "Close the search" : "Search this list (⌘F)")
        .accessibilityLabel(state.isShown ? "Close the search" : "Search this list")
        .onAppear {
            controller.listSearches += 1
            // Development hook for screenshots: MOSSAD_LIST_QUERY types into the page's list search.
            if DevHooks.preview, state.query.isEmpty, let q = ProcessInfo.processInfo.environment["MOSSAD_LIST_QUERY"] { state.query = q }
        }
        .onDisappear { controller.listSearches -= 1 }
        .onChange(of: controller.findRequest) { _, _ in
            withAnimation(.snappy(duration: 0.2)) { state.open() }
        }
    }
}

/// The field that comes down under a list's title. Escape or the cross closes it and clears it.
struct ListSearchField: View {
    @EnvironmentObject var controller: AppController
    let prompt: String
    @Binding var state: ListSearchState
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.s) {
            IconImage(.search, size: 13).foregroundStyle(Palette.tertiaryMark)
            TextField(prompt, text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: Rhythm.bodySize))
                .foregroundStyle(Palette.ink)
                .focused($focused)
                .onExitCommand(perform: close)
                // Return or Down Arrow goes to the rows, where the arrow keys move.
                .onSubmit { controller.listFocusRequest += 1 }
                .onKeyPress(.downArrow) {
                    controller.listFocusRequest += 1
                    return .handled
                }
                .accessibilityLabel(prompt)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.tertiaryMark)
            }
            .buttonStyle(.plain)
            .help("Close the search (Esc)")
            .accessibilityLabel("Close the search")
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Palette.accent.opacity(0.55) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { if state.isOpen { focus() } }
        .onChange(of: state.focusTick) { _, _ in focus() }
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { state.close() }
        focused = false
        controller.listFocusRequest += 1
    }

    /// A field that has just come into the view does not always take the focus at once on macOS.
    private func focus() {
        focused = true
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            if !focused { focused = true }
        }
    }
}

/// Why a row is in a searched list, under the row: the field's name or the speaker and time, then the matched
/// words in bold.
struct ListMatchLine: View {
    let match: ListMatch
    var lines = 2

    var body: some View {
        if let context = match.context {
            (Text(lead).foregroundStyle(Palette.tertiary) + Text(context.boldMatches(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary))
                .font(.system(size: Rhythm.secondarySize))
                .lineLimit(lines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(lead)\(context.text)")
        }
    }

    private var lead: String { match.lead }
}

extension ListMatch {
    /// "Note: ", "Dana Reyes 7:17: ": what comes before the matched text in a row's line.
    var lead: String {
        switch source {
        case .title: ""
        case .field(let label): "\(label): "
        case .transcript(let speaker): time.map { "\(speaker) \(clock($0)): " } ?? "\(speaker): "
        }
    }

    /// The line under a row as one text: the lead, then the context with its matched words in bold.
    func line(size: CGFloat) -> AttributedString? {
        guard let context else { return nil }
        var lead = AttributedString(lead)
        lead.foregroundColor = Palette.tertiary
        return lead + context.boldMatches(size: size)
    }
}

extension SearchText {
    /// The text with the matched words in a bold font of their own: a weight set on the `Text` wins over an inline
    /// bold.
    func boldMatches(size: CGFloat, design: Font.Design = .default) -> AttributedString {
        var out = attributed
        for run in out.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            out[run.range].font = .system(size: size, weight: .bold, design: design)
        }
        return out
    }
}
