import MacpoolVM

/// A failure of a subcommand, which the command line prints before it exits.
enum CommandError: Error, Equatable, CustomStringConvertible {
    /// A library operation failed.
    ///
    /// - Parameter error: The library's error.
    case library(MacpoolError)

    /// A signal interrupted the command, which removed what it had created.
    case interrupted

    /// The bundle has never booted, and its only provisioning boot would go unused.
    case firstBootNeedsProvisioning

    /// The bundle has booted before, so the guest would ignore provisioning.
    case provisioningAfterFirstBoot

    /// No `macpool run` holds the bundle, so its guest is not running.
    ///
    /// - Parameter path: The bundle directory.
    case notRunning(path: String)

    /// The requested resources are below the restore image's minimum.
    ///
    /// - Parameters:
    ///   - minimumCPUCount: The image's smallest CPU count.
    ///   - minimumMemoryByteCount: The image's smallest memory size in bytes.
    case insufficientResources(minimumCPUCount: Int, minimumMemoryByteCount: UInt64)

    /// A file that the command would create already exists.
    ///
    /// - Parameter path: The existing file.
    case fileExists(path: String)

    /// A host tool could not run or reported a failure.
    ///
    /// - Parameters:
    ///   - tool: The tool's name.
    ///   - reason: What went wrong.
    case tool(String, reason: String)

    /// The guest did not reach a step in time.
    ///
    /// - Parameters:
    ///   - step: What the command waited for.
    ///   - seconds: The timeout in seconds.
    case timedOut(step: String, seconds: Int)

    /// The VM stopped while the command still needed it.
    ///
    /// - Parameter event: The event that reported the stop.
    case stopped(MachineEvent)

    /// The host's DHCP server has no lease for the guest.
    ///
    /// - Parameter macAddress: The guest's MAC address.
    case noLease(macAddress: String)

    /// A value is out of the range that the command accepts.
    ///
    /// - Parameter reason: The rejected value and its range.
    case invalidValue(String)

    /// A one-line description for the command's error output.
    var description: String {
        switch self {
        case let .library(error):
            error.description
        case .interrupted:
            "interrupted"
        case .firstBootNeedsProvisioning:
            "the bundle has never booted, so pass --provision for the only boot that applies it"
        case .provisioningAfterFirstBoot:
            "the bundle has booted before, and the guest ignores provisioning after its first boot"
        case let .notRunning(path):
            "no macpool run is using \(path)"
        case let .insufficientResources(cpuCount, memoryByteCount):
            "the image needs at least \(cpuCount) CPUs and \(memoryByteCount) bytes of memory"
        case let .fileExists(path):
            "\(path) already exists"
        case let .tool(tool, reason):
            "\(tool): \(reason)"
        case let .timedOut(step, seconds):
            "no \(step) after \(seconds) s"
        case let .stopped(event):
            "VM stopped: \(event)"
        case let .noLease(macAddress):
            "no lease for \(macAddress)"
        case let .invalidValue(reason):
            reason
        }
    }
}

/// Runs a library operation and wraps its error for the command line.
///
/// - Parameter operation: The operation to run.
/// - Returns: The operation's result.
/// - Throws: ``CommandError/library(_:)`` with the operation's error.
func library<T>(_ operation: () throws(MacpoolError) -> T) throws(CommandError) -> T {
    do {
        return try operation()
    } catch {
        throw .library(error)
    }
}

/// Runs an asynchronous library operation and wraps its error for the command line.
///
/// - Parameter operation: The operation to run.
/// - Returns: The operation's result.
/// - Throws: ``CommandError/library(_:)`` with the operation's error.
func library<T>(_ operation: () async throws(MacpoolError) -> T) async throws(CommandError) -> T {
    do {
        return try await operation()
    } catch {
        throw .library(error)
    }
}
