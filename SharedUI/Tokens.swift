import MossadCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The editorial design's colors (docs/superpowers/specs/2026-11-06-editorial-redesign-design.md, "Design
/// system"). Each one has its light and dark value from the canvas, so both apps resolve them the same way.
enum Palette {
    /// The window background: warm paper.
    static let window = Color(light: 0xF6F4F0, dark: 0x1E1D1B)
    /// Opaque content and the glass fallback under Reduce Transparency.
    static let surface = Color(light: 0xFBFAF7, dark: 0x262523)
    /// What shows behind the window and the sidebar's glass.
    static let material = Color(light: 0xE1DDD6, dark: 0x2B2A2E)
    /// Rows, chips, and secondary buttons. Translucent so it reads the same on the window and on a surface.
    static let fill = Color(light: 0x1C1A17, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.08)
    /// The selected row and the transcript's current turn. A little lighter than the canvas (.08 light, .10 dark)
    /// so secondary text on it meets 4.5:1: 4.52 on the window and 4.75 on the surface in light mode, 5.07 and
    /// 4.55 in dark mode.
    static let selection = Color(light: 0x1C1A17, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.085)
    /// Increase Contrast raises it to 20% ink.
    static let hairline = Color(
        light: 0x1C1A17, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.09,
        contrastLight: 0x1C1A17, contrastLightAlpha: 0.2, contrastDark: 0xF1EEE8, contrastDarkAlpha: 0.2)
    /// Hollow marks: an unnamed person's avatar, an upcoming meeting's dot.
    static let ring = Color(light: 0x1C1A17, lightAlpha: 0.3, dark: 0xFFFFFF, darkAlpha: 0.3)
    /// Speech bars in the lanes when no speaker hue applies, and meters.
    static let bar = Color(light: 0x1C1A17, lightAlpha: 0.16, dark: 0xFFFFFF, darkAlpha: 0.18)

    static let ink = Color(light: 0x1C1A17, dark: 0xF1EEE8)
    static let secondary = Color(light: 0x6B665E, dark: 0xA6A097)
    /// The sidebar's sections that are not open: a little softer than ink.
    static let navText = Color(light: 0x3E3A34, dark: 0xD6D1C9)
    /// Tertiary text. The canvas's tertiary measures under 3.3:1, so text uses this darker (light) and lighter
    /// (dark) value of the same hue, which meets 4.5:1 on the window and on the surface. On fill or selection,
    /// use secondary.
    static let tertiary = Color(light: 0x746F66, dark: 0x908B82)
    /// The canvas's tertiary, for marks only: dots, icons, rules. Not for text.
    static let tertiaryMark = Color(light: 0x9B968D, dark: 0x726D65)

    /// Accent text and icons: darker than the fill in light mode so it meets 4.5:1.
    static let accent = Color(light: 0xA84D14, dark: 0xF2A05A)
    /// Accent surfaces: the primary button, the processing fill, the selected control.
    static let accentFill = Color(light: 0xC2601E, dark: 0xE8964E)
    /// Behind "needs you" chips and banners.
    static let accentTint = Color(light: 0xC2601E, lightAlpha: 0.12, dark: 0xE8964E, darkAlpha: 0.16)
    /// Text on the accent fill.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x1E1D1B)

    /// Only while audio is captured, and for destructive actions.
    static let recording = Color(light: 0xC43D31, dark: 0xFF6B5E)
    static let recordingTint = Color(light: 0xC43D31, lightAlpha: 0.1, dark: 0xFF6B5E, darkAlpha: 0.14)
    /// The faint ground under an error line in the log: lighter than the tint, so long text stays easy to read.
    static let errorWash = Color(light: 0xC43D31, lightAlpha: 0.07, dark: 0xFF6B5E, darkAlpha: 0.1)
    /// Done, connected, granted: for marks only (dots, icons). Not for text.
    static let ok = Color(light: 0x1E8E5A, dark: 0x3FCB84)
    /// "Connected", "Granted" as text: a darker green in light mode so it meets 4.5:1 on the window and the
    /// surface. On fill or selection, use secondary.
    static let okText = Color(light: 0x1B7F51, dark: 0x3FCB84)

    /// The canvas's stand-in for Liquid Glass and the sidebar; the apps use the system glass, so these only
    /// serve hand-drawn glass such as a popover arrow.
    static let glass = Color(light: 0xFFFFFF, lightAlpha: 0.6, dark: 0x3C3A37, darkAlpha: 0.6)
    static let sidebar = Color(light: 0xFFFFFF, lightAlpha: 0.58, dark: 0x34322F, darkAlpha: 0.6)
    static let glassRing = Color(light: 0xFFFFFF, lightAlpha: 0.9, dark: 0xFFFFFF, darkAlpha: 0.1)
    /// The selected segment of a segmented control.
    static let segmentOn = Color(light: 0xFFFFFF, dark: 0xFFFFFF, darkAlpha: 0.14)
    /// A solid control that sits on the header band and must read as raised from it, such as the meeting tabs.
    static let raised = Color(light: 0xFFFFFF, dark: 0x363431)

