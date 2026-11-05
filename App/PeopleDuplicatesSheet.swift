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
            Label(match == typed ? "\(match) is saved already. This voice joins them."
                                 : "Matches \(match), who is saved already. This voice joins them.",
                  systemImage: "person.crop.circle.badge.checkmark")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Pairs of saved people who look like one person. Merge keeps one name and moves the voice samples, the email,
/// and every meeting to it; "Not the same" stops asking about that pair.
struct PeopleDuplicatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pairs: [PeopleDuplicates.Pair]
    let stats: [String: PersonStats]
    let merge: (_ from: String, _ into: String) -> Void
    let notSame: (PeopleDuplicates.Pair) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Possible duplicates").font(.system(size: 15, weight: .semibold))
                Text("Merge keeps the name you pick and moves the other one's voice samples and meetings to it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(pairs) { pair in row(pair) }
                }
                .padding(18)
            }
            .frame(maxHeight: 420)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(14)
        }
        .frame(width: 520)
        .background(Theme.background)
    }

    private func row(_ pair: PeopleDuplicates.Pair) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                person(pair.first)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                person(pair.second)
                Spacer()
            }
            HStack(spacing: 8) {
                Label(reasonText(pair.reason), systemImage: reasonSymbol(pair.reason)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Not the same") { notSame(pair) }.buttonStyle(.link).font(.system(size: 12))
                Menu("Merge") {
                    Button("Keep “\(pair.first)”") { merge(pair.second, pair.first) }
                    Button("Keep “\(pair.second)”") { merge(pair.first, pair.second) }
                }
                .fixedSize()
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func person(_ name: String) -> some View {
        HStack(spacing: 7) {
            PersonMark(name: name, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(stats[name]?.meetings.count ?? 0) meetings").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func reasonText(_ r: PeopleDuplicates.Reason) -> String {
        switch r {
        case .sameEmail: "Same email"
        case .sameName: "Same name"
        case .similarName: "Names almost match"
        case .sameVoice: "Same voice"
        }
    }

    private func reasonSymbol(_ r: PeopleDuplicates.Reason) -> String {
        switch r {
        case .sameEmail: "envelope"
        case .sameName, .similarName: "textformat"
        case .sameVoice: "waveform"
        }
    }
}
