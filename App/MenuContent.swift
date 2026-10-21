import AppKit
import MossadCore
import SwiftUI

/// The menu bar panel: what Mossad is doing now, recent meetings, and the app's sections.
struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var permissions: PermissionsMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSkip = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
            if controller.processing > 0 || !permissions.allGood {
                Divider().padding(.vertical, 6)
                if controller.processing > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Processing \(controller.processing) \(controller.processing == 1 ? "call" : "calls")")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                if !permissions.allGood {
                    MenuRow(title: "Fix permissions", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                        go { controller.open(.settings) }
                    }
                }
            }
            let recent = controller.meetings.filter { $0.status != .recording }.prefix(3)
            if !recent.isEmpty {
                Divider().padding(.vertical, 6)
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 2)
                ForEach(Array(recent), id: \.id) { r in
                    MenuRow(title: r.title, detail: Calendar.current.isDateInToday(r.start)
                             ? r.start.formatted(date: .omitted, time: .shortened)
                             : r.start.formatted(.dateTime.month(.abbreviated).day())) {
                        go { controller.openMeeting(r.id) }
                    }
                }
            }
            Divider().padding(.vertical, 6)
            MenuRow(title: "Meetings", systemImage: "text.bubble") { go { controller.open(.meetings) } }
            if let first = controller.callsNeedingNames.first {
                MenuRow(title: "Name voices", systemImage: "person.crop.circle.badge.questionmark",
                        detail: "\(controller.callsNeedingNames.count)") { go { controller.openNaming(first.id) } }
            }
            MenuRow(title: "Voices", systemImage: "person.2") { go { controller.open(.voices) } }
            MenuRow(title: "Settings", systemImage: "gearshape") { go { controller.open(.settings) } }
            MenuRow(title: "Log", systemImage: "doc.text") { go { controller.open(.log) } }
            Divider().padding(.vertical, 6)
            MenuRow(title: "Quit Mossad", detail: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: 290)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch controller.status {
        case .idle:
            HStack(spacing: 10) {
                Circle().fill(.green).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Listening for calls").font(.headline)
                    Text("Zoom, Google Meet, and Microsoft Teams").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        case .recording(let platform, let since):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RecordingDot()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Recording · \(platform.displayName)").font(.headline)
                        Text("Started \(since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(elapsed(since, context.date)).font(.title3.monospacedDigit()).foregroundStyle(.red)
                    }
                }
                Button(role: .destructive) {
                    if confirmSkip {
                        controller.skipCurrentCall()
                        confirmSkip = false
                    } else {
                        confirmSkip = true
                    }
                } label: {
                    Text(confirmSkip ? "Click again to delete this recording" : "Skip and delete this call")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    /// Runs a navigation action and closes the panel.
    private func go(_ action: () -> Void) {
        action()
        dismiss()
    }
}

func elapsed(_ since: Date, _ now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(since)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

private struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle().fill(.red).frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// A menu-like row with a hover highlight.
private struct MenuRow: View {
    let title: String
    var systemImage: String?
    var tint: Color = .primary
    var detail: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(hovering ? .white : tint).frame(width: 18)
                }
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let detail { Text(detail).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary).monospacedDigit() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(hovering ? .white : .primary)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
    }
}
