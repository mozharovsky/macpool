import Foundation
@testable import MacpoolPool
import MacpoolVM
import Testing

/// Tests of how the daemon waits for, reconnects to, and ends supervisors.
@Suite(.timeLimit(.minutes(1)))
struct SupervisorRecoveryTests {
    /// Boots a lease again only after the earlier supervisor exited, and ignores that
    /// supervisor's late exit record.
    @Test func restartIgnoresRecordOfEarlierBoot() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(slots: 1)
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        pool.launcher.plan(FakeBehavior(listenDelay: .milliseconds(500)))
        // The supervisor reports the failure while it still holds the clone and its lock.
        pool.launcher.report(id, SupervisorStatus(phase: .exited, outcome: .failed("the VM crashed")))
        let restarting = try await next(granted.client)
        guard case .restarting = restarting else {
            Issue.record("unexpected reply \(restarting)")
            return
        }
        pool.clock.advance(by: 5)
        await daemon.tick()
        #expect(try await next(granted.client).lease?.phase == .starting)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pool.launcher.launches(of: id) == 1)
        // The earlier supervisor exits now and writes a record that describes its own run.
        pool.launcher.exit(id, .requested, directory: pool.directory)

        let ready = try await next(granted.client)
        #expect(ready.lease?.phase == .ready, "\(ready)")
        #expect(pool.launcher.launches(of: id) == 2)
        #expect(pool.launcher.signals().isEmpty)
        await daemon.shutdown()
    }

    /// Reconnects to a supervisor whose connection ended while it kept running.
    @Test func reconnectsToRunningSupervisor() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        await pool.launcher.dropConnections(id)
        try await Task.sleep(for: .milliseconds(300))
        try await pool.launcher.relisten(id, directory: pool.directory)
        // The reconnect window ends after a second, and a supervisor that was not reached by then
        // would get a signal.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(pool.launcher.signals().isEmpty)
        #expect(await daemon.summary().leases.map(\.phase) == [.ready])

        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.launches(of: id) == 1)
        #expect(pool.launcher.signals().isEmpty)
        await daemon.shutdown()
    }

    /// Signals a running supervisor that does not answer, then boots the lease again.
    @Test func signalsUnreachableSupervisorAndBootsAgain() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        await pool.launcher.dropConnections(id)
        let restarting = try await next(granted.client)
        guard case let .restarting(lease, reason) = restarting else {
            Issue.record("unexpected reply \(restarting)")
            return
        }
        #expect(reason.contains("did not answer"), "\(reason)")
        #expect(lease.restarts == 1)
        #expect(pool.launcher.signals() == [ReceivedSignal(lease: id, signal: .terminate, processID: 10001)])
        #expect(!pool.launcher.isRunning(id))
        pool.clock.advance(by: 5)
        await daemon.tick()
        #expect(try await next(granted.client).lease?.phase == .starting)
        #expect(try await next(granted.client).lease?.phase == .ready)
        #expect(pool.launcher.launches(of: id) == 2)
        await daemon.shutdown()
    }

    /// Leaves an unreachable supervisor of a released lease running until the state file records
    /// the release, then ends it and deletes the clone.
    @Test func keepsUnreachableSupervisorUntilReleaseIsStored() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let granted = try await pool.readyLease(pool.terms(detached: true))
        let id = granted.lease.id
        granted.client.close()
        let root = pool.directory.root.path(percentEncoded: false)
        #expect(chmod(root, 0o500) == 0)
        defer { chmod(root, 0o700) }
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        await pool.launcher.dropConnections(id)
        // The reconnect window is one second.
        try await Task.sleep(for: .seconds(2))
        #expect(pool.launcher.isRunning(id))
        #expect(pool.launcher.signals().isEmpty)

        #expect(chmod(root, 0o700) == 0)
        await daemon.tick()
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(!pool.launcher.isRunning(id))
        #expect(!FileManager.default.fileExists(atPath: granted.lease.bundle))
        await daemon.shutdown()
    }

    /// Ends a supervisor with another protocol version by signal and boots a current one.
    @Test func replacesIncompatibleSupervisor() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        pool.launcher.plan(FakeBehavior(ignoresStop: true, protocolVersion: 99))
        let client = try await pool.requestLease(pool.terms())
        let starting = try #require(await next(client).lease)
        let restarting = try await next(client)
        guard case let .restarting(_, reason) = restarting else {
            Issue.record("unexpected reply \(restarting)")
            return
        }
        #expect(reason.contains("protocol 99 instead of 1"), "\(reason)")
        #expect(pool.launcher.signals() == [ReceivedSignal(lease: starting.id, signal: .terminate, processID: 10001)])
        pool.clock.advance(by: 5)
        await daemon.tick()
        #expect(try await next(client).lease?.phase == .starting)
        #expect(try await next(client).lease?.phase == .ready)
        #expect(pool.launcher.launches(of: starting.id) == 2)
        await daemon.shutdown()
    }

    /// Escalates to `SIGTERM` and `SIGKILL` once a stopping supervisor ignores its stop for the
    /// grace period, then deletes the clone.
    @Test func killsSupervisorThatIgnoresStop() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        pool.launcher.plan(FakeBehavior(ignoresStop: true, ignoresTerminate: true))
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        #expect(try await next(granted.client) == .ended(id, reason: "released by a client"))
        pool.clock.advance(by: 29)
        await daemon.tick()
        try await Task.sleep(for: .milliseconds(200))
        #expect(pool.launcher.signals().isEmpty)
        #expect(await daemon.summary().leases.map(\.phase) == [.stopping])

        pool.clock.advance(by: 1)
        await daemon.tick()
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.signals() == [
            ReceivedSignal(lease: id, signal: .terminate, processID: 10001),
            ReceivedSignal(lease: id, signal: .kill, processID: 10001),
        ])
        #expect(!pool.launcher.isRunning(id))
        #expect(!FileManager.default.fileExists(atPath: granted.lease.bundle))
        await daemon.shutdown()
    }

    /// Signals a supervisor that keeps its lock after its run ended, and then deletes the clone.
    @Test func discardEndsLingeringSupervisor() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        pool.launcher.plan(FakeBehavior(ignoresTerminate: true, lingerAfterExit: .seconds(30)))
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        // The discard waits for the release timeout of two seconds before it signals.
        try await Task.sleep(for: .seconds(1))
        #expect(await daemon.summary().leases.map(\.phase) == [.stopping])
        #expect(FileManager.default.fileExists(atPath: granted.lease.bundle))

        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.signals().map(\.signal) == [.terminate, .kill])
        #expect(!pool.launcher.isRunning(id))
        #expect(!FileManager.default.fileExists(atPath: granted.lease.bundle))
        await daemon.shutdown()
    }

    /// Stops a supervisor that starts listening after its lease was released.
    @Test func releaseWhileConnectingStopsNewSupervisor() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        pool.launcher.plan(FakeBehavior(listenDelay: .milliseconds(500)))
        let client = try await pool.requestLease(pool.terms())
        let starting = try #require(await next(client).lease)
        let id = starting.id
        #expect(await eventually { pool.launcher.launches(of: id) == 1 })
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        #expect(try await next(client) == .ended(id, reason: "released by a client"))

        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.launches(of: id) == 1)
        #expect(!pool.launcher.isRunning(id))
        #expect(pool.launcher.signals().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: starting.bundle))
        await daemon.shutdown()
    }

    /// Ends a lease without restarts when its clone cannot be created.
    @Test func cloneFailureEndsLease() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let leases = pool.directory.leasesDirectory.path(percentEncoded: false)
        #expect(chmod(leases, 0o500) == 0)
        defer { chmod(leases, 0o700) }
        let client = try await pool.requestLease(pool.terms())
        let starting = try #require(await next(client).lease)
        let ended = try await next(client)
        guard case let .ended(id, reason) = ended else {
            Issue.record("unexpected reply \(ended)")
            return
        }
        #expect(id == starting.id)
        #expect(reason.contains("Permission denied"), "\(reason)")
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.launches(of: id) == 0)
        await daemon.shutdown()
    }

    /// Stops a supervisor that runs without a stored lease before it deletes its clone.
    @Test func stopsSupervisorWithoutLeaseOnStart() async throws {
        let pool = try PoolFixture()
        try pool.directory.prepare()
        let orphan = try #require(LeaseID("0a1b2c3d"))
        let clone = pool.directory.bundle(for: orphan).root
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: false)
        _ = try await pool.launcher.launch(SupervisorLaunch(
            lease: orphan,
            directory: pool.directory,
            sharedDirectory: nil,
            bootTimeout: 60,
        ))

        let daemon = try await pool.start()
        #expect(await eventually { !pool.launcher.isRunning(orphan) })
        #expect(await eventually { !FileManager.default.fileExists(atPath: clone.path(percentEncoded: false)) })
        #expect(pool.launcher.signals().isEmpty)
        #expect(SupervisorLock.holder(of: orphan, in: pool.directory) == nil)
        await daemon.shutdown()
    }
}
