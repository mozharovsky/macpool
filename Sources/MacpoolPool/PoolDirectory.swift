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
/// - `trust` holds this Mac's key for connections between Macs and the lists of paired Macs. Only
///   the owner can enter it, and backups skip it.
/// - `images` holds stopped bundles that serve as images, one directory per image. `list` shows
///   them.
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

    /// Checks that a shared directory keeps the guest away from the data directory and a source.
    ///
    /// The check refuses a shared directory that is the data directory, contains it, or lies
    /// inside it. It also refuses one that is the source or contains it. It compares the paths
    /// after resolving symbolic links and firmlinks, and it ignores letter case and the Unicode
    /// normalization form.
    ///
    /// The check reads the paths once. The VM opens the shared directory by its path when it
    /// boots. If a directory on that path is replaced in between, the VM shares what the path
    /// names then.
    ///
    /// - Parameters:
    ///   - shared: The absolute path of the shared directory.
    ///   - source: The absolute path of the bundle that the lease clones, or `nil` for none.
    /// - Throws: ``PoolError/invalidRequest(reason:)`` when the check refuses the directory. The
    ///   reason names the paths and a way out.
    public func checkShare(_ shared: String, source: String? = nil) throws(PoolError) {
        let share = Self.physicalComponents(of: shared)
        let data = Self.physicalComponents(of: root.path(percentEncoded: false))
        let reach = "The guest could change the images, clones, and pool state in it."
        if data.starts(with: share) {
            throw .invalidRequest(reason: """
            the shared directory \(shared) includes macpool's data directory \(root.path(percentEncoded: false)). \
            \(reach) Share a narrower directory.
            """)
        }
        if share.starts(with: data) {
            throw .invalidRequest(reason: """
            the shared directory \(shared) lies inside macpool's data directory \(root.path(percentEncoded: false)). \
            \(reach) Share a directory outside it.
            """)
        }
        if let source, Self.physicalComponents(of: source).starts(with: share) {
            throw .invalidRequest(reason: """
            the shared directory \(shared) includes the source \(source). The guest could change the source, \
            and later clones would copy the change. Share a narrower directory.
            """)
        }
    }

    /// Splits a path into components after resolving symbolic links and firmlinks.
    ///
    /// The kernel names an open directory by its path on its volume, in the letter case and
    /// normalization form that the volume stores. The components then pass through
    /// ``PoolDaemon/caselessBytes(of:)`` for volumes that keep the spelling of a request. The
    /// components after the longest existing prefix stay as written.
    ///
    /// - Parameter path: An absolute path.
    /// - Returns: The components as case-folded, decomposed UTF-8 bytes.
    private static func physicalComponents(of path: String) -> [ArraySlice<UInt8>] {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(descriptor, F_GETPATH_NOFIRMLINK, &buffer) != -1 {
                let resolved = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
                return PoolDaemon.caselessBytes(of: resolved).split(separator: UInt8(ascii: "/"))
            }
        }
        let url = URL(filePath: path)
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        guard parent.count < path.count else {
            return PoolDaemon.caselessBytes(of: path).split(separator: UInt8(ascii: "/"))
        }
        return physicalComponents(of: parent) + [PoolDaemon.caselessBytes(of: url.lastPathComponent)[...]]
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

    /// The directory with the images that `list` shows.
    public var imagesDirectory: URL {
        root.appending(path: "images", directoryHint: .isDirectory)
    }

    /// Describes every directory in ``imagesDirectory``, ordered by name.
    ///
    /// A directory without a readable image record is listed as not ready, with the reason.
    ///
    /// - Returns: The images, or an empty array if the directory does not exist or cannot be
    ///   read.
    func images() -> [ImageSummary] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: imagesDirectory.path(percentEncoded: false))) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap(image(named:))
    }

    /// Describes one entry of ``imagesDirectory``.
    ///
    /// - Parameter name: The entry's name.
    /// - Returns: The image, or `nil` if the entry is not a directory.
    private func image(named name: String) -> ImageSummary? {
        // Without a trailing slash, the path matches what `lease --from` and `clonefile` expect.
        let url = imagesDirectory.appending(path: name, directoryHint: .notDirectory)
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        do {
            guard let record = try VMBundle(root: url).imageRecord() else {
                return ImageSummary(name: name, path: path, isReady: false, problem: "it has no image.json")
            }
            return ImageSummary(name: name, path: path, isReady: record.isReady, builds: record.builds)
        } catch {
            return ImageSummary(name: name, path: path, isReady: false, problem: error.description)
        }
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
    /// list and lie on a local volume that honors ownership, because otherwise other users could
    /// read the key.
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
        try checkDataDirectory()
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

    /// Checks that no other user controls the trust directory or the data directory, and changes
    /// neither.
    ///
    /// A reader of a list of paired Macs runs this check, because another user who controls the
    /// directory could put a key in the list.
    ///
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when the data directory or the
    ///   trust directory is not a real directory or belongs to another user, when other users can
    ///   write to the data directory or enter the trust directory, or when a ``FileExposure``
    ///   lets other users reach the trust directory, or
    ///   ``PoolError/fileSystem(operation:path:reason:)`` when a directory cannot be inspected.
    func checkTrustDirectory() throws(PoolError) {
        try checkDataDirectory()
        try Self.checkOwnership(of: trustDirectory, forbidden: 0o077)
        if let exposure = try FileExposure.find(inDirectoryAt: trustDirectory) {
            throw .insecureDirectory(path: trustDirectory.pathWithoutTrailingSlash, reason: exposure.reason)
        }
    }

    /// Checks that no other user can replace the trust directory through the data directory.
    ///
    /// Another user who can rename entries of the data directory could move `trust` away. The
    /// pool would then create a new key.
    ///
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when the data directory is not a
    ///   real directory or belongs to another user, when other users can write to it through its
    ///   permissions or its access control list, or when its volume ignores ownership or is not
    ///   local, or ``PoolError/fileSystem(operation:path:reason:)`` when it cannot be inspected.
    private func checkDataDirectory() throws(PoolError) {
        try Self.checkOwnership(of: root, forbidden: 0o022)
        if let exposure = try FileExposure.findWriteAccess(inDirectoryAt: root) {
            throw .insecureDirectory(path: root.pathWithoutTrailingSlash, reason: exposure.reason)
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
