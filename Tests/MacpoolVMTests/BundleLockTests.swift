import Foundation
@testable import MacpoolVM
import Testing

/// Tests of the advisory lock that commands hold on a bundle.
struct BundleLockTests {
    /// Refuses a second lock while the first is held and grants it once the first is released.
    @Test func excludesSecondHolder() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        var lock: BundleLock? = try BundleLock(bundle: bundle)
        #expect(lock != nil)
        #expect(BundleLock.isHeld(on: bundle))
        #expect(throws: MacpoolError.bundleInUse(path: bundle.root.path(percentEncoded: false))) {
            try BundleLock(bundle: bundle)
        }
        lock = nil
        #expect(!BundleLock.isHeld(on: bundle))
        _ = try BundleLock(bundle: bundle)
    }

    /// Releases the lock while another descriptor still shares the open lock file.
    ///
    /// A process that this process spawns holds such a descriptor until it execs.
    @Test func releasesLockThatAnotherDescriptorShares() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url)
        var lock: BundleLock? = try BundleLock(bundle: bundle)
        let copy = try #require(lock.map { dup($0.descriptor) })
        defer { close(copy) }
        lock = nil
        #expect(!BundleLock.isHeld(on: bundle))
    }

    /// Treats a bundle without a lock file as unlocked.
    @Test func reportsMissingLockAsFree() throws {
        let directory = try TemporaryDirectory()
        let bundle = VMBundle(root: directory.url.appending(path: "missing"))
        #expect(!BundleLock.isHeld(on: bundle))
    }

    /// Leaves the clone of a locked bundle unlocked.
    @Test func clonesLockFileUnlocked() throws {
        let directory = try TemporaryDirectory()
        let source = VMBundle(root: directory.url.appending(path: "source"))
        try FileManager.default.createDirectory(at: source.root, withIntermediateDirectories: false)
        try VMBundleTests.settingsJSON.write(to: source.settingsFile, atomically: true, encoding: .utf8)
        let lock = try BundleLock(bundle: source)
        let clone = try source.clone(to: directory.url.appending(path: "clone"))
        #expect(FileManager.default.fileExists(atPath: clone.lockFile.path(percentEncoded: false)))
        #expect(!BundleLock.isHeld(on: clone))
        withExtendedLifetime(lock) {}
    }
}
