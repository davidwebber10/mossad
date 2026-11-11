import AppKit
import MossadCore
import SwiftUI

/// The coach's review of one call in the label column: one line with its proof, or that there is nothing to
/// say, then the talk share, open questions, and the focus. Everything else waits behind Full review.
struct CoachTab: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let people: MeetingPeople
    @ObservedObject var player: AudioPlayer
    @State private var more = CoachTab.previewOpen

    /// Development hook, in a preview only: `MOSSAD_COACH_FULL=1` opens the full review for a screenshot.
    private static var previewOpen: Bool {
        CommandLine.arguments.contains("--ui-preview") && ProcessInfo.processInfo.environment["MOSSAD_COACH_FULL"] == "1"
    }

    var body: some View {
        // Read on each coach run, so a review that lands while the tab is open shows at once.
        let review = controller.shownCoachReview(record.id)
        if let review {
            content(review)
        } else if !controller.coachEnabled {
            EmptyState(symbol: "person.wave.2", title: "The coach is off",
                       message: "Turn on the communication coach in Settings. After a call it leaves one line with its proof, or nothing.")
        } else if controller.coaching || record.status != .written {
            EmptyState(symbol: "hourglass", title: "The coach is reviewing calls",
                       message: "The review shows here when it is done.")
        } else {
            EmptyState(symbol: "text.bubble", title: "No review for this call",
                       message: "The coach reviews every call with speech, from two weeks before the day it was turned on.")
        }
    }

    private func content(_ review: CoachReview) -> some View {
        let profile = controller.shownCoachProfile
        let line = review.shownLine
        let others = review.others
        let questions = profile.openQuestions.filter { $0.callID == record.id }
        return LabelColumnStack(spacing: 18) {
            if let line {
                LabelColumn(label: line.heading) { LineRow(line: line, strong: true, long: record.isLong, player: player) }
            } else {
                LabelColumn(label: "The coach\u{2019}s read") { read(review, nothing: review.saysNothing) }
            }
            if people.speakers.contains(where: { $0.seconds > 0 }) {
                LabelColumn(label: "Talk share") { TalkShare(people: people) }
            }
            if !questions.isEmpty {
                LabelColumn(label: "Open questions") {
                    QuestionsPanel(questions: questions,
                                   answer: { controller.answerQuestion($0, $1, note: $2) },
                                   openMoment: { controller.showMoment($0, at: $1) })
                }
            }
            if FocusPanel.belongs(to: record, profile: profile) {
                LabelColumn(label: "Focus") {
                    // The line already says how this call went on the focus.
                    FocusPanel(profile: profile, callID: record.id, result: line?.kind == .focus ? nil : review.focusResult, compact: true,
                               accept: { controller.acceptFocus($0, plan: $1) }, dismiss: { controller.dismissFocus($0) })
                }
            }
            LabelColumn(label: "") {
                Button {
                    withAnimation(.snappy) { more.toggle() }
                } label: {
                    Label(more ? "Less" : "Full review", systemImage: more ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                .accessibilityHint("Shows the rest of the coach\u{2019}s review of this call")
            }
            if more { full(review, line: line, others: others, profile: profile) }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.ink)
    }

    private func read(_ review: CoachReview, nothing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(review.headline).font(.system(size: 16, weight: .medium)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if nothing {
                Text(CoachLineView.nothing).foregroundStyle(Palette.secondary)
            } else if !review.overview.isEmpty, review.overview != review.headline {
                Text(review.overview).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    /// The rest of the review: the coach's read, what else it noted, the detail points, the numbers, the
    /// meeting's value, and the conversation with the coach.
    @ViewBuilder
    private func full(_ review: CoachReview, line: CoachLine?, others: [CoachLine], profile: CoachProfile) -> some View {
        let metrics = CallMetrics(record: record, owner: controller.ownerName,
                                  history: profile.history.filter { $0.callID != record.id }.compactMap(\.delivery))
        let worked = others.filter { $0.kind == .didWell }
        let change = others.filter { $0.kind != .didWell }
        if line != nil { LabelColumn(label: "The coach\u{2019}s read") { read(review, nothing: false) } }
        if !worked.isEmpty || !review.strengths.isEmpty {
            LabelColumn(label: "What worked") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(worked.enumerated()), id: \.offset) { _, l in LineRow(line: l, long: record.isLong, player: player) }
                    ForEach(Array(review.strengths.enumerated()), id: \.offset) { _, p in point(p, review) }
                }
            }
        }
        if !change.isEmpty || !review.improvements.isEmpty {
            LabelColumn(label: "What to change") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(change.enumerated()), id: \.offset) { _, l in LineRow(line: l, titled: l.kind == .again, long: record.isLong, player: player) }
                    ForEach(Array(review.improvements.enumerated()), id: \.offset) { _, p in point(p, review) }
                }
            }
        }
        if !metrics.checks.isEmpty {
            LabelColumn(label: "Against your goals") {
                VStack(alignment: .leading, spacing: 16) {
                    GoalsGrid(metrics: metrics, focus: profile.activeFocus?.metric)
                    CallStrip(metrics: metrics)
                }
            }
        }
        if let value = review.value { ValueCard(value: value) }
        if let card = review.scorecard { ScorecardView(card: card) }
        CoachThread(callID: record.id, thread: review.thread)
        // Only for a review from before the lines, as before: the new review replaces the old file, and an
        // older review that has lines would lose its second points, its ratings, and its conversation.
        if review.version < CoachReview.currentVersion, review.didWell == nil, review.tryNext == nil, !review.quiet {
            LabelColumn(label: "") {
                Button("Review this call again with the new coach") { controller.reviewAgain(record.id) }
                    .controlSize(.small).disabled(controller.coaching)
            }
        }
    }

    private func point(_ p: CoachPoint, _ review: CoachReview) -> some View {
        TimedRow(at: p.at, long: record.isLong, player: player) {
            PointView(point: p, callID: record.id, feedback: review.feedback[p.title])
        }
    }
}

