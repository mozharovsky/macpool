import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the lock that a supervisor holds for its whole life.
struct SupervisorLockTests {
    /// Reports the holder's process identifier while the lock is held and nothing afterward.
    @Test func reportsHolderUntilRelease() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try directory.prepare()
        let id = try #require(LeaseID("0a1b2c3d"))
        #expect(SupervisorLock.holder(of: id, in: directory) == nil)

        var lock: SupervisorLock? = try SupervisorLock(of: id, in: directory, processID: 4242)
        #expect(lock != nil)
        #expect(SupervisorLock.holder(of: id, in: directory) == 4242)
        #expect(throws: PoolError.supervisorRunning(id: id.rawValue)) {
            try SupervisorLock(of: id, in: directory, processID: 4343, timeout: 0.2)
        }
        lock = nil
        #expect(SupervisorLock.holder(of: id, in: directory) == nil)
        let next = try SupervisorLock(of: id, in: directory, processID: 4343, timeout: 0)
        #expect(SupervisorLock.holder(of: id, in: directory) == 4343)
        withExtendedLifetime(next) {}
    }
}
