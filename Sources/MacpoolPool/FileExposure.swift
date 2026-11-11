import Darwin.membership
import Foundation

/// What lets other users reach a file that belongs to the current user and grants others no
/// permission bits.
///
/// Permission bits do not settle access on their own. A volume that ignores ownership treats every
/// local user as the owner of every file. On a network volume, the server decides who reads a
/// file. An extended access control list can admit other users to a file with mode 0600, and a
/// parent directory can pass such a list on to new files. Files that only the current user may
/// reach, such as this Mac's key, are checked for all three.
enum FileExposure: Sendable, Equatable {
    /// The volume ignores ownership, so every local user acts as the file's owner.
    case ownerlessVolume

    /// The volume is not local. A file server decides who can reach the file.
    case networkVolume

    /// The file has an extended access control list, whose entries can admit other users.
    case accessControlList

    /// The directory has an access control list that lets other users change its entries.
    case writableAccessControlList

    /// The reason for an error message.
    var reason: String {
        switch self {
        case .ownerlessVolume:
            "its volume ignores ownership, so every local user can reach it"
        case .networkVolume:
            "its volume is not local, so a file server decides who can reach it"
        case .accessControlList:
            "it has an access control list, which can let other users in"
        case .writableAccessControlList:
            "it has an access control list that lets other users add, delete, or rename its entries"
        }
    }

    /// The permissions of an access control entry that change a directory's entries or the
    /// directory's own access.
    private static let directoryWrites = [
        ACL_ADD_FILE,
        ACL_ADD_SUBDIRECTORY,
        ACL_DELETE_CHILD,
        ACL_DELETE,
        ACL_WRITE_SECURITY,
        ACL_CHANGE_OWNER,
    ]

    /// Finds what lets other users reach an open file or directory.
    ///
    /// - Parameters:
    ///   - descriptor: An open descriptor of the file or directory, which the call leaves open.
    ///   - file: The file's location, for error messages.
    /// - Returns: The first exposure found, or `nil` when the volume is local and honors ownership
    ///   and the file has no extended access control list.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the volume or the access
    ///   control list cannot be read.
    static func find(in descriptor: Int32, of file: URL) throws(PoolError) -> FileExposure? {
        if let exposure = try findInVolume(of: descriptor, file: file) {
            return exposure
        }
        guard let list = try accessControlList(of: descriptor, file: file) else {
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        var entry: acl_entry_t?
        return acl_get_entry(list, ACL_FIRST_ENTRY.rawValue, &entry) == 0 ? .accessControlList : nil
    }

    /// Finds what lets other users add, delete, or rename the entries of a directory, without
    /// following a symbolic link.
    ///
    /// Unlike ``find(inDirectoryAt:)``, the check accepts an access control list that only denies
    /// access or only allows reading. macOS puts `group:everyone deny delete` on folders such as
    /// `~/Library`. Such a list gives other users no access. The check also accepts an entry that
    /// allows writes only to the directory's owner.
    ///
    /// - Parameter directory: The directory.
    /// - Returns: The first exposure found, or `nil` when nothing lets other users change the
    ///   directory's entries.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the directory cannot be
    ///   opened or its volume, owner, or access control list cannot be read. A symbolic link at
    ///   its path cannot be opened.
    static func findWriteAccess(inDirectoryAt directory: URL) throws(PoolError) -> FileExposure? {
        let path = directory.pathWithoutTrailingSlash
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw .systemCall("opening", directory)
        }
        defer { close(descriptor) }
        if let exposure = try findInVolume(of: descriptor, file: directory) {
            return exposure
        }
        guard let list = try accessControlList(of: descriptor, file: directory) else {
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw .systemCall("inspecting", directory)
        }
        return try findWriteAccess(in: list, owner: status.st_uid, of: directory)
    }

    /// Finds an entry of a directory's access control list that lets another user change the
    /// directory's entries.
    ///
    /// If an entry allows a write in ``directoryWrites`` and its subject is not the owner's UUID,
    /// the call returns ``writableAccessControlList``. This holds for a group's entry even when
    /// the owner belongs to the group.
    ///
    /// - Parameters:
    ///   - list: The directory's extended access control list.
    ///   - owner: The user ID of the directory's owner.
    ///   - directory: The directory's location, for error messages.
    /// - Returns: ``writableAccessControlList``, or `nil` when no entry lets another user write.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the owner's UUID or an
    ///   entry's tag, permissions, or subject cannot be read.
    static func findWriteAccess(in list: acl_t, owner: uid_t, of directory: URL) throws(PoolError) -> FileExposure? {
        var ownerUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let code = mbr_uid_to_uuid(owner, &ownerUUID)
        guard code == 0 else {
            throw .fileSystem(
                operation: "finding the owner's UUID of",
                path: directory.path(percentEncoded: false),
                reason: String(cString: strerror(code)),
            )
        }
        let ownerID = UUID(uuid: ownerUUID)
        var entry: acl_entry_t?
        var position = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(list, position, &entry) == 0, let current = entry {
            position = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(current, &tag) == 0, acl_get_permset(current, &permissions) == 0,
                  let permissions, let subject = subject(of: current)
            else {
                throw .systemCall("reading the access control list of", directory)
            }
            if tag == ACL_EXTENDED_ALLOW, subject != ownerID,
               directoryWrites.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) {
                return .writableAccessControlList
            }
        }
        return nil
    }

    /// Reads the UUID of the user or group that an access control entry applies to.
    ///
    /// - Parameter entry: An entry of an extended access control list.
    /// - Returns: The UUID, or `nil` when the entry has no subject or it cannot be read.
    private static func subject(of entry: acl_entry_t) -> UUID? {
        guard let qualifier = acl_get_qualifier(entry) else {
            return nil
        }
        defer { acl_free(qualifier) }
        return UUID(uuid: qualifier.load(as: uuid_t.self))
    }

    /// Finds what the volume of an open file lets other users do.
    ///
    /// - Parameters:
    ///   - descriptor: An open descriptor of the file or directory.
    ///   - file: The file's location, for error messages.
    /// - Returns: ``ownerlessVolume``, ``networkVolume``, or `nil` for a local volume that honors
    ///   ownership.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the volume cannot be read.
    private static func findInVolume(of descriptor: Int32, file: URL) throws(PoolError) -> FileExposure? {
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else {
            throw .systemCall("inspecting the volume of", file)
        }
        return exposure(ofVolumeFlags: volume.f_flags)
    }

    /// Reads the exposure that a volume's mount flags cause.
    ///
    /// - Parameter flags: The `f_flags` field of the volume's `statfs` record.
    /// - Returns: ``ownerlessVolume``, ``networkVolume``, or `nil` for a local volume that honors
    ///   ownership.
    static func exposure(ofVolumeFlags flags: UInt32) -> FileExposure? {
        if flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 {
            return .ownerlessVolume
        }
        if flags & UInt32(MNT_LOCAL) == 0 {
            return .networkVolume
        }
        return nil
    }

    /// Reads the extended access control list of an open file.
    ///
    /// - Parameters:
    ///   - descriptor: An open descriptor of the file or directory.
    ///   - file: The file's location, for error messages.
    /// - Returns: The list, or `nil` when the file has none or its volume has no lists. The caller
    ///   frees the list with `acl_free`.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the list cannot be read.
    private static func accessControlList(of descriptor: Int32, file: URL) throws(PoolError) -> acl_t? {
        guard let list = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP else {
                throw .systemCall("reading the access control list of", file)
            }
            return nil
        }
        return list
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
