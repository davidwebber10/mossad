import MossadCore
import SwiftUI

/// A permission: its mark, what it is for, and the one action that gets it. Setup and Settings both show this
/// row. Setup says Required or Recommended on each one. Settings is quiet while a permission is allowed, and
/// says what does not work while it is missing.
struct PermissionRow: View {
    let item: PermissionsMonitor.Item
    /// Nil follows setup's rule: Microphone and System audio recording.
    var required: Bool?
    /// What Settings says while it is missing, in place of what does not work.
    var missingDetail: String?
    let fix: () -> Void
    @Environment(\.rowStyle) private var style

    private var isRequired: Bool { required ?? OnboardingPermissions.isRequired(item.kind) }
    private var good: Bool { item.state.isGood }

    var body: some View {
        HStack(spacing: Space.m) {
            mark.frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: style == .setup ? 3 : 2) {
                HStack(spacing: Space.s) {
                    Text(item.title).font(.system(size: style.titleSize, weight: .medium)).foregroundStyle(Palette.ink)
                    if style == .setup {
                        if isRequired { NeedsYouChip(text: "Required") } else { TagChip(text: "Recommended") }
                    } else if isRequired, !good {
                        NeedsYouChip(text: "Required")
                    }
                }
                Text(detail).font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            action
        }
        .padding(.vertical, style.padding)
        .accessibilityElement(children: .combine)
        .accessibilityValue(good ? "Allowed" : "Not allowed")
    }

    private var detail: String {
        if style == .settings, !good { return missingDetail ?? OnboardingPermissions.consequence(item.kind) }
        return OnboardingPermissions.purpose(item.kind)
    }

    @ViewBuilder
    private var mark: some View {
        if good {
            Circle().fill(Palette.ok.opacity(0.16)).overlay { IconImage(.checkSmall, size: 11).foregroundStyle(Palette.okText) }
        } else if isRequired {
            WarningMark(size: 15).foregroundStyle(Palette.accent)
        } else if style == .setup {
            Circle().strokeBorder(Palette.ring, lineWidth: 1.5).padding(2)
        } else {
            // Settings counts every missing permission as one that needs the owner.
            Circle().fill(Palette.accentFill).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var action: some View {
        if let label = OnboardingPermissions.action(item.kind, item.state) {
            Button(label, action: fix)
                .rowButton(accent: isRequired)
                .help(item.state == .denied ? "macOS asks only once. Turn Mossad on in this list in System Settings." : "")
                .accessibilityLabel(label == "Allow…" ? "Allow \(item.title)" : "\(label.replacingOccurrences(of: "…", with: "")), to allow \(item.title)")
        } else {
            Text("Allowed").font(.system(size: style.detailSize, weight: style == .setup ? .medium : .regular))
                .foregroundStyle(style == .setup ? Palette.okText : Palette.secondary)
        }
    }
}
