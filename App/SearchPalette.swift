import MossadCore
import SwiftUI

/// The palette's measures. The Mac alone draws it, so they live here rather than in the shared tokens.
private enum PaletteMetrics {
    static let width: CGFloat = 660
    /// From the window's top edge: below the toolbar row's controls.
    static let top: CGFloat = 56
    static let fieldHeight: CGFloat = 56
    static let fieldText: CGFloat = 17
    static let fieldIcon: CGFloat = 18
    static let inset: CGFloat = 8
    static let maxResults: CGFloat = 470
    static let leading: CGFloat = 28
    static let topHitLeading: CGFloat = 34
    static let footerHeight: CGFloat = 34
    /// Over the glass: results are read, so the page under them must not show through as text.
    static let veil = 0.78
}

/// Command-K: a floating glass panel near the top of the window with one field and every kind of result under it,
/// in the engine's groups. The arrows move across groups, Tab jumps to the next group, Return opens.
struct SearchPalette: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: SearchModel
    @State private var selection: String?
    /// The arrows scroll the list; a row that slides under a resting pointer must not take the selection back.
    @State private var keyedAt = Date.distantPast
    @FocusState private var fieldFocused: Bool
    /// The window the palette sits in, so its key monitor takes keys only from there.
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmed: String { model.query.trimmingCharacters(in: .whitespaces) }
    /// The suggestions until the first answer for a typed query arrives, so nothing flashes empty on the first key.
    private var showsSuggestions: Bool { trimmed.isEmpty || model.answered.isEmpty }
    private var list: SearchList { showsSuggestions ? model.suggestionList : model.list }
    private var noResults: Bool { !showsSuggestions && model.list.sections.isEmpty && model.answered == model.query }

    var body: some View {
        ZStack(alignment: .top) {
            // A light veil over the window: a click outside closes the palette.
            (scheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.1))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            panel
                .padding(.top, PaletteMetrics.top)
                .padding(.horizontal, 40)
        }
        .background(WindowReader { window = $0 })
        .defaultFocus($fieldFocused, true)
        .onAppear {
            fieldFocused = true
            selection = list.first
            startKeys()
        }
        .onDisappear(perform: stopKeys)
        // A focus set as an overlay first appears does not always take on macOS; set it again once it is on screen.
        .task {
            for delay in [30, 150] {
                try? await Task.sleep(for: .milliseconds(delay))
                if !fieldFocused { fieldFocused = true }
            }
        }
        .onChange(of: model.list) { old, new in
            // A new answer selects its first row; an expanded meeting keeps the row where the "more" row was.
            if let id = selection, id.hasPrefix("more:"), let i = old.rowIDs.firstIndex(of: id), new.rowIDs.count > i {
                selection = new.rowIDs[i]
            } else if selection.map({ new.row($0) == nil }) ?? true || old.rowIDs.first != new.rowIDs.first {
                selection = new.first
            }
            if !trimmed.isEmpty { AccessibilityNotification.Announcement(new.announcement).post() }
        }
        .onChange(of: showsSuggestions) { _, _ in selection = list.first }
        // The suggestions can arrive after the palette opens, when the index is still being built.
        .onChange(of: model.suggestions) { _, _ in
            if showsSuggestions, selection.map({ list.row($0) == nil }) ?? true { selection = list.first }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            if !list.sections.isEmpty || noResults || !model.isReady {
                Hairline()
                results
            }
            Hairline()
            footer
        }
        .frame(maxWidth: PaletteMetrics.width)
        .background(Palette.surface.opacity(PaletteMetrics.veil))
        .clipShape(RoundedRectangle(cornerRadius: Radius.pane, style: .continuous))
        .mossadGlass(cornerRadius: Radius.pane)
        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.18), radius: 30, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            IconImage(.search, size: PaletteMetrics.fieldIcon).foregroundStyle(Palette.tertiaryMark)
            TextField("Search meetings, people, transcripts, and tasks", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: PaletteMetrics.fieldText))
                .foregroundStyle(Palette.ink)
                .focused($fieldFocused)
                .accessibilityLabel("Search everything")
                .onChange(of: model.query) { _, _ in model.search() }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.tertiaryMark)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: PaletteMetrics.fieldHeight)
    }

    private func key(_ id: String?) {
        guard let id else { return }
        keyedAt = Date()
        selection = id
    }

    // MARK: Keys

    /// The palette's keys come from a local monitor rather than the field's key handlers: AppKit's key view loop
    /// takes Tab, and Command-Return or a focus that did not take never reach the field. The monitor sees every
    /// key of the window first, while the palette is open and no sheet is over it.
    private func startKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let host = window ?? NSApp.mainWindow, event.window === host, host.attachedSheet == nil else { return false }
        let editor = host.firstResponder as? NSTextView
        let flags = event.modifierFlags
        if let action = PaletteKey(keyCode: event.keyCode, shift: flags.contains(.shift), command: flags.contains(.command),
                                   option: flags.contains(.option), control: flags.contains(.control),
                                   composing: editor?.hasMarkedText() ?? false) {
            switch action {
            case .move(let by): key(list.moved(selection, by: by))
            case .nextGroup(let backward): key(list.nextSection(after: selection, backward: backward))
            case .open(let transcript): openSelection(transcript: transcript)
            case .close: close()
            }
            return true
        }
        // Typing while the field lost the focus goes to the field, not to the page under the veil.
        if !fieldFocused, flags.intersection([.command, .control, .option]).isEmpty, editor?.hasMarkedText() != true,
           let typed = event.characters, !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
           !(0xF700...0xF8FF).contains(typed.unicodeScalars.first!.value) {
            model.query += typed
            fieldFocused = true
            return true
        }
        return false
    }

    // MARK: Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.isReady, model.list.sections.isEmpty, model.suggestions == .empty {
                        status("Reading your meetings…")
                    } else if noResults {
                        status("Nothing matches “\(trimmed)”.")
                    }
                    ForEach(Array(list.sections.enumerated()), id: \.element.id) { i, section in
                        PaletteHeader(title: section.title, first: i == 0)
                        ForEach(section.rows) { row in
                            rowView(row, top: section.group == .topHit)
                                .id(row.id)
                        }
                    }
                }
                .padding(PaletteMetrics.inset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: PaletteMetrics.maxResults)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { _, id in
                guard let id, Date().timeIntervalSince(keyedAt) < 0.2 else { return }
                if reduceMotion { proxy.scrollTo(id) } else { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            .padding(.horizontal, 10).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: SearchList.Row, top: Bool) -> some View {
        let selected = selection == row.id
        PaletteRow(selected: selected, top: top, select: {
            guard Date().timeIntervalSince(keyedAt) > 0.4 else { return }
            selection = row.id
        }, open: {
            selection = row.id
            open(row, transcript: NSEvent.modifierFlags.contains(.command))
        }) {
            switch row {
            case .hit(let hit): HitContent(hit: hit, top: top, selected: selected)
            case .more(_, let count): MoreContent(count: count)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 14) {
            if showsSuggestions {
                Text(hint).lineLimit(1).truncationMode(.tail)
            } else {
                keyHint("↑↓", "move")
                keyHint("↩", "open")
                keyHint("⌘↩", "transcript")
                keyHint("⇥", "next group")
            }
            Spacer(minLength: 8)
            keyHint("esc", "close")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.tertiary)
        .padding(.horizontal, 18)
        .frame(height: PaletteMetrics.footerHeight)
    }

    /// "Type #Budget to see a tag’s meetings, @Mike for a person’s": with the owner's own most used tag and person.
    private var hint: String {
        let tag = model.suggestions.tags.first.map { $0.replacingOccurrences(of: " ", with: "") } ?? "tag"
        let person = model.suggestions.people.first.map { String($0.name.text.split(separator: " ").first ?? "") } ?? "name"
        return "Type #\(tag) for a tag’s meetings, @\(person) for a person’s"
    }

    private func keyHint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold).foregroundStyle(Palette.secondary)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func openSelection(transcript: Bool) {
        guard let id = selection ?? list.first, let row = list.row(id) else { return }
        open(row, transcript: transcript)
    }

    private func open(_ row: SearchList.Row, transcript: Bool) {
        switch row {
        case .hit(let hit): controller.openResult(hit, transcript: transcript)
        case .more(let callID, _): model.expand(callID)
        }
    }

    private func close() { model.isOpen = false }
}

