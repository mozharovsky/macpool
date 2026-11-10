public import Foundation
import Subprocess
import System

/// What a supervisor needs to boot a lease's clone.
public struct SupervisorLaunch: Sendable, Equatable {
    /// The lease whose clone the supervisor boots.
    public var lease: LeaseID

    /// The daemon's data directory, which names the clone, the socket, and the exit record.
    public var directory: PoolDirectory

    /// The absolute path of a host directory to share with the guest, or `nil`.
    public var sharedDirectory: String?

    /// Whether the guest can only read the shared directory.
    public var sharedDirectoryIsReadOnly = false

    /// The longest wait for the guest's address, SSH, and credential rotation, in seconds.
    public var bootTimeout: Int
}

/// A signal that ends a supervisor that does not stop on request.
public enum SupervisorSignal: Sendable, Equatable {
    /// Asks the supervisor to stop its VM and exit, as a stop command does.
    case terminate

    /// Ends the supervisor at once. Its VM ends with it.
    case kill
}

/// Starts and signals the supervisor processes of leases.
///
/// The daemon calls the launcher for every boot of a lease. The supervisor then takes the lease's
/// ``SupervisorLock``, listens on the lease's socket from ``PoolDirectory/supervisorSocket(for:)``,
/// and the daemon connects to it.
public protocol SupervisorLauncher: Sendable {
    /// Starts a supervisor and returns once its process exists.
    ///
    /// - Parameter launch: The lease and its boot options.
    /// - Returns: The supervisor's process identifier.
    /// - Throws: ``PoolError/supervisorLaunch(reason:)`` when the process cannot start.
    func launch(_ launch: SupervisorLaunch) async throws(PoolError) -> Int32

    /// Checks that a process is a lease's supervisor.
    ///
    /// A process identifier can belong to another process after the supervisor exited, so the
    /// daemon sends a signal only to a process that this check identifies.
    ///
    /// - Parameters:
    ///   - processID: The identifier that the supervisor recorded in its lock.
    ///   - startTime: The start time that the supervisor recorded in its lock.
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Throws: A ``SupervisorMismatch`` that tells why the process does not count as the lease's
    ///   supervisor. An identifier of 0 or less never matches.
    func identify(
        processID: Int32,
        startTime: RecordedStartTime,
        of id: LeaseID,
        in directory: PoolDirectory,
    ) async throws(SupervisorMismatch)

    /// Sends a signal to a process that ``identify(processID:startTime:of:in:)`` recognized.
    ///
    /// The call does not suspend. The daemon checks its own state and sends the signal in one
    /// step, so a lease that ends in between cannot receive a signal meant for an earlier state.
    ///
    /// - Parameters:
    ///   - signal: The signal to send.
    ///   - processID: The supervisor's process identifier. An identifier of 0 or less is ignored.
    ///   - id: The lease.
    ///   - directory: The data directory.
    func send(_ signal: SupervisorSignal, to processID: Int32, of id: LeaseID, in directory: PoolDirectory)
}

/// Starts supervisors as `macpool supervise` processes in their own sessions.
///
/// Each supervisor runs in a new session, so neither a signal to the daemon's process group nor
/// the daemon's exit reaches it. The VM therefore keeps running while the daemon restarts or
/// upgrades. The supervisor's standard output and error append to the lease's log.
///
/// The executable must carry the virtualization entitlement, because the supervisor creates the
/// VM.
public struct ProcessSupervisorLauncher: SupervisorLauncher {
    /// The signed `macpool` executable.
    public var executable: URL

    /// The diagnostic level that the supervisor writes to its log.
    public var logLevel: String

    /// Creates a launcher.
    ///
    /// - Parameters:
    ///   - executable: The signed `macpool` executable.
    ///   - logLevel: The diagnostic level for the supervisor's log, such as `info`.
    public init(executable: URL, logLevel: String = "info") {
        self.executable = executable
        self.logLevel = logLevel
    }

    /// Builds the supervisor's arguments.
    ///
    /// - Parameter launch: The lease and its boot options.
    /// - Returns: The arguments after the executable.
    func arguments(for launch: SupervisorLaunch) -> [String] {
        var arguments = [
            "supervise",
            "--data-dir", launch.directory.root.path(percentEncoded: false),
            "--lease", launch.lease.rawValue,
            "--boot-timeout", String(launch.bootTimeout),
            "--log-level", logLevel,
        ]
        if let sharedDirectory = launch.sharedDirectory {
            arguments += ["--share", sharedDirectory]
            if launch.sharedDirectoryIsReadOnly {
                arguments.append("--share-read-only")
            }
        }
        return arguments
    }

