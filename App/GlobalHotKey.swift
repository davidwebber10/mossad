import Carbon.HIToolbox
import Foundation
import MossadCore

/// The system-wide shortcuts, so a bookmark or the quick panel works while the call app is in front. Carbon hot
/// keys need no Accessibility permission, unlike a global key monitor. One event handler serves every key and
/// runs only the action of the key that was pressed, by its id.
@MainActor
final class GlobalHotKeys {
    enum ID: UInt32 {
        case bookmark = 1, ask = 2
    }

    private var handler: EventHandlerRef?
    private var refs: [ID: EventHotKeyRef] = [:]
    private var actions: [ID: () -> Void] = [:]
    nonisolated private static let signature = OSType(0x4D534144)  // "MSAD"

    /// Registers a key, in place of the one this id had. False when the system refuses it (another app has it).
    @discardableResult
    func register(_ id: ID, _ shortcut: HotKeyShortcut, action: @escaping () -> Void) -> Bool {
        unregister(id)
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, Self.carbon(shortcut.modifiers), EventHotKeyID(signature: Self.signature, id: id.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.error("The shortcut \(shortcut.symbols) could not be registered: \(status)")
            return false
        }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr, key.signature == GlobalHotKeys.signature, let id = ID(rawValue: key.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let keys = Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { keys.actions[id]?() } }
            return noErr
        }, 1, &spec, me, &handler)
    }

    private static func carbon(_ m: HotKeyShortcut.Modifiers) -> UInt32 {
        var out = 0
        if m.contains(.command) { out |= cmdKey }
        if m.contains(.option) { out |= optionKey }
        if m.contains(.control) { out |= controlKey }
        if m.contains(.shift) { out |= shiftKey }
        return UInt32(out)
    }
}
