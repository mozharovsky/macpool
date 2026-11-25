public import Foundation

/// The launchd job that runs the daemon in the user's login session.
///
/// The daemon runs as a LaunchAgent rather than a system daemon, because the Virtualization
/// framework runs VMs for a logged-in user. launchd starts the job at login and starts it again
/// when it exits. The job abandons its process group, so launchd leaves the supervisors running
/// when it stops the daemon.
public struct LaunchAgent: Sendable, Equatable {
    /// The job's label.
    public static let label = "macpool.daemon"

    /// The signed `macpool` executable that the job runs.
    public var executable: URL

    /// The data directory that the daemon serves.
    public var directory: PoolDirectory

    /// The number of VMs that the daemon runs at once.
    public var slots: Int

    /// The arguments of `macpool daemon run` that make the daemon listen for paired Macs, such as
    /// `--listen 192.0.2.20:7373`, or none.
    ///
    /// The job passes them after the other arguments. The job runs in the root directory, so the
    /// paths in them must be absolute.
    public var peerArguments: [String]

    /// Creates a job description.
    ///
    /// - Parameters:
    ///   - executable: The signed `macpool` executable.
    ///   - directory: The data directory.
    ///   - slots: The number of VMs that run at once.
    ///   - peerArguments: The arguments that make the daemon listen for paired Macs, or none.
    public init(executable: URL, directory: PoolDirectory, slots: Int, peerArguments: [String] = []) {
        self.executable = executable
        self.directory = directory
        self.slots = slots
        self.peerArguments = peerArguments
    }

    /// The job's property list file in the user's `~/Library/LaunchAgents`.
    public static var propertyListFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// The daemon's log, which receives its standard output and error.
    public var logFile: URL {
        directory.logsDirectory.appending(path: "daemon.log")
    }

    /// Encodes the job as an XML property list.
    ///
    /// - Returns: The property list's bytes.
    /// - Throws: ``PoolError/malformedMessage(reason:)`` when the values cannot be encoded.
    public func propertyList() throws(PoolError) -> Data {
        let job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [
                executable.path(percentEncoded: false),
                "daemon",
                "run",
                "--data-dir",
                directory.root.path(percentEncoded: false),
                "--slots",
                String(slots),
                "--log-level",
                "info",
            ] + peerArguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "AbandonProcessGroup": true,
            "StandardOutPath": logFile.path(percentEncoded: false),
            "StandardErrorPath": logFile.path(percentEncoded: false),
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        } catch {
            throw .malformedMessage(reason: "\(error)")
        }
    }
}
