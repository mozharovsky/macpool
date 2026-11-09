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
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Returns: Whether the process runs as the lease's supervisor. An identifier of 0 or less
    ///   never matches.
    func identifies(processID: Int32, of id: LeaseID, in directory: PoolDirectory) async -> Bool

    /// Sends a signal to a process that ``identifies(processID:of:in:)`` recognized.
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

    /// Checks a process's command line with `ps`.
    ///
    /// The process must run `supervise` with the data directory and the lease's identifier, so a
    /// reused process identifier never reaches another process.
    ///
    /// - Parameters:
    ///   - processID: The identifier that the supervisor recorded in its lock.
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Returns: Whether the process runs as the lease's supervisor. An identifier of 0 or less
    ///   never matches.
    public func identifies(processID: Int32, of id: LeaseID, in directory: PoolDirectory) async -> Bool {
        guard processID > 0 else {
            return false
        }
        let result = try? await run(
            .path("/bin/ps"),
            arguments: ["-ww", "-o", "command=", "-p", String(processID)],
            output: .string(limit: 1 << 16),
        )
        guard let command = result?.standardOutput else {
            return false
        }
        return Self.isSupervisor(command, of: id, in: directory)
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

    /// Checks whether a process's command line belongs to a lease's supervisor.
    ///
    /// The command must run `supervise` with the lease's identifier and a data directory that
    /// resolves to the same root. The resolution accepts supervisors that an earlier daemon
    /// started with another spelling of the directory, such as one with a trailing slash. The
    /// lease argument must follow the directory at once, so a data directory whose path extends
    /// the root's path, such as `/a/pool2` for `/a/pool`, does not match.
    ///
    /// - Parameters:
    ///   - command: The command line as `ps` prints it, with the arguments separated by spaces.
    ///   - id: The lease.
    ///   - directory: The data directory.
    /// - Returns: Whether the command runs `supervise` for the lease in the data directory.
    static func isSupervisor(_ command: String, of id: LeaseID, in directory: PoolDirectory) -> Bool {
        guard let start = command.range(of: " supervise --data-dir ")?.upperBound,
              let end = command.range(of: " --lease \(id.rawValue) ", range: start ..< command.endIndex)?.lowerBound
        else {
            return false
        }
        let written = String(command[start ..< end])
        // A relative path would resolve against the daemon's directory instead of the supervisor's.
        guard written.hasPrefix("/") else {
            return false
        }
        let resolved = PoolDirectory(root: URL(filePath: written)).root
        return resolved.path(percentEncoded: false) == directory.root.path(percentEncoded: false)
    }
}
