import MossadCore
import SwiftUI

/// A meeting's topic tags. Click one to see every meeting with it; right-click to remove it; + adds one.
struct TagRow: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    @State private var adding = false
    @State private var draft = ""

    /// Separate views, not one row, so the layout around them can wrap between tags.
    @ViewBuilder
    var body: some View {
        ForEach(record.tags, id: \.self) { tag in
            // Quiet, like the kind: a tag describes the meeting and never asks for anything.
            Button { controller.showTag(tag) } label: { TagChip(text: tag) }
            .buttonStyle(.plain)
            .help("Show every meeting tagged \(tag)")
            .contextMenu {
                Button("Remove tag") { controller.setTags(callID: record.id, record.tags.filter { $0 != tag }) }
            }
        }
        Button { adding = true } label: {
            Image(systemName: "plus").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
                .frame(width: 20, height: 20)
                .background(Palette.fill, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Add a tag")
        .accessibilityLabel("Add a tag")
        .popover(isPresented: $adding, arrowEdge: .bottom) { addPopover }
    }

    private var suggestions: [String] {
        let have = Set(record.tags.map { $0.lowercased() })
        let q = draft.trimmingCharacters(in: .whitespaces)
        return Tags.known(controller.meetings).filter {
            !have.contains($0.lowercased()) && (q.isEmpty || $0.localizedCaseInsensitiveContains(q))
        }.prefix(8).map { $0 }
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: Rhythm.itemGap) {
            TextField("Tag", text: $draft).textFieldStyle(.roundedBorder)
                .onSubmit { add(draft) }
            ForEach(suggestions, id: \.self) { tag in
                Button(tag) { add(tag) }.buttonStyle(.plain).foregroundStyle(Palette.ink)
            }
        }
        .font(.system(size: Rhythm.secondarySize))
        .padding(12)
        .frame(width: 220)
    }

    private func add(_ tag: String) {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        controller.setTags(callID: record.id, record.tags + [t])
        draft = ""
        adding = false
    }
}
