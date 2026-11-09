#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import CoreAudio
import Foundation

/// What the probe asks Core Audio. Every answer is nil when the read failed.
protocol AudioProcessSource {
    func processObjects() -> [AudioObjectID]?
    func bundleID(of id: AudioObjectID) -> String?
    func pid(of id: AudioObjectID) -> pid_t?
    func isRunningInput(_ id: AudioObjectID) -> Bool?
    func isRunningOutput(_ id: AudioObjectID) -> Bool?
    /// Whether any audio device with an input stream runs in any process.
    func anyInputDeviceRunning() -> Bool?
}

/// Lists the Core Audio process objects of the meeting apps (browsers, Zoom, Teams) and whether each uses input
/// (the mic) or output. Every read is a synchronous request to the audio server, and the scan runs every 2 s all
/// day, so it asks as little as it can:
/// - the bundle ID and the PID of an object are read once (they do not change while the object lives);
/// - the input and output states are read only for the apps `MeetingMatcher.appKind` knows;
/// - outside a call, when no input device runs at all, no app can use the mic: input is then known to be off
///   without a read, and output is read only for Zoom and Teams (they can be in a call without the mic).
/// Not thread-safe: call it on one queue.
public final class MicUsageProbe: MicUsageProbing {
    private struct Known {
        var bundleID: String
        var pid: pid_t?
        var isMeetingApp: Bool
        var startsWithoutMic: Bool
    }

    private let source: AudioProcessSource
    private var known: [AudioObjectID: Known] = [:]
    /// What is known is read again after this many scans (5 minutes of ticks), after an empty or unreadable list
    /// (the audio server started again and can give the old numbers to other processes), and after `forget()`.
    static let scansBeforeRefresh = 150
    private var scans = 0

    public convenience init() { self.init(source: CoreAudioProcessSource()) }

    init(source: AudioProcessSource) { self.source = source }

    public func processes() -> [AudioProcess] { scan(callActive: true) ?? [] }

    public func forget() { known = [:] }

    public func scan(callActive: Bool) -> [AudioProcess]? {
        guard let ids = source.processObjects() else {
            known = [:]
            return nil
        }
        guard !ids.isEmpty else {
            known = [:]
            return []
        }
        scans += 1
        if scans >= Self.scansBeforeRefresh {
            scans = 0
            known = [:]
        }
        let live = Set(ids)
        known = known.filter { live.contains($0.key) }
        // An unknown gate is an open gate: read each app.
        let micPossible = callActive || (source.anyInputDeviceRunning() ?? true)
        return ids.compactMap { id in
            if known[id] == nil {
                // A failed read is tried again at the next scan.
                // So is an empty ID: a process can be listed before the audio server knows its name.
                guard let bundleID = source.bundleID(of: id), !bundleID.isEmpty else { return nil }
                let kind = MeetingMatcher.appKind(bundleID: bundleID)
                let startsWithoutMic = kind == .zoomApp || kind == .teamsApp
                known[id] = Known(bundleID: bundleID, pid: nil, isMeetingApp: kind != nil, startsWithoutMic: startsWithoutMic)
            }
            guard var entry = known[id], entry.isMeetingApp else { return nil }
            if entry.pid == nil {
                entry.pid = source.pid(of: id)
                known[id] = entry
            }
            let input = micPossible ? source.isRunningInput(id) : false
            let output = micPossible || entry.startsWithoutMic ? source.isRunningOutput(id) : nil
            return AudioProcess(objectID: id, pid: entry.pid ?? -1, bundleID: entry.bundleID, isRunningInput: input, isRunningOutput: output)
        }
    }
}

struct CoreAudioProcessSource: AudioProcessSource {
    func processObjects() -> [AudioObjectID]? { objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) }

    func bundleID(of id: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &result) == noErr, let cf = result else { return nil }
        return cf.takeRetainedValue() as String
    }

    func pid(of id: AudioObjectID) -> pid_t? { value(id, kAudioProcessPropertyPID) }

    func isRunningInput(_ id: AudioObjectID) -> Bool? { flag(id, kAudioProcessPropertyIsRunningInput) }

    func isRunningOutput(_ id: AudioObjectID) -> Bool? { flag(id, kAudioProcessPropertyIsRunningOutput) }

    func anyInputDeviceRunning() -> Bool? {
        guard let devices = objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) else { return nil }
        var unknown = false
        for device in devices {
            guard let running = flag(device, kAudioDevicePropertyDeviceIsRunningSomewhere) else {
                unknown = true
                continue
            }
            guard running else { continue }
            // Only a running device is asked for its streams; a playing output device has none on the input side.
            var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else {
                unknown = true
                continue
            }
            if size > 0 { return true }
        }
        return unknown ? nil : false
    }

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func flag(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        let raw: UInt32? = value(id, selector)
        return raw.map { $0 != 0 }
    }

    private func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.load(as: T.self)
    }
}
#endif
