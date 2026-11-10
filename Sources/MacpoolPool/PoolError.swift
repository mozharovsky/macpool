public import MacpoolVM
import Foundation

/// A failure of the pool daemon, its clients, or a VM supervisor.
public enum PoolError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A VM library operation failed.
    ///
    /// - Parameter error: The library's error.
    case library(MacpoolError)

    /// A file system operation failed.
    ///
    /// - Parameters:
    ///   - operation: What the pool tried to do, such as `writing the pool state`.
    ///   - path: The file or directory involved.
    ///   - reason: The system's description of the failure.
    case fileSystem(operation: String, path: String, reason: String)

    /// Another daemon already serves the data directory.
    ///
    /// - Parameter path: The data directory.
    case daemonRunning(path: String)

    /// No daemon answers on the data directory's socket.
    ///
    /// - Parameters:
    ///   - path: The socket that refused the connection or does not exist.
    ///   - reason: The system's description of the failure.
    case daemonUnreachable(path: String, reason: String)

    /// A Unix socket path does not fit in a socket address, directly or through an alias.
    ///
    /// The pool reaches a long or non-ASCII path through a short alias in the user's temporary
    /// directory, so this happens only when the alias path does not fit either.
    ///
    /// - Parameters:
    ///   - path: The socket path in the data directory.
    ///   - length: The path's length in UTF-8 bytes.
    case socketPathTooLong(path: String, length: Int)

    /// A socket or connection failed.
    ///
    /// - Parameters:
    ///   - path: The socket path or network endpoint involved.
    ///   - reason: The network framework's description of the failure.
    case connection(path: String, reason: String)

    /// A message on a socket could not be encoded or decoded.
    ///
    /// - Parameter reason: What was wrong with the message.
    case malformedMessage(reason: String)

    /// The pool state file exists but cannot be used.
    ///
    /// - Parameters:
    ///   - path: The state file.
    ///   - reason: Why the contents are unusable.
    case invalidState(path: String, reason: String)

    /// The pool state file has a format version that this build does not read.
    ///
    /// Another build wrote the file, and that build can still resume its leases, so the daemon
    /// leaves the file and the clones alone.
    ///
    /// - Parameters:
    ///   - path: The state file.
    ///   - version: The file's format version.
    case unsupportedStateVersion(path: String, version: Int)

    /// A lease request names values outside the accepted ranges.
    ///
    /// - Parameter reason: The rejected value and its range.
    case invalidRequest(reason: String)

    /// The daemon knows no lease with the identifier.
    ///
    /// - Parameter id: The identifier that the client sent.
    case unknownLease(id: String)

    /// Another client is attached to the lease.
    ///
    /// - Parameter id: The lease's identifier.
    case leaseAttached(id: String)

    /// The lease is already ending, so it cannot be renewed or attached.
    ///
    /// - Parameter id: The lease's identifier.
    case leaseEnding(id: String)

    /// The daemon answered with an error.
    ///
    /// - Parameter message: The daemon's description of the failure.
    case daemonRefused(message: String)

    /// The daemon closed the connection before it answered.
    case connectionClosed

    /// A supervisor process could not start.
    ///
    /// - Parameter reason: Why the start failed.
    case supervisorLaunch(reason: String)

    /// Another supervisor of the lease still runs.
    ///
    /// - Parameter id: The lease's identifier.
    case supervisorRunning(id: String)

    /// The data directory could let another user reach the daemon's socket or its clones.
    ///
    /// - Parameters:
    ///   - path: The directory that fails the check.
    ///   - reason: What is wrong with its owner, type, or permissions.
    case insecureDirectory(path: String, reason: String)

    /// A one-line description for logs and command output.
    public var description: String {
        switch self {
        case let .library(error):
            error.description
        case let .fileSystem(operation, path, reason):
            "\(operation) \(path): \(reason)"
        case let .daemonRunning(path):
            "another macpool daemon already serves \(path)"
        case let .daemonUnreachable(path, reason):
            "no macpool daemon answers on \(path) (\(reason)), so start one with macpool daemon"
        case let .socketPathTooLong(path, length):
            "the socket path \(path) has \(length) bytes, and no alias fits the "
                + "\(SocketPath.capacity - 1) bytes of a Unix socket address, so choose a shorter --data-dir"
        case let .connection(path, reason):
            "the connection on \(path) failed: \(reason)"
        case let .malformedMessage(reason):
            "malformed message: \(reason)"
        case let .invalidState(path, reason):
            "the pool state \(path) is unusable: \(reason)"
        case let .unsupportedStateVersion(path, version):
            "the pool state \(path) has format version \(version), so start the macpool build that wrote it"
        case let .invalidRequest(reason):
            reason
        case let .unknownLease(id):
            "no lease \(id)"
        case let .leaseAttached(id):
            "another client is attached to lease \(id)"
        case let .leaseEnding(id):
            "lease \(id) is ending"
        case let .daemonRefused(message):
            message
        case .connectionClosed:
            "the daemon closed the connection"
        case let .supervisorLaunch(reason):
            "the VM supervisor did not start: \(reason)"
        case let .supervisorRunning(id):
            "another supervisor of lease \(id) still runs"
        case let .insecureDirectory(path, reason):
            "the data directory \(path) is unsafe: \(reason)"
        }
    }

    /// Wraps an error that a Foundation file operation reported.
    ///
    /// - Parameters:
    ///   - operation: What the pool tried to do.
    ///   - url: The file or directory involved.
    ///   - error: The reported error.
    /// - Returns: A ``fileSystem(operation:path:reason:)`` error.
    static func fileSystem(_ operation: String, _ url: URL, _ error: any Error) -> PoolError {
        .fileSystem(operation: operation, path: url.path(percentEncoded: false), reason: error.localizedDescription)
    }

    /// Describes the failure of a system call from the current `errno`.
    ///
    /// - Parameters:
    ///   - operation: What the pool tried to do.
    ///   - url: The file or directory involved.
    /// - Returns: A ``fileSystem(operation:path:reason:)`` error.
    static func systemCall(_ operation: String, _ url: URL) -> PoolError {
        .fileSystem(
            operation: operation,
            path: url.path(percentEncoded: false),
            reason: String(cString: strerror(errno)),
        )
    }
}