    static let meet = Color(light: 0x1E8E5A, dark: 0x3FCB84)
    static let zoom = Color(light: 0x2563EB, dark: 0x6AA6FF)
    static let teams = Color(light: 0x5B5FC7, dark: 0x9598FF)
    static let inPerson = Color(light: 0x8A8178, dark: 0xA49B91)

    /// Identity only: dots and icons, never surfaces or text.
    static func platform(_ platform: Platform) -> Color {
        switch platform {
        case .meet: meet
        case .zoom: zoom
        case .teams: teams
        case .inPerson: inPerson
        }
    }

    /// Twelve hues 30° apart at equal lightness and chroma: oklch(0.58 0.15 h) light, oklch(0.74 0.15 h) dark.
    /// The owner is always the first.
    static let speakers: [Color] = [25, 55, 85, 115, 145, 175, 205, 235, 265, 295, 325, 355].map { hue in
        Color(light: OKLCH(lightness: 0.58, chroma: 0.15, hue: hue), dark: OKLCH(lightness: 0.74, chroma: 0.15, hue: hue))
    }

    /// Wraps past twelve so a large meeting never runs out of colors.
    static func speaker(_ index: Int) -> Color { speakers[((index % speakers.count) + speakers.count) % speakers.count] }
}

/// The 4 pt grid.
enum Space {
    /// Inside a chip.
    static let xs: CGFloat = 4
    /// Between chips, icon to label.
    static let s: CGFloat = 8
    /// Row padding, and the gap between the label column and its content.
    static let m: CGFloat = 12
    /// Card padding.
    static let l: CGFloat = 16
    /// Between sections, and the page gutter.
    static let xl: CGFloat = 24
    /// Before a new story on dense pages.
    static let xxl: CGFloat = 40
}

/// The Mac window's chrome, from the canvas's window: the floating sidebar card, the list column, and the detail
/// column's toolbar row with its glass capsules.
enum Chrome {
    /// The sidebar column, with the card inset 10 pt from the window (4 pt toward the list). The canvas sizes
    /// boxes without their padding, so its 196 pt sidebar is a 196 pt card in a 210 pt column; the same holds
    /// below for the list (300 + 12), the toolbar row (52 + 10), and the search (240 + 24).
    static let sidebarWidth: CGFloat = 210
    static let sidebarInset = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 4)
    static let sidebarPadding = EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
    static let sidebarRadius: CGFloat = 16
    /// The traffic lights' row inside the card (24 pt and 2 pt above), and the space from it to the first section.
    static let lightsRow: CGFloat = 26
    static let lightsToNav: CGFloat = 22
    static let navRowHeight: CGFloat = 30
    static let navRowRadius: CGFloat = 8
    static let navRowGap: CGFloat = 2
    static let navRowPadding: CGFloat = 9
    static let navIcon: CGFloat = 16
    static let navIconGap: CGFloat = 9

    /// The list column: 312 pt by default (300 inside 4 and 8 pt), resizable between these, with its own 36 pt
    /// title row.
    static let listWidth: CGFloat = 312
    static let listWidthRange: ClosedRange<CGFloat> = 252...472
    static let listTitleHeight: CGFloat = 36
    static let listTop: CGFloat = 10
    static let listTitleLeading: CGFloat = 14
    /// The least the detail column gets: the Meetings toolbar (view, search, export and more) and its band fit.
    /// The window's minimum width is the sidebar, the default list, and this.
    static let detailMinWidth: CGFloat = 538
    static var windowMinWidth: CGFloat { sidebarWidth + listWidth + detailMinWidth }

    /// The detail column's toolbar row and its glass controls.
    static let toolbarHeight: CGFloat = 62
    static let toolbarInsets = EdgeInsets(top: 10, leading: 36, bottom: 0, trailing: 16)
    static let controlHeight: CGFloat = 30
    static let controlPadding: CGFloat = 3
    static let segment = CGSize(width: 32, height: 24)
    static let iconCell = CGSize(width: 30, height: 24)
    /// 240 and 12 pt padding on each side; it narrows to the minimum before any other control would clip.
    static let searchWidth: CGFloat = 264
    static let searchMinWidth: CGFloat = 150
    static let groupGap: CGFloat = 8
}

