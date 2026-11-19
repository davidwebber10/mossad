import MossadCore
import SwiftUI

/// The sheet of Settings > Profiles that is open.
enum ProfileSheet: Equatable, Identifiable {
    case add, rename(String), delete(String), code

    var id: String {
        switch self {
        case .add: "add"
        case .code: "code"
        case .rename(let id): "rename-" + id
        case .delete(let id): "delete-" + id
        }
    }
}

/// Settings > Profiles: the profiles, then what each keeps apart and what the Mac shares, as plain facts.
struct ProfileSettings: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        LabelColumnStack {
            ProfileSettingsGroup()
            // A copy with no profiles (Rehearsal, a preview, a `MOSSAD_ROOT` run) shares and keeps apart other things.
            if AppIdentity.current.takesProfiles {
                ProfileFacts(label: ProfileSettingsWords.apartLabel, lines: ProfileSettingsWords.apart)
                ProfileFacts(label: ProfileSettingsWords.sharedLabel, lines: ProfileSettingsWords.shared)
            }
        }
        .sheet(item: $controller.profileSheet) { sheet in
            switch sheet {
            case .add: AddProfileSheet()
            case .rename(let id): RenameProfileSheet(id: id)
            case .delete(let id): DeleteProfileSheet(id: id)
            case .code: ProfileCodeSheet()
            }
        }
    }
}

/// With one profile its own row and "Add profile…"; with more, a row for each with Rename and Delete, then
/// "Show code for iPhone…" and "Add profile…". The footer says what stops a change.
private struct ProfileSettingsGroup: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.rowStyle) private var style

    var body: some View {
        let rows = ProfileSettingsWords.rows(controller.profiles.registry, active: controller.activeProfile.id)
        SettingsGroup(label: "Profiles", footer: ProfileSettingsWords.footer(controller.profiles, problem: controller.visibleProfileProblem)) {
            if rows.isEmpty {
                // A copy with no profiles (a preview, Rehearsal, a `MOSSAD_ROOT` run) has no folder of its own to name.
                ProfileRow(row: ProfileSettingsWords.only(controller.activeProfile), showsFolder: AppIdentity.current.takesProfiles,
                           editable: false)
                HStack {
                    Spacer(minLength: 0)
                    addButton
                }
                .padding(.vertical, style.padding)
            } else {
                ForEach(rows) { row in
                    ProfileRow(row: row)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button(ProfileSettingsWords.codeButton) { controller.profileSheet = .code }
                        .buttonStyle(.settings)
                    addButton
                }
                .padding(.vertical, style.padding)
            }
        }
    }

    private var addButton: some View {
        Button(ProfileMenu.add) { controller.profileSheet = .add }
            .buttonStyle(.settings)
            .disabled(!controller.profiles.canSave)
    }
}

/// A short list of facts under a label: no controls and no instructions.
private struct ProfileFacts: View {
    let label: String
    let lines: [String]

    var body: some View {
        LabelColumn(label: label) {
            VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label): \(lines.joined(separator: ", "))")
        }
    }
}

/// One profile: its dot, its name, its folder, "Active" on the active one, Rename and Delete. The only profile has
/// no "Active" and no buttons.
private struct ProfileRow: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.rowStyle) private var style
    let row: ProfileSettingsWords.Row
    var showsFolder = true
    var editable = true

    var body: some View {
        HStack(spacing: Space.m) {
            ProfileDot(color: row.color)
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                HStack(spacing: Space.s) {
                    Text(row.name).font(.system(size: Rhythm.bodySize, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    if row.active, editable {
                        Text("Active").font(.system(size: Rhythm.noteSize, weight: .medium)).foregroundStyle(Palette.secondary)
                    }
                }
                // The registry's own `~/` text: it never holds the account's name.
                if showsFolder {
                    Text(row.folder)
                        .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.m)
            if editable {
                Button("Rename…") { controller.profileSheet = .rename(row.id) }
                    .buttonStyle(.settings)
                    .disabled(!controller.profiles.canSave)
                Button("Delete…") { controller.profileSheet = .delete(row.id) }
                    .buttonStyle(.settings)
                    .disabled(!row.mayDelete || !controller.profiles.canSave)
            }
        }
        .padding(.vertical, style.padding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name)\(row.active && editable ? ", active" : "")")
    }
}

/// The six colors to choose from.
private struct ColorChoice: View {
    @Binding var color: ProfileColor

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(ProfileColor.allCases, id: \.self) { c in
                Button { color = c } label: {
                    Circle().fill(c.color).frame(width: 18, height: 18)
                        .overlay { if c == color { Circle().strokeBorder(Palette.ink.opacity(0.55), lineWidth: 2).padding(-4) } }
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.title)
                .accessibilityAddTraits(c == color ? .isSelected : [])
            }
        }
    }
}

