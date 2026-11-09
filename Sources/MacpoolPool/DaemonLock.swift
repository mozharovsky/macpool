import Foundation

/// The exclusive lock that one daemon holds on its data directory.
///
/// The lock is an `flock` on the directory's `daemon.lock` file. The kernel releases it when the
/// lock is deinitialized or the process exits, including a crash, so a new daemon can start at
/// once. The descriptor closes on exec, so supervisors that the daemon starts do not inherit it.
final class DaemonLock: Sendable {
    /// The open lock file that carries the `flock`.
    private let descriptor: Int32

    /// Takes the lock without waiting.
    ///
    /// - Parameter directory: The data directory, which must exist.
    /// - Throws: ``PoolError/daemonRunning(path:)`` when another process holds the lock, or
    ///   ``PoolError/fileSystem(operation:path:reason:)`` when the lock file cannot be opened.
    init(directory: PoolDirectory) throws(PoolError) {
        let file = directory.lockFile
        let descriptor = open(file.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw .systemCall("opening the daemon lock", file)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK {
                throw .daemonRunning(path: directory.root.path(percentEncoded: false))
            }
            errno = failure
            throw .systemCall("locking the data directory", file)
        }
        self.descriptor = descriptor
    }

    /// Releases the lock by closing the lock file.
    deinit {
        close(descriptor)
    }
}
