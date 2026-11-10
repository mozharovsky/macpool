import Foundation

/// What lets other users reach a file that belongs to the current user and grants others no
/// permission bits.
///
/// Permission bits do not settle access on their own. A volume that ignores ownership treats every
/// local user as the owner of every file. An extended access control list can admit other users to
/// a file with mode 0600, and a parent directory can pass such a list on to new files. Files that
/// only the current user may reach, such as this Mac's key, are checked for both.
enum FileExposure: Sendable, Equatable {
    /// The volume ignores ownership, so every local user acts as the file's owner.
    case ownerlessVolume

    /// The file has an extended access control list, whose entries can admit other users.
    case accessControlList

    /// The reason for an error message.
    var reason: String {
        switch self {
        case .ownerlessVolume:
            "its volume ignores ownership, so every local user can reach it"
        case .accessControlList:
            "it has an access control list, which can let other users in"
        }
    }

    /// Finds what lets other users reach an open file or directory.
    ///
    /// - Parameters:
    ///   - descriptor: An open descriptor of the file or directory, which the call leaves open.
    ///   - file: The file's location, for error messages.
    /// - Returns: The first exposure found, or `nil` when the volume honors ownership and the file
    ///   has no extended access control list.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the volume or the access
    ///   control list cannot be read.
    static func find(in descriptor: Int32, of file: URL) throws(PoolError) -> FileExposure? {
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else {
            throw .systemCall("inspecting the volume of", file)
        }
        if volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 {
            return .ownerlessVolume
        }
        guard let list = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // A file without an extended list, or on a volume without lists, has none to read.
            guard errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP else {
                throw .systemCall("reading the access control list of", file)
            }
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        var entry: acl_entry_t?
        return acl_get_entry(list, ACL_FIRST_ENTRY.rawValue, &entry) == 0 ? .accessControlList : nil
    }

    /// Finds what lets other users reach a directory, without following a symbolic link.
    ///
    /// - Parameter directory: The directory.
    /// - Returns: The first exposure found, or `nil` when nothing lets other users in.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the directory cannot be
    ///   opened, which includes a symbolic link at its path, or when its volume or access control
    ///   list cannot be read.
    static func find(inDirectoryAt directory: URL) throws(PoolError) -> FileExposure? {
        let path = directory.pathWithoutTrailingSlash
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw .systemCall("opening", directory)
        }
        defer { close(descriptor) }
        return try find(in: descriptor, of: directory)
    }
}
