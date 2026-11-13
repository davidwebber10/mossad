import MossadCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The coach's findings as a stack of cards. Each card asks one question (`Kind.question`) and names its two
/// answers in words: Useful and Not useful, True and Not true, Take it on and Not now. A swipe to the right is the
/// first; a swipe to the left is the second, for this one card. The card follows the pointer or the finger, tilts, and takes a tint that grows with the
/// distance; past the threshold a light tap says the answer will count. At the release the answer is saved, and
/// the card leaves with the speed of the hand while the next one rises from behind. The arrow keys and two small
/// buttons do the same. "Never again" is its own quiet button on the card. After a no, one quiet line under
/// the deck asks why; it never stands in the way.
struct FindingsDeck: View {
    /// A fixed state for a picture of the deck, in a preview only.
    struct Preview: Equatable {
        var drag: CGFloat = 0
        /// The line about the last no: `line` shows it, `open` shows its field, `never` answers "Never again"
        /// and shows what it blocked.
        var why: Why?
        enum Why { case line, open, never }
    }

    let cards: [CoachFinding]
    /// The meeting a card is from, in the deck of all calls. Nil inside a meeting.
    var source: ((CoachFinding) -> String?)?
    var openSource: ((CoachFinding) -> Void)?
    /// Plays the card's moment. `playing` is the id of the card whose moment plays now.
    var play: ((CoachFinding) -> Void)?
    var playing: String?
    /// Stops the moment that a card started: when a card is answered, leaves the top, or the deck closes.
    var stopPlaying: (() -> Void)?
    /// False inside a meeting: the audio is the meeting's player, which the owner may follow on another tab.
    var stopsOnClose = true
    /// Whether that player plays now, when the deck shares it: a pause there forgets the card, so later audio that
    /// the owner starts is never stopped by an answer.
    var playerRunning: Bool?
    /// Whether a card offers "Never again". Not on a card of the active focus.
    var offersNever: (CoachFinding) -> Bool = { _ in true }
    /// Shows the calm empty state when there is no card. Inside a meeting the deck is then not there at all.
    var showsEmpty = true
    /// Takes the arrow keys when the page opens. Off inside a meeting, where the keys belong to the page.
    var focusOnAppear = false
    var preview: Preview?
    let answer: (CoachFinding, FindingVerdict) -> Void
    let undo: (String) -> Void
    let explain: (String, String) -> Void

    /// A card on its way out: a copy, so the answer is saved at the release and the flight is only a picture.
    private struct Flight: Equatable {
        var card: CoachFinding
        var direction: CGFloat
        var from: CGSize
        var launched = false
    }

    private struct Answered: Equatable {
        var finding: CoachFinding
        var verdict: FindingVerdict
    }

    /// Changes with each answer: the tap it gives.
    private struct Tick: Equatable {
        var count = 0
        var yes = false
    }

    @State private var drag: CGSize = .zero
    @State private var flight: Flight?
    /// Cards answered here that the owner of `cards` did not take out yet.
    @State private var gone: [String] = []
    @State private var last: Answered?
    /// The side a card comes back from on Undo.
    @State private var returnEdge: Edge = .leading
    /// -1 or 1 while the card is past the threshold: a change is the tap.
    @State private var armed = 0
    @State private var tick = Tick()
    @State private var why: CoachFinding?
    /// The card that just got "Never again": one line says what it blocked.
    @State private var blocked: CoachFinding?
    @State private var writing = false
    @State private var note = ""
    @State private var saved = false
    @State private var whyTimer: Task<Void, Never>?
    @State private var previewed = false
    @State private var playback = DeckPlayback()
    @FocusState private var deckFocused: Bool
    @FocusState private var noteFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Past this distance a release answers the card.
    static let threshold = CGFloat(DeckRelease.threshold)
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
    /// How far the top card is toward an answer, 0 to 1. The card behind rises as the top card leaves.
    private var progress: CGFloat { min(1, abs(drag.width) / Self.threshold) }

    var body: some View {
        feedback(content)
            .onAppear { if focusOnAppear { deckFocused = true } }
            // When the cards are there: a view that waits in a task would keep the cards of its start.
            .onChange(of: cards.isEmpty, initial: true) { _, empty in if !empty { startPreview() } }
            .onDisappear {
                whyTimer?.cancel()
                if playback.closed() { stopPlaying?() }
            }
            .onChange(of: visible.first?.id) { _, top in if playback.topChanged(to: top) { stopPlaying?() } }
            .onChange(of: playerRunning) { _, running in if running == false { playback.paused() } }
            .onAppear { playback.stopsOnClose = stopsOnClose }
            // The page and the sheet do not scroll or close while a card moves to the side.
            .preference(key: DeckDragging.self, value: drag != .zero)
    }

