import Foundation
import Virtualization

/// A failure of a library operation, with enough context to report it to a person.
public enum MacpoolError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A file system operation failed.
    ///
    /// - Parameters:
    ///   - operation: What the library tried to do, such as `reading settings`.
    ///   - path: The file or directory involved.
    ///   - reason: The system's description of the failure.
    case fileSystem(operation: String, path: String, reason: String)

    /// A bundle file exists but holds data that the library or the framework rejects.
    ///
    /// - Parameters:
    ///   - path: The rejected file.
    ///   - reason: Why the data is unusable.
    case invalidBundle(path: String, reason: String)

    /// The Virtualization framework reported an error.
    ///
    /// - Parameters:
    ///   - operation: What the library asked the framework to do.
    ///   - domain: The error domain from the framework.
    ///   - code: The error code within that domain.
    ///   - description: The framework's localized description.
    case framework(operation: String, domain: String, code: Int, description: String)

    /// The host cannot run what the caller asked for.
    ///
    /// - Parameter reason: The missing capability or unmet requirement.
    case unsupported(reason: String)

    /// Another task already waits for the next VM event.
    ///
    /// A ``VirtualMachine`` delivers each event once, so it accepts only one waiting task.
    case eventWaitInProgress

    /// A command already holds the bundle's lock, so a VM may run from it.
    ///
    /// - Parameter path: The bundle directory.
    case bundleInUse(path: String)

    /// The host already runs as many macOS VMs as macOS allows.
    ///
    /// The framework enforces the limit of two macOS VMs per host and reports it when a VM starts.
    case virtualMachineLimitReached

    /// A clone's credential rotation began and did not finish, so the guest's credentials are
    /// unknown.
    ///
    /// - Parameter path: The bundle directory, which can only be deleted.
    case credentialRotationIncomplete(path: String)

    /// Replacing a clone's inherited guest credentials failed.
    ///
    /// - Parameters:
    ///   - step: The step that failed, such as `logging in with the inherited account`.
    ///   - reason: The failure, which includes the end of the guest command's error output.
    case credentialRotation(step: String, reason: String)

    /// Another macpool command holds a bundle whose credential rotation has not finished.
    ///
    /// The other command is usually the clone's first `run`, which records its progress before it
    /// ends.
    ///
    /// - Parameter path: The bundle directory.
    case credentialRotationInProgress(path: String)

    /// A one-line description for logs and command output.
    public var description: String {
        switch self {
        case let .fileSystem(operation, path, reason):
            "\(operation) \(path): \(reason)"
        case let .invalidBundle(path, reason):
            "invalid bundle file \(path): \(reason)"
        case let .framework(operation, domain, code, description):
            "\(operation): \(description) (domain \(domain), code \(code))"
        case let .unsupported(reason):
            "unsupported: \(reason)"
        case .eventWaitInProgress:
            "another task already waits for a VM event"
        case let .bundleInUse(path):
            "\(path) is in use by another macpool command"
        case .virtualMachineLimitReached:
            "this host already runs the two macOS VMs that macOS allows"
        case let .credentialRotationIncomplete(path):
            "the credential rotation of \(path) did not finish, so delete the clone and clone its source again"
        case let .credentialRotation(step, reason):
            "rotating the guest credentials failed while \(step): \(reason)"
        case let .credentialRotationInProgress(path):
            "another macpool run is replacing the guest credentials of \(path), so wait until it prints ready"
        }
    }

    /// Wraps an error that a Virtualization or Foundation call reported.
    ///
    /// - Parameters:
    ///   - operation: What the library asked the framework to do.
    ///   - error: The reported error, which bridges to `NSError`.
    /// - Returns: ``virtualMachineLimitReached`` for the framework's VM limit error, otherwise a
    ///   ``framework(operation:domain:code:description:)`` error.
    static func framework(_ operation: String, _ error: any Error) -> MacpoolError {
        let error = error as NSError
        if error.domain == VZError.errorDomain, error.code == VZError.Code.virtualMachineLimitExceeded.rawValue {
            return .virtualMachineLimitReached
        }
        return .framework(
            operation: operation,
            domain: error.domain,
            code: error.code,
            description: error.localizedDescription,
        )
    }

    /// Wraps an error that a Foundation file operation reported.
    ///
    /// - Parameters:
    ///   - operation: What the library tried to do.
    ///   - url: The file or directory involved.
    ///   - error: The reported error.
    /// - Returns: A ``fileSystem(operation:path:reason:)`` error.
    static func fileSystem(_ operation: String, _ url: URL, _ error: any Error) -> MacpoolError {
        .fileSystem(operation: operation, path: url.filePath, reason: error.localizedDescription)
    }

    /// Describes the failure of a system call from the current `errno`.
    ///
    /// - Parameters:
    ///   - operation: What the library tried to do.
    ///   - url: The file or directory involved.
    /// - Returns: A ``fileSystem(operation:path:reason:)`` error.
    static func systemCall(_ operation: String, _ url: URL) -> MacpoolError {
        .fileSystem(operation: operation, path: url.filePath, reason: String(cString: strerror(errno)))
    }
}
