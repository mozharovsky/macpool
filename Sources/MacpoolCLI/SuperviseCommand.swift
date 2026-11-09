import ArgumentParser
import Foundation
import MacpoolPool
import MacpoolVM

/// Boots one leased clone for the daemon and reports its status on the lease's socket.
///
/// The daemon starts this hidden subcommand in a new session for every boot of a lease. The
/// supervisor owns the VM, because the framework ties a VM to the process that created it. The
/// VM therefore keeps running when the daemon exits, and a new daemon reconnects to the socket.
///
/// The supervisor first takes the lease's `SupervisorLock` and holds it until it exits. The
/// daemon waits for that lock before it boots the lease again or deletes the clone, so an exiting
/// supervisor never removes a newer supervisor's socket and its exit record never describes a
/// newer run.
///
/// The supervisor boots the clone through a ``MachineSession`` that waits for SSH and holds the
/// VM until a stop arrives. A stop command on the socket, `SIGTERM`, or `SIGINT` stops the VM at
/// once, because the daemon deletes the clone afterward. When the run ends, the supervisor writes
/// the lease's exit record, reports the outcome on the socket, closes the socket, and exits.
struct SuperviseCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "supervise",
        abstract: "Boots a leased clone for the daemon and reports its status.",
        shouldDisplay: false,
    )

    /// The daemon's data directory.
    @OptionGroup var location: PoolOptions

    /// The lease whose clone to boot.
    @Option(help: "The lease whose clone to boot.")
    var lease: String

    /// A host directory to share with the guest.
    @Option(help: "A host directory to share with the guest through VirtioFS.")
    var share: String?

    /// The longest wait for the guest's address, SSH server, and credential rotation, in seconds.
    @Option(name: .customLong("boot-timeout"), help: "The longest wait for the guest to become ready, in seconds.")
    var bootTimeout = 900

    /// The diagnostic output options.
    @OptionGroup var logging: LoggingOptions

    /// Boots the clone, reports its status, and stops it on request.
    ///
    /// - Throws: ``CommandError`` when the lease identifier is malformed, another supervisor of the
    ///   lease runs, the socket cannot listen, or the boot or the VM fails.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the lease identifier is malformed, another supervisor of the
    ///   lease runs, the socket cannot listen, or the boot or the VM fails.
    private func perform() async throws(CommandError) {
        guard let id = LeaseID(lease) else {
            throw .invalidValue("\(lease) is not a lease identifier")
        }
        let directory = location.directory
        // The lock comes before the socket, so a supervisor that finds another one running leaves
        // that one's socket and record alone.
        let lock = try pool { () throws(PoolError) in try SupervisorLock(of: id, in: directory) }
        defer { withExtendedLifetime(lock) {} }
        let stop = StopFlag()
        let server = try await pool { () async throws(PoolError) in
            try await SupervisorServer(
                socket: directory.supervisorSocket(for: id),
                status: SupervisorStatus(phase: .booting),
                onStop: { stop.set() },
            )
        }
        let signals = SignalWatch { _ in stop.set() }
        defer { signals.cancel() }
        let session = MachineSession(
            target: directory.bundle(for: id),
            sharedDirectory: share.map { URL(filePath: $0).absoluteURL },
            provision: false,
            waitSSH: true,
            timeout: bootTimeout,
            hold: nil,
            stopMode: .immediate,
            logging: logging,
            isStopRequested: { stop.isSet },
            onReady: { address in server.publish(SupervisorStatus(phase: .ready, address: address)) },
        )
        let outcome: MachineOutcome
        do {
            switch try await session.run() {
            case .guestStopped:
                outcome = .guestShutdown
            case .stopped:
                outcome = .requested
            }
        } catch .stopRequested {
            outcome = .requested
        } catch {
            outcome = .failed(error.description)
        }
        // The record comes first, so a daemon that is away now still learns how the run ended.
        do {
            try directory.writeExitRecord(outcome, for: id)
        } catch {
            Report.line("the exit record could not be written: \(error)")
        }
        server.publish(SupervisorStatus(phase: .exited, outcome: outcome))
        await server.close()
        Report.line("exited: \(outcome)")
        if case let .failed(reason) = outcome {
            throw .supervisedRunFailed(reason)
        }
    }
}
