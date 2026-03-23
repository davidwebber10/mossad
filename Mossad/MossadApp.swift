// Mossad/MossadApp.swift
import SwiftUI
import MossadShared

@main
struct MossadApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.recordingState == .recording ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.window)

        Window("Conversations", id: "browser") {
            ConversationBrowserWindow()
                .environmentObject(appState)
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .defaultSize(width: 450, height: 680)

        Window("Setup", id: "onboarding") {
            OnboardingView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 500, height: 400)
    }
}
