import Foundation

/// A uniquely named directory that a test owns and that disappears with it.
///
/// The directory lives in the user's temporary directory, which is on the APFS data volume, so
/// clone tests can use it.
final class TemporaryDirectory {
    /// The directory.
    let url: URL

    /// Creates an empty directory.
    ///
    /// - Throws: An error when the directory cannot be created.
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "macpool-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Removes the directory and its contents.
    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
