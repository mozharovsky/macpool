import CryptoKit
import Foundation

/// The paths that the pool hands to Network for its Unix sockets.
///
/// Network copies a socket path into the socket address with as many bytes as the path has
/// characters. A path whose UTF-8 form is longer, because it holds characters outside ASCII,
/// loses its last bytes, and the socket file gets a truncated name. A path of 104 bytes or more
/// does not fit in the address at all.
///
/// Such a socket goes through an alias instead. The alias is a symbolic link in the user's
/// temporary directory that names the socket's directory, and its own path is short and ASCII.
/// The kernel resolves the link, so the socket file lies in the real directory under its full
/// name. Every process makes its own alias as needed, and any alias reaches the same file.
enum SocketPath {
    /// The size of the path field in a Unix socket address, including the terminating zero byte.
    static let capacity = 104

    /// The user's temporary directory, which only the user can enter, or `nil` when the system
    /// does not name one.
    static var userTemporaryDirectory: URL? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(filePath: String(decoding: bytes, as: UTF8.self), directoryHint: .isDirectory)
    }

    /// Checks whether Network keeps a path exactly.
    ///
    /// - Parameter path: The socket path.
    /// - Returns: Whether the path has one byte per character and fits in a socket address.
    static func isExact(_ path: String) -> Bool {
        path.utf8.count < capacity && path.utf8.count == path.count
    }

    /// Checks whether earlier builds listened on a truncated name for a path.
    ///
    /// Those builds handed every path that fit in a socket address to Network, which truncated
    /// the inexact ones.
    ///
    /// - Parameter path: The socket path.
    /// - Returns: Whether the path is inexact and still fits in a socket address.
    static func hasTruncatedName(_ path: String) -> Bool {
        !isExact(path) && path.utf8.count < capacity
    }

    /// Returns the path to hand to Network for a socket.
    ///
    /// An exact path stays as it is. Any other path goes through an alias of its directory in
    /// `aliasDirectory`, which the call creates or replaces when it names another directory.
    ///
    /// - Parameters:
    ///   - socket: The socket file.
    ///   - aliasDirectory: The directory for the alias. It must belong to the user and admit no
    ///     one else. `nil` allows no alias.
    /// - Returns: The socket's path or its path through the alias.
    /// - Throws: ``PoolError/socketPathTooLong(path:length:)`` when no exact path reaches the
    ///   socket, and ``PoolError/insecureDirectory(path:reason:)`` or
    ///   ``PoolError/fileSystem(operation:path:reason:)`` when the alias cannot be made.
    static func endpoint(for socket: URL, aliasDirectory: URL?) throws(PoolError) -> String {
        let path = socket.path(percentEncoded: false)
        if isExact(path) {
            return path
        }
        let tooLong = PoolError.socketPathTooLong(path: path, length: path.utf8.count)
        guard let aliasDirectory else {
            throw tooLong
        }
        let alias = try makeAlias(of: socket.deletingLastPathComponent(), in: aliasDirectory)
        let aliased = alias.appending(path: socket.lastPathComponent).path(percentEncoded: false)
        guard isExact(aliased) else {
            throw tooLong
        }
        return aliased
    }

    /// Makes a symbolic link to a directory unless one already names it.
    ///
    /// The link's name comes from a hash of the directory's path, so each directory has its own.
    /// A new link replaces the old one in one rename, so a concurrent user never finds the name
    /// missing.
    ///
    /// - Parameters:
    ///   - directory: The directory that the link names.
    ///   - parent: The directory that holds the link.
    /// - Returns: The link.
    /// - Throws: ``PoolError/insecureDirectory(path:reason:)`` when another user could enter
    ///   `parent`, and ``PoolError/fileSystem(operation:path:reason:)`` when the link cannot be
    ///   made.
    private static func makeAlias(of directory: URL, in parent: URL) throws(PoolError) -> URL {
        try PoolDirectory.checkOwnership(of: parent, forbidden: 0o077)
        var target = directory.path(percentEncoded: false)
        while target.count > 1, target.hasSuffix("/") {
            target.removeLast()
        }
        let digest = SHA256.hash(data: Data(target.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let alias = parent.appending(path: "mp-\(digest)", directoryHint: .notDirectory)
        let aliasPath = alias.path(percentEncoded: false)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: aliasPath)) == target {
            return alias
        }
        let staged = parent.appending(path: ".mp-\(digest)-\(UUID().uuidString)").path(percentEncoded: false)
        do {
            try FileManager.default.createSymbolicLink(atPath: staged, withDestinationPath: target)
        } catch {
            throw .fileSystem("creating the socket alias", URL(filePath: staged), error)
        }
        guard rename(staged, aliasPath) == 0 else {
            let failure = PoolError.systemCall("installing the socket alias", alias)
            unlink(staged)
            throw failure
        }
        return alias
    }
}