/// One line of the coach: what it saw, the proof (the owner's words at a time that plays, or a measured number),
/// and what to say.
private struct LineRow: View {
    let line: CoachLine
    /// The line of the page: a size larger than the notes in the full review.
    var strong = false
    /// Says what kind of note it is, where the label column does not.
    var titled = false
    var long = false
    @ObservedObject var player: AudioPlayer

    var body: some View {
        TimedRow(at: line.at, long: long, player: player) {
            VStack(alignment: .leading, spacing: 4) {
                Text(titled ? "\(line.title): \(line.text)" : line.text)
                    .font(.system(size: strong ? 16 : 13, weight: strong ? .medium : .regular)).lineSpacing(strong ? 3 : 0)
                    .fixedSize(horizontal: false, vertical: true)
                if let q = line.quote { Text("\u{201C}\(q)\u{201D}").italic().foregroundStyle(Palette.secondary) }
                if let number = line.number {
                    Text(number).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let say = line.say {
                    Text("Say: \u{201C}\(say)\u{201D}")
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .textSelection(.enabled)
        }
    }
}

/// One point of an older review: what the coach saw, the quote, what to try, and a rating the coach learns from.
private struct PointView: View {
    @EnvironmentObject var controller: AppController
    let point: CoachPoint
    let callID: String
    let feedback: CoachFeedback?
    @State private var writing = false
    @State private var note = ""
    @State private var sending = false
    @State private var error: FriendlyError?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(Text(point.title).fontWeight(.semibold)). \(point.observation)").fixedSize(horizontal: false, vertical: true)
            if !point.quote.isEmpty { Text("\u{201C}\(point.quote)\u{201D}").italic().foregroundStyle(Palette.secondary) }
            if let next = point.tryInstead {
                Text("Try: \(next)")
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            rating
        }
        .textSelection(.enabled)
    }

    /// Right or wrong, and after wrong a line to say what it got wrong. The coach learns from both.
    @ViewBuilder
    private var rating: some View {
        HStack(spacing: 10) {
            thumb(agree: true)
            thumb(agree: false)
            Text(point.principle).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            if let note = feedback?.note {
                Text("You said: \(note)").font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(2)
            } else if let feedback {
                Text(feedback.agree ? "Marked right" : "Marked wrong").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
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
        if let error { InlineError(error: error) }
    }

    private func thumb(agree: Bool) -> some View {
        let chosen = feedback?.agree == agree
        return Button {
            if agree { send(agree: true) } else { writing.toggle() }
        } label: {
            Image(systemName: agree ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup") : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 11))
                .foregroundStyle(chosen ? Palette.accent : Palette.tertiaryMark)
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
                Log.error("The coach reply failed: \(error)")
                let friendly = FriendlyError(error, context: .coaching)
                if friendly.shouldShow(failures: 1) { self.error = friendly }
            }
            sending = false
        }
    }
}

private struct CoachThread: View {
    @EnvironmentObject var controller: AppController
    let callID: String
    let thread: [ChatMessage]
    @State private var draft = ""
    @State private var sending = false
    @State private var error: FriendlyError? = AppController.errorPreview("coach")

    var body: some View {
        LabelColumn(label: "Talk to the coach") {
            VStack(alignment: .leading, spacing: 10) {
                if thread.isEmpty {
                    Text("Tell the coach what it missed or got wrong, or ask about this call. It answers and remembers what should change in later reviews.")
                        .foregroundStyle(.secondary)
                }
                ForEach(thread) { m in
                    Text(m.text)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(m.role == .user ? Palette.accentTint : Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                if let error { ErrorCard(error: error, retry: error.canRetry && !sending ? { send() } : nil) }
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
                Log.error("The coach reply failed: \(error)")
                let friendly = FriendlyError(error, context: .coaching)
                if friendly.shouldShow(failures: 1) { self.error = friendly }
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
        case .high: Palette.ok
        case .medium: .secondary
        case .low: Palette.accentFill
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
        LabelColumn(label: "Meeting value") {
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
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .textSelection(.enabled)
        }
    }
}

/// The review at a glance: the score out of 5, the score by area, and the key points.
private struct ScorecardView: View {
    let card: Scorecard

    private func color(_ score: Int) -> Color {
        score >= 4 ? Palette.ok : score == 3 ? Palette.tertiaryMark : Palette.accentFill
    }

    var body: some View {
        LabelColumn(label: "Scorecard") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(spacing: 4) {
                        (Text("\(card.score)").font(.system(size: 40, weight: .bold)) + Text("/5").font(.system(size: 17, weight: .semibold)).foregroundColor(.secondary))
                            .foregroundStyle(color(card.score))
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= card.score ? "star.fill" : "star").font(.system(size: 10))
                                    .foregroundStyle(i <= card.score ? Palette.accentFill : Palette.tertiaryMark)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Score \(card.score) of 5")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(card.reason).fontWeight(.medium)
                        ForEach(card.dimensions, id: \.self) { d in
                            HStack(spacing: 8) {
                                Text(d.name).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                                HStack(spacing: 3) {
                                    ForEach(1...5, id: \.self) { i in
                                        Capsule().fill(i <= d.score ? color(d.score) : Palette.fill).frame(width: 22, height: 6)
                                    }
                                }
                                Text("\(d.score)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(d.name): \(d.score) of 5")
                        }
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    points(card.positives, symbol: "checkmark.circle.fill", tint: Palette.ok)
                    points(card.negatives, symbol: "xmark.circle.fill", tint: Palette.accentFill)
                }
            }
            .textSelection(.enabled)
        }
    }

    private func points(_ list: [String], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(list, id: \.self) { p in
                Label { Text(p) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
