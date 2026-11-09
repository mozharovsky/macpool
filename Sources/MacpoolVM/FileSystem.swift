import Foundation

/// File operations that Foundation does not offer with the semantics a bundle needs.
enum FileSystem {
    /// Creates a file that must not exist yet and writes its contents.
    ///
    /// The exclusive create keeps a second command from replacing a file that another one wrote,
    /// such as a guest account whose password the guest already uses.
    ///
    /// - Parameters:
    ///   - url: The file to create.
    ///   - contents: The bytes to write.
    ///   - permissions: The POSIX permission bits of the new file.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file exists or the
    ///   write fails.
    static func createNewFile(
        at url: URL,
        contents: Data,
        permissions: mode_t,
    ) throws(MacpoolError) {
        let descriptor = open(url.filePath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard descriptor >= 0 else {
            throw .systemCall("creating", url)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
            try handle.close()
        } catch {
            throw .fileSystem("writing", url, error)
        }
    }

    /// Replaces a file atomically with contents that only the owner can read.
    ///
    /// `Data.write(to:options:)` creates its temporary file with the default permissions, which
    /// would expose a password between the write and a later `chmod`. This call creates the
    /// temporary file with owner-only permissions and renames it over the target, so readers see
    /// either the old or the new contents.
    ///
    /// - Parameters:
    ///   - url: The file to replace or create.
    ///   - contents: The bytes to write.
    ///   - operation: The description used in an error, such as `writing the guest account`.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the temporary file cannot
    ///   be written or renamed.
    static func replacePrivateFile(at url: URL, contents: Data, for operation: String) throws(MacpoolError) {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            try createNewFile(at: temporary, contents: contents, permissions: 0o600)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.filePath, url.filePath) == 0 else {
            let failure = MacpoolError.systemCall(operation, url)
            try? FileManager.default.removeItem(at: temporary)
            throw failure
        }
    }

    /// Removes a file when it exists.
    ///
    /// - Parameters:
    ///   - url: The file to remove.
    ///   - operation: The description used in an error.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file exists and
    ///   cannot be removed.
    static func removeIfPresent(_ url: URL, for operation: String) throws(MacpoolError) {
        guard unlink(url.filePath) == 0 || errno == ENOENT else {
            throw .systemCall(operation, url)
        }
    }

    /// Reads a whole file.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - operation: The description used in an error, such as `reading settings`.
    /// - Returns: The file's bytes.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file cannot be read.
    static func read(_ url: URL, for operation: String) throws(MacpoolError) -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw .fileSystem(operation, url, error)
        }
    }

    /// Reads a whole file that may be missing.
    ///
    /// Only a missing file counts as absent. A file that exists and cannot be read is an error,
    /// so a caller never mistakes an unreadable file for a missing one.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - operation: The description used in an error.
    /// - Returns: The file's bytes, or `nil` when the file does not exist.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the file exists and
    ///   cannot be read.
    static func readIfPresent(_ url: URL, for operation: String) throws(MacpoolError) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw .fileSystem(operation, url, error)
        }
    }

    /// Replaces a file's contents atomically.
    ///
    /// - Parameters:
    ///   - data: The new contents.
    ///   - url: The file to write.
    ///   - operation: The description used in an error.
    /// - Throws: ``MacpoolError/fileSystem(operation:path:reason:)`` when the write fails.
    static func write(_ data: Data, to url: URL, for operation: String) throws(MacpoolError) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw .fileSystem(operation, url, error)
        }
    }
}

/// File system paths of URLs.
extension URL {
    /// The URL's file system path without percent encoding.
    var filePath: String {
        path(percentEncoded: false)
    }
}