/// A sheet's labeled field: the small label, then the control.
private struct SheetField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.itemGap) {
            Text(label).font(.system(size: Rhythm.secondarySize, weight: .medium)).foregroundStyle(Palette.secondary)
            content
        }
    }
}

struct AddProfileSheet: View {
    @EnvironmentObject var controller: AppController
    @State private var name = ""
    @State private var color: ProfileColor = .blue
    @State private var typed = false

    var body: some View {
        let problem = ProfileRules.nameProblem(name, in: controller.profiles.registry)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .people, title: "Add a profile", close: { controller.profileSheet = nil })
            VStack(alignment: .leading, spacing: Rhythm.groupGap) {
                SheetField(label: "Name") {
                    TextField("Name", text: $name, prompt: Text("Client"))
                        .textFieldStyle(SheetFieldStyle())
                        .onChange(of: name) { _, _ in typed = true }
                    if typed, let problem {
                        Text(problem).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.recording)
                    }
                }
                SheetField(label: "Color") { ColorChoice(color: $color) }
                Text(ProfileSettingsWords.addExplanation)
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            SheetFooter {
                Button("Cancel") { controller.profileSheet = nil }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                Button("Add and restart") {
                    controller.profileSheet = nil
                    controller.addProfile(name: name, color: color)
                }
                .buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .mossadSheet(width: 440)
        .onAppear { color = ProfileRules.nextColor(in: controller.profiles.registry) }
    }
}

struct RenameProfileSheet: View {
    @EnvironmentObject var controller: AppController
    let id: String
    @State private var name = ""
    @State private var color: ProfileColor = .blue

    var body: some View {
        let problem = ProfileRules.nameProblem(name, in: controller.profiles.registry, renaming: id)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .pencil, title: "Rename the profile", close: { controller.profileSheet = nil })
            VStack(alignment: .leading, spacing: Rhythm.groupGap) {
                SheetField(label: "Name") {
                    TextField("Name", text: $name).textFieldStyle(SheetFieldStyle())
                    if let problem {
                        Text(problem).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.recording)
                    }
                }
                SheetField(label: "Color") { ColorChoice(color: $color) }
                Text(ProfileSettingsWords.renameNote)
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            SheetFooter {
                Button("Cancel") { controller.profileSheet = nil }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                Button("Save") {
                    controller.profileSheet = nil
                    controller.renameProfile(id, name: name, color: color)
                }
                .buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .mossadSheet(width: 440)
        .onAppear {
            let profile = controller.profiles.registry.profile(id)
            name = profile?.name ?? ""
            color = profile?.color ?? .blue
        }
    }
}

struct DeleteProfileSheet: View {
    @EnvironmentObject var controller: AppController
    let id: String
    @State private var typed = ""

    var body: some View {
        let profile = controller.profiles.registry.profile(id)
        let problem = ProfileRules.deleteProblem(id, in: controller.profiles.registry, active: controller.activeProfile.id, typed: typed)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .warning, title: "Delete \(profile?.name ?? "the profile")?", close: { controller.profileSheet = nil })
            VStack(alignment: .leading, spacing: Rhythm.groupGap) {
                if let profile {
                    VStack(alignment: .leading, spacing: Rhythm.blockGap) {
                        Text(ProfileSettingsWords.deleteText(profile))
                        ForEach(ProfileSettingsWords.deleteNotes(profile), id: \.self) { Text($0) }
                    }
                    .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                }
                SheetField(label: "Type the profile's name") {
                    TextField("Name", text: $typed, prompt: Text(profile?.name ?? "")).textFieldStyle(SheetFieldStyle())
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            SheetFooter {
                Button("Cancel") { controller.profileSheet = nil }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                Button("Delete") {
                    controller.profileSheet = nil
                    controller.deleteProfile(id, typed: typed)
                }
                .buttonStyle(.sheetDestructive)
                .disabled(problem != nil)
            }
        }
        .mossadSheet(width: 460)
    }
}
