import AppKit
import MossadCore
import SwiftUI

/// The profile color for AppKit; the color itself and `ProfileDot` are in `SharedUI/ProfileDot.swift`.
extension ProfileColor {
    var nsColor: NSColor { NSColor(color) }
}

/// The control at the bottom of the sidebar, with two profiles or more: the active profile's color and name, and a
/// menu of the profiles, "Add profile…", and "Manage profiles…".
struct ProfileSwitcher: View {
    @EnvironmentObject var controller: AppController
    let menu: ProfileMenu

    var body: some View {
        Menu {
            if let note = menu.note {
                Text(note)
            }
            ForEach(menu.rows) { row in
                Button {
                    controller.switchProfile(to: row.id)
                } label: {
                    if row.active {
                        Label(row.name, systemImage: "checkmark")
                    } else if let status = row.status {
                        // The menu shows the second Text as the item's second line, in its own secondary style.
                        Text(row.name)
                        Text(status)
                    } else {
                        Text(row.name)
                    }
                }
                .accessibilityLabel(row.status.map { "\(row.name), \($0)" } ?? row.name)
                .disabled(menu.note != nil || row.active)
            }
            Divider()
            Button(ProfileMenu.add) { controller.openProfileSettings(sheet: .add) }
                .disabled(menu.note != nil || !controller.profiles.canSave)
            if let why = ProfileSettingsWords.changeRefusal(controller.profiles) {
                Text(why)
            }
            Button(ProfileMenu.manage) { controller.openProfileSettings(sheet: nil) }
        } label: {
            HStack(spacing: Chrome.navIconGap) {
                ProfileDot(color: menu.color)
                    .frame(width: Chrome.navIcon, height: Chrome.navIcon)
                Text(menu.title)
                    .font(.system(size: Rhythm.bodySize, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, Chrome.navRowPadding)
            .frame(height: Chrome.navRowHeight)
            .contentShape(Rectangle())
        }
        // The button style with a plain button keeps the label as drawn; the borderless style keeps only its text.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(ProfileSettingsWords.accessibilityLabel(controller.activeProfile))
        .help("Change the profile")
    }
}

/// Under the switcher, quiet: why the last switch or Add did not happen, for a while, and a refusal for a call only
/// while one records.
struct ProfileProblemLine: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            if let problem = controller.visibleProfileProblem {
                Text(problem)
                    .font(.system(size: Rhythm.secondarySize))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Chrome.navRowPadding)
            }
        }
    }
}

extension AppController {
    /// Settings > Profiles, with one of its sheets when one is given.
    func openProfileSettings(sheet: ProfileSheet?) {
        UserDefaults.standard.set(SettingsPage.profiles.rawValue, forKey: "settingsPage")
        open(.settings)
        profileSheet = sheet
    }
}