/// The meeting detail, from the canvas: the header band, the lanes player, the tab capsule, and the tab bodies.
extension Palette {
    /// The band at the top of a meeting or a person: a trace of ink over the window, so the title and the player read as one block.
    static let band = Color(light: 0x1C1A17, lightAlpha: 0.035, dark: 0xFFFFFF, darkAlpha: 0.035)
    /// The band over the window as one opaque color, for the fade at the foot of scrolling lanes.
    static let bandOpaque = Color(light: 0xEEECE9, dark: 0x262523)
}

enum Detail {
    /// The reading column and its gutter.
    static let columnMax: CGFloat = 980
    static let gutter: CGFloat = 36
    /// The band: 30 pt above and below, then a hairline.
    static let bandPadding: CGFloat = 30
    static let titleSize: CGFloat = 26
    static let titleMax: CGFloat = 740
    /// The label column every tab and the lanes share, and the gap after it.
    static let labelColumn: CGFloat = 150
    static let labelGap: CGFloat = 12
    static var labelGutter: CGFloat { labelColumn + labelGap }

    /// A lane is one line of 12 pt text (16 pt) with an 11 pt track centered in it; the bars sit 1.5 pt inside
    /// the track. Rows are 3 pt apart, so they repeat every 19 pt.
    static let laneRow: CGFloat = 16
    static let laneGap: CGFloat = 3
    static let laneTrack: CGFloat = 11
    static let laneTrackRadius: CGFloat = 3
    static let laneBarInset: CGFloat = 1.5
    static let laneBarRadius: CGFloat = 1.5
    static let laneMinutes: CGFloat = 30
    /// Turns closer than this many points join into one block, and a block is at least this wide.
    static let laneMergeGap: CGFloat = 4
    static let laneMinBlock: CGFloat = 3
    /// Space the band leaves under the player for the tab's content when it picks how many lanes to show.
    static let lanesReserve: CGFloat = 230

    static let rulerHeight: CGFloat = 26
    static let transportHeight: CGFloat = 32
    static let transportGap: CGFloat = 12
    static let playButton: CGFloat = 28
    static let skipButton: CGFloat = 26
    static let bookmarkHeight: CGFloat = 28

    /// The tab capsule sits on the band's lower edge; this much of it hangs below.
    static let underTabs: CGFloat = 17

    /// The chat composer: a floating glass field centered over the tab, 720 pt inside 18 and 6 pt of padding.
    static let composerWidth: CGFloat = 744
    static let composerHeight: CGFloat = 46
    static let composerSend: CGFloat = 34
    /// The canvas's page body starts 10 pt under the toolbar row.
    static let bodyTop: CGFloat = 10
    /// Lists that read as a page (Commitments) stop at 960 pt.
    static let listMax: CGFloat = 960
}

/// Concentric radii: an inner radius is the outer one minus the padding between them. Capsules use `Capsule()`.
enum Radius {
    static let control: CGFloat = 6
    static let row: CGFloat = 10
    static let card: CGFloat = 14
    static let pane: CGFloat = 20
}

/// The seven type steps. The Mac uses the canvas's desktop sizes; the iPhone canvas sets its own larger
/// scale (32 pt titles, 15 pt body, 13 pt secondary), and iPhone sizes follow Dynamic Type.
enum TextRole: CaseIterable {
    case display, title, lede, headline, body, secondary, label

    var size: CGFloat {
        #if os(iOS)
        switch self {
        case .display: 32
        case .title: 22
        case .lede: 17
        case .headline: 15
        case .body: 15
        case .secondary: 13
        case .label: 11
        }
        #else
        switch self {
        case .display: 28
        case .title: 22
        case .lede: 17
        case .headline: 13
        case .body: 13
        case .secondary: 12
        case .label: 11
        }
        #endif
    }

    var weight: Font.Weight {
        switch self {
        #if os(iOS)
        case .display: .bold
        #else
        case .display: .semibold
        #endif
        case .title, .headline, .label: .semibold
        case .lede: .medium
        case .body, .secondary: .regular
        }
    }

    /// Letter spacing in em, from the canvas: large type tightens, caps open up.
    var trackingEm: CGFloat {
        switch self {
        case .display: -0.02
        case .title: -0.015
        case .label: 0.06
        default: 0
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title: .title2
        case .lede: .title3
        case .headline: .headline
        case .body: .body
        case .secondary: .callout
        case .label: .caption
        }
    }
}

extension View {
    /// The canvas's CSS line height (it sets 1.35 on the window): SwiftUI lays out SF text at about 1.19 em a line,
    /// so the rest goes between lines and half above and below, as CSS spreads it. Without it every row reads
    /// tighter than the canvas.
    func cssLineHeight(_ multiple: CGFloat = 1.35, size: CGFloat) -> some View {
        let extra = max(0, (multiple - 1.19) * size)
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }

