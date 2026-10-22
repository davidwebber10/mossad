#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import AVFoundation
import CoreAudio
import Foundation

/// Captures the audio that specific processes play, before it reaches the speakers,
/// using a Core Audio process tap on a private aggregate device.
public final class ProcessTap: TrackSource, @unchecked Sendable {
    private let processObjectIDs: [AudioObjectID]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.dwebber.mossad.tap", qos: .userInitiated)

    /// An empty list taps all system audio.
    public init(processObjectIDs: [AudioObjectID]) {
        self.processObjectIDs = processObjectIDs
    }

    public func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        do {
            try create(global: processObjectIDs.isEmpty, onBuffer)
        } catch where !processObjectIDs.isEmpty {
            Log.error("Process tap failed (\(error)); using a global system-audio tap")
            stop()
            try create(global: true, onBuffer)
        }
    }

    private func create(global: Bool, _ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description = global
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Mossad Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format), "read tap format")
        guard let avFormat = AVAudioFormat(streamDescription: &format) else { throw CaptureError.message("unsupported tap format") }

        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mossad Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            onBuffer(buffer)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "start device")
        Log.info("Tap started (\(global ? "global" : "\(processObjectIDs.count) processes"), \(avFormat.sampleRate) Hz, \(avFormat.channelCount) ch)")
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID), "default output device")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "output device UID")
        guard let uid else { throw CaptureError.message("no output device UID") }
        return uid.takeRetainedValue() as String
    }
}

public enum CaptureError: Error, CustomStringConvertible {
    case status(OSStatus, String)
    case message(String)

    public var description: String {
        switch self {
        case .status(let s, let what): "\(what) failed (\(s))"
        case .message(let m): m
        }
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CaptureError.status(status, what) }
}

/// Calls back when the default output device changes (headphones connected, USB headset unplugged).
public final class OutputDeviceWatcher: @unchecked Sendable {
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let block: AudioObjectPropertyListenerBlock

    public init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }
}
#endif
