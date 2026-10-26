import AppKit
import MossadCore
import SwiftUI

/// The last 500 log lines with level pills and a filter. Reloads every 2 s while visible.
struct LogView: View {
    @State private var lines: [LogLine] = []
    @State private var levels: Set<LogLine.Level> = [.info, .error, .other]
    @State private var filter = ""

    private var visible: [LogLine] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return lines.filter { levels.contains($0.level) && (q.isEmpty || $0.message.localizedCaseInsensitiveContains(q)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.date.map { Self.time.string(from: $0) } ?? "")
                                .foregroundStyle(.tertiary).frame(width: 64, alignment: .leading)
                            Text(line.level == .other ? "" : line.level.rawValue)
                                .fontWeight(.semibold).foregroundStyle(color(line.level)).frame(width: 44, alignment: .leading)
                            Text(line.message).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(4)
                        .padding(.vertical, 2)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
        }
        .background(Theme.background)
        .navigationTitle("Log")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                pill("Info", .info)
                pill("Error", .error)
                pill("Debug", .debug)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visible.map(plain).joined(separator: "\n"), forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the lines shown")
            }
        }
        .task {
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 24-hour local time, as log readers expect.
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func pill(_ title: String, _ level: LogLine.Level) -> some View {
        Toggle(title, isOn: Binding(get: { levels.contains(level) }, set: { if $0 { levels.insert(level) } else { levels.remove(level) } }))
            .help("Show \(title.lowercased()) lines")
    }

    private func color(_ level: LogLine.Level) -> Color {
        switch level {
        case .error: Theme.recording
        case .debug: Theme.unknown
        default: .secondary
        }
    }

    private func plain(_ line: LogLine) -> String {
        [line.date.map { $0.ISO8601Format() }, line.level == .other ? nil : line.level.rawValue, line.message]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func load() {
        guard let url = Log.fileURL, let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let tail = content.split(separator: "\n", omittingEmptySubsequences: false).suffix(500).joined(separator: "\n")
        let parsed = LogLine.parse(tail)
        if parsed != lines { lines = parsed }
    }
}
