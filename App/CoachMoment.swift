import MossadCore
import SwiftUI

/// The coach's one line after today's latest coached call: what to try next with the words to say, or what
/// went well. It arrives with a short pause, like a thought, and leaves when dismissed or opened.
struct CoachMoment: View {
    @EnvironmentObject var controller: AppController
    var compact = false
    @AppStorage("coachMomentSeen") private var seen = ""
    @State private var moment: (record: CallRecord, note: CoachNote, kind: String)?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A ZStack exists even when empty, so the task below runs; an empty Group would drop it.
        ZStack {
            if let m = moment, m.record.id != seen {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                            .symbolEffect(.bounce, value: shown)
                        Text("\(m.kind) · \(m.record.title)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button { withAnimation(.snappy) { seen = m.record.id } } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    Text(m.note.text).font(compact ? .callout : .body).fixedSize(horizontal: false, vertical: true)
                    if let say = m.note.say {
                        Text("“\(say)”").font(compact ? .callout : .body).italic().foregroundStyle(.secondary)
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
        let found = await Task.detached(priority: .utility) { () -> (CallRecord, CoachNote, String)? in
            for r in today.prefix(3) {
                guard let review = CoachReview.load(in: paths.callDirectory(r.id)) else { continue }
                if let next = review.tryNext { return (r, next, "Try next") }
                if let good = review.didWell { return (r, good, "Went well") }
            }
            return nil
        }.value
        guard found?.0.id != moment?.record.id else { return }
        moment = found.map { (record: $0.0, note: $0.1, kind: $0.2) }
        shown = false
        // A short pause before it appears: one thought, delivered, not a banner.
        try? await Task.sleep(for: .milliseconds(400))
        withAnimation(reduceMotion ? .none : .smooth(duration: 0.5)) { shown = true }
    }
}
