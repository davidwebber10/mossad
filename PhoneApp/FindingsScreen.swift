import MossadCore
import SwiftUI

/// The coach's findings of all calls as one deck, the newest call first. A swipe to the right is the card's first
/// answer (Useful, True, Take it on), a swipe to the left its second, for that one card. The play button opens the meeting at the moment: the audio stays on
/// the Mac.
struct FindingsScreen: View {
    @Environment(PhoneStore.self) private var store
    /// Closes the sheet this screen is in, before a meeting opens.
    var close: () -> Void = {}
    /// The page does not scroll, and the sheet does not close, while a card moves to the side.
    @State private var dragging = false
    /// The cards the owner saw in the deck: the row above the meetings shows again only for a new card.
    @AppStorage("findingsSeen") private var seen = ""

    /// Development hooks for screenshots: `MOSSAD_DECK_DRAG=<points>` holds the top card mid-drag,
    /// `MOSSAD_DECK_WHY=line|open|never` answers no (or never again) to the first card and shows the line about it.
    static var deckPreview: FindingsDeck.Preview? {
        let why: FindingsDeck.Preview.Why? = PhoneStore.hook("MOSSAD_DECK_WHY") == "open" ? .open : PhoneStore.hook("MOSSAD_DECK_WHY") == "line" ? .line : PhoneStore.hook("MOSSAD_DECK_WHY") == "never" ? .never : nil
        let drag = PhoneStore.hook("MOSSAD_DECK_DRAG").flatMap(Double.init) ?? 0
        return drag == 0 && why == nil ? nil : FindingsDeck.Preview(drag: drag, why: why)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                // The empty deck says it itself.
                if !store.findings.isEmpty {
                    Text("\(store.findings.count) to review").textRole(.secondary).foregroundStyle(Palette.secondary)
                }
                FindingsDeck(cards: store.findings, source: source, openSource: open, play: play, offersNever: offersNever,
                             preview: Self.deckPreview,
                             answer: { store.answerFinding($0, $1) }, undo: { store.takeBackFinding($0) },
                             explain: { store.explainFinding($0, note: $1) })
                    .frame(maxWidth: .infinity)
                Text("Useful and Not useful teach the coach what helps you; True and Not true correct what it believes; Take it on starts a goal. \u{201C}Never again\u{201D} stops a subject for good, and on praise only the praise; you can undo it in Coach \u{203A} Knowledge. At most two cards come from a call, and a card with no answer goes after two weeks.")
                    .textRole(.secondary).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xxl)
        }
        .scrollDisabled(dragging)
        .onPreferenceChange(DeckDragging.self) { dragging = $0 }
        .interactiveDismissDisabled(dragging)
        .phonePage()
        .navigationTitle("Findings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            store.refreshFindings()
            seen = store.findings.map(\.id).joined(separator: "\n")
        }
        .onChange(of: store.findings.map(\.id)) { _, ids in seen = (seen.split(separator: "\n").map(String.init) + ids).suffix(60).joined(separator: "\n") }
    }

    private func open(_ finding: CoachFinding) {
        close()
        store.openMeeting(finding.callID)
    }

    private func play(_ finding: CoachFinding) {
        close()
        store.showMoment(finding.callID, at: finding.at)
    }

    private func offersNever(_ finding: CoachFinding) -> Bool { FindingRules.offersNever(finding, profile: store.profile) }

    /// "Budget review · Nov 9": where the card is from.
    private func source(_ finding: CoachFinding) -> String? {
        let day = finding.date.formatted(.dateTime.month(.abbreviated).day())
        guard let title = store.meeting(finding.callID)?.title, !title.isEmpty else { return day }
        return "\(title) \u{00B7} \(day)"
    }
}
