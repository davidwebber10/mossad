import MossadCore
import SwiftUI

/// A call being processed: the four steps, an overall bar, each track's upload percent or stage, and the time
/// it has taken. Under it, the last failed attempt with the time of the next one. Never a spinner: what waits
/// shows a moving fill.
struct ProcessingCard: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let step: ProcessingStep

    private var progress: ProcessingProgress? { controller.progress[record.id] }
    private var current: ProcessingStep { progress?.step ?? step }
    private var room: Bool { record.platform == .inPerson }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            card
            if let reason = record.failureReason, record.attempts > 0 { failure(reason) }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(current.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("step \(current.rawValue) of \(ProcessingStep.total)").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Spacer(minLength: Space.s)
                if let started = progress?.started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(clock(context.date.timeIntervalSince(started)))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.secondary)
                    }
                    .accessibilityLabel("Time taken")
                }
            }

            ProgressBar(fraction: progress?.fraction ?? 0.02, height: 5, track: Palette.bar)
                .padding(.top, 12)

            HStack(spacing: 0) {
                ForEach(ProcessingStep.allCases, id: \.self) { s in
                    let state: StepMark.State = s.rawValue < current.rawValue ? .done : s == current ? .active : .waiting
                    StepMark(title: shortTitle(s), state: state)
                    if s != ProcessingStep.allCases.last {
                        Rectangle().fill(s.rawValue < current.rawValue ? Palette.accentFill.opacity(0.45) : Palette.hairline)
                            .frame(height: 1).frame(maxWidth: .infinity).padding(.horizontal, Space.s)
                    }
                }
            }
            .padding(.top, Space.l)

            if let lines = subLines, !lines.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines, id: \.text) { line in row(line) }
                }
                .padding(.top, 14)
                .hairline(.top)
                .padding(.top, 18)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(current.title), step \(current.rawValue) of \(ProcessingStep.total)")
        .accessibilityValue("\(Int(((progress?.fraction ?? 0) * 100).rounded())) percent")
    }

    private func row(_ line: SubLine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: line.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(line.done ? Palette.ok : Palette.accent)
                .frame(width: 14)
                .contentTransition(.symbolEffect(.replace))
            Text(line.text)
                .font(.system(size: 12.5)).monospacedDigit()
                .foregroundStyle(line.done ? Palette.secondary : Palette.ink)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            switch line.trailing {
            case .fraction(let f): ProgressBar(fraction: f, height: 4, track: Palette.fill).frame(width: 120)
            case .waiting: WaitingBar().frame(width: 120)
            case .hint(let text): Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
            case .none: EmptyView()
            }
        }
    }

    /// "Attempt 1 failed: … Mossad tries again at 2:31 PM." with Retry now.
    private func failure(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.accent)
            Text("Attempt \(record.attempts) failed: \(reason)"
                 + (record.nextAttempt.map { ". Mossad tries again at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""))
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            Button("Retry now") { controller.retry(record.id) }.buttonStyle(.mossadFill)
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.l)
        .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private struct SubLine {
        enum Trailing { case fraction(Double), waiting, hint(String), none }
        let symbol: String
        let text: String
        let trailing: Trailing
        let done: Bool
    }

    /// One line per track while transcribing; the sub-step after that.
    private var subLines: [SubLine]? {
        guard let p = progress else { return nil }
        let service = controller.transcriptionProvider.displayName
        if p.step == .transcribing, p.detail == nil {
            return [Track.me, .them].compactMap { t in
                guard let state = p.tracks[t], let text = p.trackLine(t, service: service, room: room) else { return nil }
                switch state {
                case .uploading(let f): return SubLine(symbol: "arrow.up", text: text, trailing: f.map { .fraction($0) } ?? .waiting, done: false)
                case .queued: return SubLine(symbol: "clock", text: text, trailing: .hint("usually under a minute"), done: false)
                case .transcribing: return SubLine(symbol: "waveform", text: text, trailing: .waiting, done: false)
                case .done: return SubLine(symbol: "checkmark", text: text, trailing: .none, done: true)
                case .skipped: return nil
                }
            }
        }
        return p.detail.map { [SubLine(symbol: "ellipsis", text: $0, trailing: .waiting, done: false)] }
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

/// One step: a filled mark with a check when done, a filled mark with a dot while it runs, a ring before.
private struct StepMark: View {
    enum State { case done, active, waiting }
    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if state == .waiting {
                    Circle().strokeBorder(Palette.hairline, lineWidth: 1.5)
                } else {
                    Circle().fill(Palette.accentFill)
                }
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.onAccent)
                } else if state == .active {
                    Circle().fill(Palette.onAccent).frame(width: 6, height: 6)
                }
            }
            .frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: 12, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? Palette.tertiary : state == .active ? Palette.ink : Palette.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(state == .done ? "done" : state == .active ? "in progress" : "waiting")")
    }
}

/// A determinate bar whose fill carries a slow light that moves across it, so a long upload never looks stuck.
/// It keeps moving under Reduce Motion, as the design asks: it is the only sign of progress.
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 5
    var track: Color = Palette.bar
    @Environment(\.animationsActive) private var active
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { g in
            let width = max(height, g.size.width * min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(Palette.accentFill)
                    .frame(width: width)
                    .overlay {
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(24, width * 0.4))
                            .offset(x: phase * width)
                            .blendMode(.plusLighter)
                    }
                    .clipShape(Capsule())
                    .animation(.smooth(duration: 0.4), value: fraction)
            }
        }
        .frame(height: height)
        .onAppear(perform: start)
        .onChange(of: active) { _, _ in start() }
        .accessibilityHidden(true)
    }

    private func start() {
        guard active else { phase = -1; return }
        phase = -1
        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1 }
    }
}

/// For a stage with no percent: a short accent fill that travels the track, never a spinner.
struct WaitingBar: View {
    var height: CGFloat = 4
    @Environment(\.animationsActive) private var active
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let segment = g.size.width * 0.32
            Capsule().fill(Palette.fill)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.accentFill.opacity(0.7))
                        .frame(width: segment)
                        .offset(x: phase * (g.size.width - segment))
                }
                .clipShape(Capsule())
        }
        .frame(height: height)
        .onAppear(perform: start)
        .onChange(of: active) { _, _ in start() }
        .accessibilityHidden(true)
    }

    private func start() {
        guard active else { phase = 0; return }
        phase = 0
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 1 }
    }
}
