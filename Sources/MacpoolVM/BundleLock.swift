import Foundation

/// An exclusive advisory lock on a bundle, held while a command uses the bundle.
///
/// The lock is an `flock` on the bundle's `lock` file. `run` and `create` hold it while a VM uses
/// the bundle, and `clone` holds it while it copies the source, so a clone never captures a disk
/// that a running guest is writing.
///
/// The kernel releases the lock when the lock is deinitialized or the process exits, including a
/// crash. The lock file itself stays in the bundle, and an APFS clone copies it unlocked.
public final class BundleLock: Sendable {
    /// The open lock file that carries the `flock`.
    private let descriptor: Int32

    /// Takes the lock of a bundle without waiting.
    ///
    /// The call creates the lock file when it is missing, so bundles from before the lock gain one
    /// on first use.
    ///
    /// - Parameter bundle: The bundle to lock. Its directory must exist.
    /// - Throws: ``MacpoolError/bundleInUse(path:)`` when another process holds the lock, or
    ///   ``MacpoolError/fileSystem(operation:path:reason:)`` when the lock file cannot be opened.
    public init(bundle: VMBundle) throws(MacpoolError) {
        let file = bundle.lockFile
        let descriptor = open(file.filePath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw .systemCall("opening the bundle lock", file)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK {
                throw .bundleInUse(path: bundle.root.filePath)
            }
            errno = failure
            throw .systemCall("locking the bundle", file)
        }
        self.descriptor = descriptor
    }

    /// Reports whether another process holds a bundle's lock.
    ///
    /// The check takes and releases the lock at once, so its answer can be stale by the time the
    /// caller uses it.
    ///
    /// - Parameter bundle: The bundle to check.
    /// - Returns: `true` when another process holds the lock. A bundle without a lock file, or one
    ///   whose lock file cannot be opened, counts as unlocked.
    public static func isHeld(on bundle: VMBundle) -> Bool {
        do {
            _ = try BundleLock(bundle: bundle)
            return false
        } catch .bundleInUse {
            return true
        } catch {
            return false
        }
    }

    /// Releases the lock by closing the lock file.
    deinit {
        close(descriptor)
    }
}
