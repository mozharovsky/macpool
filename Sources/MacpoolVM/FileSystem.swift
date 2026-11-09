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
