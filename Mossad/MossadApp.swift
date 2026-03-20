// Mossad/MossadApp.swift
import SwiftUI
import MossadShared

@main
struct MossadApp: App {
    @StateObject private var appState = AppState()
    @State private var showBrowser = false
    @State private var showSettings = false
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.recordingState == .recording ? "mic.fill" : "mic")
                .symbolRenderingMode(.palette)
                .foregroundStyle(appState.recordingState == .recording ? .red : .primary)
                .symbolEffect(.pulse, options: .repeating, isActive: appState.recordingState == .recording)
        }
        .menuBarExtraStyle(.window)

        Window("Conversations", id: "browser") {
            ConversationBrowserWindow()
                .environmentObject(appState)
        }

        Settings {
            SettingsView()
        }

        Window("Setup", id: "onboarding") {
            OnboardingView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 500, height: 400)
    }
}
