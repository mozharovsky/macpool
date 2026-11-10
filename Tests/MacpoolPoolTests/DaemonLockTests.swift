import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the lock that one daemon holds on its data directory.
struct DaemonLockTests {
    /// Refuses a second lock while the first is held.
    @Test func excludesSecondDaemon() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try directory.prepare()
        let lock = try DaemonLock(directory: directory)
        #expect(throws: PoolError.daemonRunning(path: directory.root.path(percentEncoded: false))) {
            try DaemonLock(directory: directory)
        }
        withExtendedLifetime(lock) {}
    }

    /// Releases the lock while another descriptor still shares the open lock file.
    ///
    /// A process that this process spawns holds such a descriptor until it execs.
    @Test func releasesLockThatAnotherDescriptorShares() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try directory.prepare()
        var lock: DaemonLock? = try DaemonLock(directory: directory)
        let copy = try #require(lock.map { dup($0.descriptor) })
        try #require(copy >= 0)
        defer { close(copy) }
        lock = nil
        #expect(throws: Never.self) {
            try DaemonLock(directory: directory)
        }
    }
}