/// "TOP HIT", "MEETINGS": the list columns' group header, in the label role.
private struct PaletteHeader: View {
    let title: String
    let first: Bool

    var body: some View {
        Text(title)
            .textRole(.label)
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, first ? 6 : 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The list's row: its padding, the quiet selection fill, hover selects and a click opens.
private struct PaletteRow<Content: View>: View {
    let selected: Bool
    let top: Bool
    let select: () -> Void
    let open: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, top ? 11 : 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .onHover { if $0 { select() } }
            .onTapGesture(perform: open)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, open)
    }
}

/// One result: a mark in the leading column, the matched text with its words in bold, quiet details under it, and a
/// number on the right.
private struct HitContent: View {
    let hit: SearchHit
    let top: Bool
    let selected: Bool

    private var leading: CGFloat { top ? PaletteMetrics.topHitLeading : PaletteMetrics.leading }
    private var titleSize: CGFloat { top ? 15 : 13 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            mark.frame(width: leading, height: top ? 34 : 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) { lines }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.secondary)
                .fixedSize()
                .padding(.top, top ? 3 : 1)
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch hit {
        case .meeting(let m): PlatformDot(platform: m.platform, size: top ? 10 : 8)
        case .person(let p): PersonMark(name: p.name.text, size: top ? 34 : 24, isOwner: p.isOwner)
        case .moment: IconImage(.waveform, size: top ? 18 : 15).foregroundStyle(Palette.accent)
        case .outcome(let o): IconImage(o.kind == .decision ? .check : .note, size: top ? 18 : 15).foregroundStyle(Palette.accent)
        case .task(let t):
            Circle().strokeBorder(t.isDone ? Palette.ok : Palette.ring, lineWidth: 1.5)
                .frame(width: top ? 18 : 15, height: top ? 18 : 15)
        case .chat: IconImage(.sparkle, size: top ? 18 : 15).foregroundStyle(Palette.accent)
        }
    }

    @ViewBuilder
    private var lines: some View {
        switch hit {
        case .meeting(let m):
            title(m.title)
            if let context = m.context {
                // The tag or person that matched, with its words in bold.
                Text("\(dateText(m.start)) · \(context.attributed)")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            } else {
                detail([dateText(m.start), m.kind].compactMap { $0 })
            }
        case .person(let p):
            title(p.name)
            detail([p.email ?? (p.isOwner ? "You" : nil), p.lastMet.map { "Last met \(dateText($0))" }].compactMap { $0 })
        case .moment(let m):
            HStack(spacing: 0) {
                Text(m.meetingTitle).fontWeight(.medium).foregroundStyle(Palette.ink).lineLimit(1).layoutPriority(-1)
                Text(" · \(m.speaker) · \(clock(m.time))").foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .font(.system(size: top ? 13 : 12))
            snippet(m.snippet)
        case .outcome(let o):
            title(o.text, lines: 2)
            detail([o.kind == .decision ? "Decision" : "Action item", o.meetingTitle, dateText(o.meetingStart)])
        case .task(let t):
            title(t.text, lines: 2)
            detail([t.to.map { "To \($0)" }, t.callTitle, t.isDone ? "Done" : nil].compactMap { $0 })
        case .chat(let c):
            title(c.title)
            if let s = c.snippet { snippet(s) }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch hit {
        case .meeting(let m): Text(durationLabel(m.end.timeIntervalSince(m.start)))
        case .person(let p): Text(p.meetings == 1 ? "1 meeting" : "\(p.meetings) meetings")
        case .moment(let m): Text(dateText(m.meetingStart))
        case .outcome(let o): if let t = o.time { Text(clock(t)) }
        case .task(let t): if let due = t.due { Text("Due \(dateText(due))") }
        case .chat(let c): Text(dateText(c.updated))
        }
    }

    private func title(_ text: SearchText, lines: Int = 1) -> some View {
        // Medium, not semibold, on the top hit: the matched words are bold and must still stand out.
        Text(emphasized(text, size: titleSize))
            .font(.system(size: titleSize, weight: top ? .medium : .regular))
            .foregroundStyle(Palette.ink)
            .lineLimit(lines)
            .truncationMode(.tail)
    }

    private func snippet(_ text: SearchText) -> some View {
        Text(emphasized(text, size: top ? 13 : 12.5))
            .font(.system(size: top ? 13 : 12.5))
            .foregroundStyle(Palette.ink.opacity(0.88))
            .lineLimit(2)
            .lineSpacing(1.5)
    }

    /// A font with a weight set on the Text wins over the inline bold, so the matched runs get a bold font of their own.
    private func emphasized(_ text: SearchText, size: CGFloat) -> AttributedString {
        var out = text.attributed
        for run in out.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            out[run.range].font = .system(size: size, weight: .bold)
        }
        return out
    }

    @ViewBuilder
    private func detail(_ parts: [String]) -> some View {
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
        }
    }

    /// "Today", "Yesterday", "Nov 3", or "Nov 3, 2025" for another year.
    private func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// "2 more in this meeting": opens the rest of the meeting's moments in place.
private struct MoreContent: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: PaletteMetrics.leading, height: 1)
            Text("\(count) more in this meeting")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accent)
            IconImage(.chevronDown, size: 12).foregroundStyle(Palette.accent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) more in this meeting")
        .accessibilityHint("Shows them here")
    }
}

/// Reports the window a view sits in, once it has one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Reader(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Later, not during the view update that moved it.
            guard let window else { return }
            DispatchQueue.main.async { [found] in found(window) }
        }
    }
}
