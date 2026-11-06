import AppKit
import MossadCore
import SwiftUI

/// Old names for the editorial tokens in SharedUI/Tokens.swift, so screens not yet rebuilt keep compiling.
/// They go away once every screen uses `Palette` directly.
enum Theme {
    static let background = Palette.window
    static let field = Palette.fill
    static let hover = Palette.selection
    static let surface = Palette.surface
    static let separator = Palette.hairline

    static let listening = Palette.ok
    static let recording = Palette.recording
    static let warning = Palette.accent
    static let unknown = Palette.tertiary

    static let speakerPalette = Palette.speakers
}

/// "Jordan L." for "Jordan Lee", so two people with one first name stay apart; unnamed voices keep their
/// label ("Speaker C").
func shortName(_ name: String) -> String {
    if name.hasPrefix("Speaker ") || name.contains("@") { return name }
    let words = name.split(separator: " ")
    guard let first = words.first else { return name }
    guard words.count > 1, let initial = words.last?.first else { return String(first) }
    return "\(first) \(initial)."
}

/// The first word of a name, for matching an action item owner written as a first name.
func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension Platform {
    var color: Color { Palette.platform(self) }
}

/// The small rounded square before a meeting title.
struct PlatformSquare: View {
    let platform: Platform
    var size: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(platform.color)
            .frame(width: size, height: size)
    }
}

/// A status dot; recording dots pulse with a fading ring.
extension EnvironmentValues {
    /// False while the window or panel cannot be seen: animations stop instead of drawing for nobody.
    @Entry var animationsActive = true
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsActive) private var active

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay {
                if pulsing, !reduceMotion, active {
                    // Core Animation runs the pulse on its own, outside SwiftUI's view updates.
                    PulseRing(color: NSColor(color.opacity(0.5)), size: size)
                        .frame(width: size, height: size)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A capsule label such as "Needs names", "Processing", or "Failed".
struct StatusBadge: View {
    enum Kind { case needsNames, processing, failed, recording }
    let kind: Kind
    /// Replaces the word "Processing" with the live sub-step.
    var text: String?

    var body: some View {
        HStack(spacing: 4) {
            switch kind {
            case .needsNames: Image(systemName: "person.wave.2").font(.system(size: 9))
            case .processing: ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            case .recording: StatusDot(color: Theme.recording, size: 6, pulsing: true)
            case .failed: EmptyView()
            }
            Text(text ?? label).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(background, in: Capsule())
    }

    private var label: String {
        switch kind {
        case .needsNames: "Needs names"
        case .processing: "Processing"
        case .failed: "Failed"
        case .recording: "Recording"
        }
    }

    private var foreground: Color {
        switch kind {
        case .failed: Color(nsColor: .systemOrange)
        case .recording: Theme.recording
        default: .secondary
        }
    }

    private var background: Color {
        switch kind {
        case .failed: Color.orange.opacity(0.16)
        case .recording: Theme.recording.opacity(0.14)
        default: Theme.field
        }
    }
}

/// Shown while the person is muted in the call app: Mossad records silence on their mic meanwhile. A quiet
/// note on the fill, not a warning: being muted is normal.
struct MutedBanner: View {
    let platform: Platform
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "mic.slash").font(.system(size: compact ? 12 : 13.5, weight: .medium)).foregroundStyle(Palette.secondary)
            Text("\(Text("Muted in \(platform.displayName).").fontWeight(.semibold).foregroundStyle(Palette.ink)) \(Text("Your mic is not recorded while you are muted.").foregroundStyle(Palette.secondary))")
                .font(.system(size: compact ? 12 : 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 8 : 10)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A ring that grows and fades from the dot, repeated by Core Animation.
private struct PulseRing: NSViewRepresentable {
    let color: NSColor
    let size: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = (size + 14) / size
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        ring.add(group, forKey: "pulse")
        view.layer?.addSublayer(ring)
        // The ring grows past the dot's own frame.
        view.layer?.masksToBounds = false
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