    private var content: some View {
        let visible = visible
        return VStack(spacing: Space.m) {
            if let top = visible.first {
                stack(top, visible)
                controls(top)
            } else if showsEmpty {
                FindingsEmpty(undo: emptyUndo)
                    .overlay { if let flight { flying(flight) } }
            } else if last != nil {
                HStack(spacing: Space.s) {
                    Text("All answered.").foregroundStyle(Palette.secondary)
                    undoButton
                }
                .textRole(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { if let flight { flying(flight).frame(height: Self.cardMinHeight) } }
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

    /// The light tap at the threshold, and the one at an answer: a success for yes, a soft tap for a no.
    @ViewBuilder
    private func feedback(_ view: some View) -> some View {
        #if os(iOS)
        view
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now != 0 }
            .sensoryFeedback(trigger: tick) { _, now in now.count == 0 ? nil : now.yes ? .success : .impact(flexibility: .soft, intensity: 0.6) }
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
            commit(first, state == .never ? .never : .no)
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
                    if let flight { flying(flight) }
                }
            }
            .padding(.bottom, 22)
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($deckFocused)
            // A click on the card gives the deck the arrow keys.
            .simultaneousGesture(TapGesture().onEnded { deckFocused = true })
            // A key that is held answers one card, not one card after the other.
            .onKeyPress(.leftArrow, phases: .down) { _ in commit(top, .no); return .handled }
            .onKeyPress(.rightArrow, phases: .down) { _ in commit(top, .yes); return .handled }
            #if os(macOS)
            .background {
                SwipeScroll { x in
                    deckFocused = true
                    move(to: CGSize(width: x, height: 0))
                } ended: { x, speed in
                    release(top, x: x, predicted: x + speed * 12, velocity: speed * 90)
                } cancelled: {
                    release(top, x: 0, predicted: 0, velocity: 0)
                }
            }
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text(top.kind.yes)) { commit(top, .yes) }
            .accessibilityAction(named: Text(top.kind.no)) { commit(top, .no) }
    }

    private func card(_ finding: CoachFinding, faded: CGFloat = 1, quiet: CGFloat = 0) -> some View {
        FindingCard(finding: finding, source: source?(finding), openSource: openSource.map { open in { open(finding) } },
                    play: play.map { play in {
                        if playing == finding.id { playback.paused() } else { playback.started(finding.id) }
                        play(finding)
                    } }, isPlaying: playing == finding.id,
                    never: offersNever(finding) ? { commit(finding, .never) } : nil, quiet: quiet)
            .opacity(faded)
            .frame(maxWidth: .infinity, minHeight: Self.cardMinHeight, alignment: .topLeading)
    }

