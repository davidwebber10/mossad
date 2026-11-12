import MossadCore
import SwiftUI

/// Under a meeting on the iPhone: the owner's points it discussed, with the moment, and the ones it left for the
/// next meeting. The Mac checks the points; the phone shows what it found.
struct PhoneMeetingPoints: View {
    @Environment(PhoneStore.self) private var store
    let callID: String
    let read: (TimeInterval?) -> Void
    @State private var book = NextTimeBook()

    var body: some View {
        let discussed = book.discussed(in: callID)
        let carried = book.visible.filter { $0.isOpen && ($0.carried ?? []).contains(callID) }
        VStack(spacing: 0) {
            if !discussed.isEmpty || !carried.isEmpty {
                LabelColumn(label: "Your points") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(discussed) { p in
                            Button { read(p.done?.at) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.text).textRole(.body).foregroundStyle(Palette.ink)
                                        Text("Discussed" + (p.done?.at.map { " at \(meetingClock($0, length: 0))" } ?? "")).textRole(.secondary).foregroundStyle(Palette.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(carried) { p in
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Image(systemName: "circle").font(.caption).foregroundStyle(Palette.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.text).textRole(.body).foregroundStyle(Palette.ink)
                                    Text("Not discussed: carried to next time").textRole(.secondary).foregroundStyle(Palette.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: store.meetingsVersion) { book = NextTimeBook.peek(in: store.paths.nextTime) ?? NextTimeBook() }
    }
}
