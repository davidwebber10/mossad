import MossadCore
import SwiftUI

/// The coach's review of one call: the headline, progress on the focus, delivery numbers, what worked, and
/// what to try next. Each quote's time plays the moment.
struct CoachTab: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    @ObservedObject var player: AudioPlayer

    var body: some View {
        // Read on each coach run, so a review that lands while the tab is open shows at once.
        let review = controller.coachVersion >= 0 ? controller.coachReview(record.id) : nil
        if let review {
            content(review)
        } else if !controller.coachEnabled {
            DetailEmptyState(symbol: "person.wave.2", title: "The coach is off",
                             message: "Turn on the communication coach in Settings. It reviews each call and tracks your progress over time.")
        } else if controller.coaching || record.status != .written {
            DetailEmptyState(symbol: "hourglass", title: "The coach is reviewing calls",
                             message: "The review shows here when it is done.")
        } else {
            DetailEmptyState(symbol: "text.bubble", title: "No review for this call",
                             message: "The coach reviews calls where you spoke for at least a minute, from the day it was turned on, two weeks back.")
        }
    }

    private func content(_ review: CoachReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Card("Coach") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.headline).font(.system(size: 15, weight: .semibold))
                    Text(review.overview).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
            if let progress = review.focusProgress {
                focusCard(progress)
            }
            if let d = review.delivery { DeliveryCard(stats: d) }
            if !review.strengths.isEmpty {
                section("What worked", symbol: "checkmark.circle.fill", tint: .green, points: review.strengths)
            }
            if !review.improvements.isEmpty {
                section("Try next time", symbol: "arrow.up.forward.circle.fill", tint: Theme.warning, points: review.improvements)
            }
        }
        .padding(.top, 6)
    }

    private func focusCard(_ progress: String) -> some View {
        let focus = controller.coachProfile.focus
        return Card("Your focus") {
            VStack(alignment: .leading, spacing: 6) {
                if !focus.isEmpty { Text(focus).fontWeight(.medium) }
                Text(progress).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
    }

    private func section(_ title: String, symbol: String, tint: Color, points: [CoachPoint]) -> some View {
        Card(title) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(points.enumerated()), id: \.offset) { i, point in
                    if i > 0 { Rectangle().fill(Theme.separator).frame(height: 1) }
                    PointView(point: point, symbol: symbol, tint: tint, player: player)
                }
            }
        }
    }
}

private struct PointView: View {
    let point: CoachPoint
    let symbol: String
    let tint: Color
    @ObservedObject var player: AudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 13))
                Text(point.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(point.principle)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.field, in: Capsule())
            }
            Text(point.observation)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let at = point.at {
                    Button(clock(at)) { player.play(from: at) }
                        .buttonStyle(.plain).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(player.isAvailable ? Color.accentColor : .secondary)
                        .disabled(!player.isAvailable)
                        .help(player.isAvailable ? "Play from here" : "The audio is not available")
                }
                Text("“\(point.quote)”").italic().foregroundStyle(.secondary)
            }
            if let next = point.tryInstead {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TRY").font(.system(size: 10, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary)
                    Text(next)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .textSelection(.enabled)
    }
}

/// Pace, fillers, and turn-taking, measured from the transcript timing.
private struct DeliveryCard: View {
    let stats: DeliveryStats

    var body: some View {
        Card("Delivery") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
                tile("Pace", "\(Int(stats.wordsPerMinute)) wpm", "fastest \(Int(stats.fastestWordsPerMinute))")
                tile("Fillers", String(format: "%.1f / min", stats.fillersPerMinute), "\(stats.fillers) in all")
                tile("Talk share", "\(Int((stats.talkShare * 100).rounded()))%", clock(stats.talkSeconds))
                tile("Longest turn", clock(stats.longestTurnSeconds), nil)
                tile("Questions", "\(stats.questions)", nil)
                tile("Cut-ins", "\(stats.interruptions) / \(stats.interrupted)", "by you / by others")
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            // A blank line keeps every tile the same height, so the values line up.
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}
