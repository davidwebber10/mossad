import MossadCore
import SwiftUI

/// The pages of Coach. They show under Coach in the sidebar while Coach is open.
enum CoachPage: String, CaseIterable, Identifiable {
    case findings, goals, weekly, knowledge, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .findings: "Findings"
        case .goals: "Goals"
        case .weekly: "Weekly review"
        case .knowledge: "Knowledge"
        case .settings: "Settings"
        }
    }
}

/// Coach: the findings of all calls as one deck, the goal and how it goes, the weekly review, what the coach
/// knows, and the coach's settings.
struct CoachView: View {
    @EnvironmentObject var controller: AppController

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
        Group {
            if !controller.coachEnabled, controller.coachPage != .settings {
                DetailColumn {
                    PageToolbar(title: controller.coachPage.title) { EmptyView() }
                } content: {
                    EmptyState(symbol: "person.wave.2", title: "The coach is off",
                               message: "Turn on the communication coach. After a call it leaves one line with its proof, and a few cards in Findings.",
                               action: ("Open Settings", { controller.coachPage = .settings }))
                        .pageCentered()
                }
            } else {
                switch controller.coachPage {
                case .findings: FindingsPage()
                case .goals: CoachGoalsPage()
                case .weekly: WeeklyReviewPage()
                case .knowledge: CoachKnowledgePage()
                case .settings: CoachPageColumn(page: .settings) { CoachSettings(showsPagesLink: false) }
                }
            }
        }
        .onAppear {
            // Development hook for screenshots: MOSSAD_COACH_PAGE names a page.
            if CommandLine.arguments.contains("--ui-preview"),
               let page = ProcessInfo.processInfo.environment["MOSSAD_COACH_PAGE"].flatMap(CoachPage.init(rawValue:)) {
                controller.coachPage = page
            }
        }
    }
}

/// A page of Coach: the toolbar with its name, and the page in the label column, as in Settings.
struct CoachPageColumn<Content: View>: View {
    let page: CoachPage
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        DetailColumn {
            PageToolbar(title: page.title, subtitle: subtitle) { EmptyView() }
        } content: {
            ScrollView {
                content
                    .padding(EdgeInsets(top: 10, leading: 36, bottom: 40, trailing: 36))
                    .frame(maxWidth: 760 + 72, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Coach › Findings: the cards of all calls as one deck, the newest call first. Each card has a moment to play
/// or a number with its usual value. The owner's answers train the coach.
private struct FindingsPage: View {
    @EnvironmentObject var controller: AppController
    @StateObject private var moments = CardMomentPlayer()

    var body: some View {
        let profile = controller.shownCoachProfile
        DetailColumn {
            PageToolbar(title: "Findings", subtitle: controller.findings.isEmpty ? nil : "\(controller.findings.count) to review") { EmptyView() }
        } content: {
            ScrollView {
                // One column, as wide as a card: the deck and the note share its left edge.
                VStack(alignment: .leading, spacing: Space.l) {
                    FindingsDeck(cards: controller.findings, source: source, openSource: { controller.openMeeting($0.callID) },
                                 play: { moments.toggle($0, paths: controller.paths) }, playing: moments.playing,
                                 offersNever: { FindingRules.offersNever($0, profile: profile) }, focusOnAppear: true, preview: CoachView.deckPreview,
                                 answer: { controller.answerFinding($0, $1) }, undo: { controller.takeBackFinding($0) },
                                 explain: { controller.explainFinding($0, note: $1) })
                    Text("Yes and no teach the coach what is useful to you. \u{201C}No, never again\u{201D} stops a subject for good; you can undo it in Knowledge. At most two cards come from a call, and a card with no answer goes after two weeks.")
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
        .onAppear { controller.refreshFindings() }
        .onDisappear { moments.stop() }
    }

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
