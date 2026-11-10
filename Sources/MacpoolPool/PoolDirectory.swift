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
/// - `trust` holds this Mac's key for connections between Macs. Only the owner can enter it, and
///   backups skip it.
///
/// Clones must live on the same APFS volume as their sources, so the data directory shares a
/// volume with the source bundles.
public struct PoolDirectory: Sendable, Hashable {
    /// The data directory.
    public let root: URL

    /// Refers to a data directory without checking its contents.
    ///
    /// The root takes one form for every spelling of the same directory. It is absolute, ends
    /// without a slash, and has its symbolic links resolved as far as the path exists. Two
    /// spellings of one directory therefore produce equal values.
    ///
    /// - Parameter root: The data directory. A relative URL resolves against the current directory.
    public init(root: URL) {
        self.root = Self.resolve(root.absoluteURL.standardizedFileURL)
    }

    /// Resolves the symbolic links of a path's longest existing prefix.
    ///
    /// The directory may not exist yet, because ``prepare()`` creates it. The components after the
    /// existing prefix stay as written.
    ///
    /// - Parameter url: An absolute file URL without `.` and `..` components.
    /// - Returns: The resolved URL without a trailing slash.
    private static func resolve(_ url: URL) -> URL {
        let path = url.path(percentEncoded: false)
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return URL(filePath: String(cString: resolved), directoryHint: .notDirectory)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path(percentEncoded: false).count < path.count else {
            return url
        }
        return resolve(parent).appending(path: url.lastPathComponent, directoryHint: .notDirectory)
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

    /// The directory with this Mac's key, which only the owner can enter.
    public var trustDirectory: URL {
        root.appending(path: "trust", directoryHint: .isDirectory)
    }

    /// The file with this Mac's P-256 private key in PKCS#8 PEM, which only the owner can read.
    public var identityFile: URL {
        trustDirectory.appending(path: "identity.pem")
    }

    /// The clone that a lease uses.
    ///
    /// - Parameter id: The lease's identifier.
    /// - Returns: The bundle, which the daemon creates when the lease's first boot starts.
    public func bundle(for id: LeaseID) -> VMBundle {
        // A directory hint would add a trailing slash, and `clonefile` refuses such a destination.
        VMBundle(root: leasesDirectory.appending(path: id.rawValue))
    }

    /// The place where the daemon builds a lease's clone before it gives the clone its identity.
    ///
    /// The clone moves to ``bundle(for:)`` only once it has its own machine identifier and MAC
    /// address, so a crash in between never leaves a clone that shares its source's identity.
    ///
    /// - Parameter id: The lease's identifier.
    /// - Returns: The partial clone's location.
    func partialBundle(for id: LeaseID) -> URL {
        leasesDirectory.appending(path: "\(id.rawValue).partial")
    }

    /// The file that a lease's supervisor locks for its whole life.
    ///
    /// - Parameter id: The lease's identifier.
    /// - Returns: The lock file's location.
    public func supervisorLock(for id: LeaseID) -> URL {
        runDirectory.appending(path: "\(id.rawValue).lock")
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

    /// Creates the directories, restricts the run directory to its owner, and checks that no other
    /// user controls them.
    ///
    /// Another user who could replace the run directory could take over the daemon's socket, so
    /// every directory must be a real directory that the current user owns and that others cannot
    /// write to. Nobody else may enter the run directory.
    ///
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when a directory cannot be
    ///   created or its permissions cannot be set, ``PoolError/insecureDirectory(path:reason:)``
    ///   when a directory is a symbolic link, belongs to another user, or is writable by others, or
    ///   ``PoolError/socketPathTooLong(path:length:)`` when the sockets would not fit in a Unix
    ///   socket address even through an alias. A long or non-ASCII run directory gets its alias, a
    ///   symbolic link in the user's temporary directory, here.
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
        for directory in [root, leasesDirectory, logsDirectory] {
            try Self.checkOwnership(of: directory, forbidden: 0o022)
        }
        try Self.checkOwnership(of: runDirectory, forbidden: 0o077)
        // A supervisor's socket has the longest name in the run directory.
        let aliasDirectory = SocketPath.userTemporaryDirectory
        _ = try SocketPath.endpoint(for: daemonSocket, aliasDirectory: aliasDirectory)
        _ = try SocketPath.endpoint(for: supervisorSocket(for: LeaseID.random()), aliasDirectory: aliasDirectory)
    }

    /// Creates the trust directory, restricts it to its owner, keeps it out of backups, and
    /// checks that no other user controls it or the data directory.
    ///
    /// Another user who could replace the trust directory could put their own key in it, so it
    /// gets the same checks as the run directory. The directory must also have no access control
    /// list and lie on a volume that honors ownership, because either would let other users read
    /// the key.
    ///
    /// A backup would keep a readable copy of the key, and restoring it on another Mac would give
    /// two Macs one key.
    ///
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when a directory cannot be
    ///   created, inspected, or changed, or ``PoolError/insecureDirectory(path:reason:)`` when the
    ///   data directory or the trust directory is not a real directory or belongs to another user,
    ///   when other users can write to the data directory, or when a ``FileExposure`` lets other
    ///   users reach the trust directory.
    func prepareTrustDirectory() throws(PoolError) {
        do {
            try FileManager.default.createDirectory(
                at: trustDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700],
            )
        } catch {
            throw .fileSystem("creating", trustDirectory, error)
        }
        try Self.checkOwnership(of: root, forbidden: 0o022)
        // The check before the change of permissions keeps chmod from following a symbolic link.
        try Self.checkOwnership(of: trustDirectory, forbidden: 0)
        if let exposure = try FileExposure.find(inDirectoryAt: trustDirectory) {
            throw .insecureDirectory(path: trustDirectory.pathWithoutTrailingSlash, reason: exposure.reason)
        }
        guard chmod(trustDirectory.path(percentEncoded: false), 0o700) == 0 else {
            throw .systemCall("restricting", trustDirectory)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var trust = trustDirectory
        do {
            try trust.setResourceValues(values)
        } catch {
            throw .fileSystem("excluding from backups", trustDirectory, error)
        }
    }

    /// Checks that a directory is a real directory of the current user without forbidden
    /// permissions.
    ///
    /// - Parameters:
    ///   - directory: The directory to check.
    ///   - forbidden: The permission bits that must be clear, such as `0o022` for write access by
    ///     the group and others.
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when the check fails, or
    ///   ``PoolError/fileSystem(operation:path:reason:)`` when the directory cannot be inspected.
    static func checkOwnership(of directory: URL, forbidden: mode_t) throws(PoolError) {
        let path = directory.pathWithoutTrailingSlash
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw .systemCall("inspecting", directory)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw .insecureDirectory(path: path, reason: "it is not a directory")
        }
        guard status.st_uid == getuid() else {
            throw .insecureDirectory(path: path, reason: "another user owns it")
        }
        guard status.st_mode & forbidden == 0 else {
            let mode = String(status.st_mode & 0o777, radix: 8)
            throw .insecureDirectory(path: path, reason: "its permissions \(mode) let other users in")
        }
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

/// The path forms that system calls on directories need.
extension URL {
    /// The path without a trailing slash, which keeps the slash only for the root directory.
    ///
    /// A trailing slash would make `lstat` and `open` follow a symbolic link at the path.
    var pathWithoutTrailingSlash: String {
        var text = path(percentEncoded: false)
        while text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}
