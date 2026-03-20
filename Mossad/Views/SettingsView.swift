// Mossad/Views/SettingsView.swift
import SwiftUI
import MossadShared
import CoreAudio

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var userName: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var selectedAudioDevice: String = "default"
    @State private var audioDevices: [AudioDeviceInfo] = []
    @State private var showSavedMessage = false

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
        .frame(width: 450, height: 320)
        .task {
            apiKey = (try? KeychainManager.retrieve(account: "assemblyai-api-key")) ?? ""
            userName = UserDefaults.standard.string(forKey: "userName") ?? ""
            launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
            selectedAudioDevice = UserDefaults.standard.string(forKey: "audioDeviceId") ?? "default"
            audioDevices = AudioDeviceInfo.listInputDevices()
        }
    }

    private func save() {
        if !apiKey.isEmpty {
            try? KeychainManager.save(account: "assemblyai-api-key", data: apiKey)
        }
        UserDefaults.standard.set(userName, forKey: "userName")
        UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        UserDefaults.standard.set(selectedAudioDevice, forKey: "audioDeviceId")

        withAnimation {
            showSavedMessage = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSavedMessage = false }
        }
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
