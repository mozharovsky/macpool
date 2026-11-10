import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the lock that a supervisor holds for its whole life.
struct SupervisorLockTests {
    /// Reports the holder's record while the lock is held and nothing afterward.
    @Test func reportsHolderUntilRelease() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try directory.prepare()
        let id = try #require(LeaseID("0a1b2c3d"))
        #expect(SupervisorLock.holder(of: id, in: directory) == nil)

        var lock: SupervisorLock? = try SupervisorLock(of: id, in: directory, processID: 4242, startTime: 7)
        #expect(lock != nil)
        #expect(SupervisorLock.holder(of: id, in: directory) == SupervisorLockRecord(
            processID: 4242,
            startTime: .recorded(7),
        ))
        #expect(throws: PoolError.supervisorRunning(id: id.rawValue)) {
            try SupervisorLock(of: id, in: directory, processID: 4343, startTime: 8, timeout: 0.2)
        }
        lock = nil
        #expect(SupervisorLock.holder(of: id, in: directory) == nil)
        // The shorter record replaces the longer one completely.
        let next = try SupervisorLock(of: id, in: directory, processID: 4343, startTime: 8, timeout: 0)
        #expect(SupervisorLock.holder(of: id, in: directory) == SupervisorLockRecord(
            processID: 4343,
            startTime: .recorded(8),
        ))
        withExtendedLifetime(next) {}
    }

    /// Releases the lock while another descriptor still shares the open lock file.
    ///
    /// A process that this process spawns holds such a descriptor until it execs.
    @Test func releasesLockThatAnotherDescriptorShares() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try directory.prepare()
        let id = try #require(LeaseID("0a1b2c3d"))

        var lock: SupervisorLock? = try SupervisorLock(of: id, in: directory, processID: 4242, startTime: 7)
        let copy = try #require(lock.map { dup($0.descriptor) })
        defer { close(copy) }
        lock = nil
        #expect(SupervisorLock.holder(of: id, in: directory) == nil)
    }

    /// Records the calling process's identifier and its start time from the kernel.
    @Test func recordsOwnStartTime() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try directory.prepare()
        let id = try #require(LeaseID("0a1b2c3d"))
        let lock = try SupervisorLock(of: id, in: directory)
        let started = try ProcessStartTime.read(processID: getpid())
        #expect(try ProcessStartTime.read(processID: getpid()) == started)
        #expect(SupervisorLock.holder(of: id, in: directory) == SupervisorLockRecord(
            processID: getpid(),
            startTime: .recorded(started),
        ))
        let contents = try String(contentsOf: directory.supervisorLock(for: id), encoding: .utf8)
        #expect(contents == "\(getpid())\n\(started)\n")
        withExtendedLifetime(lock) {}
    }

    /// Reads a one-line record that an earlier build wrote while its supervisor holds the lock.
    @Test func readsRecordOfEarlierBuild() throws {
        let root = try ShortDirectory()
        let directory = PoolDirectory(root: root.url.appending(path: "pool", directoryHint: .isDirectory))
        try directory.prepare()
        let id = try #require(LeaseID("0a1b2c3d"))
        let lock = try SupervisorLock(of: id, in: directory, processID: 4242, startTime: 7)
        try Data("4242\n".utf8).write(to: directory.supervisorLock(for: id))
        #expect(SupervisorLock.holder(of: id, in: directory) == SupervisorLockRecord(
            processID: 4242,
            startTime: .absent,
        ))
        withExtendedLifetime(lock) {}
    }

    /// Tells a record without a start time from a complete one and from a malformed one.
    @Test func readsEachRecordForm() {
        func record(_ text: String) -> SupervisorLockRecord {
            SupervisorLockRecord(contents: Array(text.utf8))
        }
        #expect(record("") == SupervisorLockRecord(processID: 0, startTime: .absent))
        #expect(record("4242\n") == SupervisorLockRecord(processID: 4242, startTime: .absent))
        #expect(record("4242\n17\n") == SupervisorLockRecord(processID: 4242, startTime: .recorded(17)))
        // Lines after the start time belong to a later format.
        #expect(record("4242\n17\nmore\n") == SupervisorLockRecord(processID: 4242, startTime: .recorded(17)))
        #expect(record("4242\n17\nmo") == SupervisorLockRecord(processID: 4242, startTime: .recorded(17)))
        // A truncated or unreadable start time is not an earlier build's record.
        #expect(record("4242\n17") == SupervisorLockRecord(processID: 4242, startTime: .malformed))
        #expect(record("4242\n\n") == SupervisorLockRecord(processID: 4242, startTime: .malformed))
        #expect(record("4242\n1.5\n") == SupervisorLockRecord(processID: 4242, startTime: .malformed))
        #expect(record("4242\n-17\n") == SupervisorLockRecord(processID: 4242, startTime: .malformed))
        #expect(record("4242") == SupervisorLockRecord(processID: 0, startTime: .malformed))
        #expect(record("pid\n17\n") == SupervisorLockRecord(processID: 0, startTime: .malformed))
    }

    /// Reads the start time of the test process and fails for an identifier above the system's
    /// highest one.
    @Test func readsProcessStartTime() throws {
        let started = try ProcessStartTime.read(processID: getpid())
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        #expect(started > 0 && started <= now)
        #expect(throws: SupervisorMismatch.unreadableStartTime(errno: ESRCH)) {
            try ProcessStartTime.read(processID: 99_999_999)
        }
    }
}
