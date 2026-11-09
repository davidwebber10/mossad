import Foundation

/// An exclusive lock on `<data root>/.lock`, held for the life of the app, so only one copy records, recovers
/// interrupted calls, and processes in a folder. A second copy that started on the same folder gets nil.
/// The system frees the lock when the holder ends, also after a crash.
public final class InstanceLock: @unchecked Sendable {
    private let fd: Int32

    public init?(root: URL) {
        let fd = open(root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
