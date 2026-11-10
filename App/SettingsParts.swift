import MossadCore
import SwiftUI

/// The parts every Settings page is built from: a group in the label column with its rows divided by
/// hairlines, the rows themselves, and the canvas's 24 pt controls on the fill.
struct SettingsGroup<Content: View>: View {
    let label: String
    /// "3 need attention", in the accent under the label.
    var note: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        LabelColumn(label: label, note: note, labelTopPadding: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row.frame(maxWidth: .infinity, alignment: .leading).hairline(.bottom)
                    }
                }
                if let footer { SettingsFootnote(text: footer) }
            }
        }
    }
}

/// The quiet note under a group.
struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            .cssLineHeight(1.5, size: 12)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A title, an optional line under it, and the control on the right. The text gets all the width that the control
/// leaves, so a line does not wrap while the row has room. When the control leaves the text less than
/// `textMinimum`, the control goes under the text.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    /// A quiet word after the title: "optional".
    var titleNote: String?
    var alignment: VerticalAlignment = .center
    @ViewBuilder var trailing: Trailing
    @Environment(\.rowStyle) private var style

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // All of it on one line.
            HStack(alignment: alignment, spacing: Space.m) {
                text.fixedSize()
                Spacer(minLength: Space.m)
                trailing
            }
            // The text wraps beside the control. Its ideal width is the least it may get, so this shape is
            // chosen by the room the control leaves, not by the length of the line.
            HStack(alignment: alignment, spacing: Space.m) {
                text.frame(minWidth: Self.textMinimum, idealWidth: Self.textMinimum, maxWidth: .infinity, alignment: .leading)
                trailing
            }
            VStack(alignment: .leading, spacing: 6) {
                text
                trailing
            }
        }
        .padding(.vertical, style.padding)
    }

    private var text: some View { SettingsRowText(title: title, detail: detail, titleNote: titleNote) }

    private static var textMinimum: CGFloat { 150 }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

struct SettingsRowText: View {
    let title: String
    var detail: String?
    var titleNote: String?
    @Environment(\.rowStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let titleNote {
                    Text("\(title) \(Text(titleNote).fontWeight(.regular).foregroundStyle(Palette.tertiary))")
                } else {
                    Text(title)
                }
            }
            .font(.system(size: style.titleSize, weight: .medium)).foregroundStyle(Palette.ink)
            .cssLineHeight(size: style.titleSize)
            if let detail {
                Text(detail).font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
                    .cssLineHeight(size: style.detailSize)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row that is a switch: the whole row flips it, from the keyboard too.
struct SettingsSwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    @Environment(\.rowStyle) private var style

    var body: some View {
        Toggle(isOn: $isOn) { SettingsRowText(title: title, detail: detail) }
            .toggleStyle(SheetSwitchStyle())
            .padding(.vertical, style.padding)
    }
}

/// The canvas's small controls: 24 pt, the fill, or the accent for the one action that needs the owner.
struct SettingsButtonStyle: ButtonStyle {
    var accent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: accent ? .semibold : .medium))
            .foregroundStyle(accent ? Palette.onAccent : Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(accent ? Palette.accentFill : configuration.isPressed ? Palette.selection : Palette.fill, in: shape)
            .overlay { if accent, configuration.isPressed { shape.fill(.black.opacity(0.12)) } }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsAccent: SettingsButtonStyle { SettingsButtonStyle(accent: true) }
}

/// Text that acts: "Open", "Remove", "Delete all saved voices…".
struct SettingsTextButtonStyle: ButtonStyle {
    var color: Color = Palette.secondary
    var weight: Font.Weight = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: weight))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A field on the fill, 24 pt tall.
struct SettingsFieldStyle: TextFieldStyle {
    var width: CGFloat?
    var monospaced = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.s)
            // The canvas gives a field's width without its 8 pt padding on each side (CSS content-box).
            .frame(width: width.map { $0 + 2 * Space.s }, height: 24)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// A menu of choices drawn as the canvas's fill control with a chevron. A system menu underneath, so the
/// keyboard and VoiceOver treat it as a pop-up button.
struct FillPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(value: Value, label: String)]
    var width: CGFloat?
    /// Choices above the others, set apart by a separator.
    var leading: [(value: Value, label: String)] = []

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(leading, id: \.value) { Text($0.label).tag($0.value) }
                if !leading.isEmpty { Divider() }
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            FillMenuLabel(text: (leading + choices).first { $0.value == selection }?.label ?? "", width: width)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// "Turn off ⌄": a label on the fill with a chevron, for menus.
struct FillMenuLabel: View {
    let text: String
    var width: CGFloat?

    var body: some View {
        HStack(spacing: 6) {
            Text(text).lineLimit(1).truncationMode(.tail)
            if width != nil { Spacer(minLength: 0) }
            IconImage(.chevronDown, size: 10).foregroundStyle(Palette.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Palette.ink)
        .padding(.leading, 10).padding(.trailing, Space.s)
        .frame(width: width, height: 24)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A number of days in a fill field, with the unit after it.
struct DaysField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: Space.s) {
            TextField(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), format: .number)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(SettingsFieldStyle(width: 48))
            Stepper(title, value: $value, in: range).labelsHidden().controlSize(.small)
            Text(value == 1 ? "day" : "days").font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }
}

/// "Key set · Change", or "Set key" in the accent when it is missing. The key itself never shows.
struct KeyStatus: View {
    @EnvironmentObject var controller: AppController
    let key: APIKey
    let edit: (APIKey) -> Void

    var body: some View {
        let set = controller.hasKey(key)
        HStack(spacing: Space.s) {
            Text(set ? "Key set" : "No key").font(.system(size: 12)).foregroundStyle(set ? Palette.secondary : Palette.accent)
            Button(set ? "Change" : "Set key…") { edit(key) }
                .buttonStyle(SettingsButtonStyle(accent: !set))
                .accessibilityLabel(set ? "Change the \(key.displayName)" : "Set the \(key.displayName)")
        }
    }
}

/// A selectable row with a radio mark: one choice among a few.
struct RadioRow<Trailing: View>: View {
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                RadioMark(on: selected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium)).foregroundStyle(Palette.ink)
                        .cssLineHeight(size: 13)
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).cssLineHeight(size: 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.m)
                trailing
            }
            .padding(.vertical, 9)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The canvas's radio: a ring, or the accent with a white center.
struct RadioMark: View {
    let on: Bool

    var body: some View {
        Group {
            if on {
                Circle().fill(Palette.accentFill).overlay { Circle().fill(.white).frame(width: 6, height: 6) }
            } else {
                Circle().strokeBorder(Palette.ring, lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 16)
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

/// A dot and a few words: "Synced 2 minutes ago", "Available".
struct StatusLine: View {
    struct Model {
        var text: String
        var color: Color
        var busy = false
    }

    let model: Model

    var body: some View {
        HStack(spacing: 6) {
            if model.busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(model.color).frame(width: 7, height: 7)
            }
            Text(model.text).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A command or address in monospace on the fill, with Copy beside it.
struct CopyField: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        HStack(spacing: Space.s) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .cssLineHeight(1.4, size: 11.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.s).padding(.vertical, 4)
                // The canvas's 24 pt minimum is without its 4 pt padding (CSS content-box).
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            Button(copied ? "Copied" : label) {
                copy(text)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .buttonStyle(.settings)
        }
    }
}
