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
        VStack(alignment: .leading, spacing: 4) {
            statusSection
            if controller.processing > 0 { processingRow }
            if !permissions.allGood { permissionsRow }
            let recent = controller.meetings.filter { $0.status != .recording }.prefix(3)
            if !recent.isEmpty {
                PanelSeparator()
                Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.top, 2)
                ForEach(Array(recent), id: \.id) { r in
                    PanelRow(action: { go { controller.openMeeting(r.id) } }) {
                        PlatformSquare(platform: r.platform, size: 14)
                        Text(r.title).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(shortTime(r.start)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            PanelSeparator()
            navigationRow("Meetings", "bubble.left.and.text.bubble.right") { controller.open(.meetings) }
            if let first = controller.callsNeedingNames.first {
                PanelRow(action: { go { controller.openNaming(first.id) } }) {
                    icon("person.wave.2")
                    Text("Name voices")
                    Spacer()
                    Text("\(controller.callsNeedingNames.count)")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, 4)
                        .background(Color.primary, in: Capsule())
                }
            }
            navigationRow("People", "person.2") { controller.open(.people) }
            navigationRow("Settings", "gearshape") { controller.open(.settings) }
            navigationRow("Log", "doc.text") { controller.open(.log) }
            PanelSeparator()
            PanelRow(action: { NSApp.terminate(nil) }) {
                Text("Quit Mossad")
                Spacer()
                Text("⌘Q").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .keyboardShortcut("q")
        }
        .font(.system(size: 13))
        .padding(8)
        .frame(width: 320)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch controller.status {
        case .idle:
            HStack(alignment: .top, spacing: 10) {
                StatusDot(color: Theme.listening, size: 9)
                    .background(Circle().fill(Theme.listening.opacity(0.2)).frame(width: 15, height: 15))
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for a call").font(.system(size: 14, weight: .semibold))
                    Text("Zoom, Google Meet, and Microsoft Teams").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
        case .recording(let platform, let since):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: Theme.recording, size: 10, pulsing: true)
                    Text("Recording").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(elapsed(since, context.date)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                            .foregroundStyle(Theme.recording)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.recordingTitle ?? "\(platform.displayName) call").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(platform.displayName) · started \(since.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button {
                    if confirmSkip {
                        controller.skipCurrentCall()
                        confirmSkip = false
                    } else {
                        confirmSkip = true
                    }
                } label: {
                    Text(confirmSkip ? "Click again to delete this recording" : "Skip and delete this call")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.recording)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        }
    }

    private var processingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Processing \(controller.processing) \(controller.processing == 1 ? "call" : "calls")").fontWeight(.medium)
                if let step = controller.currentStep {
                    Text(step.title).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 6)
    }

    private var permissionsRow: some View {
        PanelRow(background: Color.orange.opacity(0.14), cornerRadius: 11, action: { go { controller.open(.settings) } }) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.warning)
            Text(permissionsText(permissions.problemCount)).fontWeight(.medium)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }
    }

    private func navigationRow(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        PanelRow(action: { go(action) }) {
            icon(symbol)
            Text(title)
            Spacer()
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 18)
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

/// "11:31 AM" today, "Oct 9" before.
func shortTime(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.month(.abbreviated).day())
}

private struct PanelSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 4)
    }
}

/// A menu-like row with a gray hover fill.
private struct PanelRow<Content: View>: View {
    var background: Color = .clear
    var cornerRadius: CGFloat = 8
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content() }
                .padding(.horizontal, 8)
                .padding(.vertical, background == .clear ? 5 : 9)
                .background(hovering ? Theme.hover : background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}
