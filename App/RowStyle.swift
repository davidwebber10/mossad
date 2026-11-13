import SwiftUI

/// Where a shared row sits. Settings is dense, with 24 pt controls; setup's rows are a little taller, with the
/// sheet's controls. A row reads this, so setup and Settings draw the same row and neither keeps a copy.
enum RowStyle {
    case settings, setup

    var padding: CGFloat { self == .setup ? Onboard.rowPadding : 9 }
    var titleSize: CGFloat { self == .setup ? 13.5 : 13 }
    var detailSize: CGFloat { self == .setup ? 12.5 : 12 }
}

extension EnvironmentValues {
    @Entry var rowStyle: RowStyle = .settings
}

extension View {
    /// A row's button in the look of its place; the accent for the one action that needs the owner.
    func rowButton(accent: Bool = false) -> some View { modifier(RowButton(accent: accent)) }
}

private struct RowButton: ViewModifier {
    let accent: Bool
    @Environment(\.rowStyle) private var style

    func body(content: Content) -> some View {
        if style == .setup {
            content.buttonStyle(SheetButtonStyle(kind: accent ? .primary : .secondary, compact: true))
        } else {
            content.buttonStyle(SettingsButtonStyle(accent: accent))
        }
    }
}

/// "Get a key" with the arrow that says it leaves the app. Quiet once there is nothing to get.
struct RowLink: View {
    let text: String
    let destination: URL
    var quiet = false
    var spoken: String?
    @Environment(\.rowStyle) private var style

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: Space.xs) {
                Text(text)
                IconImage(.arrowUp, size: 10).rotationEffect(.degrees(45))
            }
        }
        .font(.system(size: style.detailSize, weight: .medium))
        .foregroundStyle(quiet ? Palette.secondary : Palette.accent)
        .accessibilityLabel(spoken ?? text)
    }
}

/// One decision: its name beside the control, then a line on what it decides across the full width, then what
/// rates the choice. The line is under the control, not beside it, so a long one does not wrap into a column.
struct ChoiceRow<Control: View, Below: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control
    @ViewBuilder var below: Below
    @Environment(\.rowStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            // In a narrow column a wide control goes under its name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.m) {
                    name.fixedSize()
                    Spacer(minLength: Space.m)
                    control
                }
                VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                    name
                    control
                }
            }
            if let detail {
                Text(detail).font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
                    .cssLineHeight(size: style.detailSize)
                    .fixedSize(horizontal: false, vertical: true)
                    // The control is taller than the title, so the line starts closer to the title than to it.
                    .padding(.top, -5)
            }
            below.padding(.top, 2)
        }
        .padding(.vertical, style.padding)
    }

    private var name: some View {
        Text(title).font(.system(size: style.titleSize, weight: .medium)).foregroundStyle(Palette.ink)
    }
}

extension ChoiceRow where Below == EmptyView {
    init(title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(title: title, detail: detail, control: control) { EmptyView() }
    }
}
