import MossadCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The coach's findings as a stack of cards. A swipe to the right is yes; a swipe to the left is a plain no to
/// this one card. The card follows the pointer or the finger, tilts, and takes a tint that grows with the
/// distance; past the threshold a light tap says the answer will count, and the card leaves while the next one
/// rises from behind. The arrow keys and two small buttons do the same. "No, never again" is its own quiet
/// button on the card. After a no, one quiet line under the deck asks why; it never stands in the way.
struct FindingsDeck: View {
    /// A fixed state for a picture of the deck, in a preview only.
    struct Preview: Equatable {
        var drag: CGFloat = 0
        /// The line about the last no: `line` shows it, `open` shows its field.
        var why: Why?
        enum Why { case line, open }
    }

    let cards: [CoachFinding]
    /// The meeting a card is from, in the deck of all calls. Nil inside a meeting.
    var source: ((CoachFinding) -> String?)?
    var openSource: ((CoachFinding) -> Void)?
    /// Plays the card's moment. `playing` is the id of the card whose moment plays now.
    var play: ((CoachFinding) -> Void)?
    var playing: String?
    /// Shows the calm empty state when there is no card. Inside a meeting the deck is then not there at all.
    var showsEmpty = true
    /// Takes the arrow keys when the page opens. Off inside a meeting, where the keys belong to the page.
    var focusOnAppear = false
    var preview: Preview?
    let answer: (CoachFinding, FindingVerdict) -> Void
    let undo: (String) -> Void
    let explain: (String, String) -> Void

    private struct Flight: Equatable {
        var id: String
        var direction: CGFloat
    }

    private struct Answered: Equatable {
        var finding: CoachFinding
        var verdict: FindingVerdict
    }

    @State private var drag: CGSize = .zero
    @State private var flying: Flight?
    /// Cards answered here that the owner of `cards` did not take out yet.
    @State private var gone: [String] = []
    @State private var last: Answered?
    /// The side a card comes back from on Undo.
    @State private var returnEdge: Edge = .leading
    /// -1 or 1 while the card is past the threshold: a change is the tap.
    @State private var armed = 0
    @State private var answered = 0
    @State private var why: CoachFinding?
    @State private var writing = false
    @State private var note = ""
    @State private var saved = false
    @State private var whyTimer: Task<Void, Never>?
    @State private var previewed = false
    @FocusState private var deckFocused: Bool
    @FocusState private var noteFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Past this distance a release answers the card.
    static let threshold: CGFloat = 110
    /// The quiet line about a no stays this long when nobody opens it.
    static let whySeconds = 12.0
    #if os(iOS)
    static let cardWidth: CGFloat = 520
    static let cardMinHeight: CGFloat = 300
    #else
    static let cardWidth: CGFloat = 500
    static let cardMinHeight: CGFloat = 236
    #endif

