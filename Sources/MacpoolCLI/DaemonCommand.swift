import ArgumentParser
import Foundation
import Logging
import MacpoolPool
import Subprocess
import System

/// Runs the pool daemon, or installs and removes it as a launchd job.
///
/// `macpool daemon` without a subcommand runs the daemon in the foreground.
struct DaemonCommand: AsyncParsableCommand {
    /// The subcommand's name, summary, and subcommands.
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Runs the pool daemon, or installs and removes it as a launchd job.",
        subcommands: [DaemonRunCommand.self, DaemonInstallCommand.self, DaemonUninstallCommand.self],
        defaultSubcommand: DaemonRunCommand.self,
    )
}

/// Runs the pool daemon in the foreground until `SIGINT` or `SIGTERM`.
///
/// The daemon leaves its supervisors and their VMs running when it exits. A daemon that starts
/// later on the same data directory resumes the leases.
struct DaemonRunCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Runs the pool daemon in the foreground.",
    )

    /// The daemon's data directory.
    @OptionGroup var location: PoolOptions

    /// The number of VMs that run at once.
    @Option(help: "The number of VMs that run at once, 1 or 2.")
    var slots = PoolPolicy.maximumSlots

    /// The diagnostic output options.
    @OptionGroup var logging: LoggingOptions

    /// Rejects a slot count that macOS does not allow.
    ///
    /// - Throws: `ValidationError` when the count is not 1 or 2.
    func validate() throws {
        guard (1 ... PoolPolicy.maximumSlots).contains(slots) else {
            throw ValidationError("--slots takes 1 to \(PoolPolicy.maximumSlots).")
        }
    }

    /// Runs the daemon until a termination signal arrives.
    ///
    /// - Throws: ``CommandError`` when another daemon serves the data directory, the directory or
    ///   its state is unusable, or the socket cannot listen.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when another daemon serves the data directory, the directory or
    ///   its state is unusable, or the socket cannot listen.
    private func perform() async throws(CommandError) {
        let executable = try Executable.current()
        let directory = location.directory
        let configuration = PoolDaemon.Configuration(
            directory: directory,
            policy: PoolPolicy(slots: slots),
            launcher: ProcessSupervisorLauncher(executable: executable),
            logger: logging.makeLogger(label: "macpool.daemon"),
        )
        let (signals, continuation) = AsyncStream.makeStream(of: Int32.self)
        let watch = SignalWatch { continuation.yield($0) }
        defer { watch.cancel() }
        let daemon = try pool { () throws(PoolError) in try PoolDaemon(configuration: configuration) }
        try await pool { () async throws(PoolError) in try await daemon.start() }
        Report.line("listening \(directory.daemonSocket.path(percentEncoded: false))")
        for await signal in signals {
            Report.line("stopping on signal \(signal), supervisors keep running")
            break
        }
        await daemon.shutdown()
    }
}

/// Installs the daemon as a launchd job in the user's login session and starts it.
///
/// The job runs the executable that runs this command, so a later build at the same path takes
/// effect at the job's next start.
struct DaemonInstallCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Installs the daemon as a launchd job in your login session and starts it.",
    )

    /// The daemon's data directory.
    @OptionGroup var location: PoolOptions

    /// The number of VMs that run at once.
    @Option(help: "The number of VMs that run at once, 1 or 2.")
    var slots = PoolPolicy.maximumSlots

    /// Rejects a slot count that macOS does not allow.
    ///
    /// - Throws: `ValidationError` when the count is not 1 or 2.
    func validate() throws {
        guard (1 ... PoolPolicy.maximumSlots).contains(slots) else {
            throw ValidationError("--slots takes 1 to \(PoolPolicy.maximumSlots).")
        }
    }

    /// Writes the job's property list and loads it.
    ///
    /// - Throws: ``CommandError`` when the job file cannot be written or launchd rejects it.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the job file cannot be written or launchd rejects it.
    private func perform() async throws(CommandError) {
        let agent = try LaunchAgent(executable: Executable.current(), directory: location.directory, slots: slots)
        try pool { () throws(PoolError) in try agent.directory.prepare() }
        let data = try pool { () throws(PoolError) in try agent.propertyList() }
        let file = LaunchAgent.propertyListFile
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try data.write(to: file, options: .atomic)
        } catch {
            throw .pool(.fileSystem(
                operation: "writing the launchd job",
                path: file.path(percentEncoded: false),
                reason: error.localizedDescription,
            ))
        }
        try await Launchctl.run(["bootstrap", Launchctl.domain, file.path(percentEncoded: false)])
        Report.line("installed \(file.path(percentEncoded: false))")
        Report.line("log \(agent.logFile.path(percentEncoded: false))")
    }
}

/// Stops the daemon's launchd job and removes it.
///
/// Leased VMs keep running under their supervisors, and the data directory stays as it is, so a
/// daemon that starts later resumes the leases.
struct DaemonUninstallCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stops the daemon's launchd job and removes it.",
    )

    /// Unloads the job and deletes its property list.
    ///
    /// - Throws: ``CommandError`` when launchd rejects the request or the file cannot be removed.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when launchd rejects the request or the file cannot be removed.
    private func perform() async throws(CommandError) {
        try await Launchctl.run(["bootout", "\(Launchctl.domain)/\(LaunchAgent.label)"])
        let file = LaunchAgent.propertyListFile
        do {
            try FileManager.default.removeItem(at: file)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw .pool(.fileSystem(
                operation: "removing the launchd job",
                path: file.path(percentEncoded: false),
                reason: error.localizedDescription,
            ))
        }
        Report.line("removed \(file.path(percentEncoded: false))")
    }
}

/// Requests to launchd through `launchctl`.
enum Launchctl {
    /// The launchd domain of the user's login session.
    static var domain: String {
        "gui/\(getuid())"
    }

    /// Runs `launchctl` with arguments.
    ///
    /// - Parameter arguments: The subcommand and its arguments.
    /// - Throws: ``CommandError/tool(_:reason:)`` when `launchctl` cannot start or fails.
    static func run(_ arguments: [String]) async throws(CommandError) {
        let status: TerminationStatus
        do {
            status = try await Subprocess.run(
                .path("/bin/launchctl"),
                arguments: Arguments(arguments),
                output: .currentStandardOutput,
                error: .currentStandardError,
            ).terminationStatus
        } catch {
            throw .tool("launchctl", reason: "\(error)")
        }
        guard status.isSuccess else {
            throw .tool("launchctl", reason: "\(arguments.first ?? "") ended with \(status)")
        }
    }
}
