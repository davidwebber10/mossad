import MossadCore
import SwiftUI

/// The coach's findings of all calls as one deck, the newest call first. A swipe to the right is yes, a swipe to
/// the left is a plain no to that one card. The play button opens the meeting at the moment: the audio stays on
/// the Mac.
struct FindingsScreen: View {
    @Environment(PhoneStore.self) private var store
    /// Closes the sheet this screen is in, before a meeting opens.
    var close: () -> Void = {}

    /// Development hooks for screenshots: `MOSSAD_DECK_DRAG=<points>` holds the top card mid-drag,
    /// `MOSSAD_DECK_WHY=line|open` answers no to the first card and shows the line about it.
    static var deckPreview: FindingsDeck.Preview? {
        let why: FindingsDeck.Preview.Why? = PhoneStore.hook("MOSSAD_DECK_WHY") == "open" ? .open : PhoneStore.hook("MOSSAD_DECK_WHY") == "line" ? .line : nil
        let drag = PhoneStore.hook("MOSSAD_DECK_DRAG").flatMap(Double.init) ?? 0
        return drag == 0 && why == nil ? nil : FindingsDeck.Preview(drag: drag, why: why)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                Text(store.findings.isEmpty ? "Nothing to review" : "\(store.findings.count) to review")
                    .textRole(.secondary).foregroundStyle(Palette.secondary)
                FindingsDeck(cards: store.findings, source: source,
                             openSource: { finding in
                                 close()
                                 store.openMeeting(finding.callID)
                             },
                             play: { finding in
                                 close()
                                 store.showMoment(finding.callID, at: finding.at)
                             },
                             preview: Self.deckPreview,
                             answer: { store.answerFinding($0, $1) }, undo: { store.takeBackFinding($0) },
                             explain: { store.explainFinding($0, note: $1) })
                    .frame(maxWidth: .infinity)
                Text("Yes and no teach the coach what is useful to you. \u{201C}No, never again\u{201D} stops a subject for good; you can allow it again in the Mac\u{2019}s Settings. A card with no answer goes after two weeks.")
                    .textRole(.secondary).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xxl)
        }
        .phonePage()
        .navigationTitle("Findings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { store.refreshFindings() }
    }

    /// "Budget review · Nov 9": where the card is from.
    private func source(_ finding: CoachFinding) -> String? {
        let day = finding.date.formatted(.dateTime.month(.abbreviated).day())
        guard let title = store.meeting(finding.callID)?.title, !title.isEmpty else { return day }
        return "\(title) \u{00B7} \(day)"
    }
}