    /// Starts the supervisor process and returns once it exists.
    ///
    /// A detached task keeps waiting for the process so that it is reaped when it exits. The task
    /// is never cancelled, because cancelling it would end the supervisor and its VM.
    ///
    /// - Parameter launch: The lease and its boot options.
    /// - Returns: The supervisor's process identifier.
    /// - Throws: ``PoolError/supervisorLaunch(reason:)`` when the log cannot be opened or the
    ///   process cannot start.
    public func launch(_ launch: SupervisorLaunch) async throws(PoolError) -> Int32 {
        let log = launch.directory.supervisorLog(for: launch.lease)
        let output: FileDescriptor
        let errorOutput: FileDescriptor
        do {
            output = try FileDescriptor.open(
                FilePath(log.path(percentEncoded: false)),
                .writeOnly,
                options: [.append, .create, .closeOnExec],
                permissions: [.ownerReadWrite],
            )
            errorOutput = try output.duplicate()
        } catch {
            throw .supervisorLaunch(reason: "opening \(log.path(percentEncoded: false)): \(error)")
        }
        let options = {
            var options = PlatformOptions()
            options.createSession = true
            return options
        }()
        let executable = FilePath(executable.path(percentEncoded: false))
        let arguments = Arguments(arguments(for: launch))
        let started: Result<Int32, PoolError> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task.detached {
                do {
                    _ = try await run(
                        .path(executable),
                        arguments: arguments,
                        platformOptions: options,
                        input: .none,
                        output: .fileDescriptor(output, closeAfterSpawningProcess: true),
                        error: .fileDescriptor(errorOutput, closeAfterSpawningProcess: true),
                    ) { execution in
                        once.resume(returning: .success(execution.processIdentifier.value))
                    }
                } catch {
                    once.resume(returning: .failure(.supervisorLaunch(reason: "\(error)")))
                }
            }
        }
        return try started.get()
    }

    /// Checks a process's start time and arguments as the kernel holds them.
    ///
    /// A recorded start time must equal the process's start time to the microsecond. That keeps a
    /// reused process identifier from matching even when the new process has the same arguments.
    /// A record from a build before the start time has none, and the arguments decide alone.
    ///
    /// The process's arguments after the first must hold `supervise`, `--data-dir`, the data
    /// directory, `--lease`, and the lease's identifier as consecutive whole arguments. The
    /// directory may be spelled differently if it resolves to the same root. A reused process
    /// identifier therefore never reaches another process.
    ///
    /// - Parameters:
    ///   - processID: The identifier that the supervisor recorded in its lock.
    ///   - startTime: The start time that the supervisor recorded in its lock.
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Throws: ``SupervisorMismatch/noProcess`` for an identifier of 0 or less,
    ///   ``SupervisorMismatch/malformedStartTime`` for a malformed record,
    ///   ``SupervisorMismatch/startTimeDiffers(recorded:actual:)`` for another start time,
    ///   ``SupervisorMismatch/otherArguments`` when the arguments do not match, and the errors of
    ///   reading the start time and the arguments.
    public func identify(
        processID: Int32,
        startTime: RecordedStartTime,
        of id: LeaseID,
        in directory: PoolDirectory,
    ) async throws(SupervisorMismatch) {
        guard processID > 0 else {
            throw .noProcess
        }
        switch startTime {
        case .absent:
            break
        case .malformed:
            throw .malformedStartTime
        case let .recorded(recorded):
            let actual = try ProcessStartTime.read(processID: processID)
            guard actual == recorded else {
                throw .startTimeDiffers(recorded: recorded, actual: actual)
            }
        }
        let arguments = try ProcessArguments.read(processID: processID)
        guard Self.isSupervisor(arguments, of: id, in: directory) else {
            throw .otherArguments
        }
    }

    /// Sends `SIGTERM` or `SIGKILL` to a supervisor.
    ///
    /// - Parameters:
    ///   - signal: The signal to send.
    ///   - processID: The supervisor's process identifier. An identifier of 0 or less is ignored,
    ///     because `kill` would apply it to a process group.
    ///   - id: The lease, which the process identifier already names.
    ///   - directory: The data directory, which the process identifier already names.
    public func send(_ signal: SupervisorSignal, to processID: Int32, of _: LeaseID, in _: PoolDirectory) {
        guard processID > 0 else {
            return
        }
        kill(processID, signal == .kill ? SIGKILL : SIGTERM)
    }

    /// Checks whether a process's arguments belong to a lease's supervisor.
    ///
    /// The arguments after the first must contain five consecutive elements. They are
    /// `supervise`, `--data-dir`, an absolute data directory, `--lease`, and the lease's
    /// identifier.
    ///
    /// Two facts keep another process from matching. Each element must equal a whole argument, so
    /// elements spread over other arguments or joined inside one argument do not match. No two
    /// leases share an identifier, so another lease's supervisor names a different one.
    ///
    /// The data directory matches when it resolves to the same root. This accepts supervisors that
    /// an earlier daemon started with another spelling of the directory, such as one with a
    /// trailing slash. The executable's path is not compared, so a daemon that runs from a replaced
    /// or moved binary still recognizes the supervisors that an earlier binary started.
    ///
    /// - Parameters:
    ///   - arguments: The process's arguments, including the first one.
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Returns: Whether the arguments run `supervise` for the lease in the data directory.
    static func isSupervisor(_ arguments: [String], of id: LeaseID, in directory: PoolDirectory) -> Bool {
        let root = directory.root.path(percentEncoded: false)
        let expected = ["supervise", "--data-dir", nil, "--lease", id.rawValue]
        return arguments.indices.dropFirst().contains { start in
            let window = arguments[start...].prefix(expected.count)
            guard window.count == expected.count,
                  zip(window, expected).allSatisfy({ $1 == nil || $0 == $1 })
            else {
                return false
            }
            let written = window[start + 2]
            // A relative path would resolve against the daemon's directory instead of the
            // supervisor's.
            guard written.hasPrefix("/") else {
                return false
            }
            return PoolDirectory(root: URL(filePath: written)).root.path(percentEncoded: false) == root
        }
    }
}