    /// Font, tracking, caps, and tabular numbers for a type step. Color stays with the caller (`Palette`).
    func textRole(_ role: TextRole) -> some View { modifier(TextRoleModifier(role: role)) }
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole
    @ScaledMetric private var scale: CGFloat

    init(role: TextRole) {
        self.role = role
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: role.textStyle)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let size = role.size * scale
        let styled = content
            .font(.system(size: size, weight: role.weight))
            .tracking(size * role.trackingEm)
            .monospacedDigit()
        // Only the label sets a case: `textCase(nil)` on the others would clear a parent's.
        if role == .label { styled.textCase(.uppercase) } else { styled }
    }
}

/// A color in the OKLCH space, as the canvas writes the speaker hues.
struct OKLCH {
    let lightness: Double
    let chroma: Double
    let hue: Double

    /// Display P3 components. A color outside P3 loses chroma until it fits, as CSS gamut mapping does, so the
    /// hue and lightness stay put.
    var displayP3: (red: Double, green: Double, blue: Double) {
        if let p3 = Self.displayP3(lightness, chroma, hue) { return p3 }
        var low = 0.0, high = chroma
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if Self.displayP3(lightness, mid, hue) != nil { low = mid } else { high = mid }
        }
        return Self.displayP3(lightness, low, hue) ?? (lightness, lightness, lightness)
    }

    private static func displayP3(_ l: Double, _ c: Double, _ h: Double) -> (red: Double, green: Double, blue: Double)? {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l3 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m3 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s3 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        // Linear sRGB, then XYZ (D65), then linear Display P3.
        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        let x = 0.4123907993 * r + 0.3575843394 * g + 0.1804807884 * bl
        let y = 0.2126390059 * r + 0.7151686788 * g + 0.0721923054 * bl
        let z = 0.0193308187 * r + 0.1191947798 * g + 0.9505321522 * bl
        let linear = [
            2.4934969119 * x - 0.9313836179 * y - 0.4027107845 * z,
            -0.8294889696 * x + 1.7626640603 * y + 0.0236246858 * z,
            0.0358458302 * x - 0.0761723893 * y + 0.9568845240 * z,
        ]
        guard linear.allSatisfy({ $0 >= -0.0001 && $0 <= 1.0001 }) else { return nil }
        let encoded = linear.map { v in
            let v = min(max(v, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return (encoded[0], encoded[1], encoded[2])
    }
}

extension Color {
    /// A color that follows the appearance on both platforms; the contrast values apply under Increase Contrast.
    init(
        light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1,
        contrastLight: UInt32? = nil, contrastLightAlpha: Double = 1,
        contrastDark: UInt32? = nil, contrastDarkAlpha: Double = 1
    ) {
        let normal = (light: PlatformColor(hex: light, alpha: lightAlpha), dark: PlatformColor(hex: dark, alpha: darkAlpha))
        let contrast = (
            light: contrastLight.map { PlatformColor(hex: $0, alpha: contrastLightAlpha) } ?? normal.light,
            dark: contrastDark.map { PlatformColor(hex: $0, alpha: contrastDarkAlpha) } ?? normal.dark)
        self.init(dynamic: { isDark, highContrast in
            let set = highContrast ? contrast : normal
            return isDark ? set.dark : set.light
        })
    }

    init(light: OKLCH, dark: OKLCH) {
        let l = light.displayP3, d = dark.displayP3
        let lightColor = PlatformColor(displayP3Red: l.red, green: l.green, blue: l.blue, alpha: 1)
        let darkColor = PlatformColor(displayP3Red: d.red, green: d.green, blue: d.blue, alpha: 1)
        self.init(dynamic: { isDark, _ in isDark ? darkColor : lightColor })
    }

    private init(dynamic: @escaping @Sendable (_ isDark: Bool, _ highContrast: Bool) -> PlatformColor) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let highContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            return dynamic(isDark, highContrast)
        })
        #else
        self.init(uiColor: UIColor { traits in
            dynamic(traits.userInterfaceStyle == .dark, traits.accessibilityContrast == .high)
        })
        #endif
    }
}

#if canImport(AppKit)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

extension PlatformColor {
    convenience init(hex: UInt32, alpha: Double) {
        let red = CGFloat((hex >> 16) & 0xff) / 255, green = CGFloat((hex >> 8) & 0xff) / 255, blue = CGFloat(hex & 0xff) / 255
        #if canImport(AppKit)
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        self.init(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }
}
