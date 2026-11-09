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

/// Starts the supervisor process of a lease.
///
/// The daemon calls the launcher for every boot of a lease. The supervisor then listens on the
/// lease's socket from ``PoolDirectory/supervisorSocket(for:)``, and the daemon connects to it.
public protocol SupervisorLauncher: Sendable {
    /// Starts a supervisor and returns once its process exists.
    ///
    /// - Parameter launch: The lease and its boot options.
    /// - Returns: The supervisor's process identifier.
    /// - Throws: ``PoolError/supervisorLaunch(reason:)`` when the process cannot start.
    func launch(_ launch: SupervisorLaunch) async throws(PoolError) -> Int32
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
}
