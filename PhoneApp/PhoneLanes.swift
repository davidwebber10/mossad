import MossadCore
import SwiftUI

/// The Mac's lanes player at phone size: one lane per speaker in their hue, the owner first, about ten lanes
/// before the rest scroll with "+N more voices". The audio stays on the Mac, so the playhead marks a moment to
/// read: a tap on a lane, a decision, or the ruler opens the transcript there.
struct PhoneLanes: View {
    let lanes: [SpeakerLanes.Lane]
    let duration: TimeInterval
    /// The moment being read, drawn as the playhead.
    let moment: TimeInterval?
    let decisions: [Decision]
    let bookmarks: [TranscriptMarker]
    let seek: (TimeInterval) -> Void

    static let visibleLanes = 10

    @ScaledMetric(relativeTo: .caption) private var nameSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var gutter: CGFloat = 64
    @State private var atEnd = false

    private var rowHeight: CGFloat { max(16, nameSize * 1.45) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !lanes.isEmpty { laneArea }
            ruler
            readout
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speakers over time")
    }

    // MARK: Lanes

    private var laneArea: some View {
        let shown = min(lanes.count, Self.visibleLanes)
        let scrolls = lanes.count > Self.visibleLanes
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.element.key) { i, lane in
                    laneRow(lane, color: Palette.speaker(i))
                }
            }
        }
        .frame(height: CGFloat(shown) * rowHeight)
        .scrollDisabled(!scrolls)
        .scrollIndicators(scrolls ? .automatic : .never)
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 4
        } action: { _, end in atEnd = end }
        .overlay(alignment: .bottom) {
            if scrolls, !atEnd { moreVoices(lanes.count - Self.visibleLanes) }
        }
    }

    private func laneRow(_ lane: SpeakerLanes.Lane, color: Color) -> some View {
        let speaking = moment.map { t in lane.segments.contains { $0.contains(t) } } ?? false
        return HStack(spacing: Space.s) {
            Text(lane.name)
                .font(.system(size: nameSize, weight: speaking ? .semibold : .regular))
                .foregroundStyle(speaking ? Palette.ink : Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: gutter, alignment: .trailing)
            track(lane, color: color)
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lane.name), \(durationText(lane.seconds)) of talk")
        .accessibilityHint("Opens the transcript at their first turn")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let first = lane.segments.first { seek(first.lowerBound) } }
    }

    private func track(_ lane: SpeakerLanes.Lane, color: Color) -> some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let bar = CGRect(x: 0, y: (size.height - 8) / 2, width: size.width, height: 8)
                    context.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(Palette.fill))
                    for s in lane.segments {
                        let x = size.width * s.lowerBound / duration
                        let width = max(2, size.width * (s.upperBound - s.lowerBound) / duration)
                        context.fill(Path(roundedRect: CGRect(x: x, y: bar.minY, width: width, height: 8), cornerRadius: 1.5),
                                     with: .color(color))
                    }
                }
                if let moment { playhead(at: w * min(max(moment / duration, 0), 1)) }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in seek(duration * min(max(location.x / max(w, 1), 0), 1)) }
        }
    }

    private func playhead(at x: CGFloat) -> some View {
        Rectangle().fill(Palette.ink).frame(width: 1.5).offset(x: x - 0.75).allowsHitTesting(false)
    }

    private func moreVoices(_ n: Int) -> some View {
        Text("+\(n) more \(n == 1 ? "voice" : "voices")")
            .font(.system(size: nameSize, weight: .semibold))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Palette.window.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .allowsHitTesting(false)
            .padding(.bottom, 1)
    }

    // MARK: Ruler

    /// Decisions as dots and bookmarks as accent flags, under the lanes.
    private var ruler: some View {
        HStack(spacing: Space.s) {
            Color.clear.frame(width: gutter, height: 1)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, d in
                        if let at = d.at {
                            Circle().fill(Palette.ink).frame(width: 6, height: 6)
                                .offset(x: w * min(at / duration, 1) - 3)
                                .accessibilityElement()
                                .accessibilityLabel("Decision at \(stamp(at)): \(d.text)")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { seek(at) }
                        }
                    }
                    ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, b in
                        Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(Palette.accent)
                            .offset(x: w * min(b.offset / duration, 1) - 4)
                            .accessibilityLabel(bookmarkLabel(b))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { seek(b.offset) }
                    }
                }
                .frame(height: 12)
                .contentShape(Rectangle())
                .onTapGesture { location in seek(duration * min(max(location.x / max(w, 1), 0), 1)) }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .contain)
    }

    /// "Bookmark at 52:08: Surcharge decision"
    private func bookmarkLabel(_ b: TranscriptMarker) -> String {
        let note = b.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Bookmark at \(stamp(b.offset))" + (note.isEmpty ? "" : ": \(note)")
    }

    private var readout: some View {
        HStack(spacing: Space.s) {
            Color.clear.frame(width: gutter, height: 1)
            Text(moment.map { "\(stamp($0)) / \(stamp(duration))" } ?? stamp(duration))
                .textRole(.secondary)
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: Space.s)
            Text(moment == nil ? "Tap a lane to read from there" : "Audio plays on your Mac")
                .textRole(.secondary)
                .foregroundStyle(Palette.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

extension PhoneLanes {
    private func stamp(_ t: TimeInterval) -> String { meetingClock(t, length: duration) }
}

/// "0:52:08" in a meeting that runs past an hour, so every time in it lines up; "4:05" otherwise.
func meetingClock(_ t: TimeInterval, length: TimeInterval) -> String {
    guard length >= 3600 else { return clock(t) }
    let s = max(0, Int(t))
    return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}
/// "12 min", "1 h 5 min".
func durationText(_ seconds: TimeInterval) -> String { duration(seconds) }
