import AppKit
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
                             message: "The coach reviews every call with speech, from two weeks before the day it was turned on.")
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
            if let value = review.value { ValueCard(value: value) }
            if let progress = review.focusProgress {
                focusCard(progress)
            }
            if let d = review.delivery {
                if CoachReview.isListener(d) {
                    Card("Delivery") {
                        Text("You mostly listened in this call, so the coach looked at listening, follow-ups, and whether the meeting needed you.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    DeliveryCard(stats: d)
                }
            }
            if !review.strengths.isEmpty {
                section("What worked", symbol: "checkmark.circle.fill", tint: .green, points: review.strengths)
            }
            if !review.improvements.isEmpty {
                section("Try next time", symbol: "arrow.up.forward.circle.fill", tint: Theme.warning, points: review.improvements)
            }
            CoachThread(callID: record.id, thread: review.thread)
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
                    PointView(point: point, symbol: symbol, tint: tint, player: player, callID: record.id,
                              feedback: controller.coachReview(record.id)?.feedback[point.title])
                }
            }
        }
    }
}

private struct PointView: View {
    @EnvironmentObject var controller: AppController
    let point: CoachPoint
    let symbol: String
    let tint: Color
    @ObservedObject var player: AudioPlayer
    let callID: String
    let feedback: CoachFeedback?
    @State private var writing = false
    @State private var note = ""
    @State private var sending = false
    @State private var error: String?

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
            rating
        }
        .textSelection(.enabled)
    }

    /// 👍 / 👎, and after 👎 a line to say what it got wrong. The coach learns from both.
    @ViewBuilder
    private var rating: some View {
        HStack(spacing: 10) {
            thumb(agree: true)
            thumb(agree: false)
            if let note = feedback?.note {
                Text("You said: \(note)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            } else if feedback != nil {
                Text(feedback!.agree ? "Marked right" : "Marked wrong").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if sending { ProgressView().controlSize(.mini) }
            Spacer()
        }
        if writing {
            HStack(spacing: 6) {
                TextField("What did it get wrong? The coach will remember.", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    .onSubmit { send(agree: false) }
                Button("Send") { send(agree: false) }.disabled(sending)
            }
        }
        if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.recording) }
    }

    private func thumb(agree: Bool) -> some View {
        let chosen = feedback?.agree == agree
        return Button {
            if agree { send(agree: true) } else { writing.toggle() }
        } label: {
            Image(systemName: agree ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup") : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 12))
                .foregroundStyle(chosen ? (agree ? Color.green : Theme.warning) : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(agree ? "The coach got this right" : "The coach got this wrong")
        .accessibilityLabel(agree ? "Mark right" : "Mark wrong")
    }

    private func send(agree: Bool) {
        sending = true
        error = nil
        let text = agree ? nil : note
        Task {
            do {
                try await controller.rateCoachPoint(callID: callID, point: point, agree: agree, note: text)
                writing = false
                note = ""
            } catch {
                self.error = "\(error)"
            }
            sending = false
        }
    }
}

/// A conversation with the coach about this review: it answers and remembers what should change.
private struct CoachThread: View {
    @EnvironmentObject var controller: AppController
    let callID: String
    let thread: [ChatMessage]
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Card("Talk to the coach") {
            VStack(alignment: .leading, spacing: 10) {
                if thread.isEmpty {
                    Text("Tell the coach what it missed or got wrong, or ask about this call. It answers and remembers what should change in later reviews.")
                        .foregroundStyle(.secondary)
                }
                ForEach(thread) { m in
                    Text(m.text)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(m.role == .user ? Color.accentColor.opacity(0.14) : Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
                        .textSelection(.enabled)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Reply to the coach", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...5)
                        .onSubmit(send)
                    if sending { ProgressView().controlSize(.small) }
                    Button("Send", action: send).disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.recording) }
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        error = nil
        Task {
            do {
                try await controller.replyToCoach(callID: callID, message: text)
                draft = ""
            } catch {
                self.error = "\(error)"
            }
            sending = false
        }
    }
}

/// Whether the meeting was worth your time, and the change to make.
private struct ValueCard: View {
    let value: MeetingValue
    @State private var copied = false

    private var tint: Color {
        switch value.rating {
        case .high: .green
        case .medium: .secondary
        case .low: Theme.warning
        }
    }

    private var action: String {
        switch value.action {
        case .keep: "Keep it"
        case .shorten: "Make it shorter"
        case .async: "Make it a written update"
        case .delegate: "Send someone else"
        case .decline: "Decline it"
        case .restructure: "Change the format"
        }
    }

    var body: some View {
        Card("Meeting value") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(value.rating.rawValue.capitalized)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(tint.opacity(0.14), in: Capsule())
                    Text(action).fontWeight(.medium)
                }
                Text(value.reason).foregroundStyle(.secondary)
                if value.action != .keep {
                    HStack(alignment: .top) {
                        Text(value.suggestion).frame(maxWidth: .infinity, alignment: .leading)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(value.suggestion, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .textSelection(.enabled)
        }
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
                if let t = stats.tone {
                    tile("Pitch range", String(format: "%.1f st", t.pitchVariation), t.pitchVariation < 2 ? "sounds flat" : "around \(Int(t.medianPitch)) Hz")
                    tile("Turn ends", String(format: "%+.0f dB", -t.endDrop), t.endDrop > 4 ? "trailing off" : "steady")
                }
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
