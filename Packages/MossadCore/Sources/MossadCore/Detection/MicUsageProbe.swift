#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import CoreAudio
import Foundation

/// Lists Core Audio process objects and whether each is using input (the mic) or output.
public final class MicUsageProbe: MicUsageProbing {
    public init() {}

    public func processes() -> [AudioProcess] {
        objectIDs().compactMap { id in
            guard let bundleID = string(id, kAudioProcessPropertyBundleID), !bundleID.isEmpty else { return nil }
            let pid: pid_t = value(id, kAudioProcessPropertyPID) ?? -1
            let input: UInt32 = value(id, kAudioProcessPropertyIsRunningInput) ?? 0
            let output: UInt32 = value(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningInput: input != 0, isRunningOutput: output != 0)
        }
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func objectIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.load(as: T.self)
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &result) == noErr, let cf = result else { return nil }
        return cf.takeRetainedValue() as String
    }
}
#endif
