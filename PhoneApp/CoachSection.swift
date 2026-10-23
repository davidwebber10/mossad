import MossadCore
import SwiftUI

/// The coach's review of one meeting, as on the Mac: the scorecard, the meeting's value, delivery, the points
/// with 👍 / 👎, and a conversation with the coach.
struct CoachSection: View {
    let record: CallRecord
    let review: CoachReview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let card = review.scorecard { ScorecardCard(card: card) }
            Card {
                Text(review.headline).font(.headline)
                Text(review.overview).foregroundStyle(.secondary)
                if let focus = review.focusProgress {
                    Label(focus, systemImage: "scope").font(.subheadline)
                }
            }
            if let value = review.value { ValueCard(value: value) }
            if let d = review.delivery { DeliveryCard(stats: d) }
            PointsCard(title: "What worked", symbol: "hand.thumbsup.fill", tint: .green, points: review.strengths, review: review, callID: record.id)
            PointsCard(title: "Try next time", symbol: "arrow.up.forward.circle.fill", tint: .orange, points: review.improvements, review: review, callID: record.id)
            CoachThread(callID: record.id, thread: review.thread)
        }
        .textSelection(.enabled)
    }
}

private struct ScorecardCard: View {
    let card: Scorecard

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                Text("\(card.score)")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                    .foregroundStyle(scoreColor(card.score))
                    .frame(width: 64, height: 64)
                    .background(scoreColor(card.score).opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("out of 5").font(.caption).foregroundStyle(.secondary)
                    Text(card.reason).font(.subheadline)
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(card.dimensions, id: \.self) { d in
                Gauge(value: Double(d.score), in: 0...5) {
                    HStack {
                        Text(d.name).font(.subheadline)
                        Spacer()
                        Text("\(d.score)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
                .gaugeStyle(.linearCapacity)
                .tint(scoreColor(d.score))
            }
            if !card.positives.isEmpty || !card.negatives.isEmpty { Divider() }
            ForEach(card.positives, id: \.self) { point($0, "plus.circle.fill", .green) }
            ForEach(card.negatives, id: \.self) { point($0, "minus.circle.fill", .orange) }
        }
    }
}

private extension ScorecardCard {
    func point(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }.font(.subheadline)
    }
}

private struct ValueCard: View {
    let value: MeetingValue

    var body: some View {
        Card {
            HStack {
                CardTitle(text: "Meeting value", symbol: "clock.badge.checkmark")
                Spacer()
                Text(value.rating.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(tint).background(tint.opacity(0.15), in: .capsule)
            }
            Text(value.reason).font(.subheadline)
            if value.action != .keep {
                Label(value.suggestion, systemImage: "lightbulb").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color { value.rating == .high ? .green : value.rating == .medium ? .yellow : .orange }
}

private struct DeliveryCard: View {
    let stats: DeliveryStats

    var body: some View {
        Card {
            CardTitle(text: "Delivery", symbol: "waveform")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                metric("\(Int(stats.wordsPerMinute))", "words a minute")
                metric("\(Int((stats.talkShare * 100).rounded()))%", "of the talking")
                metric(String(format: "%.1f", stats.fillersPerMinute), "fillers a minute")
                metric(clock(stats.longestTurnSeconds), "longest turn")
                metric("\(stats.questions)", "questions asked")
                metric("\(stats.interruptions)", "times you cut in")
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PointsCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let points: [CoachPoint]
    let review: CoachReview
    let callID: String

    var body: some View {
        if !points.isEmpty {
            Card {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint)
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    if i > 0 { Divider() }
                    PointView(point: p, callID: callID, feedback: review.feedback[p.title])
                }
            }
        }
    }
}

private struct PointView: View {
    @EnvironmentObject var store: PhoneStore
    let point: CoachPoint
    let callID: String
    let feedback: CoachFeedback?
    @State private var writing = false
    @State private var note = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(point.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(point.principle)
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: .capsule)
            }
            Text(point.observation).font(.subheadline)
            Text("“\(point.quote)”").font(.subheadline).italic().foregroundStyle(.secondary)
            if let next = point.tryInstead {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TRY").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(next).font(.subheadline)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12))
            }
            rating
        }
    }

    /// 👍 / 👎, and after 👎 a line to say what it got wrong. The coach learns from both.
    @ViewBuilder
    private var rating: some View {
        HStack(spacing: 14) {
            thumb(agree: true)
            thumb(agree: false)
            if sending { ProgressView() }
            if let note = feedback?.note {
                Text("You said: \(note)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        if writing {
            HStack {
                TextField("What did the coach get wrong?", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit { rate(agree: false, note: note) }
                Button("Send") { rate(agree: false, note: note) }.disabled(sending)
            }
            .font(.subheadline)
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }

    private func thumb(agree: Bool) -> some View {
        let chosen = feedback?.agree == agree
        return Button {
            if agree { rate(agree: true, note: nil) } else { writing.toggle() }
        } label: {
            Image(systemName: agree ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup") : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.body)
                .foregroundStyle(chosen ? (agree ? Color.green : Color.orange) : Color.secondary)
                .frame(minWidth: 32, minHeight: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agree ? "The coach is right" : "The coach is wrong")
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private func rate(agree: Bool, note: String?) {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        writing = false
        sending = true
        error = nil
        Task {
            do {
                try await store.rate(callID: callID, point: point, agree: agree, note: text?.isEmpty == false ? text : nil)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
            self.note = ""
        }
    }
}

/// "Talk to the coach" about this review. Its answers can change what it remembers about you.
private struct CoachThread: View {
    @EnvironmentObject var store: PhoneStore
    let callID: String
    let thread: [ChatMessage]
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Card {
            CardTitle(text: "Talk to the coach", symbol: "bubble.left.and.bubble.right")
            if thread.isEmpty {
                Text("Disagree, give context, or ask for more. The coach remembers what you tell it.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(thread) { MessageBubble(message: $0) }
            if sending {
                HStack(spacing: 8) { ProgressView(); Text("The coach is thinking…").font(.subheadline).foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to the coach", text: $message, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 18))
                Button { send() } label: { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                    .accessibilityLabel("Send")
            }
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        sending = true
        error = nil
        Task {
            do { try await store.reply(callID: callID, message: text) } catch {
                self.error = error.localizedDescription
                message = text
            }
            sending = false
        }
    }
}
