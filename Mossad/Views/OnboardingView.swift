// Mossad/Views/OnboardingView.swift
import AVFoundation
import EventKit
import ScreenCaptureKit
import SwiftUI
import MossadShared

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0
    @State private var apiKey = ""
    @State private var userName = ""
    @State private var micGranted = false
    @State private var calendarGranted = false
    @State private var screenGranted = false

    var body: some View {
        VStack(spacing: 24) {
            // Progress
            HStack {
                ForEach(0..<4) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            switch currentStep {
            case 0:
                welcomeStep
            case 1:
                apiKeyStep
            case 2:
                permissionsStep
            case 3:
                readyStep
            default:
                EmptyView()
            }
        }
        .padding(40)
        .frame(width: 500, height: 400)
    }

    @ViewBuilder
    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Mossad")
                .font(.title)
                .fontWeight(.bold)
            Text("Automatic meeting transcription that runs quietly in your menu bar. Let's get you set up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") {
                withAnimation { currentStep = 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var apiKeyStep: some View {
        VStack(spacing: 16) {
            Text("AssemblyAI API Key")
                .font(.title2)
                .fontWeight(.bold)
            Text("Mossad uses AssemblyAI for transcription. Enter your API key below.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)

            TextField("Your Name", text: $userName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)

            Spacer()
            Button("Continue") {
                if !apiKey.isEmpty {
                    try? KeychainManager.save(account: "assemblyai-api-key", data: apiKey)
                }
                if !userName.isEmpty {
                    UserDefaults.standard.set(userName, forKey: "userName")
                }
                withAnimation { currentStep = 2 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(apiKey.isEmpty || userName.isEmpty)
        }
    }

    @ViewBuilder
    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Text("Permissions")
                .font(.title2)
                .fontWeight(.bold)
            Text("Mossad needs a few permissions to work.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "To capture your voice",
                    granted: micGranted
                ) {
                    requestMicPermission()
                }

                permissionRow(
                    icon: "calendar",
                    title: "Calendar",
                    description: "To match meetings with events",
                    granted: calendarGranted
                ) {
                    requestCalendarPermission()
                }

                permissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    description: "To capture meeting audio",
                    granted: screenGranted
                ) {
                    requestScreenPermission()
                }
            }

            Spacer()
            Button("Continue") {
                withAnimation { currentStep = 3 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 30)
            VStack(alignment: .leading) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.5)))
    }

    @ViewBuilder
    private var readyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)
            Text("Mossad is now running in your menu bar. It will automatically detect and transcribe your meetings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                UserDefaults.standard.set(true, forKey: "onboardingComplete")
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Permission Requests

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
    }

    private func requestCalendarPermission() {
        let store = EKEventStore()
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            await MainActor.run { calendarGranted = granted }
        }
    }

    private func requestScreenPermission() {
        // ScreenCaptureKit permission is granted via System Settings
        // We can check if we have it, but can't trigger the prompt programmatically
        Task {
            do {
                let _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                await MainActor.run { screenGranted = true }
            } catch {
                // Open System Settings to the Screen Recording pane
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
