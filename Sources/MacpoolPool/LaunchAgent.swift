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

    /// Creates a job description.
    ///
    /// - Parameters:
    ///   - executable: The signed `macpool` executable.
    ///   - directory: The data directory.
    ///   - slots: The number of VMs that run at once.
    public init(executable: URL, directory: PoolDirectory, slots: Int) {
        self.executable = executable
        self.directory = directory
        self.slots = slots
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
            ],
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
