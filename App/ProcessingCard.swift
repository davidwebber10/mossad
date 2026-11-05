import MossadCore
import SwiftUI

/// A call being processed: the four steps, an overall bar, each track's upload percent or stage, and the time
/// it has taken. Shown above a meeting while it is processed.
struct ProcessingCard: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let step: ProcessingStep

    private var progress: ProcessingProgress? { controller.progress[record.id] }
    private var current: ProcessingStep { progress?.step ?? step }
    private var room: Bool { record.platform == .inPerson }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(current.title).font(.system(size: 13, weight: .semibold))
                Text("step \(current.rawValue) of \(ProcessingStep.total)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if let started = progress?.started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(clock(context.date.timeIntervalSince(started)))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if record.attempts > 0 { Button("Retry now") { controller.retry(record.id) }.controlSize(.small) }
            }

            ProgressView(value: progress?.fraction ?? 0.02)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(.smooth(duration: 0.4), value: progress?.fraction)

            HStack(spacing: 0) {
                ForEach(ProcessingStep.allCases, id: \.self) { s in
                    StepChip(title: shortTitle(s), state: s.rawValue < current.rawValue ? .done : s == current ? .active : .waiting)
                    if s != ProcessingStep.allCases.last {
                        Rectangle().fill(s.rawValue < current.rawValue ? Color.accentColor.opacity(0.5) : Theme.separator)
                            .frame(height: 1).frame(maxWidth: .infinity).padding(.horizontal, 6)
                    }
                }
            }

            if let lines = subLines, !lines.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(lines, id: \.text) { line in
                        HStack(spacing: 8) {
                            Image(systemName: line.symbol).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(line.done ? Color.green : Color.accentColor).frame(width: 16)
                                .contentTransition(.symbolEffect(.replace))
                            Text(line.text).font(.system(size: 12)).foregroundStyle(line.done ? .secondary : .primary)
                                .monospacedDigit().lineLimit(1)
                            Spacer(minLength: 8)
                            if let f = line.fraction {
                                ProgressView(value: f).progressViewStyle(.linear).frame(width: 110).controlSize(.small)
                            } else if !line.done {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
            if let reason = record.failureReason, record.attempts > 0 {
                Label("Attempt \(record.attempts) failed: \(reason)" + (record.nextAttempt.map { ". Mossad tries again at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(2)
            }
        }
        .padding(14)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(((progress?.fraction ?? 0) * 100).rounded())) percent")
    }

    private struct SubLine { let symbol: String; let text: String; let fraction: Double?; let done: Bool }

    /// One line per track while transcribing; the sub-step after that.
    private var subLines: [SubLine]? {
        guard let p = progress else { return nil }
        let service = controller.transcriptionProvider.displayName
        if p.step == .transcribing, p.detail == nil {
            return [Track.me, .them].compactMap { t in
                guard let state = p.tracks[t], let text = p.trackLine(t, service: service, room: room) else { return nil }
                switch state {
                case .uploading(let f): return SubLine(symbol: "arrow.up.circle.fill", text: text, fraction: f, done: false)
                case .queued: return SubLine(symbol: "hourglass", text: text, fraction: nil, done: false)
                case .transcribing: return SubLine(symbol: "waveform", text: text, fraction: nil, done: false)
                case .done: return SubLine(symbol: "checkmark.circle.fill", text: text, fraction: nil, done: true)
                case .skipped: return nil
                }
            }
        }
        return p.detail.map { [SubLine(symbol: "ellipsis.circle.fill", text: $0, fraction: nil, done: false)] }
    }

    private func shortTitle(_ s: ProcessingStep) -> String {
        switch s {
        case .transcribing: "Transcript"
        case .identifying: "Speakers"
        case .summarizing: "Summary"
        case .writing: "Note"
        }
    }
}

private struct StepChip: View {
    enum State { case done, active, waiting }
    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(state == .waiting ? Color.clear : Color.accentColor)
                Circle().strokeBorder(state == .waiting ? Theme.separator : Color.accentColor, lineWidth: 1.5)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                } else if state == .active {
                    Circle().fill(.white).frame(width: 5, height: 5)
                }
            }
            .frame(width: 15, height: 15)
            Text(title).font(.system(size: 11, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? .tertiary : state == .active ? .primary : .secondary)
                .fixedSize()
        }
    }
}
