// Mossad/Views/SettingsView.swift
import SwiftUI
import MossadShared
import CoreAudio
import EventKit
import AVFoundation
import ScreenCaptureKit

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var userName: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var selectedAudioDevice: String = "default"
    @State private var audioDevices: [AudioDeviceInfo] = []
    @State private var selectedCalendarId: String = "all"
    @State private var calendars: [CalendarInfo] = []
    @State private var showSavedMessage = false
    @State private var micPermission: Bool = false
    @State private var calendarPermission: Bool = false
    @State private var screenPermission: Bool = false
    @State private var skipPatterns: [String] = []
    @State private var newSkipPattern: String = ""

    var body: some View {
        Form {
            Section("AssemblyAI") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Get your API key at assemblyai.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Identity") {
                TextField("Your Name", text: $userName)
                    .textFieldStyle(.roundedBorder)
                Text("Used to label your utterances in transcripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Input Device", selection: $selectedAudioDevice) {
                    Text("System Default").tag("default")
                    ForEach(audioDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                Text("Which microphone to use for capturing your voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendar") {
                Picker("Calendar", selection: $selectedCalendarId) {
                    Text("All Calendars").tag("all")
                    ForEach(calendars, id: \.id) { cal in
                        HStack {
                            Circle()
                                .fill(cal.color)
                                .frame(width: 8, height: 8)
                            Text(cal.title)
                        }
                        .tag(cal.id)
                    }
                }
                Text("Which calendar to use for matching meetings. Select a specific calendar to avoid matching events from unrelated calendars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Auto-Skip Events") {
                Text("Events with titles containing these words will be unchecked by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(skipPatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                        Spacer()
                        Button {
                            skipPatterns.removeAll { $0 == pattern }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("e.g. Busy, OOO, Focus Time...", text: $newSkipPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addSkipPattern() }
                    Button("Add") { addSkipPattern() }
                        .disabled(newSkipPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    description: "Capture your voice during calls",
                    systemImage: "mic.fill",
                    granted: micPermission
                ) {
                    requestMicPermission()
                }
                PermissionRow(
                    title: "Calendar",
                    description: "Match meetings with calendar events",
                    systemImage: "calendar",
                    granted: calendarPermission
                ) {
                    requestCalendarPermission()
                }
                PermissionRow(
                    title: "Screen Recording",
                    description: "Capture meeting app audio",
                    systemImage: "rectangle.on.rectangle",
                    granted: screenPermission
                ) {
                    requestScreenPermission()
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
            }

            HStack {
                Spacer()
                if showSavedMessage {
                    Text("Saved!")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 680)
        .task {
            apiKey = (try? KeychainManager.retrieve(account: "assemblyai-api-key")) ?? ""
            userName = UserDefaults.standard.string(forKey: "userName") ?? ""
            launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
            selectedAudioDevice = UserDefaults.standard.string(forKey: "audioDeviceId") ?? "default"
            audioDevices = AudioDeviceInfo.listInputDevices()
            selectedCalendarId = UserDefaults.standard.string(forKey: "calendarId") ?? "all"
            calendars = CalendarInfo.listCalendars()
            skipPatterns = UserDefaults.standard.stringArray(forKey: "skipPatterns") ?? ["Busy", "Out of Office", "OOO", "Focus Time", "No Meeting Block"]
            checkPermissions()
        }
    }

    private func save() {
        if !apiKey.isEmpty {
            try? KeychainManager.save(account: "assemblyai-api-key", data: apiKey)
        }
        UserDefaults.standard.set(userName, forKey: "userName")
        UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        UserDefaults.standard.set(selectedAudioDevice, forKey: "audioDeviceId")
        UserDefaults.standard.set(selectedCalendarId, forKey: "calendarId")
        UserDefaults.standard.set(skipPatterns, forKey: "skipPatterns")

        withAnimation {
            showSavedMessage = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSavedMessage = false }
        }
    }

    private func addSkipPattern() {
        let pattern = newSkipPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !skipPatterns.contains(pattern) else { return }
        skipPatterns.append(pattern)
        newSkipPattern = ""
    }

    private func checkPermissions() {
        // Mic
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        // Calendar
        let ekStatus = EKEventStore.authorizationStatus(for: .event)
        calendarPermission = ekStatus == .fullAccess || ekStatus == .authorized

        // Screen Recording — check by attempting to get shareable content
        Task {
            do {
                let _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                await MainActor.run { screenPermission = true }
            } catch {
                await MainActor.run { screenPermission = false }
            }
        }
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micPermission = granted
            }
        }
    }

    private func requestCalendarPermission() {
        let store = EKEventStore()
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            await MainActor.run {
                calendarPermission = granted
                if granted {
                    calendars = CalendarInfo.listCalendars()
                }
            }
        }
    }

    private func requestScreenPermission() {
        // macOS can't programmatically prompt — open System Settings
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let systemImage: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }
}

struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    let color: Color

    static func listCalendars() -> [CalendarInfo] {
        let store = EKEventStore()
        let calendars = store.calendars(for: .event)
        return calendars.map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                color: Color(cgColor: cal.cgColor)
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

struct AudioDeviceInfo: Identifiable {
    let id: String
    let name: String

    static func listInputDevices() -> [AudioDeviceInfo] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)

        return deviceIDs.compactMap { deviceID -> AudioDeviceInfo? in
            // Check if it has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPtr)
            let channelCount = bufferListPtr.pointee.mBuffers.mNumberChannels
            guard channelCount > 0 else { return nil }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

            return AudioDeviceInfo(id: "\(deviceID)", name: name as String)
        }
    }
}
