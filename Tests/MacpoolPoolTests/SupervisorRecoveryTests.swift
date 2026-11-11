import Foundation
@testable import MacpoolPool
import MacpoolVM
import Testing

/// Tests of how the daemon waits for, reconnects to, and ends supervisors.
@Suite(.timeLimit(.minutes(1)))
struct SupervisorRecoveryTests {
    /// The log line of a supervisor that keeps running because the state file does not record its
    /// lease's end.
    static let deferral = "A supervisor keeps running until the state file records its stop"

    /// Boots a lease again only after the earlier supervisor exited, and ignores that
    /// supervisor's late exit record.
    @Test func restartIgnoresRecordOfEarlierBoot() async throws {
        let pool = try PoolFixture()
        // The earlier supervisor exits only when the test ends it. The daemon must not stop it
        // before that.
        let daemon = try await pool.start(slots: 1, releaseTimeout: .seconds(30))
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        let listening = Gate()
        pool.launcher.plan(FakeBehavior(listenGate: listening))
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
        #expect(await eventually { pool.launcher.launches(of: id) == 2 })
        listening.open()

        let ready = try await next(granted.client)
        #expect(ready.lease?.phase == .ready, "\(ready)")
        #expect(pool.launcher.launches(of: id) == 2)
        #expect(pool.launcher.signals().isEmpty)
        await daemon.shutdown()
    }

    /// Reconnects to a supervisor whose connection ended while it kept running.
    @Test func reconnectsToRunningSupervisor() async throws {
        let pool = try PoolFixture()
        // A supervisor that the daemon does not reach within the window gets a signal. The test
        // must not depend on how fast it relistens.
        let daemon = try await pool.start(reconnectWindow: .seconds(30))
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        await pool.launcher.dropConnections(id)
        #expect(await eventually { !pool.logs.entries("A supervisor connection ended").isEmpty })
        try await pool.launcher.relisten(id, directory: pool.directory)
        #expect(await eventually { !pool.logs.entries("Reconnected to a supervisor").isEmpty })
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
        let bundle = try #require(granted.lease.bundle)
        let id = granted.lease.id
        granted.client.close()
        let root = pool.directory.root.path(percentEncoded: false)
        #expect(chmod(root, 0o500) == 0)
        defer { chmod(root, 0o700) }
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        await pool.launcher.dropConnections(id)
        // After the reconnect window the daemon finds that the stop must wait.
        #expect(await eventually { !pool.logs.entries(Self.deferral).isEmpty })
        #expect(pool.launcher.isRunning(id))
        #expect(pool.launcher.signals().isEmpty)

        #expect(chmod(root, 0o700) == 0)
        await daemon.tick()
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(!pool.launcher.isRunning(id))
        #expect(!FileManager.default.fileExists(atPath: bundle))
        await daemon.shutdown()
    }

    /// Holds back the next signal when a release that the state file does not record arrives
    /// while the daemon ends an unreachable supervisor.
    @Test func releaseDuringSignalsDefersTheNextSignal() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let killCheck = Gate()
        pool.launcher.plan(FakeBehavior(ignoresTerminate: true, identifyGates: [2: killCheck]))
        let granted = try await pool.readyLease(pool.terms(detached: true))
        let id = granted.lease.id
        granted.client.close()
        await pool.launcher.dropConnections(id)
        // After the reconnect window the daemon sends `SIGTERM`. Half a second later it checks the
        // process again before `SIGKILL`, and the check waits for the gate.
        #expect(await eventually { pool.launcher.identifications() == 2 })
        #expect(pool.launcher.signals().map(\.signal) == [.terminate])
        let root = pool.directory.root.path(percentEncoded: false)
        #expect(chmod(root, 0o500) == 0)
        defer { chmod(root, 0o700) }
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        killCheck.open()
        #expect(await eventually { !pool.logs.entries(Self.deferral).isEmpty })
        #expect(pool.launcher.signals().map(\.signal) == [.terminate])
        #expect(pool.launcher.isRunning(id))

