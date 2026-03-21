// Mossad/Views/MenuBarPopover.swift
import SwiftUI
import MossadShared

struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Mossad")
                    .font(.headline)
                Spacer()
                statusBadge
            }
            .padding()

            Divider()

            // Status content
            Group {
                switch appState.recordingState {
                case .idle, .detecting:
                    idleContent
                case .recording:
                    recordingContent
                case .paused:
                    pausedContent
                }
            }

            // Upcoming events
            if !appState.upcomingEvents.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Upcoming")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(appState.upcomingEvents.prefix(4)) { event in
                        UpcomingEventRow(
                            event: event,
                            enabled: appState.isEventEnabled(event.id)
                        ) {
                            appState.toggleEventRecording(event.id)
                        }
                    }
                }
            }

            Divider()
                .padding(.bottom, 6)

            // Actions
            VStack(alignment: .leading, spacing: 2) {
                PopoverButton("Open Conversations...", systemImage: "list.bullet.rectangle") {
                    openConversationBrowser()
                }
                PopoverButton("Settings...", systemImage: "gear") {
                    openSettings()
                }

                Divider()
                    .padding(.vertical, 4)

                PopoverButton("Quit Mossad", systemImage: "xmark.circle") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch appState.recordingState {
        case .idle, .detecting:
            Text("Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recording:
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .paused:
            Text("Paused")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        Text("No active call detected")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
    }

    @ViewBuilder
    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.currentMeetingTitle ?? "Unknown Meeting")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack {
                if let platform = appState.currentPlatform {
                    Label(platform.capitalized, systemImage: platformIcon(platform))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("·")
                    .foregroundStyle(.secondary)
                Text(appState.elapsedFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("\(appState.speakerCount) speakers detected")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()

        Button {
            appState.pauseRecording()
        } label: {
            Label("Pause Recording", systemImage: "pause.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var pausedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.currentMeetingTitle ?? "Unknown Meeting")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Recording paused")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding()

        Button {
            appState.resumeRecording()
        } label: {
            Label("Resume Recording", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.green)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "zoom": return "video.fill"
        case "meet": return "person.3.fill"
        case "teams": return "person.2.fill"
        default: return "phone.fill"
        }
    }

    private func openConversationBrowser() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "browser")
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }
}

struct UpcomingEventRow: View {
    let event: UpcomingEvent
    let enabled: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(enabled ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .strikethrough(!enabled, color: .secondary)
                    .foregroundStyle(enabled ? .primary : .secondary)
                HStack(spacing: 4) {
                    Text(event.startDate, style: .time)
                    Text("–")
                    Text(event.endDate, style: .time)
                    if event.meetingUrl != nil {
                        Image(systemName: "video.fill")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.horizontal, 8)
        )
        .onHover { isHovered = $0 }
    }
}

struct PopoverButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

extension Notification.Name {
    static let openConversationBrowser = Notification.Name("openConversationBrowser")
    static let openSettings = Notification.Name("openSettings")
}
