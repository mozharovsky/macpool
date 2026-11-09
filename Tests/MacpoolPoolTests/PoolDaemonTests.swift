import Foundation
@testable import MacpoolPool
import MacpoolVM
import Testing

/// Tests of the daemon over its socket with supervisors that the test process serves.
@Suite(.timeLimit(.minutes(1)))
struct PoolDaemonTests {
    /// Grants a lease with its own clone and deletes the clone after a release.
    @Test func grantsLeaseAndDeletesCloneOnRelease() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let granted = try await pool.readyLease(pool.terms())
        let lease = granted.lease
        #expect(lease.address == "192.168.64.2")
        #expect(lease.expiresAt == pool.clock.now.addingTimeInterval(3600))
        let clone = try VMBundle(root: URL(filePath: lease.bundle)).settings()
        #expect(clone.macAddress != PoolFixture.sourceMACAddress)
        #expect(clone.credentialRotation == .pending)
        #expect(try PoolStore(file: pool.directory.stateFile).load().leases.map(\.id) == [lease.id])

        #expect(try await PoolClient.send(.release(lease.id), to: pool.directory) == .released(lease.id))
        #expect(try await next(granted.client) == .ended(lease.id, reason: "released by a client"))
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: lease.bundle))
        #expect(!pool.launcher.isRunning(lease.id))
        #expect(try PoolStore(file: pool.directory.stateFile).load().leases.isEmpty)
        await daemon.shutdown()
    }

    /// Queues requests by priority and grants the slot when the attached client leaves.
    @Test func queuesRequestsUntilSlotFrees() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(slots: 1)
        let first = try await pool.readyLease(pool.terms())
        let low = try await pool.requestLease(pool.terms())
        #expect(try await next(low) == .queued(position: 1))
        let high = try await pool.requestLease(pool.terms(priority: 5))
        #expect(try await next(high) == .queued(position: 1))
        #expect(try await next(low) == .queued(position: 2))
        let status = try await PoolClient.send(.status, to: pool.directory)
        guard case let .status(summary) = status else {
            Issue.record("unexpected reply \(status)")
            return
        }
        #expect(summary.slots == 1)
        #expect(summary.leases.map(\.id) == [first.lease.id])
        #expect(summary.queue.map(\.priority) == [5, 0])

        first.client.close()
        #expect(try await next(high).lease?.phase == .starting)
        #expect(try await next(high).lease?.phase == .ready)
        #expect(try await next(low) == .queued(position: 1))
        #expect(!FileManager.default.fileExists(atPath: first.lease.bundle))
        await daemon.shutdown()
    }

    /// Ends a lease at its expiry, which a renewal moves.
    @Test func endsLeaseAtItsExpiry() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let granted = try await pool.readyLease(pool.terms(timeToLive: 60))
        let id = granted.lease.id
        pool.clock.advance(by: 59)
        await daemon.tick()
        let renewed = try await PoolClient.send(.renew(id), to: pool.directory)
        #expect(renewed.lease?.expiresAt == pool.clock.now.addingTimeInterval(60))
        pool.clock.advance(by: 59)
        await daemon.tick()
        #expect(await daemon.summary().leases.first?.phase == .ready)
        pool.clock.advance(by: 1)
        await daemon.tick()
        #expect(try await next(granted.client) == .ended(id, reason: "the lease expired"))
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        await daemon.shutdown()
    }

    /// Keeps running VMs when the daemon stops, and resumes them in a new daemon.
    @Test func resumesLeasesAfterDaemonRestart() async throws {
        let pool = try PoolFixture()
        let first = try await pool.start()
        let detached = try await pool.readyLease(pool.terms(detached: true))
        detached.client.close()
        let attached = try await pool.readyLease(pool.terms())
        await first.shutdown()
        #expect(try await attached.client.receive(PoolReply.self) == nil)

        let second = try await pool.start()
        let client = try await PoolClient.connect(to: pool.directory)
        try client.send(PoolRequest.attach(attached.lease.id))
        #expect(try await next(client).lease?.phase == .ready)
        pool.clock.advance(by: 61)
        await second.tick()
        let leases = await second.summary().leases
        #expect(Set(leases.map(\.id)) == [detached.lease.id, attached.lease.id])
        #expect(leases.allSatisfy { $0.phase == .ready && $0.restarts == 0 })
        #expect(pool.launcher.launches(of: detached.lease.id) == 1)
        #expect(pool.launcher.launches(of: attached.lease.id) == 1)
        await second.shutdown()
    }

    /// Ends an attached lease whose client does not return within the grace period.
    @Test func endsUnclaimedLeaseAfterDaemonRestart() async throws {
        let pool = try PoolFixture()
        let first = try await pool.start()
        let attached = try await pool.readyLease(pool.terms())
        await first.shutdown()
        attached.client.close()

        let second = try await pool.start()
        pool.clock.advance(by: 59)
        await second.tick()
        #expect(await second.summary().leases.count == 1)
        pool.clock.advance(by: 1)
        await second.tick()
        #expect(await eventually { await second.summary().leases.isEmpty })
        #expect(!pool.launcher.isRunning(attached.lease.id))
        await second.shutdown()
    }

    /// Boots a lease again when its supervisor ended while no daemon ran.
    @Test func restartsMachineLostWhileDaemonWasAway() async throws {
        let pool = try PoolFixture()
        let first = try await pool.start()
        let granted = try await pool.readyLease(pool.terms(detached: true))
        let id = granted.lease.id
        granted.client.close()
        await first.shutdown()
        await pool.launcher.crash(id)

        let second = try await pool.start()
        #expect(await eventually { await second.summary().leases.first?.phase == .restarting })
        #expect(await second.summary().leases.first?.restarts == 1)
        pool.clock.advance(by: 5)
        await second.tick()
        #expect(await eventually { await second.summary().leases.first?.phase == .ready })
        #expect(pool.launcher.launches(of: id) == 2)
        #expect(await second.summary().leases.first?.expiresAt == granted.lease.expiresAt)
        await second.shutdown()
    }

    /// Tells the client about a crashed supervisor and boots the VM again.
    @Test func restartsCrashedSupervisor() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let granted = try await pool.readyLease(pool.terms())
        let id = granted.lease.id
        await pool.launcher.crash(id)
        let restarting = try await next(granted.client)
        guard case let .restarting(lease, reason) = restarting else {
            Issue.record("unexpected reply \(restarting)")
            return
        }
        #expect(reason == "the VM supervisor ended without a report")
        #expect(lease.restarts == 1)
        pool.clock.advance(by: 5)
        await daemon.tick()
        #expect(try await next(granted.client).lease?.phase == .starting)
        let ready = try #require(await next(granted.client).lease)
        #expect(ready.phase == .ready)
        #expect(ready.bundle == granted.lease.bundle)
        #expect(pool.launcher.launches(of: id) == 2)
        await daemon.shutdown()
    }

    /// Refuses requests that cannot succeed and leaves the pool unchanged.
    @Test func refusesUnusableRequests() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let missing = pool.root.url.appending(path: "missing").path(percentEncoded: false)
        let fresh = VMBundle(root: pool.root.url.appending(path: "fresh", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: fresh.root, withIntermediateDirectories: false)
        try fresh.writeSettings(BundleSettings(
            cpuCount: 2,
            memoryByteCount: 4 << 30,
            macAddress: "02:00:00:00:00:02",
            build: "25A1",
            hasBooted: false,
        ))
        let requests: [PoolRequest] = try [
            .lease(LeaseTerms(source: missing, timeToLive: 60)),
            .lease(LeaseTerms(source: "relative", timeToLive: 60)),
            .lease(pool.terms(timeToLive: 0)),
            .lease(LeaseTerms(source: fresh.root.path(percentEncoded: false), timeToLive: 60)),
            .lease(LeaseTerms(source: pool.source, timeToLive: 60, sharedDirectory: missing)),
            .release(#require(LeaseID("0a1b2c3d"))),
            .renew(#require(LeaseID("0a1b2c3d"))),
            .attach(#require(LeaseID("0a1b2c3d"))),
        ]
        for request in requests {
            await #expect {
                try await PoolClient.send(request, to: pool.directory)
            } throws: { error in
                if case .daemonRefused = error as? PoolError {
                    true
                } else {
                    false
                }
            }
        }
        // A source that a VM uses cannot be cloned.
        let lock = try BundleLock(bundle: VMBundle(root: URL(filePath: pool.source)))
        let inUse = PoolError.library(.bundleInUse(path: pool.source)).description
        await #expect(throws: PoolError.daemonRefused(message: inUse)) {
            try await PoolClient.send(.lease(pool.terms()), to: pool.directory)
        }
        withExtendedLifetime(lock) {}
        #expect(await daemon.summary().leases.isEmpty)
        #expect(await daemon.summary().queue.isEmpty)
        await daemon.shutdown()
    }

    /// Refuses a data directory that another user could replace or write to.
    @Test func refusesDirectoryOthersControl() throws {
        let pool = try PoolFixture()
        let root = pool.directory.root.path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        #expect(chmod(root, 0o777) == 0)
        #expect {
            try pool.daemon()
        } throws: { error in
            if case let .insecureDirectory(_, reason) = error as? PoolError {
                reason == "its permissions 777 let other users in"
            } else {
                false
            }
        }
        #expect(chmod(root, 0o700) == 0)
        try FileManager.default.removeItem(atPath: root + "run")
        let elsewhere = pool.root.url.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: root + "run",
            withDestinationPath: elsewhere.path(percentEncoded: false),
        )
        #expect {
            try pool.daemon()
        } throws: { error in
            if case let .insecureDirectory(_, reason) = error as? PoolError {
                reason == "it is not a directory"
            } else {
                false
            }
        }
    }

    /// Moves an unreadable state file aside, starts without leases, and removes their clones.
    @Test func setsAsideUnreadableState() async throws {
        let pool = try PoolFixture()
        try pool.directory.prepare()
        try Data("{".utf8).write(to: pool.directory.stateFile)
        let orphan = try #require(LeaseID("0a1b2c3d"))
        let clone = pool.directory.bundle(for: orphan).root
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: false)

        let daemon = try await pool.start()
        #expect(await daemon.summary().leases.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: pool.directory.root.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("state.json.invalid-") }, "\(names)")
        #expect(!FileManager.default.fileExists(atPath: clone.path(percentEncoded: false)))
        await daemon.shutdown()
    }

    /// Refuses a second daemon for the same data directory.
    @Test func refusesSecondDaemon() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        #expect {
            try pool.daemon()
        } throws: { error in
            if case .daemonRunning = error as? PoolError {
                true
            } else {
                false
            }
        }
        await daemon.shutdown()
        _ = try pool.daemon()
    }

    /// Removes clones, partial clones, run files, and old logs that belong to no stored lease, and
    /// keeps other entries.
    @Test func removesFilesWithoutLeasesOnStart() async throws {
        let pool = try PoolFixture()
        try pool.directory.prepare()
        let orphan = try #require(LeaseID("0a1b2c3d"))
        let manager = FileManager.default
        try manager.createDirectory(at: pool.directory.bundle(for: orphan).root, withIntermediateDirectories: false)
        try pool.directory.writeExitRecord(.lost, for: orphan)
        let partial = pool.directory.partialBundle(for: orphan)
        try manager.createDirectory(at: partial, withIntermediateDirectories: false)
        let other = pool.directory.leasesDirectory.appending(path: "keep")
        try manager.createDirectory(at: other, withIntermediateDirectories: false)
        let logs = pool.directory.logsDirectory
        let old = Date().addingTimeInterval(-8 * 24 * 3600)
        for name in ["0a1b2c3d.log", "1a2b3c4d.log", "daemon.log"] {
            try Data().write(to: logs.appending(path: name))
        }
        for name in ["0a1b2c3d.log", "daemon.log"] {
            try manager.setAttributes([.modificationDate: old], ofItemAtPath: logs.appending(path: name).path())
        }

        let daemon = try await pool.start()
        #expect(!manager.fileExists(atPath: pool.directory.bundle(for: orphan).root.path(percentEncoded: false)))
        #expect(!manager.fileExists(atPath: partial.path(percentEncoded: false)))
        #expect(!manager.fileExists(atPath: pool.directory.exitRecord(for: orphan).path(percentEncoded: false)))
        #expect(manager.fileExists(atPath: other.path(percentEncoded: false)))
        let kept = try manager.contentsOfDirectory(atPath: logs.path(percentEncoded: false)).sorted()
        #expect(kept == ["1a2b3c4d.log", "daemon.log"])
        await daemon.shutdown()
    }
}
