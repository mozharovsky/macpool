import ArgumentParser
import Foundation
import MacpoolVM

/// Boots a bundle headless, waits for its network, and stops it on request.
///
/// The command boots the bundle through a ``MachineSession``. It prints `ready` once the guest has
/// an address and, when asked, answers on SSH. It then holds the VM until the hold time ends, the
/// bundle's `stop-request` file appears, or the guest shuts itself down. A `stop-request` file
/// that appears before `ready` stops the VM and fails the run.
///
/// A VM that is still running when the hold ends gets a shutdown request first and a forced stop
/// after 90 seconds. The session's documentation covers the bundle lock, the first-boot rules,
/// and the credential rotation of a clone's first run.
struct RunCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Boots a bundle headless, waits for its network, and stops it on request.",
    )

    /// The bundle to boot.
    @Option(help: "The bundle to boot.")
    var bundle: String

    /// A host directory to share with the guest.
    @Option(help: "A host directory to share with the guest through VirtioFS.")
    var share: String?

    /// Whether to provision the guest with the account stored in the bundle.
    @Flag(help: "Provisions the guest on its first boot with the account stored in the bundle.")
    var provision = false

    /// Whether to wait for the guest's SSH server after its address appears.
    @Flag(
        name: .customLong("wait-ssh"),
        help: """
        Waits for the guest's SSH server after its address appears. \
        A clone's first run always waits, because it replaces the inherited credentials over SSH.
        """,
    )
    var waitSSH = false

    /// The longest wait for the guest's address, SSH server, and credential rotation, in seconds.
    @Option(
        help: """
        The longest wait for the guest's address and SSH server, in seconds. \
        On a clone's first run it also bounds the credential rotation.
        """,
    )
    var timeout = 900

    /// The time the VM keeps running once it is ready, in seconds.
    @Option(
        help: """
        The time the VM keeps running once it is ready, in seconds. \
        Creating the bundle's stop-request file ends the run sooner.
        """,
    )
    var hold = 0

    /// The diagnostic output options.
    @OptionGroup var logging: LoggingOptions

    /// Rejects negative durations.
    ///
    /// - Throws: `ValidationError` when the timeout or the hold time is negative.
    func validate() throws {
        guard timeout >= 0, hold >= 0 else {
            throw ValidationError("--timeout and --hold take seconds of zero or more.")
        }
    }

    /// Boots the VM, measures the time to its network and SSH, holds it, and stops it.
    ///
    /// - Throws: ``CommandError`` when the bundle is in use, the boot record rules out the
    ///   provisioning choice, the VM cannot start, a step times out, the credential rotation
    ///   fails, or the VM stops early.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the bundle is in use, the boot record rules out the
    ///   provisioning choice, the VM cannot start, a step times out, the credential rotation
    ///   fails, or the VM stops early.
    private func perform() async throws(CommandError) {
        let target = VMBundle(root: URL(filePath: bundle))
        let stopRequest = target.stopRequest.path(percentEncoded: false)
        let session = MachineSession(
            target: target,
            sharedDirectory: share.map { URL(filePath: $0).absoluteURL },
            provision: provision,
            waitSSH: waitSSH,
            timeout: timeout,
            hold: .seconds(hold),
            stopMode: .requestThenForce,
            logging: logging,
            isStopRequested: { FileManager.default.fileExists(atPath: stopRequest) },
            onReady: { _ in },
        )
        _ = try await session.run()
    }
}
