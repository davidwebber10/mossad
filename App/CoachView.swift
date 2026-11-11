import MossadCore
import SwiftUI

/// The Coach page: the findings of all calls as one deck, the newest call first. Each card has a moment to play
/// or a number with its usual value. The owner's answers train the coach.
struct CoachView: View {
    @EnvironmentObject var controller: AppController
    @StateObject private var moments = CardMomentPlayer()

    /// Development hooks, in a preview only: `MOSSAD_DECK_DRAG=<points>` holds the top card mid-drag,
    /// `MOSSAD_DECK_WHY=line|open` answers no to the first card and shows the line about it.
    static var deckPreview: FindingsDeck.Preview? {
        guard CommandLine.arguments.contains("--ui-preview") else { return nil }
        let env = ProcessInfo.processInfo.environment
        let why: FindingsDeck.Preview.Why? = env["MOSSAD_DECK_WHY"] == "open" ? .open : env["MOSSAD_DECK_WHY"] == "line" ? .line : nil
        let drag = env["MOSSAD_DECK_DRAG"].flatMap(Double.init) ?? 0
        return drag == 0 && why == nil ? nil : FindingsDeck.Preview(drag: drag, why: why)
    }

    var body: some View {
        DetailColumn {
            PageToolbar(title: "Coach") {
                Button("Coach settings", action: openSettings)
                    .buttonStyle(.mossadFill)
            }
        } content: {
            if !controller.coachEnabled {
                EmptyState(symbol: "person.wave.2", title: "The coach is off",
                           message: "Turn on the communication coach in Settings. After a call it leaves one line with its proof, and a few cards here.",
                           action: ("Open Settings", openSettings))
                    .pageCentered()
            } else {
                ScrollView {
                    // One column, as wide as a card: the heading, the deck, and the note share its left edge.
                    VStack(alignment: .leading, spacing: Space.l) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text("Findings").textRole(.lede).foregroundStyle(Palette.ink)
                            Text(subtitle).textRole(.secondary).foregroundStyle(Palette.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        FindingsDeck(cards: controller.findings, source: source, openSource: { controller.openMeeting($0.callID) },
                                     play: { moments.toggle($0, paths: controller.paths) }, playing: moments.playing, focusOnAppear: true, preview: Self.deckPreview,
                                     answer: { controller.answerFinding($0, $1) }, undo: { controller.takeBackFinding($0) },
                                     explain: { controller.explainFinding($0, note: $1) })
                        Text("Yes and no teach the coach what is useful to you. \u{201C}No, never again\u{201D} stops a subject for good; you can allow it again in Settings \u{203A} Coach. A card with no answer goes after two weeks.")
                            .textRole(.secondary).foregroundStyle(Palette.tertiary).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: FindingsDeck.cardWidth, alignment: .leading)
                    .padding(.horizontal, Detail.gutter)
                    .padding(.top, Space.xl)
                    .padding(.bottom, Space.xxl)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { controller.refreshFindings() }
        .onDisappear { moments.stop() }
    }

    private func openSettings() {
        UserDefaults.standard.set(SettingsPage.coach.rawValue, forKey: "settingsPage")
        controller.open(.settings)
    }

    private var subtitle: String { controller.findings.isEmpty ? "Nothing to review" : "\(controller.findings.count) to review" }

    /// "Budget review · Nov 9": where the card is from.
    private func source(_ finding: CoachFinding) -> String? {
        let day = finding.date.formatted(.dateTime.month(.abbreviated).day())
        guard let title = controller.meetings.first(where: { $0.id == finding.callID })?.title.nonEmpty else { return day }
        return "\(title) \u{00B7} \(day)"
    }
}

/// Plays the moment of a card in place: one call's audio at a time.
@MainActor
final class CardMomentPlayer: ObservableObject {
    /// The id of the card whose moment plays.
    @Published private(set) var playing: String?
    private var player: AudioPlayer?
    private var callID: String?
    private var watch: Task<Void, Never>?

    func toggle(_ finding: CoachFinding, paths: Paths) {
        guard let at = finding.at else { return }
        if playing == finding.id { return stop() }
        if callID != finding.callID {
            player?.pause()
            player = AudioPlayer(callDirectory: paths.callDirectory(finding.callID))
            callID = finding.callID
        }
        playing = finding.id
        watch?.cancel()
        watch = Task { [weak self] in
            guard let player = self?.player else { return }
            // The audio loads off the main thread: wait for it, a few seconds at most.
            for _ in 0..<40 where !player.isAvailable && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled, player.isAvailable else {
                if !Task.isCancelled { self?.playing = nil }
                return
            }
            player.play(from: max(0, at - 1))
            // The mark goes when the audio stops by itself.
            while !Task.isCancelled, player.isPlaying { try? await Task.sleep(for: .milliseconds(300)) }
            if !Task.isCancelled { self?.playing = nil }
        }
    }

    func stop() {
        watch?.cancel()
        player?.pause()
        playing = nil
    }
}