    private var visible: [CoachFinding] { cards.filter { !gone.contains($0.id) } }
    private var spring: Animation? { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.76) }
    /// How far the top card is toward an answer, 0 to 1.
    private var progress: CGFloat { flying != nil ? 1 : min(1, abs(drag.width) / Self.threshold) }

    var body: some View {
        feedback(content)
            .onAppear { if focusOnAppear { deckFocused = true } }
            // When the cards are there: a view that waits in a task would keep the cards of its start.
            .onChange(of: cards.isEmpty, initial: true) { _, empty in if !empty { startPreview() } }
            .onDisappear { whyTimer?.cancel() }
    }

    private var content: some View {
        let visible = visible
        return VStack(spacing: Space.m) {
            if let top = visible.first {
                stack(top, visible)
                controls(top)
            } else if showsEmpty {
                FindingsEmpty(undo: emptyUndo)
            } else if last != nil {
                HStack(spacing: Space.s) {
                    Text("All answered.").foregroundStyle(Palette.secondary)
                    undoButton
                }
                .textRole(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            whyLine
        }
        .frame(maxWidth: Self.cardWidth)
        .animation(spring, value: visible.map(\.id))
        .onChange(of: cards.map(\.id)) { _, ids in forget(notIn: ids) }
    }

    private var emptyUndo: (() -> Void)? {
        guard last != nil else { return nil }
        return { takeBack() }
    }

    /// The light tap at the threshold, and the one at an answer.
    @ViewBuilder
    private func feedback(_ view: some View) -> some View {
        #if os(iOS)
        view
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now != 0 }
            .sensoryFeedback(.success, trigger: answered)
        #else
        view.onChange(of: armed) { _, now in if now != 0 { Haptic.threshold() } }
        #endif
    }

    private func startPreview() {
        guard let preview, !previewed else { return }
        previewed = true
        drag = CGSize(width: preview.drag, height: 0)
        guard let state = preview.why, let first = visible.first else { return }
        // As the owner does it: a no to the first card, then the line about it, then its field.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            commit(first, .no)
            guard state == .open else { return }
            try? await Task.sleep(for: .milliseconds(900))
            whyTimer?.cancel()
            writing = true
            note = "I gave the day in the email after the call."
        }
    }

    // MARK: The stack

    private func stack(_ top: CoachFinding, _ visible: [CoachFinding]) -> some View {
        // The top card gives the stack its size; the cards are drawn over it, so a card that leaves takes no room.
        card(top).hidden()
            .overlay {
                ZStack {
                    ForEach(Array(visible.prefix(3).enumerated()).reversed(), id: \.element.id) { depth, finding in
                        layer(finding, depth: depth)
                    }
                }
            }
            .padding(.bottom, 22)
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($deckFocused)
            // A click on the card gives the deck the arrow keys.
            .simultaneousGesture(TapGesture().onEnded { deckFocused = true })
            .onKeyPress(.leftArrow) { commit(top, .no); return .handled }
            .onKeyPress(.rightArrow) { commit(top, .yes); return .handled }
            #if os(macOS)
            .background {
                SwipeScroll { x in
                    guard flying == nil else { return }
                    deckFocused = true
                    move(to: CGSize(width: x, height: 0))
                } ended: { x, speed in
                    release(top, x: x, predicted: x + speed * 12)
                }
            }
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Yes") { commit(top, .yes) }
            .accessibilityAction(named: "No") { commit(top, .no) }
    }

    private func card(_ finding: CoachFinding, faded: CGFloat = 1) -> some View {
        FindingCard(finding: finding, source: source?(finding), openSource: openSource.map { open in { open(finding) } },
                    play: play.map { play in { play(finding) } }, isPlaying: playing == finding.id, never: { commit(finding, .never) })
            .opacity(faded)
            .frame(maxWidth: .infinity, minHeight: Self.cardMinHeight, alignment: .topLeading)
    }

    private func layer(_ finding: CoachFinding, depth: Int) -> some View {
        let top = depth == 0
        let flies = flying?.id == finding.id
        // The cards behind move up as the top card leaves.
        let place = CGFloat(depth) - (top ? 0 : progress)
        let x = flies ? (flying?.direction ?? 1) * 760 : (top ? drag.width : 0)
        let y = reduceMotion ? 0 : (flies ? 60 : (top ? drag.height * 0.22 : 0))
        let turn = reduceMotion || !top ? 0 : max(-14, min(14, x / 24))
        let shape = RoundedRectangle(cornerRadius: Radius.pane, style: .continuous)
        return card(finding, faded: top ? 1 : (depth == 1 ? progress : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.raised, in: shape)
            .overlay { if top { tint(x).clipShape(shape).allowsHitTesting(false) } }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
            // In the corner that the card's own words leave free.
            .overlay(alignment: .bottomTrailing) { if top { stamp(x) } }
            .shadow(color: .black.opacity(top ? 0.13 : 0.06), radius: top ? 18 : 8, y: top ? 9 : 4)
            .scaleEffect(1 - 0.05 * max(0, place), anchor: .bottom)
            .offset(y: 11 * max(0, place))
            .opacity(flies && reduceMotion ? 0 : 1)
            .rotationEffect(.degrees(turn), anchor: .bottom)
            .offset(x: x, y: y)
            .zIndex(Double(10 - depth))
            .allowsHitTesting(top && flying == nil)
            .accessibilityHidden(!top)
            .modifier(Dragging(on: top && flying == nil, changed: { move(to: $0) }, ended: { release(finding, x: $0.width, predicted: $1.width) }))
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: returnEdge).combined(with: .opacity), removal: .opacity))
    }

    /// Green for yes, a neutral wash for no: a no is not a mistake. It grows with the distance.
    private func tint(_ x: CGFloat) -> some View {
        let amount = min(1, abs(x) / Self.threshold)
        return (x >= 0 ? Palette.ok : Palette.secondary).opacity(Double(amount) * (x >= 0 ? 0.16 : 0.13))
    }

    private func stamp(_ x: CGFloat) -> some View {
        let amount = min(1, abs(x) / Self.threshold)
        let yes = x >= 0
        return Label(yes ? "Yes" : "No", systemImage: yes ? "checkmark" : "xmark")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(yes ? Palette.okText : Palette.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background((yes ? Palette.ok : Palette.secondary).opacity(0.14), in: Capsule())
            .overlay { Capsule().strokeBorder((yes ? Palette.ok : Palette.secondary).opacity(0.45), lineWidth: 1) }
            .padding(14)
            .opacity(abs(x) < 6 ? 0 : Double(amount))
            .scaleEffect(reduceMotion ? 1 : 0.9 + 0.1 * amount)
            .accessibilityHidden(true)
    }

    /// The owner of `cards` took an answered card out: it needs no mark here any more.
    private func forget(notIn ids: [String]) {
        let there = Set(ids)
        let kept: [String] = gone.filter { (id: String) -> Bool in there.contains(id) }
        if kept != gone { gone = kept }
    }

    // MARK: Moving and answering

    private func move(to translation: CGSize) {
        guard flying == nil else { return }
        drag = translation
        let now = abs(translation.width) >= Self.threshold ? (translation.width > 0 ? 1 : -1) : 0
        if now != armed { armed = now }
    }

    /// A release past the threshold, or a quick flick toward it, answers. Else the card springs back.
    private func release(_ finding: CoachFinding, x: CGFloat, predicted: CGFloat) {
        guard flying == nil else { return }
        let flick = abs(predicted) > Self.threshold * 2.4 && abs(x) > Self.threshold * 0.35 && (predicted > 0) == (x > 0)
        if abs(x) >= Self.threshold || flick {
            commit(finding, x > 0 ? .yes : .no)
        } else {
            armed = 0
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.36, dampingFraction: 0.62)) { drag = .zero }
        }
    }

    private func commit(_ finding: CoachFinding, _ verdict: FindingVerdict) {
        guard flying == nil, visible.first?.id == finding.id else { return }
        // The line about an earlier no goes when the owner answers again.
        hideWhy()
        let direction: CGFloat = verdict == .yes ? 1 : -1
        let finish = {
            gone.append(finding.id)
            flying = nil
            drag = .zero
            armed = 0
            answered += 1
            returnEdge = verdict == .yes ? .trailing : .leading
            last = Answered(finding: finding, verdict: verdict)
            Haptic.answered()
            answer(finding, verdict)
            if verdict == .no { askWhy(finding) }
        }
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.15)) { finish() }
            return
        }
        withAnimation(.easeIn(duration: 0.2)) { flying = Flight(id: finding.id, direction: direction) }
        Task {
            try? await Task.sleep(for: .milliseconds(170))
            withAnimation(spring) { finish() }
        }
    }

    private func takeBack() {
        guard let last else { return }
        hideWhy()
        withAnimation(spring) {
            gone.removeAll { $0 == last.finding.id }
            self.last = nil
        }
        undo(last.finding.id)
    }

    // MARK: Yes, No, Undo

    private func controls(_ top: CoachFinding) -> some View {
        HStack(spacing: Space.s) {
            Button { commit(top, .no) } label: { Label("No", systemImage: "arrow.left") }
                .buttonStyle(DeckButtonStyle(tint: Palette.secondary))
                .help("No to this card (Left Arrow)")
            Button { commit(top, .yes) } label: { Label("Yes", systemImage: "arrow.right").labelStyle(TrailingIconStyle()) }
                .buttonStyle(DeckButtonStyle(tint: Palette.okText))
                .help("Yes (Right Arrow)")
            #if os(macOS)
            Spacer(minLength: Space.s)
            if last != nil { undoButton.textRole(.secondary) }
            #endif
        }
    }

    private var undoButton: some View {
        Button(action: takeBack) { Label("Undo", systemImage: "arrow.uturn.backward") }
            .buttonStyle(QuietLinkStyle())
            .help("Take the last answer back")
    }

    // MARK: Why not

    /// One quiet line about the card that just got a no. It opens a field in place, waits a short time, and goes
    /// with the next answer. The room for it is always there, so the deck does not move.
    private var whyLine: some View {
        ZStack(alignment: .leading) {
            if let card = why {
                if saved {
                    Label("Saved. The coach reads it before its next review.", systemImage: "checkmark")
                        .foregroundStyle(Palette.secondary)
                        .transition(.opacity)
                } else if writing {
                    HStack(spacing: Space.s) {
                        TextField("Why not, in one short line", text: $note)
                            .textFieldStyle(.plain)
                            .focused($noteFocused)
                            .onSubmit { save(card) }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous))
                            .accessibilityLabel("Why you did not agree with \(FindingRules.shortTitle(card.text))")
                        Button("Save") { save(card) }
                            .buttonStyle(QuietLinkStyle(color: Palette.accent))
                            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button { withAnimation(spring) { hideWhy() } } label: { Image(systemName: "xmark") }
                            .buttonStyle(QuietLinkStyle())
                            .accessibilityLabel("Close")
                    }
                    .transition(.opacity)
                } else {
                    Button {
                        whyTimer?.cancel()
                        withAnimation(spring) { writing = true }
                        noteFocused = true
                    } label: {
                        Text("Why didn\u{2019}t you agree with \u{201C}\(FindingRules.shortTitle(card.text))\u{201D}?")
                            .lineLimit(1)
                    }
                    .buttonStyle(QuietLinkStyle())
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
                }
            }
        }
        .textRole(.secondary)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        #if os(iOS)
        // On the iPhone the two answers take the row: Undo sits here, at the right.
        .overlay(alignment: .trailing) { if last != nil, !writing, !visible.isEmpty { undoButton.textRole(.secondary) } }
        #endif
    }

    private func askWhy(_ card: CoachFinding) {
        why = card
        writing = false
        saved = false
        note = ""
        whyTimer?.cancel()
        whyTimer = Task {
            try? await Task.sleep(for: .seconds(Self.whySeconds))
            guard !Task.isCancelled, !writing else { return }
            withAnimation(.easeOut(duration: 0.3)) { why = nil }
        }
    }

    private func hideWhy() {
        whyTimer?.cancel()
        why = nil
        writing = false
        saved = false
        note = ""
    }

    private func save(_ card: CoachFinding) {
        let words = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        explain(card.id, words)
        withAnimation(spring) {
            writing = false
            saved = true
        }
        whyTimer?.cancel()
        whyTimer = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { hideWhy() }
        }
    }
}

