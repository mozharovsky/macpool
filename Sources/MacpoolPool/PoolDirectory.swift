public import Foundation
public import MacpoolVM

/// The daemon's data directory and the locations of its parts.
///
/// The directory holds the state file, the daemon's lock, the sockets, the leased clones, and the
/// supervisor logs.
///
/// - `state.json` records every lease that holds a slot.
/// - `daemon.lock` carries the `flock` that keeps a second daemon away.
/// - `run` holds the daemon's socket, one socket per supervisor, and the exit records that
///   supervisors leave behind. Only the owner can enter it.
/// - `leases` holds one cloned bundle per lease, named after the lease.
/// - `logs` holds the supervisors' output and, under launchd, the daemon's.
///
/// Clones must live on the same APFS volume as their sources, so the data directory shares a
/// volume with the source bundles.
public struct PoolDirectory: Sendable, Hashable {
    /// The data directory.
    public let root: URL

    /// Refers to a data directory without checking its contents.
    ///
    /// - Parameter root: The data directory. A relative URL resolves against the current directory.
    public init(root: URL) {
        self.root = root.absoluteURL.standardizedFileURL
    }

    /// The default data directory, `~/Library/Application Support/macpool`.
    public static var standard: PoolDirectory {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/macpool", directoryHint: .isDirectory)
        return PoolDirectory(root: support)
    }

    /// The JSON file with the leases that hold a slot.
    public var stateFile: URL {
        root.appending(path: "state.json")
    }

    /// The file that carries the daemon's lock.
    public var lockFile: URL {
        root.appending(path: "daemon.lock")
    }

    /// The directory with the sockets and exit records, which only the owner can enter.
    public var runDirectory: URL {
        root.appending(path: "run", directoryHint: .isDirectory)
    }

    /// The socket on which the daemon accepts clients.
    public var daemonSocket: URL {
        runDirectory.appending(path: "daemon.sock")
    }

    /// The directory with the leased clones.
    public var leasesDirectory: URL {
        root.appending(path: "leases", directoryHint: .isDirectory)
    }

    /// The directory with the supervisors' logs.
    public var logsDirectory: URL {
        root.appending(path: "logs", directoryHint: .isDirectory)
    }

    /// The clone that a lease uses.
    ///
    /// - Parameter id: The lease's identifier.
    /// - Returns: The bundle, which the daemon creates when the lease's first boot starts.
    public func bundle(for id: LeaseID) -> VMBundle {
        // A directory hint would add a trailing slash, and `clonefile` refuses such a destination.
        VMBundle(root: leasesDirectory.appending(path: id.rawValue))
    }

    /// The socket on which a lease's supervisor reports its status.
    ///
    /// - Parameter id: The lease's identifier.
    /// - Returns: The socket's location.
    public func supervisorSocket(for id: LeaseID) -> URL {
        runDirectory.appending(path: "\(id.rawValue).sock")
    }

    /// The file in which a lease's supervisor records how its last run ended.
    ///
    /// The daemon reads the record when the supervisor exited while no daemon listened.
    ///
    /// - Parameter id: The lease's identifier.
    /// - Returns: The file's location.
    public func exitRecord(for id: LeaseID) -> URL {
        runDirectory.appending(path: "\(id.rawValue).exit.json")
    }

    /// The log of a lease's supervisors, which every boot of the lease appends to.
    ///
    /// - Parameter id: The lease's identifier.
    /// - Returns: The file's location.
    public func supervisorLog(for id: LeaseID) -> URL {
        logsDirectory.appending(path: "\(id.rawValue).log")
    }

    /// Creates the directories and restricts the run directory to its owner.
    ///
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when a directory cannot be
    ///   created or its permissions cannot be set, or ``PoolError/socketPathTooLong(path:)`` when
    ///   the sockets would not fit in a Unix socket address.
    public func prepare() throws(PoolError) {
        for directory in [root, runDirectory, leasesDirectory, logsDirectory] {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700],
                )
            } catch {
                throw .fileSystem("creating", directory, error)
            }
        }
        guard chmod(runDirectory.path(percentEncoded: false), 0o700) == 0 else {
            throw .systemCall("restricting", runDirectory)
        }
        try SocketPath.check(daemonSocket.path(percentEncoded: false))
        try SocketPath.check(supervisorSocket(for: LeaseID.random()).path(percentEncoded: false))
    }

    /// Writes the record of how a supervisor's run ended.
    ///
    /// - Parameters:
    ///   - outcome: How the run ended.
    ///   - id: The lease's identifier.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the file cannot be written.
    public func writeExitRecord(_ outcome: MachineOutcome, for id: LeaseID) throws(PoolError) {
        let file = exitRecord(for: id)
        do {
            try MessageCoding.encoder.encode(outcome).write(to: file, options: .atomic)
        } catch {
            throw .fileSystem("writing the exit record", file, error)
        }
    }

    /// Reads the record of how a lease's last supervisor run ended.
    ///
    /// - Parameter id: The lease's identifier.
    /// - Returns: The outcome, or `nil` when no readable record exists.
    func readExitRecord(for id: LeaseID) -> MachineOutcome? {
        guard let data = try? Data(contentsOf: exitRecord(for: id)) else {
            return nil
        }
        return try? MessageCoding.decoder.decode(MachineOutcome.self, from: data)
    }
}
