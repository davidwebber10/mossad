#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Which buffers of an aggregate device's input list hold the tap.
enum TapLayout {
    /// The aggregate lists its sub-device's input streams first (a USB headset's mic, an audio interface) and the
    /// tap's stream after them, so the tap is the last buffer, or the last `tapChannels` buffers of one channel each
    /// when the tap is not interleaved. Nil when the list does not fit the tap's format. `channels` gives the channel
    /// count of the buffer at an index; nothing here allocates, so the audio thread can call it.
    static func tapBuffers(count: Int, channels: (Int) -> Int, tapChannels: Int, interleaved: Bool) -> Range<Int>? {
        guard tapChannels > 0 else { return nil }
        if interleaved {
            guard count >= 1, channels(count - 1) == tapChannels else { return nil }
            return (count - 1)..<count
        }
        guard count >= tapChannels else { return nil }
        let range = (count - tapChannels)..<count
        for i in range where channels(i) != 1 { return nil }
        return range
    }
}

/// Captures the audio that specific processes play, before it reaches the speakers,
/// using a Core Audio process tap on a private aggregate device.
public final class ProcessTap: TrackSource, @unchecked Sendable {
    private let processObjectIDs: [AudioObjectID]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.dwebber.mossad.tap", qos: .userInitiated)
    public private(set) var isGlobal = false

    /// An empty list taps all system audio.
    public init(processObjectIDs: [AudioObjectID]) {
        self.processObjectIDs = processObjectIDs
    }

    public func start(_ feed: AudioFeed) throws {
        do {
            try create(global: processObjectIDs.isEmpty, feed)
        } catch where !processObjectIDs.isEmpty {
            Log.error("Process tap failed (\(error)); using a global system-audio tap")
            stop()
            try create(global: true, feed)
        }
    }

    private func create(global: Bool, _ feed: AudioFeed) throws {
        let description = global
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Mossad Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")
        isGlobal = global

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format), "read tap format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0 else {
            throw CaptureError.message("unsupported tap format (\(format.mBitsPerChannel) bits, \(format.mChannelsPerFrame) ch, flags \(format.mFormatFlags))")
        }

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
        // The buffers come at the output device's rate, which can differ from the tap's: AirPods in a call run at
        // 24 kHz while the tap says 48 kHz, and the other side then played at double speed.
        if let rate = nominalSampleRate(aggregateID), rate != format.mSampleRate {
            Log.info("Tap says \(Int(format.mSampleRate)) Hz; the output device runs at \(Int(rate)) Hz")
            format.mSampleRate = rate
        }
        guard format.mSampleRate > 0 else { throw CaptureError.message("the tap has no sample rate") }

        let rate = format.mSampleRate
        let tapChannels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        // An output device with inputs of its own (a USB headset) puts its mic streams in the same list. Say so once,
        // so a wrong stream in the call track can be traced.
        let layout = inputLayout(aggregateID)
        if let layout {
            let chosen = TapLayout.tapBuffers(count: layout.count, channels: { layout[$0] }, tapChannels: tapChannels, interleaved: interleaved)
            let extra = layout.count - (chosen?.count ?? 0)
            if chosen == nil {
                Log.error("Tap input layout \(layout) does not fit the tap (\(tapChannels) ch, interleaved \(interleaved))")
            } else if extra > 0 {
                Log.info("Tap input layout \(layout): the output device has \(extra) input streams of its own; using buffers \(chosen!)")
            }
        }
        let expectedCount = layout?.count
        let warned = WarnOnce()

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, inputTime, _, _ in
            // The audio thread: copy into the feed and return. No allocation, no lock, no file.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let count = list.count
            if let expectedCount, count != expectedCount { warned.once("Tap delivers \(count) buffers, not the \(expectedCount) its device listed") }
            guard let buffers = TapLayout.tapBuffers(count: count, channels: { Int(list[$0].mNumberChannels) },
                                                     tapChannels: tapChannels, interleaved: interleaved) else {
                feed.reject()
                return
            }
            let stamp = inputTime.pointee
            feed.push(input, buffers: buffers, channelsPerBuffer: interleaved ? tapChannels : 1, rate: rate,
                      hostTime: stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : nil)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "start device")
        Log.info("Tap started (\(global ? "global" : "\(processObjectIDs.count) processes"), \(rate) Hz, \(tapChannels) ch)")
    }

    public func stop() {
        func log(_ status: OSStatus, _ what: String) {
            if status != noErr { Log.error("Tap cleanup: \(what) failed (\(status))") }
        }
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                log(AudioDeviceStop(aggregateID, ioProcID), "stop device")
                log(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "destroy IO proc")
            }
            log(AudioHardwareDestroyAggregateDevice(aggregateID), "destroy aggregate device")
        }
        if tapID != kAudioObjectUnknown { log(AudioHardwareDestroyProcessTap(tapID), "destroy tap") }
        // A block that was already on its way finishes before the next source writes to the same feed.
        queue.sync {}
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The channel count of each buffer the device delivers on its input side; nil when it cannot be read.
    private func inputLayout(_ device: AudioObjectID) -> [Int]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<UInt32>.size) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    private func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
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

/// Logs one message from the audio thread, on another queue, the first time only.
private final class WarnOnce: @unchecked Sendable {
    private let done = Atomic<Bool>(false)
    func once(_ message: @autoclosure () -> String) {
        guard !done.exchange(true, ordering: .relaxed) else { return }
        let text = message()
        DispatchQueue.global(qos: .utility).async { Log.error(text) }
    }
}

/// Calls back when the tap must be rebuilt: the default output device changed (headphones connected, USB headset
/// unplugged), that device changed its sample rate (AirPods go from 48 kHz to 24 kHz when a call takes their mic), or
/// the Mac woke from sleep. Changes that come together give one call.
public final class OutputDeviceWatcher: @unchecked Sendable {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let onChange: @Sendable () -> Void
    // Main queue only.
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var rateBlock: AudioObjectPropertyListenerBlock?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var pending: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.watchRate()
            self?.changed()
        }
        let rateBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        self.deviceBlock = deviceBlock
        self.rateBlock = rateBlock
        AudioObjectAddPropertyListenerBlock(Self.system, &defaultAddress, DispatchQueue.main, deviceBlock)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in self?.changed() }
        DispatchQueue.main.async { [weak self] in self?.watchRate() }
    }

    deinit {
        if let deviceBlock { AudioObjectRemovePropertyListenerBlock(Self.system, &defaultAddress, DispatchQueue.main, deviceBlock) }
        if let rateBlock, device != kAudioObjectUnknown { AudioObjectRemovePropertyListenerBlock(device, &rateAddress, DispatchQueue.main, rateBlock) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        pending?.cancel()
    }

    /// Follows the sample rate of the device that is the default output now.
    private func watchRate() {
        guard let rateBlock else { return }
        var current = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &defaultAddress, 0, nil, &size, &current) == noErr, current != device else { return }
        if device != kAudioObjectUnknown { AudioObjectRemovePropertyListenerBlock(device, &rateAddress, DispatchQueue.main, rateBlock) }
        device = current
        if device != kAudioObjectUnknown { AudioObjectAddPropertyListenerBlock(device, &rateAddress, DispatchQueue.main, rateBlock) }
    }

    private func changed() {
        pending?.cancel()
        let onChange = onChange
        let item = DispatchWorkItem { onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
#endif
