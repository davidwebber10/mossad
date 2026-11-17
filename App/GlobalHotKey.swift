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
        /// A debug build's made-up key for the proof of a switch.
        case proof = 99
    }

    private var handler: EventHandlerRef?
    private var refs: [ID: EventHotKeyRef] = [:]
    private var actions: [ID: () -> Void] = [:]
    /// The keys this copy wants, also while they are let go for a switch or wait for a retry.
    private var wanted: [ID: (shortcut: HotKeyShortcut, action: () -> Void)] = [:]
    private var retries: [ID: Task<Void, Never>] = [:]
    /// A key that a retry registered: the controller updates what it shows.
    var onRegistered: ((ID) -> Void)?
    nonisolated private static let signature = OSType(0x4D534144)  // "MSAD"

    /// Registers a key, in place of the one this id had. False when the system refuses it (another app, or the
    /// instance before a switch, has it). With `retrying`, a refused key is tried again by `HotKeyRetry`.
    @discardableResult
    func register(_ id: ID, _ shortcut: HotKeyShortcut, retrying: Bool = false, action: @escaping () -> Void) -> Bool {
        unregister(id)
        wanted[id] = (shortcut, action)
        if attempt(id) { return true }
        if retrying { retry(id, failures: 1) } else { Log.error("The shortcut \(shortcut.symbols) could not be registered") }
        return false
    }

    private func attempt(_ id: ID) -> Bool {
        guard let want = wanted[id] else { return false }
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(want.shortcut.keyCode, Self.carbon(want.shortcut.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id.rawValue), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = want.action
        return true
    }

    private func retry(_ id: ID, failures: Int) {
        guard let delay = HotKeyRetry.delay(afterFailure: failures) else {
            Log.error("The shortcut \(wanted[id]?.shortcut.symbols ?? "") could not be registered; Mossad stopped trying")
            return
        }
        retries[id]?.cancel()
        retries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.wanted[id] != nil, self.refs[id] == nil else { return }
            if self.attempt(id) {
                Log.info("Hot keys: \(id) registered after \(failures) \(failures == 1 ? "retry" : "retries")")
                self.onRegistered?(id)
            } else {
                self.retry(id, failures: failures + 1)
            }
        }
    }

    func unregister(_ id: ID) {
        retries.removeValue(forKey: id)?.cancel()
        wanted[id] = nil
        release(id)
    }

    private func release(_ id: ID) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    /// Before a switch: the keys go, so the new instance can take them; they stay wanted.
    func suspendAll() {
        retries.values.forEach { $0.cancel() }
        retries = [:]
        let held = refs.keys.map { "\($0)" }.sorted()
        for id in Array(refs.keys) { release(id) }
        Log.info("Hot keys: let go of \(held.isEmpty ? "none" : held.joined(separator: ", ")) before the switch")
    }

    /// After a switch that did not happen: the wanted keys again, with retries (the new instance may hold them still).
    func resumeAll() {
        for id in wanted.keys.sorted(by: { $0.rawValue < $1.rawValue }) where refs[id] == nil {
            if attempt(id) { Log.info("Hot keys: \(id) registered again") } else { retry(id, failures: 1) }
        }
    }

    var holds: [ID] { refs.keys.sorted { $0.rawValue < $1.rawValue } }

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
