public import Foundation

/// The lock that a lease's supervisor holds for its whole life.
///
/// The lock is an `flock` on the lease's file from ``PoolDirectory/supervisorLock(for:)``. A
/// supervisor takes it before anything else and keeps it until it has written its exit record and
/// closed its socket. A free lock therefore means that no supervisor of the lease runs and that
/// the socket and the record are final. The daemon waits for a free lock before it starts another
/// boot of the lease or deletes the clone, so no boot can mistake an earlier boot's files for its
/// own.
///
/// The holder writes its process identifier into the file, so the daemon can signal a supervisor
/// that no longer answers on its socket. The kernel releases the lock when the process exits,
/// including a crash.
public final class SupervisorLock: Sendable {
    /// The open lock file that carries the `flock`.
    private let descriptor: Int32

    /// The wait between attempts to take a lock that is briefly held by a check.
    private static let retryInterval: useconds_t = 50000

    /// Takes a lease's lock, retrying while another process holds it.
    ///
    /// ``holder(of:in:)`` takes the lock for a moment to test it, so the call retries for up to
    /// `timeout` before it gives up.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - directory: The data directory, whose run directory must exist.
    ///   - processID: The identifier to record as the holder, which is the calling process's own
    ///     identifier outside of tests.
    ///   - timeout: The longest wait for the lock, in seconds.
    /// - Throws: ``PoolError/supervisorRunning(id:)`` when another process keeps the lock for the
    ///   whole wait, or ``PoolError/fileSystem(operation:path:reason:)`` when the file cannot be
    ///   opened or written.
    public init(
        of id: LeaseID,
        in directory: PoolDirectory,
        processID: Int32 = getpid(),
        timeout: TimeInterval = 5,
    ) throws(PoolError) {
        let file = directory.supervisorLock(for: id)
        let descriptor = open(file.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw .systemCall("opening the supervisor lock", file)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK, Date() < deadline else {
                close(descriptor)
                if failure == EWOULDBLOCK {
                    throw .supervisorRunning(id: id.rawValue)
                }
                errno = failure
                throw .systemCall("locking the supervisor lock", file)
            }
            usleep(Self.retryInterval)
        }
        let text = Array("\(processID)\n".utf8)
        let written = text.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == text.count, ftruncate(descriptor, off_t(text.count)) == 0 else {
            let failure = errno
            close(descriptor)
            errno = failure
            throw .systemCall("recording the supervisor process", file)
        }
        self.descriptor = descriptor
    }

    /// Finds the process that holds a lease's lock.
    ///
    /// The check takes and releases the lock at once when it is free, so its answer can be stale
    /// by the time the caller uses it.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Returns: `nil` when no process holds the lock or the file does not exist. Otherwise the
    ///   recorded process identifier, or 0 when the holder has not recorded one yet.
    public static func holder(of id: LeaseID, in directory: PoolDirectory) -> Int32? {
        let file = directory.supervisorLock(for: id).path(percentEncoded: false)
        let descriptor = open(file, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            flock(descriptor, LOCK_UN)
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        let text = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Releases the lock by closing the lock file.
    deinit {
        close(descriptor)
    }
}