// MARK: - The card

/// One finding: what it is, the words, the proof (a moment that plays, a number with its usual value), and the
/// quiet "No, never again".
struct FindingCard: View {
    let finding: CoachFinding
    var source: String?
    var openSource: (() -> Void)?
    var play: (() -> Void)?
    var isPlaying = false
    var never: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: 6) {
                Image(systemName: finding.kind.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(finding.kind.tint)
                Text(finding.kind.title).textRole(.label).foregroundStyle(finding.kind.tint)
                Spacer(minLength: Space.s)
                if let source {
                    Button { openSource?() } label: { Text(source).lineLimit(1) }
                        .buttonStyle(QuietLinkStyle())
                        .textRole(.secondary)
                        .disabled(openSource == nil)
                        .help("Open this meeting")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(finding.text).textRole(.lede).foregroundStyle(Palette.ink).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = finding.detail {
                    Text(detail).textRole(.body).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let name = finding.personName {
                    Label("About \(name)", systemImage: "person.crop.circle")
                        .textRole(.secondary).foregroundStyle(Palette.secondary)
                        .padding(.top, 2)
                }
            }
            proof
            if let say = finding.say {
                Text("Say: \u{201C}\(say)\u{201D}")
                    .textRole(.body).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.row - 2, style: .continuous))
            }
            Spacer(minLength: 0)
            HStack {
                if let never {
                    Button("No, never again", action: never)
                        .buttonStyle(QuietLinkStyle(color: Palette.tertiary))
                        .textRole(.secondary)
                        #if os(iOS)
                        .frame(minHeight: 36)
                        #endif
                        .help(finding.kind == .learning ? "The coach never asks this again" : finding.kind == .goalOffer ? "The coach never offers this goal again"
                              : "The coach never brings this up again. You can allow it again in Settings.")
                }
                Spacer()
            }
        }
        .padding(Space.l + 2)
        .accessibilityElement(children: .contain)
    }

    /// The proof: the words with a time that plays, and the measured number with what is usual.
    @ViewBuilder
    private var proof: some View {
        if finding.quote != nil || finding.at != nil || finding.number != nil || finding.usual != nil {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(finding.kind.tint.opacity(0.55)).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    if let quote = finding.quote {
                        Text("\u{201C}\(quote)\u{201D}").italic().textRole(.body).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let number = finding.number {
                        Text(number).textRole(.secondary).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let usual = finding.usual {
                        Text(usual).textRole(.secondary).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let at = finding.at {
                        Button { play?() } label: {
                            Label(coachClock(at), systemImage: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .foregroundStyle(play == nil ? Palette.secondary : Palette.accent)
                                .background(play == nil ? Palette.fill : Palette.accentTint, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(play == nil)
                        .help(isPlaying ? "Pause" : "Play this moment")
                        .accessibilityLabel(isPlaying ? "Pause" : "Play the moment at \(coachClock(at))")
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension CoachFinding.Kind {
    var symbol: String {
        switch self {
        case .didWell: "checkmark.circle.fill"
        case .missed: "circle.dashed"
        case .couldBeBetter: "arrow.up.forward.circle.fill"
        case .learning: "questionmark.bubble.fill"
        case .goalOffer: "scope"
        default: "circle"
        }
    }

    var tint: Color {
        switch self {
        case .didWell: Palette.okText
        case .missed: Palette.secondary
        default: Palette.accent
        }
    }
}

// MARK: - Empty

/// Nothing waits for an answer: the outline of the stack at rest, and one calm sentence.
struct FindingsEmpty: View {
    var undo: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.l) {
            ZStack {
                ForEach((0..<3).reversed(), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.tertiaryMark.opacity(0.55 - 0.16 * Double(i)), style: StrokeStyle(lineWidth: 1, dash: i == 0 ? [] : [3, 3]))
                        .background(i == 0 ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(width: 112 - CGFloat(i) * 10, height: 72)
                        .offset(y: CGFloat(i) * 8)
                }
                Image(systemName: "checkmark").font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.okText)
            }
            .frame(height: 92)
            .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text("Nothing to review").textRole(.headline).foregroundStyle(Palette.ink)
                Text("After a call the coach leaves a few cards here. Each one has a moment to play or a number.")
                    .textRole(.body).foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let undo {
                Button(action: undo) { Label("Undo the last answer", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(QuietLinkStyle())
                    .textRole(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxl)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Parts

/// The small Yes and No under the deck.
private struct DeckButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(iOS)
            // A whole row for two answers: each is a full touch target.
            .font(.system(size: TextRole.body.size, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            #else
            .font(.system(size: TextRole.secondary.size, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            #endif
            .foregroundStyle(tint)
            .background(configuration.isPressed ? Palette.bar : Palette.fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.5)
    }
}

/// A text button that stays out of the way until the pointer is on it.
struct QuietLinkStyle: ButtonStyle {
    var color: Color = Palette.secondary
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering && enabled ? Palette.ink : color)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct TrailingIconStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon
        }
    }
}

/// The drag of the top card: the mouse on the Mac, the finger on the iPhone. On the iPhone it runs next to the
/// page's scroll, and moves the card only when the finger first went sideways.
private struct Dragging: ViewModifier {
    let on: Bool
    let changed: (CGSize) -> Void
    let ended: (CGSize, CGSize) -> Void
    @State private var sideways: Bool?

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if sideways == nil { sideways = abs(value.translation.width) > abs(value.translation.height) }
                if sideways == true { changed(value.translation) }
            }
            .onEnded { value in
                if sideways == true { ended(value.translation, value.predictedEndTranslation) }
                sideways = nil
            }
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content.simultaneousGesture(gesture, isEnabled: on)
        #else
        content.gesture(gesture, isEnabled: on)
        #endif
    }
}

/// The light tap at the threshold and at an answer. The Mac's trackpad gives it; the iPhone uses `sensoryFeedback`.
enum Haptic {
    static func threshold() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }

    static func answered() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }
}

#if os(macOS)
/// A two-finger swipe on the trackpad over the deck moves the top card. Only a swipe that starts sideways is
/// taken; a scroll up or down goes to the page as before.
private struct SwipeScroll: NSViewRepresentable {
    let moved: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.moved = moved
        context.coordinator.ended = ended
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var moved: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat, CGFloat) -> Void = { _, _ in }
        private var monitor: Any?
        /// Nil until the swipe shows its direction; then true for sideways.
        private var sideways: Bool?
        private var total = CGPoint.zero
        private var speed: CGFloat = 0
        /// The glide after a swipe that was taken: it must not scroll the page.
        private var swallowGlide = false

        func start() {
            // A local monitor runs on the main thread.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let taken = MainActor.assumeIsolated { self?.take(event) ?? false }
                return taken ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func inside(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }

        /// True when the event belongs to a swipe of the card: the page does not get it.
        private func take(_ event: NSEvent) -> Bool {
            // A mouse wheel has no phases: it is never a swipe.
            guard event.hasPreciseScrollingDeltas else { return false }
            if !event.momentumPhase.isEmpty {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    let was = swallowGlide
                    swallowGlide = false
                    return was
                }
                return swallowGlide
            }
            let done = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            if event.phase.contains(.began) {
                sideways = nil
                total = .zero
                speed = 0
                swallowGlide = false
            }
            // A swipe that does not start over the deck is the page's.
            if sideways == nil, total == .zero, !inside(event) { sideways = false }
            if sideways == false {
                if done { sideways = nil }
                return false
            }
            // The card follows the fingers, with natural scrolling on or off.
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            total.x += dx
            total.y += dy
            if sideways == nil {
                guard abs(total.x) + abs(total.y) > 3 else { return true }
                sideways = abs(total.x) > abs(total.y) * 1.3
                if sideways == false { return false }
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                ended(total.x, speed)
                sideways = nil
                swallowGlide = true
                return true
            }
            speed = dx
            moved(total.x)
            return true
        }
    }
}
#endif
