import AppKit
import SwiftUI

/// The parts every sheet shares: an accent tile and a title over a hairline, a body, and the buttons under a
/// hairline. Sheets are the opaque window color; only popovers and menus are glass.
struct SheetHeader: View {
    /// The canvas's own icon for the sheet, drawn in the accent tile.
    let icon: Icon
    let title: String
    var subtitle: String?
    /// With this, the header has a close control in its corner, and Escape and Command-period close the sheet.
    var close: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 12) {
                IconImage(icon, size: 16)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let close { SheetCloseButton(action: close) }
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 16, trailing: close == nil ? 22 : 16))
        .hairline(.bottom)
    }
}

/// The close control in a sheet's corner: a small X on the fill. Escape presses it, and so does Command-period.
struct SheetCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(hovering ? Palette.ink : Palette.secondary)
                .frame(width: 22, height: 22)
                .background(hovering ? Palette.selection : Palette.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.cancelAction)
        .background { Button("Close", action: action).keyboardShortcut(".", modifiers: .command).opacity(0).accessibilityHidden(true) }
        .accessibilityLabel("Close")
        .help("Close (Esc)")
    }
}

/// The button row: a quiet note or a destructive action on the left, the actions on the right.
struct SheetFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .hairline(.top)
    }
}

extension SheetFooter where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.leading = EmptyView()
        self.trailing = trailing()
    }
}

extension View {
    /// Closes a sheet when its owner clicks the window under it. The click goes no further, so it cannot also press
    /// something in that window. A sheet with another sheet or an alert over it ignores the click.
    func closesOnOutsideClick(_ action: @escaping () -> Void) -> some View {
        background(OutsideClickWatcher(action: action))
    }

    /// A sheet's ground: the opaque window color at the canvas's width.
    func mossadSheet(width: CGFloat) -> some View {
        frame(width: width)
            .background(Palette.window)
            .foregroundStyle(Palette.ink)
            .font(.system(size: 13))
    }

    /// A group inside a sheet: a hairline ring, no fill, so it stays on the window's paper.
    func sheetCard(horizontal: CGFloat = 16, vertical: CGFloat = 14) -> some View {
        padding(.horizontal, horizontal).padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairlineBorder(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The sheet buttons of the canvas, 30 pt tall: the accent primary, the quiet fill, accent text, and red text
/// for a destructive action.
struct SheetButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text, destructive }
    var kind: Kind
    var compact = false

    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 12.5
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: textSize, weight: kind == .secondary ? .medium : .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .text ? 4 : compact ? 11 : 14)
            .frame(height: compact || kind == .text ? 26 : 30)
            .background(background(pressed: configuration.isPressed), in: shape)
            .overlay { if kind == .primary, configuration.isPressed { shape.fill(.black.opacity(0.12)) } }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Palette.onAccent
        case .secondary: Palette.ink
        case .text: Palette.accent
        case .destructive: Palette.recording
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Palette.accentFill
        case .secondary: pressed ? Palette.selection : Palette.fill
        case .text, .destructive: pressed ? Palette.fill : .clear
        }
    }
}

extension ButtonStyle where Self == SheetButtonStyle {
    static var sheetPrimary: SheetButtonStyle { SheetButtonStyle(kind: .primary) }
    static var sheetSecondary: SheetButtonStyle { SheetButtonStyle(kind: .secondary) }
    static var sheetText: SheetButtonStyle { SheetButtonStyle(kind: .text) }
    static var sheetDestructive: SheetButtonStyle { SheetButtonStyle(kind: .destructive) }
}

/// A field on the fill with no border, 30 pt tall.
struct SheetFieldStyle: TextFieldStyle {
    var monospaced = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The canvas's switch: 34 by 20, the accent fill when on, the bar color when off. A button underneath, so Tab
/// reaches it and Space flips it.
struct SheetSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                Capsule()
                    .fill(configuration.isOn ? Palette.accentFill : Palette.bar)
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                            .padding(2)
                    }
                    .opacity(isEnabled ? 1 : 0.45)
                    .animation(.snappy(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// The canvas's checkbox box: 16 pt, the accent fill with a check when on, a ring when off.
struct SheetCheckbox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isOn ? Palette.accentFill : .clear)
            .overlay {
                if isOn {
                    IconImage(.checkSmall, size: 11).foregroundStyle(Palette.onAccent)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.ring, lineWidth: 1.5)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// A checkbox row: the box, then the label. A button underneath, so Tab reaches it and Space flips it.
struct SheetCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                SheetCheckbox(isOn: configuration.isOn)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A small glass segmented control, for one choice among a few short words.
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [(value: Value, title: String)]
    @Namespace private var on

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.value) { choice in
                let selected = choice.value == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = choice.value } } label: {
                    Text(choice.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.ink : Palette.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background {
                            if selected {
                                Capsule().fill(Palette.segmentOn)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "on", in: on)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .mossadGlass(in: Capsule())
    }
}

/// Watches the clicks of the app while its sheet shows, and calls `action` for a click in the window under the sheet.
private struct OutsideClickWatcher: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.action = action
        context.coordinator.start(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.action = action }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        var action: () -> Void = {}
        private weak var view: NSView?
        private var monitor: Any?

        func start(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, let sheet = self.view?.window, let parent = sheet.sheetParent,
                      event.window === parent, sheet.attachedSheet == nil else { return event }
                self.action()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
