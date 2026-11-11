import Foundation

/// Files that only the current user may read, such as this Mac's key and its lists of paired Macs.
///
/// A read checks the open file, so the file cannot change between the check and the read. A write
/// puts the contents on the disk under a temporary name before it names the file. After a power
/// loss the file is therefore absent, the old one, or a complete new one.
enum PrivateFile {
    /// Reads a file that only the current user can read.
    ///
    /// The file opens without waiting, so a FIFO at its path fails the type check instead of
    /// blocking until a writer appears.
    ///
    /// - Parameters:
    ///   - file: The file to read.
    ///   - name: What the file holds, for error messages, such as `this Mac's key`.
    ///   - limit: The most bytes that the file may have.
    ///   - refusal: Makes the error for a file that fails a check, from the reason.
    /// - Returns: The contents, or `nil` when the file does not exist.
    /// - Throws: The error from `refusal` when the file is a symbolic link, not a regular file,
    ///   owned by another user, open to other users through its permissions or a
    ///   ``FileExposure``, or larger than `limit`, or
    ///   ``PoolError/fileSystem(operation:path:reason:)`` when it cannot be opened or read.
    static func read(
        at file: URL,
        name: String,
        limit: Int,
        refusal: (String) -> PoolError,
    ) throws(PoolError) -> Data? {
        let path = file.path(percentEncoded: false)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT:
                return nil
            case ELOOP:
                throw refusal("it is a symbolic link")
            default:
                throw .systemCall("opening", file)
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw .systemCall("inspecting", file)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw refusal("it is not a regular file")
        }
        guard status.st_uid == getuid() else {
            throw refusal("another user owns it")
        }
        guard status.st_mode & 0o077 == 0 else {
            let mode = String(status.st_mode & 0o777, radix: 8)
            throw refusal("its permissions \(mode) let other users in")
        }
        if let exposure = try FileExposure.find(in: descriptor, of: file) {
            throw refusal(exposure.reason)
        }
        let tooLarge = "it has more than \(limit) bytes, the most that the pool reads"
        guard status.st_size <= limit else {
            throw refusal(tooLarge)
        }
        let data: Data
        do {
            // The file may grow after the check. A read of one byte past the limit catches that.
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw .fileSystem("reading \(name)", file, error)
        }
        guard data.count <= limit else {
            throw refusal(tooLarge)
        }
        return data
    }

    /// Creates a file that only the current user can read, unless a file already exists at its
    /// path.
    ///
    /// A hard link gives the new file its name. The link fails when another process created the
    /// file first, and that file stays.
    ///
    /// - Parameters:
    ///   - file: The file to create.
    ///   - contents: The contents of a new file.
    ///   - name: What the file holds, for error messages, such as `this Mac's key`.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the contents cannot be
    ///   written or flushed, the file cannot be named, or its directory cannot be opened or
    ///   flushed.
    static func create(at file: URL, contents: Data, name: String) throws(PoolError) {
        let temporary = try writeTemporary(beside: file, contents: contents, name: name)
        let temporaryPath = temporary.path(percentEncoded: false)
        defer { unlink(temporaryPath) }
        guard link(temporaryPath, file.path(percentEncoded: false)) == 0 || errno == EEXIST else {
            throw .systemCall("naming \(name)", file)
        }
        try flushName(of: file, name: name)
    }

    /// Replaces a file with one that only the current user can read.
    ///
    /// A rename gives the new file its name, so a reader sees the old contents or the new ones.
    /// The rename replaces a symbolic link at the path and leaves the link's target alone.
    ///
    /// - Parameters:
    ///   - file: The file to replace.
    ///   - contents: The new contents.
    ///   - name: What the file holds, for error messages, such as `the list of paired clients`.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the contents cannot be
    ///   written or flushed, the file cannot be named, or its directory cannot be opened or
    ///   flushed. Naming fails when a directory has the file's path.
    static func replace(at file: URL, contents: Data, name: String) throws(PoolError) {
        let temporary = try writeTemporary(beside: file, contents: contents, name: name)
        let temporaryPath = temporary.path(percentEncoded: false)
        guard rename(temporaryPath, file.path(percentEncoded: false)) == 0 else {
            let failure = PoolError.systemCall("naming \(name)", file)
            unlink(temporaryPath)
            throw failure
        }
        try flushName(of: file, name: name)
    }

    /// Writes contents to a new file with a temporary name in the file's directory and flushes
    /// them.
    ///
    /// - Parameters:
    ///   - file: The file that the temporary file will become.
    ///   - contents: The bytes to write.
    ///   - name: What the file holds, for error messages.
    /// - Returns: The temporary file. The caller names or removes it.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the file cannot be
    ///   created, written, or flushed.
    private static func writeTemporary(beside file: URL, contents: Data, name: String) throws(PoolError) -> URL {
        let temporary = file.deletingLastPathComponent()
            .appending(path: ".\(file.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8))")
        let temporaryPath = temporary.path(percentEncoded: false)
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw .systemCall("creating", temporary)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
        } catch {
            unlink(temporaryPath)
            throw .fileSystem("writing \(name)", temporary, error)
        }
        // The contents reach the disk before the name does. A power loss then leaves no file or a
        // complete one.
        guard flush(descriptor) else {
            let failure = PoolError.systemCall("flushing \(name)", temporary)
            unlink(temporaryPath)
            throw failure
        }
        return temporary
    }

    /// Puts the name of a file on the disk, so the file keeps its name after a power loss.
    ///
    /// - Parameters:
    ///   - file: The file whose directory entry to flush.
    ///   - name: What the file holds, for error messages.
    /// - Throws: ``PoolError/fileSystem(operation:path:reason:)`` when the directory cannot be
    ///   opened or flushed.
    private static func flushName(of file: URL, name: String) throws(PoolError) {
        let directory = file.deletingLastPathComponent()
        let descriptor = open(directory.pathWithoutTrailingSlash, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw .systemCall("opening", directory)
        }
        defer { close(descriptor) }
        guard flush(descriptor) else {
            throw .systemCall("flushing the name of \(name) in", directory)
        }
    }

    /// Puts a file's contents or a directory's entries on the disk.
    ///
    /// A full flush also empties the drive's cache. A volume without full flushes gets `fsync`,
    /// which reaches only that cache.
    ///
    /// - Parameter descriptor: An open descriptor of the file or directory.
    /// - Returns: Whether a flush succeeded. After a failure, `errno` describes the last attempt.
    private static func flush(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0
    }
}
