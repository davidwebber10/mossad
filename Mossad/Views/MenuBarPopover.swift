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

            Divider()

            // Actions
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    openConversationBrowser()
                } label: {
                    Label("Open Conversations...", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 6)

                Button {
                    openSettings()
                } label: {
                    Label("Settings...", systemImage: "gear")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 6)

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit Mossad")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 280)
        .glassEffect(.regular.tint(.clear))
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

extension Notification.Name {
    static let openConversationBrowser = Notification.Name("openConversationBrowser")
    static let openSettings = Notification.Name("openSettings")
}