        #expect(chmod(root, 0o700) == 0)
        await daemon.tick()
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.signals().map(\.signal) == [.terminate, .terminate, .kill])
        #expect(!pool.launcher.isRunning(id))
        await daemon.shutdown()
    }

    /// Sends no signal when a release that the state file does not record arrives while the
    /// daemon checks the supervisor's process.
    @Test func releaseDuringProcessCheckDefersTheSignal() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let terminateCheck = Gate()
        pool.launcher.plan(FakeBehavior(identifyGates: [1: terminateCheck]))
        let granted = try await pool.readyLease(pool.terms(detached: true))
        let id = granted.lease.id
        granted.client.close()
        await pool.launcher.dropConnections(id)
        #expect(await eventually { pool.launcher.identifications() == 1 })
        let root = pool.directory.root.path(percentEncoded: false)
        #expect(chmod(root, 0o500) == 0)
        defer { chmod(root, 0o700) }
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        terminateCheck.open()
        #expect(await eventually { !pool.logs.entries(Self.deferral).isEmpty })
        #expect(pool.launcher.signals().isEmpty)
        #expect(pool.launcher.isRunning(id))

        #expect(chmod(root, 0o700) == 0)
        await daemon.tick()
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.signals().map(\.signal) == [.terminate])
        #expect(!pool.launcher.isRunning(id))
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
        let bundle = try #require(granted.lease.bundle)
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
        #expect(!FileManager.default.fileExists(atPath: bundle))
        await daemon.shutdown()
    }

    /// Withholds each signal from a process that the launcher does not identify, logs the reason
    /// once per signal, and reports the supervisor as running without a SIGKILL.
    @Test func logsWhyASignalIsWithheld() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let mismatch = SupervisorMismatch.unreadableArguments(errno: EPERM)
        pool.launcher.plan(FakeBehavior(ignoresStop: true, mismatch: mismatch))
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        #expect(try await next(granted.client) == .ended(id, reason: "released by a client"))
        pool.clock.advance(by: 30)
        await daemon.tick()
        let withheld = "A process is not the lease's supervisor"
        #expect(await eventually { pool.logs.entries(withheld).count >= 2 })
        let entries = pool.logs.entries(withheld)
        #expect(entries.map { $0.metadata["signal"] } == ["terminate", "kill"])
        #expect(entries.map { $0.metadata["reason"] } == [mismatch.description, mismatch.description])
        #expect(entries.allSatisfy { $0.metadata["pid"] == "10001" })
        // No SIGKILL went out, so the log does not claim that the supervisor survived one.
        #expect(await eventually {
            !pool.logs.entries("A supervisor does not exit, and the daemon withheld SIGKILL").isEmpty
        })
        #expect(pool.logs.entries("A supervisor survives SIGKILL").isEmpty)
        #expect(pool.launcher.signals().isEmpty)
        #expect(pool.launcher.isRunning(id))
        await daemon.shutdown()
        await pool.launcher.crash(id)
    }

    /// Passes the start time from the supervisor's lock to each process check.
    @Test func checksRecordedStartTime() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        pool.launcher.plan(FakeBehavior(ignoresStop: true, ignoresTerminate: true))
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        pool.clock.advance(by: 30)
        await daemon.tick()
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        let started = RecordedStartTime.recorded(FakeLauncher.startTime(of: 10001))
        #expect(pool.launcher.startTimes() == [started, started])
        #expect(pool.launcher.signals().map(\.signal) == [.terminate, .kill])
        await daemon.shutdown()
    }

    /// Passes a malformed start time from the supervisor's lock to the process check instead of
    /// reading the record as one from an earlier build.
    @Test func reportsMalformedStartTime() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        pool.launcher.plan(FakeBehavior(ignoresStop: true, mismatch: .malformedStartTime))
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        try Data("10001\nsoon\n".utf8).write(to: pool.directory.supervisorLock(for: id))
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        pool.clock.advance(by: 30)
        await daemon.tick()
        let withheld = "A process is not the lease's supervisor"
        #expect(await eventually { pool.logs.entries(withheld).count >= 2 })
        #expect(pool.launcher.startTimes() == [.malformed, .malformed])
        #expect(pool.logs.entries(withheld).map { $0.metadata["reason"] } == [
            SupervisorMismatch.malformedStartTime.description,
            SupervisorMismatch.malformedStartTime.description,
        ])
        #expect(pool.launcher.signals().isEmpty)
        await daemon.shutdown()
        await pool.launcher.crash(id)
    }

    /// Signals a supervisor that keeps its lock after its run ended, and then deletes the clone.
    @Test func discardEndsLingeringSupervisor() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let terminateCheck = Gate()
        pool.launcher.plan(FakeBehavior(
            ignoresTerminate: true,
            identifyGates: [1: terminateCheck],
            lingerAfterExit: .seconds(30),
        ))
        let granted = try await pool.readyLease(pool.terms())
        let bundle = try #require(granted.lease.bundle)
        let id = granted.lease.id
        let clock = ContinuousClock()
        let released = clock.now
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        // The discard waits for the release timeout of two seconds before it checks the process.
        #expect(await eventually { pool.launcher.identifications() == 1 })
        #expect(clock.now - released >= .seconds(2))
        #expect(await daemon.summary().leases.map(\.phase) == [.stopping])
        #expect(FileManager.default.fileExists(atPath: bundle))
        #expect(pool.launcher.signals().isEmpty)
        terminateCheck.open()

        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.signals().map(\.signal) == [.terminate, .kill])
        #expect(!pool.launcher.isRunning(id))
        #expect(!FileManager.default.fileExists(atPath: bundle))
        await daemon.shutdown()
    }

    /// Stops a supervisor that starts listening after its lease was released.
    @Test func releaseWhileConnectingStopsNewSupervisor() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let listening = Gate()
        pool.launcher.plan(FakeBehavior(listenGate: listening))
        let client = try await pool.requestLease(pool.terms())
        let starting = try #require(await next(client).lease)
        let bundle = try #require(starting.bundle)
        let id = starting.id
        #expect(await eventually { pool.launcher.launches(of: id) == 1 })
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        #expect(try await next(client) == .ended(id, reason: "released by a client"))
        listening.open()

        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(pool.launcher.launches(of: id) == 1)
        #expect(!pool.launcher.isRunning(id))
        #expect(pool.launcher.signals().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bundle))
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

        // On a busy runner the supervisor can take longer than half a second to exit after the stop.
        let daemon = try await pool.start(signalGrace: .seconds(5))
        #expect(await eventually { !pool.launcher.isRunning(orphan) })
        #expect(await eventually { !FileManager.default.fileExists(atPath: clone.path(percentEncoded: false)) })
        #expect(pool.launcher.signals().isEmpty)
        #expect(SupervisorLock.holder(of: orphan, in: pool.directory) == nil)
        await daemon.shutdown()
    }
}
