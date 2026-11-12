import MacpoolPool
import MacpoolVM

/// A failure of a subcommand, which the command line prints before it exits.
enum CommandError: Error, Equatable, CustomStringConvertible {
    /// A library operation failed.
    ///
    /// - Parameter error: The library's error.
    case library(MacpoolError)

    /// A signal interrupted the command.
    ///
    /// The command removed what it had created, unless `image xcode --keep-failed` kept the
    /// failed image.
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

    /// The bundle's stop-request file appeared before the VM was ready.
    case stopRequested

    /// The host's DHCP server has no lease for the guest.
    ///
    /// - Parameter macAddress: The guest's MAC address.
    case noLease(macAddress: String)

    /// A value is out of the range that the command accepts.
    ///
    /// - Parameter reason: The rejected value and its range.
    case invalidValue(String)

    /// A pool operation failed.
    ///
    /// - Parameter error: The pool's error.
    case pool(PoolError)

    /// The daemon ended the lease before the command released it.
    ///
    /// - Parameters:
    ///   - id: The lease's identifier.
    ///   - reason: Why the lease ended.
    case leaseEnded(id: String, reason: String)

    /// A step of an image build failed.
    ///
    /// - Parameters:
    ///   - step: What the build was doing.
    ///   - reason: Why the step failed.
    case imageStep(step: String, reason: String)

    /// An image build that did not finish left its clone or its inputs behind.
    ///
    /// - Parameters:
    ///   - name: The image's name.
    ///   - building: The clone's directory.
    ///   - inputs: The directory of the inputs that the guest reads.
    case unfinishedImageBuild(name: String, building: String, inputs: String)

    /// A supervised VM's boot or run failed.
    ///
    /// - Parameter reason: The failure.
    case supervisedRunFailed(String)

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
        case .stopRequested:
            "a stop was requested before the VM was ready"
        case let .noLease(macAddress):
            "no lease for \(macAddress)"
        case let .invalidValue(reason):
            reason
        case let .pool(error):
            error.description
        case let .leaseEnded(id, reason):
            "lease \(id) ended: \(reason)"
        case let .supervisedRunFailed(reason):
            reason
        case let .imageStep(step, reason):
            "building the image failed while \(step): \(reason)"
        case let .unfinishedImageBuild(name, building, inputs):
            "an earlier build of \(name) did not finish and may have left \(building) and \(inputs). "
                + "If no image xcode command is building \(name) now, delete both and build again"
        }
    }
}

/// Takes a bundle's lock and explains a lock held by an unfinished credential rotation.
///
/// - Parameter bundle: The bundle to lock.
/// - Returns: The lock, which the caller keeps alive while it uses the bundle.
/// - Throws: ``CommandError/library(_:)`` with `MacpoolError.credentialRotationInProgress` when
///   another command holds the lock of a bundle whose rotation is pending or started, or with the
///   lock's own error otherwise.
func lockBundle(_ bundle: VMBundle) throws(CommandError) -> BundleLock {
    do {
        return try BundleLock(bundle: bundle)
    } catch let .bundleInUse(path) {
        let state = try? bundle.settings().credentialRotation
        if state == .pending || state == .started {
            throw .library(.credentialRotationInProgress(path: path))
        }
        throw .library(.bundleInUse(path: path))
    } catch {
        throw .library(error)
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

/// Runs a pool operation and wraps its error for the command line.
///
/// - Parameter operation: The operation to run.
/// - Returns: The operation's result.
/// - Throws: ``CommandError/pool(_:)`` with the operation's error.
func pool<T>(_ operation: () throws(PoolError) -> T) throws(CommandError) -> T {
    do {
        return try operation()
    } catch {
        throw .pool(error)
    }
}

/// Runs an asynchronous pool operation and wraps its error for the command line.
///
/// - Parameter operation: The operation to run.
/// - Returns: The operation's result.
/// - Throws: ``CommandError/pool(_:)`` with the operation's error.
func pool<T>(_ operation: () async throws(PoolError) -> T) async throws(CommandError) -> T {
    do {
        return try await operation()
    } catch {
        throw .pool(error)
    }
}
