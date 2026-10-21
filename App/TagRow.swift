import MossadCore
import SwiftUI

/// A meeting's topic tags. Click one to see every meeting with it; right-click to remove it; + adds one.
struct TagRow: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(record.tags, id: \.self) { tag in
                Button { controller.showTag(tag) } label: {
                    Text("#\(tag)").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Show every meeting tagged \(tag)")
                .contextMenu {
                    Button("Remove tag") { controller.setTags(callID: record.id, record.tags.filter { $0 != tag }) }
                }
            }
            Button { adding = true } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .background(Theme.field, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Add a tag")
            .accessibilityLabel("Add a tag")
            .popover(isPresented: $adding, arrowEdge: .bottom) { addPopover }
        }
    }

    private var suggestions: [String] {
        let have = Set(record.tags.map { $0.lowercased() })
        let q = draft.trimmingCharacters(in: .whitespaces)
        return Tags.known(controller.meetings).filter {
            !have.contains($0.lowercased()) && (q.isEmpty || $0.localizedCaseInsensitiveContains(q))
        }.prefix(8).map { $0 }
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tag", text: $draft).textFieldStyle(.roundedBorder)
                .onSubmit { add(draft) }
            ForEach(suggestions, id: \.self) { tag in
                Button("#\(tag)") { add(tag) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 12))
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
