import Foundation

/// The one gate of every write and delete of the iCloud Keychain items that the iPhone reads.
public enum SharedItemsGate {
    /// Runs `write` only for a copy that may write them: never a preview or a run on a made-up registry.
    public static func perform(_ identity: AppIdentity = .current, _ write: () throws -> Void) rethrows {
        guard identity.writesSharedItems else { return }
        try write()
    }

    /// The app's own rule: iCloud in this build, the launch decided whether this copy is inert, and it is not.
    public static func appMayWrite(iCloud: Bool, launchDecided: Bool, inert: Bool) -> Bool {
        iCloud && launchDecided && !inert
    }
}
