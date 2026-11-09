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
    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
