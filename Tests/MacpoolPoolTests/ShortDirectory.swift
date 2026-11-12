import Foundation

/// A temporary directory with a short name that a test owns and that disappears with it.
///
/// Unix socket paths must stay below 104 bytes, so the name has eight characters instead of a
/// full UUID.
final class ShortDirectory {
    /// The directory.
    let url: URL

    /// Creates an empty directory in the user's temporary directory.
    ///
    /// - Throws: An error when the directory cannot be created.
    init() throws {
        let name = "mp-" + UUID().uuidString.prefix(8).lowercased()
        url = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Removes the directory and its contents.
    ///
    /// If a test ends before its cleanup, a file may stay immutable. The removal then clears the
    /// flag first.
    deinit {
        let manager = FileManager.default
        let paths = manager.enumerator(atPath: url.path(percentEncoded: false))?.allObjects as? [String] ?? []
        for path in paths {
            let item = url.appending(path: path).path(percentEncoded: false)
            // The attributes describe a symbolic link itself. A change of flags would follow it.
            guard let attributes = try? manager.attributesOfItem(atPath: item),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  attributes[.immutable] as? Bool == true else {
                continue
            }
            try? manager.setAttributes([.immutable: false], ofItemAtPath: item)
        }
        try? manager.removeItem(at: url)
    }
}
