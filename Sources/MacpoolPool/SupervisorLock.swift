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
/// The holder records itself in the file, so the daemon can signal a supervisor that no longer
/// answers on its socket. The kernel releases the lock when the process exits, including a crash.
///
/// ## Record format
///
/// The supervisor writes the record right after it takes the lock and before it opens its socket.
/// The record is UTF-8 text with lines that each end in a line feed.
///
/// 1. The supervisor's process identifier in decimal.
/// 2. The supervisor's start time in decimal microseconds since 1970, as the kernel reports it.
///
/// Builds before the start time wrote only the first line. ``holder(of:in:)`` reads such a record
/// with an absent start time, and the daemon then identifies the process by its arguments alone.
/// A second line that is not a whole number or lacks its line feed makes the start time
/// ``RecordedStartTime/malformed``, and the daemon then sends no signal.
///
/// A later format keeps these two lines and may add lines after them, which this build ignores.
/// A build that reads only the first line parses the whole record as one number, fails, and falls
/// back to the process identifier in the pool state.
public final class SupervisorLock: Sendable {
    /// The open lock file that carries the `flock`.
    private let descriptor: Int32

    /// The wait between attempts to take a lock that is briefly held by a check.
    private static let retryInterval: useconds_t = 50000

    /// Takes a lease's lock, retrying while another process holds it, and writes the record.
    ///
    /// ``holder(of:in:)`` takes the lock for a moment to test it, so the call retries for up to
    /// `timeout` before it gives up.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - directory: The data directory, whose run directory must exist.
    ///   - processID: The identifier to record as the holder, which is the calling process's own
    ///     identifier outside of tests.
    ///   - startTime: The holder's start time in microseconds since 1970, or `nil` to read the
    ///     start time of `processID` from the kernel.
    ///   - timeout: The longest wait for the lock, in seconds.
    /// - Throws: ``PoolError/supervisorRunning(id:)`` when another process keeps the lock for the
    ///   whole wait, or ``PoolError/fileSystem(operation:path:reason:)`` when the start time cannot
    ///   be read or the file cannot be opened or written.
    public init(
        of id: LeaseID,
        in directory: PoolDirectory,
        processID: Int32 = getpid(),
        startTime: UInt64? = nil,
        timeout: TimeInterval = 5,
    ) throws(PoolError) {
        let file = directory.supervisorLock(for: id)
        let recordedStart: UInt64
        do {
            recordedStart = try startTime ?? ProcessStartTime.read(processID: processID)
        } catch {
            throw .fileSystem(
                operation: "reading the supervisor's start time",
                path: file.path(percentEncoded: false),
                reason: "\(error)",
            )
        }
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
        let text = Array("\(processID)\n\(recordedStart)\n".utf8)
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
    ///   holder's record, whose process identifier is 0 when the holder has not written it yet.
    public static func holder(of id: LeaseID, in directory: PoolDirectory) -> SupervisorLockRecord? {
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
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        return SupervisorLockRecord(contents: buffer.prefix(max(count, 0)))
    }

    /// Releases the lock by closing the lock file.
    deinit {
        close(descriptor)
    }
}

/// What a supervisor recorded in its lock.
public struct SupervisorLockRecord: Sendable, Equatable {
    /// The supervisor's process identifier, or 0 when the record holds none yet or it is not a
    /// number.
    public var processID: Int32

    /// The supervisor's start time as the record holds it.
    public var startTime: RecordedStartTime

    /// Creates a record.
    ///
    /// - Parameters:
    ///   - processID: The supervisor's process identifier, or 0 when it is unknown.
    ///   - startTime: The supervisor's start time as the record holds it.
    public init(processID: Int32, startTime: RecordedStartTime) {
        self.processID = processID
        self.startTime = startTime
    }

    /// Reads a record in the format that ``SupervisorLock`` describes.
    ///
    /// An empty record is one that the holder has not written yet. It reads as process 0 with an
    /// absent start time.
    ///
    /// - Parameter contents: The beginning of the lock file, at least as long as the two lines.
    init(contents: some Collection<UInt8>) {
        let lines = String(decoding: contents, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        // Only lines followed by a line feed are complete. The last element is the unterminated rest.
        let complete = lines.dropLast()
        guard let first = complete.first, let processID = Int32(first) else {
            self.init(processID: 0, startTime: contents.isEmpty ? .absent : .malformed)
            return
        }
        guard complete.count >= 2 else {
            self.init(processID: processID, startTime: lines.last?.isEmpty == true ? .absent : .malformed)
            return
        }
        let startTime = UInt64(complete[complete.startIndex + 1]).map(RecordedStartTime.recorded) ?? .malformed
        self.init(processID: processID, startTime: startTime)
    }
}

/// A supervisor's start time as its lock records it.
public enum RecordedStartTime: Sendable, Equatable {
    /// The record has no start time line, as a build before the start time wrote it.
    case absent

    /// The start time in microseconds since 1970.
    ///
    /// - Parameter microseconds: The start time.
    case recorded(UInt64)

    /// The start time line is not a whole number or lacks its line feed.
    case malformed
}
