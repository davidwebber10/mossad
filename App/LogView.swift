import AppKit
import MossadCore
import SwiftUI

/// The last 500 log lines as they are: monospace time, level, and message, grouped by day. Errors sit on a
/// faint red ground in full-contrast text; info stays secondary. Reloads every 2 s while visible.
struct LogView: View {
    @EnvironmentObject var controller: AppController
    @State private var lines: [LogLine] = []
    /// The size and the change time of the file at the last read: an unchanged file is not read again.
    @State private var stamp = ""
    @State private var levels: Set<LogLine.Level> = [.info, .error, .other]
    @State private var search = ListSearchState()
    private var filter: String { search.query }

    private var visible: [LogLine] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return lines.filter { levels.contains($0.level) && (q.isEmpty || $0.message.localizedCaseInsensitiveContains(q)) }
    }

    /// Lines without a time belong to the day before them.
    /// Each group's id is its first line's index: a day can come back after a gap, so its name is not unique.
    private var days: [(id: Int, day: String, lines: [(id: Int, line: LogLine)])] {
        var result: [(id: Int, day: String, lines: [(id: Int, line: LogLine)])] = []
        var current: Date?
        for (i, line) in visible.enumerated() {
            let date = line.date ?? current
            let day = date.map(Self.day) ?? ""
            if result.last?.day != day { result.append((i, day, [])) }
            result[result.count - 1].lines.append((i, line))
            current = date
        }
        return result
    }

    var body: some View {
        DetailColumn {
            PageToolbar(title: "Log", search: $search, searchPrompt: "Filter the lines") {
                HStack(spacing: 6) {
                    chip("Info", .info)
                    chip("Error", .error)
                    chip("Debug", .debug)
                }
                ToolbarCircleButton(icon: .copy, label: "Copy", help: "Copy the lines shown", size: 14) {
                    copy(visible.map(plain).joined(separator: "\n"))
                }
            }
        } content: {
            logLines
        }
        .task {
            while !Task.isCancelled {
                // A window that is closed or covered keeps this view: nothing to show, so nothing to read.
                if controller.windowVisible { await load() }
                try? await Task.sleep(for: .seconds(controller.windowVisible ? 2 : 30))
            }
        }
        .onChange(of: controller.windowVisible) { _, visible in if visible { Task { await load() } } }
    }

    private var logLines: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.id) { group in
                    if !group.day.isEmpty {
                        Text(group.day).textRole(.label).foregroundStyle(Palette.tertiary)
                            .padding(.top, 14).padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(group.lines, id: \.id) { LogRow(line: $0.line) }
                }
                if visible.isEmpty, !lines.isEmpty {
                    Text("No lines match.").font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.top, 14)
                }
            }
            .textSelection(.enabled)
            // The canvas starts the page 10 pt under the toolbar row, so the first day never sits under it.
            .padding(EdgeInsets(top: Detail.bodyTop, leading: Detail.gutter, bottom: 24, trailing: Detail.gutter))
            .frame(maxWidth: 1172, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Opens at the newest line, follows new lines, and a short log still starts at the top.
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }

    private func chip(_ title: String, _ level: LogLine.Level) -> some View {
        let on = levels.contains(level)
        return Button {
            if on { levels.remove(level) } else { levels.insert(level) }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Palette.accent : Palette.secondary)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(on ? Palette.accentTint : Palette.fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) lines")
        .accessibilityValue(on ? "Shown" : "Hidden")
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(on ? "Hide \(title.lowercased()) lines" : "Show \(title.lowercased()) lines")
    }

    /// 24-hour local time, as log readers expect.
    fileprivate static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func plain(_ line: LogLine) -> String {
        [line.date.map { $0.ISO8601Format() }, line.level == .other ? nil : line.level.rawValue, line.message]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// Reads the end of the file off the main thread, and only when the file changed.
    private func load() async {
        guard let url = Log.fileURL else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let now = "\(attributes?[.size] as? Int ?? -1) \((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        guard now != stamp else { return }
        let parsed = await Task.detached(priority: .utility) { () -> [LogLine]? in
            guard let content = Log.tail(of: url) else { return nil }
            return LogLine.parse(content.split(separator: "\n", omittingEmptySubsequences: false).suffix(500).joined(separator: "\n"))
        }.value
        guard let parsed else { return }
        stamp = now
        if parsed != lines { lines = parsed }
    }
}

private struct LogRow: View {
    let line: LogLine
    private var error: Bool { line.level == .error }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(line.date.map { LogView.time.string(from: $0) } ?? "")
                // Tertiary loses contrast on the red ground.
                .foregroundStyle(error ? Palette.secondary : Palette.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(line.level == .other ? "" : line.level.rawValue)
                .fontWeight(.bold)
                .foregroundStyle(error ? Palette.recording : Palette.tertiary)
                .frame(width: 48, alignment: .leading)
            Text(line.message)
                .foregroundStyle(error ? Palette.ink : Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .cssLineHeight(1.5, size: 11.5)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(error ? Palette.errorWash : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, -6)
    }
}