    private func face(_ finding: CoachFinding, top: Bool, x: CGFloat, faded: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.pane, style: .continuous)
        let amount = min(1, abs(x) / Self.threshold)
        return card(finding, faded: faded, quiet: top ? amount : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.raised, in: shape)
            .overlay { if top { tint(x).clipShape(shape).allowsHitTesting(false) } }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
            #if os(macOS)
            // Where the arrow keys go.
            .overlay { if top, deckFocused { shape.strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1.5).allowsHitTesting(false) } }
            #endif
            // Each mark on the side of the card that stays on the screen: "Useful" on the left in a swipe to the
            // right, "Not useful" on the right in a swipe to the left. "Never again" steps back while it shows.
            .overlay(alignment: x >= 0 ? .bottomLeading : .bottomTrailing) { if top { stamp(x, finding.kind) } }
            .shadow(color: .black.opacity(top ? 0.13 : 0.06), radius: top ? 18 : 8, y: top ? 9 : 4)
    }

    private func layer(_ finding: CoachFinding, depth: Int) -> some View {
        let top = depth == 0
        // The cards behind move up as the top card leaves.
        let place = CGFloat(depth) - (top ? 0 : progress)
        let x = top ? drag.width : 0
        let y = reduceMotion ? 0 : (top ? drag.height * 0.22 : 0)
        let turn = reduceMotion || !top ? 0 : max(-14, min(14, x / 24))
        return face(finding, top: top, x: x, faded: top ? 1 : (depth == 1 ? progress : 0))
            .scaleEffect(1 - 0.05 * max(0, place), anchor: .bottom)
            .offset(y: 11 * max(0, place))
            .rotationEffect(.degrees(turn), anchor: .bottom)
            .offset(x: x, y: y)
            .zIndex(Double(10 - depth))
            .allowsHitTesting(top)
            .accessibilityHidden(!top)
            .modifier(Dragging(on: top, changed: { move(to: $0) }, ended: { release(finding, x: $0.width, predicted: $1.width, velocity: $2) }))
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: returnEdge).combined(with: .opacity), removal: .identity))
    }

    /// The copy of an answered card on its way out, from where the hand left it.
    private func flying(_ f: Flight) -> some View {
        let x = f.launched ? f.direction * 760 : f.from.width
        let y = f.launched ? 60 : f.from.height * 0.22
        return face(f.card, top: true, x: f.launched ? f.direction * Self.threshold : f.from.width, faded: 1)
            .rotationEffect(.degrees(max(-14, min(14, x / 24))), anchor: .bottom)
            .offset(x: x, y: y)
            .zIndex(20)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Green for yes, a neutral wash for no: a no is not a mistake. It grows with the distance.
    private func tint(_ x: CGFloat) -> some View {
        let amount = min(1, abs(x) / Self.threshold)
        return (x >= 0 ? Palette.ok : Palette.secondary).opacity(Double(amount) * (x >= 0 ? 0.16 : 0.13))
    }

    private func stamp(_ x: CGFloat, _ kind: CoachFinding.Kind) -> some View {
        let amount = min(1, abs(x) / Self.threshold)
        let yes = x >= 0
        return Label(yes ? kind.yes : kind.no, systemImage: yes ? "checkmark" : "xmark")
            .labelStyle(.titleAndIcon)
            .font(.system(size: Rhythm.secondarySize, weight: .semibold))
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
        drag = translation
        let now = abs(translation.width) >= Self.threshold ? (translation.width > 0 ? 1 : -1) : 0
        if now != armed { armed = now }
    }

    /// A release past the threshold, or a quick flick toward it, answers. Else the card springs back.
    private func release(_ finding: CoachFinding, x: CGFloat, predicted: CGFloat, velocity: CGFloat) {
        if let verdict = DeckRelease.verdict(x: Double(x), predicted: Double(predicted)) {
            commit(finding, verdict, velocity: velocity)
        } else {
            armed = 0
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.36, dampingFraction: 0.62)) { drag = .zero }
        }
    }

    /// Saves the answer now, at the release, and lets a copy of the card fly out with the speed of the hand.
    private func commit(_ finding: CoachFinding, _ verdict: FindingVerdict, velocity: CGFloat = 0) {
        guard visible.first?.id == finding.id else { return }
        // A reason that was typed and not saved is not lost: it is saved with the next answer.
        let typed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if writing, let card = why, !typed.isEmpty { explain(card.id, typed) }
        hideWhy()
        let from = drag
        let direction: CGFloat = verdict == .yes ? 1 : -1
        returnEdge = verdict == .yes ? .trailing : .leading
        if !reduceMotion { flight = Flight(card: finding, direction: direction, from: from) }
        withAnimation(spring) {
            gone.append(finding.id)
            drag = .zero
        }
        armed = 0
        tick = Tick(count: tick.count + 1, yes: verdict == .yes)
        last = Answered(finding: finding, verdict: verdict)
        Haptic.answered()
        if playback.answered(finding.id) { stopPlaying?() }
        answer(finding, verdict)
        if verdict == .no { askWhy(finding) }
        if verdict == .never { showBlocked(finding) }
        guard !reduceMotion else { return }
        let id = finding.id
        // The rest of the way at the speed of the hand: a spring that starts as fast as the release.
        let distance = max(1, 760 - abs(from.width))
        let start = max(2.2, abs(velocity) / distance)
        DispatchQueue.main.async {
            withAnimation(.interpolatingSpring(mass: 1, stiffness: 140, damping: 22, initialVelocity: start)) { flight?.launched = true }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if flight?.card.id == id { flight = nil }
        }
    }

    private func takeBack() {
        guard let last else { return }
        hideWhy()
        flight = nil
        withAnimation(spring) {
            gone.removeAll { $0 == last.finding.id }
            self.last = nil
        }
        undo(last.finding.id)
    }

    // MARK: The question, its two answers, Undo

    private func controls(_ top: CoachFinding) -> some View {
        let buttons = HStack(spacing: Space.s) {
            Button { commit(top, .no) } label: { Label(top.kind.no, systemImage: "arrow.left") }
                .buttonStyle(DeckButtonStyle(tint: Palette.secondary))
                .help("\(top.kind.no) (Left Arrow)")
            Button { commit(top, .yes) } label: { Label(top.kind.yes, systemImage: "arrow.right").labelStyle(TrailingIconStyle()) }
                .buttonStyle(DeckButtonStyle(tint: Palette.okText))
                .help("\(top.kind.yes) (Right Arrow)")
        }
        let question = Text(top.kind.question).textRole(.secondary).foregroundStyle(Palette.secondary)
        #if os(macOS)
        return HStack(spacing: Space.m) {
            question.lineLimit(1).layoutPriority(1)
            buttons
            Spacer(minLength: Space.s)
            if last != nil, why == nil, blocked == nil { undoButton.textRole(.secondary) }
        }
        #else
        return VStack(alignment: .leading, spacing: Space.s) {
            question
            buttons
        }
        #endif
    }

    private var undoButton: some View {
        Button(action: takeBack) { Label("Undo", systemImage: "arrow.uturn.backward") }
            .buttonStyle(QuietLinkStyle())
            .help("Take the last answer back")
    }

    // MARK: Why not

    /// One quiet line about the card that just got a no, or about what "Never again" blocked. It opens a
    /// field in place, waits a short time, and goes with the next answer. The room for it is always there, so the
    /// deck does not move. Undo sits at its right.
    private var whyLine: some View {
        HStack(spacing: Space.s) {
            ZStack(alignment: .leading) {
                if let card = blocked {
                    Text(blockedText(card)).lineLimit(1).truncationMode(.tail).foregroundStyle(Palette.secondary)
                        .transition(.opacity)
                } else if let card = why {
                    if saved {
                        Label("Saved. The coach reads it before its next review.", systemImage: "checkmark")
                            .lineLimit(1)
                            .foregroundStyle(Palette.secondary)
                            .transition(.opacity)
                    } else if writing {
                        HStack(spacing: Space.s) {
                            TextField("Why not, in one short line", text: $note)
                                .textFieldStyle(.plain)
                                .focused($noteFocused)
                                .onSubmit { save(card) }
                                #if os(macOS)
                                .onExitCommand { withAnimation(spring) { hideWhy() } }
                                #endif
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous))
                                .accessibilityLabel(card.kind.whyNot(FindingRules.shortTitle(card.text)))
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
                            Text(card.kind.whyNot(FindingRules.shortTitle(card.text, words: Self.whyWords)))
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .buttonStyle(QuietLinkStyle())
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if last != nil, !writing, !visible.isEmpty, why != nil || blocked != nil || isPhone {
                undoButton.fixedSize()
            }
        }
        .textRole(.secondary)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    #if os(iOS)
    private var isPhone: Bool { true }
    /// Fewer words of the card on the narrow screen, so the line and Undo both fit.
    private static let whyWords = 3
    #else
    private var isPhone: Bool { false }
    private static let whyWords = 6
    #endif

    private func blockedText(_ card: CoachFinding) -> String {
        switch card.kind {
        case .learning: "Not true, never asked again: \u{201C}\(FindingRules.shortTitle(card.text, words: Self.whyWords))\u{201D}"
        case .trait: "Not true of \(card.personName ?? "them"), never shown: \u{201C}\(FindingRules.shortTitle(card.text, words: Self.whyWords))\u{201D}"
        case .goalOffer: "This goal is not offered again."
        case .didWell: "No more praise for: \(CoachSkill.subject(of: card.skill))"
        default: "Never again: \(CoachSkill.subject(of: card.skill))"
        }
    }

    private func askWhy(_ card: CoachFinding) {
        why = card
        writing = false
        saved = false
        note = ""
        startTimer()
    }

    private func showBlocked(_ card: CoachFinding) {
        blocked = card
        startTimer()
    }

    private func startTimer() {
        whyTimer?.cancel()
        whyTimer = Task {
            try? await Task.sleep(for: .seconds(Self.whySeconds))
            guard !Task.isCancelled, !writing else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                why = nil
                blocked = nil
            }
        }
    }

    private func hideWhy() {
        whyTimer?.cancel()
        why = nil
        blocked = nil
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

/// True while the top card of a deck moves to the side: the page around it does not scroll, and a sheet does not
/// close.
struct DeckDragging: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// MARK: - The card

/// One finding: what it is, the words, why it matters and what that stands on, the proof (a moment that plays,
/// a number with its usual value), and the quiet "Never again".
struct FindingCard: View {
    let finding: CoachFinding
    var source: String?
    var openSource: (() -> Void)?
    var play: (() -> Void)?
    var isPlaying = false
    var never: (() -> Void)?
    /// 0 to 1 while the card is dragged: "Never again" steps back for the mark of the answer.
    var quiet: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: 6) {
                Image(systemName: finding.kind.symbol).font(.system(size: Rhythm.secondarySize, weight: .semibold)).foregroundStyle(finding.kind.tint)
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
                if let why = finding.why {
                    (Text("Why it matters: ").foregroundStyle(Palette.secondary) + Text(why).foregroundStyle(Palette.ink))
                        .textRole(.body).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if let basis = finding.basis {
                    Label(basis, systemImage: finding.basisIsGoal ? "scope" : "tag")
                        .textRole(.secondary).foregroundStyle(Palette.secondary)
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
                    Button(finding.kind.never, action: never)
                        .buttonStyle(QuietLinkStyle(color: Palette.tertiary))
                        .textRole(.secondary)
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #endif
                        .opacity(1 - Double(min(1, quiet * 2)))
                        .help(finding.kind == .learning ? "Marks this not true, and the coach never asks it again. You can undo it in Coach \u{203A} Knowledge."
                              : finding.kind == .trait ? "Marks this not true of this person: the trait never shows. You can undo it in Coach \u{203A} Knowledge."
                              : finding.kind == .goalOffer ? "The coach never offers this goal again. You can undo it in Coach \u{203A} Knowledge."
                              : finding.kind == .didWell ? "The coach never praises this again; its advice can still come. You can undo it in Coach \u{203A} Knowledge."
                              : "The coach never brings this up again. You can undo it in Coach \u{203A} Knowledge.")
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
                                .font(.system(size: Rhythm.secondarySize, weight: .semibold)).monospacedDigit()
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
        case .trait: "person.crop.circle.badge.questionmark"
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
                Image(systemName: "checkmark").font(.system(size: Rhythm.ledeSize, weight: .medium)).foregroundStyle(Palette.okText)
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

/// The two small answers under the deck.
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
/// page's scroll, and moves the card only when the finger first went sideways. On the Mac there is no scroll to
/// keep: the card follows the mouse from the start.
private struct Dragging: ViewModifier {
    let on: Bool
    let changed: (CGSize) -> Void
    /// The translation, the predicted end, and the speed to the side in points a second.
    let ended: (CGSize, CGSize, CGFloat) -> Void
    @State private var sideways: Bool?

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                #if os(iOS)
                if sideways == nil { sideways = abs(value.translation.width) > abs(value.translation.height) }
                #else
                sideways = true
                #endif
                if sideways == true { changed(value.translation) }
            }
            .onEnded { value in
                if sideways == true { ended(value.translation, value.predictedEndTranslation, value.velocity.width) }
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
/// A two-finger swipe on the trackpad over the deck moves the top card. The rules are `ScrollSwipe`: only a
/// swipe that starts sideways over the part of the deck that shows is taken, and a scroll up or down goes to the
/// page as before, each of its events.
private struct SwipeScroll: NSViewRepresentable {
    let moved: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void
    let cancelled: () -> Void

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
        context.coordinator.cancelled = cancelled
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var moved: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat, CGFloat) -> Void = { _, _ in }
        var cancelled: () -> Void = {}
        private var monitor: Any?
        private var swipe = ScrollSwipe()

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

        /// Over the part of the deck that shows: a deck that scrolled under the band of a meeting is not there.
        private func inside(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            return view.visibleRect.contains(view.convert(event.locationInWindow, from: nil))
        }

        private static func phase(_ p: NSEvent.Phase) -> ScrollSwipe.Phase {
            if p.contains(.began) { return .began }
            if p.contains(.ended) { return .ended }
            if p.contains(.cancelled) { return .cancelled }
            if p.contains(.changed) || p.contains(.stationary) || p.contains(.mayBegin) { return p.contains(.mayBegin) ? .none : .changed }
            return .none
        }

        /// True when the event belongs to a swipe of the card: the page does not get it.
        private func take(_ event: NSEvent) -> Bool {
            // A mouse wheel has no phases: it is never a swipe.
            guard event.hasPreciseScrollingDeltas else { return false }
            let phase = Self.phase(event.phase)
            // The card follows the fingers, with natural scrolling on or off.
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let outcome = swipe.handle(ScrollSwipe.Event(phase: phase, momentum: Self.phase(event.momentumPhase), dx: Double(dx), dy: Double(event.scrollingDeltaY),
                                                         inside: phase == .began ? inside(event) : true))
            switch outcome.effect {
            case .move(let x): moved(CGFloat(x))
            case .release(let x, let speed): ended(CGFloat(x), CGFloat(speed))
            case .cancel: cancelled()
            case nil: break
            }
            return outcome.taken
        }
    }
}
#endif
