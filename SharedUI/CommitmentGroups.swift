import MossadCore
import SwiftUI

/// "Overdue 3" in the title step, the count in secondary, and a note on the right.
struct CommitmentSectionTitle: View {
    let title: String
    let count: Int
    let accent: Bool
    let note: String?

    @ScaledMetric(relativeTo: .body) private var countSize: CGFloat = 15
    @ScaledMetric(relativeTo: .callout) private var noteSize: CGFloat = CommitmentRowMetrics.detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).textRole(.title).foregroundStyle(accent ? Palette.accent : Palette.ink)
            Text("\(count)").font(.system(size: countSize)).monospacedDigit().foregroundStyle(Palette.secondary)
            Spacer(minLength: Space.m)
            if let note { Text(note).font(.system(size: noteSize)).foregroundStyle(Palette.secondary) }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The commitments with no date for one person, most first; ones with no one named come last.
struct CommitmentPersonGroup: Identifiable {
    let name: String?
    let items: [Commitment]
    var id: String { name ?? "" }

    static func make(_ list: [Commitment]) -> [CommitmentPersonGroup] {
        var order: [String] = []
        var byKey: [String: (name: String?, items: [Commitment])] = [:]
        for c in list {
            let trimmed = c.to?.trimmingCharacters(in: .whitespaces)
            let name = trimmed?.isEmpty == false ? trimmed : nil
            let key = name?.lowercased() ?? ""
            if byKey[key] == nil { order.append(key); byKey[key] = (name, []) }
            byKey[key]?.items.append(c)
        }
        return order.compactMap { byKey[$0].map { CommitmentPersonGroup(name: $0.name, items: $0.items) } }
            .sorted { a, b in
                if (a.name == nil) != (b.name == nil) { return b.name == nil }
                if a.items.count != b.items.count { return a.items.count > b.items.count }
                return (a.name ?? "").localizedCompare(b.name ?? "") == .orderedAscending
            }
    }
}

/// The person's mark, name, and count over their commitments.
struct CommitmentPersonHeading: View {
    let group: CommitmentPersonGroup

    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = CommitmentRowMetrics.detail

    var body: some View {
        HStack(spacing: 8) {
            if let name = group.name {
                PersonMark(name: name, size: 18)
            } else {
                Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 18, height: 18).accessibilityHidden(true)
            }
            Text(group.name ?? "No one named").fontWeight(.semibold).foregroundStyle(Palette.secondary)
            Text("\(group.items.count)").fontWeight(.medium).monospacedDigit().foregroundStyle(Palette.tertiary)
        }
        .font(.system(size: size))
        .padding(.top, 14).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
