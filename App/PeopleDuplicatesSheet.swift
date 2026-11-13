import MossadCore
import SwiftUI

/// A hint under a name field: this name or email belongs to someone saved already, so the voice joins them.
struct ExistingPersonHint: View {
    @EnvironmentObject var controller: AppController
    let name: String
    let email: String?

    var body: some View {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty || !(email ?? "").isEmpty, let match = controller.library.existingName(name: typed, email: email) {
            HStack(spacing: 6) {
                IconImage(.check, size: 12).foregroundStyle(Palette.ok)
                    .accessibilityHidden(true)
                Text(match == typed ? "\(match) is saved already. This voice joins them."
                                    : "Matches \(match), who is saved already. This voice joins them.")
            }
            .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
        }
    }
}

/// Pairs of saved people who look like one person. Merge keeps one name and moves the voice samples, the email,
/// and every meeting to it; "Not the same" stops asking about that pair.
struct PeopleDuplicatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pairs: [PeopleDuplicates.Pair]
    let stats: [String: PersonStats]
    /// Saved emails by name, shown under each name so a pair with the same email reads as one.
    var emails: [String: String] = [:]
    let merge: (_ from: String, _ into: String) -> Void
    let notSame: (PeopleDuplicates.Pair) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .people, title: "Possible duplicates",
                        subtitle: "Merge keeps the name you pick and moves voice samples, the email, and meetings to it.")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(pairs) { pair in row(pair) }
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            SheetFooter {
                Button("Done") { dismiss() }.buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .mossadSheet(width: 600)
    }

    private func row(_ pair: PeopleDuplicates.Pair) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                person(pair.first).frame(maxWidth: .infinity, alignment: .leading)
                IconImage(.merge, size: 13).foregroundStyle(Palette.tertiaryMark)
                    .accessibilityHidden(true)
                person(pair.second).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Label {
                    Text(reasonText(pair.reason))
                } icon: {
                    IconImage(reasonIcon(pair.reason), size: 12).foregroundStyle(Palette.tertiaryMark)
                }
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Spacer()
                Button("Not the same") { notSame(pair) }.buttonStyle(.sheetText)
                Menu {
                    Button("Keep “\(pair.first)”") { merge(pair.second, pair.first) }
                    Button("Keep “\(pair.second)”") { merge(pair.first, pair.second) }
                } label: {
                    HStack(spacing: 6) {
                        IconImage(.merge, size: 13)
                        Text("Merge")
                        IconImage(.chevronDown, size: 10).foregroundStyle(Palette.secondary)
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(SheetButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
            }
        }
        .sheetCard(horizontal: 14, vertical: 12)
    }

    private func person(_ name: String) -> some View {
        let count = stats[name]?.meetings.count ?? 0
        let meetings = "\(count) \(count == 1 ? "meeting" : "meetings")"
        return HStack(spacing: 8) {
            PersonMark(name: name, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                Text(emails[name].map { "\($0) · \(meetings)" } ?? meetings)
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reasonText(_ r: PeopleDuplicates.Reason) -> String { r.words }

    private func reasonIcon(_ r: PeopleDuplicates.Reason) -> Icon {
        switch r {
        case .sameEmail: .document
        case .sameName, .similarName: .pencil
        case .sameVoice: .waveform
        }
    }
}
