import MossadCore
import SwiftUI

/// The coach's one line after today's latest coached call that has one, with its proof. A call with nothing to
/// say shows nothing. It arrives with a short pause, like a thought, and leaves when dismissed or opened.
struct CoachMoment: View {
    @EnvironmentObject var controller: AppController
    var compact = false
    @AppStorage("coachMomentSeen") private var seen = ""
    @State private var moment: (record: CallRecord, line: CoachLine)?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A ZStack exists even when empty, so the task below runs; an empty Group would drop it.
        ZStack {
            if let m = moment, m.record.id != seen {
                VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                            .symbolEffect(.bounce, value: shown)
                        Text("\(m.line.heading) · \(m.record.title)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button { withAnimation(.snappy) { seen = m.record.id } } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    Text(m.line.text).font(compact ? .callout : .body).fixedSize(horizontal: false, vertical: true)
                    // The proof: the time of the owner's words, and the measured number. The tap opens the review, which plays it.
                    if let proof = [m.line.at.map { "At \(coachClock($0))" }, m.line.number].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                        Text(proof).font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    // Marked as words to say: in quote marks alone they read as words that the owner said.
                    if let say = m.line.say {
                        Text("Say: “\(say)”").font(compact ? .callout : .body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(compact ? 12 : 14)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture {
                    seen = m.record.id
                    controller.openMeeting(m.record.id)
                }
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 6)
                .help("Open the coach's review")
            }
        }
        .task(id: "\(controller.coachVersion)-\(controller.meetings.count)") { await load() }
    }

    private func load() async {
        let today = controller.meetings.filter { $0.status == .written && Calendar.current.isDateInToday($0.start) }
            .sorted { $0.end > $1.end }
        let paths = controller.paths
        let found = await Task.detached(priority: .utility) { () -> (CallRecord, CoachLine)? in
            for r in today.prefix(3) {
                if let line = CoachReview.load(in: paths.callDirectory(r.id))?.shownLine { return (r, line) }
            }
            return nil
        }.value
        guard found?.0.id != moment?.record.id else { return }
        moment = found.map { (record: $0.0, line: $0.1) }
        shown = false
        // A short pause before it appears: one thought, delivered, not a banner.
        try? await Task.sleep(for: .milliseconds(400))
        withAnimation(reduceMotion ? .none : .smooth(duration: 0.5)) { shown = true }
    }
}
