import Foundation

/// An exclusive lock on `<data root>/.lock`, held for the life of the app, so only one copy records, recovers
/// interrupted calls, and processes in a folder. The system frees the lock when the holder ends, also after a crash.
public final class InstanceLock: @unchecked Sendable {
    public enum Attempt {
        case held(InstanceLock)
        /// Another copy has the lock.
        case taken
        /// The lock could not be tried (the `errno`): the folder cannot be written, or the volume has no locks.
        /// This says nothing about another copy.
        case failed(Int32)
    }

    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func acquire(root: URL) -> Attempt {
        let fd = open(root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failed(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            return code == EWOULDBLOCK ? .taken : .failed(code)
        }
        return .held(InstanceLock(fd: fd))
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
