import MossadCore
import SwiftUI

/// The coach's read on one person: the best way to work with them, then the sections the coach chose.
struct PersonBriefCard: View {
    let name: String
    let brief: PersonBrief?
    var refreshing = false
    var refresh: (() -> Void)?
    var openCall: ((String) -> Void)?

    private var first: String { name.split(separator: " ").first.map(String.init) ?? name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle").foregroundStyle(.tint)
                Text("The coach's read on \(first)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let brief {
                    Text("From \(brief.calls) \(brief.calls == 1 ? "call" : "calls") · \(brief.updated.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if let refresh {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Read the calls with \(first) again")
                            .accessibilityLabel("Refresh the coach's read")
                    }
                }
            }
            if let brief {
                Text(brief.headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(brief.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.callout.weight(.semibold))
                            ForEach(section.points, id: \.text) { point in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(point.text).fixedSize(horizontal: false, vertical: true)
                                    if let id = point.callID, let openCall {
                                        Button { openCall(id) } label: { Image(systemName: "arrow.up.right.circle").foregroundStyle(.tertiary) }
                                            .buttonStyle(.plain)
                                            .help("Open the call this came from")
                                            .accessibilityLabel("Open the source call")
                                    }
                                }
                                .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("After two calls with \(first), the coach writes how to work with them: their goals, how to get through to them, and how they communicate.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.5))
    }
}
