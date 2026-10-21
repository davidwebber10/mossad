import AppKit
import MossadCore
import SwiftUI

/// The redesign's tokens (docs/superpowers/specs/2026-10-21-ui-redesign.md, section 1).
enum Theme {
    static let field = Color.primary.opacity(0.06)
    static let hover = Color.primary.opacity(0.07)
    /// Cards and tables: white in light mode, a step above the window in dark mode.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x2b / 255, green: 0x2b / 255, blue: 0x30 / 255, alpha: 1)
            : .white
    })
    static let separator = Color(nsColor: .separatorColor)

    static let listening = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let recording = Color(red: 1, green: 0.23, blue: 0.19)
    static let warning = Color.orange
    static let unknown = Color(red: 0.56, green: 0.56, blue: 0.58)

    /// The owner first, then by first appearance.
    static let speakerPalette: [Color] = [
        Color(hex: 0x0a7aff), Color(hex: 0xff9500), Color(hex: 0xaf52de), Color(hex: 0x34c759),
        Color(hex: 0xff2d55), Color(hex: 0x30b0c7), Color(hex: 0x5e5ce6), Color(hex: 0xa2845e),
    ]
}

/// "Jordan" for "Jordan Lee"; unnamed voices keep their label ("Speaker C").
func shortName(_ name: String) -> String {
    if name.hasPrefix("Speaker ") || name.contains("@") { return name }
    return name.split(separator: " ").first.map(String.init) ?? name
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension Platform {
    var color: Color {
        switch self {
        case .meet: Color(hex: 0x00ac47)
        case .zoom: Color(hex: 0x2d8cff)
        case .teams: Color(hex: 0x5b5fc7)
        }
    }
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
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay {
                if pulsing, !reduceMotion {
                    Circle().stroke(color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(animate ? (size + 14) / size : 1)
                        .opacity(animate ? 0 : 1)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: animate)
                        .onAppear { animate = true }
                }
            }
    }
}

/// A capsule label such as "Needs names", "Processing", or "Failed".
struct StatusBadge: View {
    enum Kind { case needsNames, processing, failed, recording }
    let kind: Kind

    var body: some View {
        HStack(spacing: 4) {
            switch kind {
            case .needsNames: Image(systemName: "person.wave.2").font(.system(size: 9))
            case .processing: ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            case .recording: StatusDot(color: Theme.recording, size: 6, pulsing: true)
            case .failed: EmptyView()
            }
            Text(label)
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

extension View {
    /// The design's glass surfaces (player, hover card).
    func mossadGlass(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
