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
        let bundle = try #require(lease.bundle)
        #expect(lease.address == "192.168.64.2")
        #expect(lease.expiresAt == pool.clock.now.addingTimeInterval(3600))
        let clone = try VMBundle(root: URL(filePath: bundle)).settings()
        #expect(clone.macAddress != PoolFixture.sourceMACAddress)
        #expect(clone.credentialRotation == .pending)
        #expect(try PoolStore(file: pool.directory.stateFile).load().leases.map(\.id) == [lease.id])

        #expect(try await PoolClient.send(.release(lease.id), to: pool.directory) == .released(lease.id))
        #expect(try await next(granted.client) == .ended(lease.id, reason: "released by a client"))
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: bundle))
        #expect(!pool.launcher.isRunning(lease.id))
        #expect(try PoolStore(file: pool.directory.stateFile).load().leases.isEmpty)
        await daemon.shutdown()
    }

    /// Keeps a released lease's VM and clone until the state file records the release.
    @Test func keepsMachineUntilStateRecordsRelease() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let granted = try await pool.readyLease(pool.terms())
        let lease = granted.lease
        let bundle = try #require(lease.bundle)
        // A read-only data directory makes every write of the state fail.
        let root = pool.directory.root.path(percentEncoded: false)
        #expect(chmod(root, 0o500) == 0)
        defer { chmod(root, 0o700) }
        #expect(try await PoolClient.send(.release(lease.id), to: pool.directory) == .released(lease.id))
        #expect(try await next(granted.client) == .ended(lease.id, reason: "released by a client"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(pool.launcher.isRunning(lease.id))
        #expect(await daemon.summary().leases.map(\.phase) == [.stopping])
        #expect(FileManager.default.fileExists(atPath: bundle))
        #expect(try PoolStore(file: pool.directory.stateFile).load().leases.map(\.phase) == [.ready])

        #expect(chmod(root, 0o700) == 0)
        await daemon.tick()
        #expect(await eventually { !pool.launcher.isRunning(lease.id) })
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: bundle))
        #expect(try PoolStore(file: pool.directory.stateFile).load().leases.isEmpty)
        await daemon.shutdown()
    }

    /// Keeps a lease that always restarts from booting again when its release never reached the
    /// state file before the daemon stopped.
    @Test func unstoredReleaseDoesNotBootAgain() async throws {
        let pool = try PoolFixture()
        let first = try await pool.start()
        let terms = LeaseTerms(source: pool.source, timeToLive: 3600, restartPolicy: .always, detached: true)
        let granted = try await pool.readyLease(terms)
        let id = granted.lease.id
        granted.client.close()
        let root = pool.directory.root.path(percentEncoded: false)
        #expect(chmod(root, 0o500) == 0)
        defer { chmod(root, 0o700) }
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        try await Task.sleep(for: .milliseconds(300))
        await first.shutdown()
        #expect(chmod(root, 0o700) == 0)

        // The state still records the lease as ready, and its VM still runs.
        let second = try await pool.start()
        try await Task.sleep(for: .milliseconds(500))
        pool.clock.advance(by: 5)
        await second.tick()
        #expect(await second.summary().leases.map(\.phase) == [.ready])
        #expect(pool.launcher.launches(of: id) == 1)
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        #expect(await eventually { await second.summary().leases.isEmpty })
        #expect(pool.launcher.launches(of: id) == 1)
        await second.shutdown()
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
        #expect(try !FileManager.default.fileExists(atPath: #require(first.lease.bundle)))
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
        let offered = pool.root.url.appending(path: "offered").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: offered, withIntermediateDirectories: false)
        let daemon = try await pool.start(offeredSources: ["offered": offered])
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
            .lease(LeaseTerms(source: pool.source, timeToLive: 60, sharedDirectory: pool.root.url.path())),
            .lease(LeaseTerms(source: pool.source, timeToLive: 60, sharedDirectory: pool.source)),
            .lease(LeaseTerms(source: pool.source, timeToLive: 60, sharedDirectory: offered)),
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

    /// Refuses a writable share that includes the executable that starts supervisors.
    @Test func refusesShareWithSupervisorExecutable() async throws {
        let pool = try PoolFixture()
        let bin = pool.root.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let daemon = try PoolDaemon(configuration: PoolDaemon.Configuration(
            directory: pool.directory,
            policy: PoolPolicy(slots: 1),
            launcher: ProcessSupervisorLauncher(executable: bin.appending(path: "macpool")),
        ))
        try await daemon.start()
        var terms = pool.terms()
        terms.sharedDirectory = bin.path(percentEncoded: false)
        await #expect {
            try await PoolClient.send(.lease(terms), to: pool.directory)
        } throws: { error in
            "\(error)".contains("includes the macpool executable")
        }
        await daemon.shutdown()
    }

    /// Limits a paired client to its own leases, to the sources that the host offers, and to
    /// leases without a shared directory or a priority above its ceiling. Shows the client the
    /// source by its name, without a clone or an address.
    @Test func limitsPairedClients() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let local = try await pool.readyLease(pool.terms())
        let alice = try LeaseLedgerTests.paired("a")
        let remote = try await pool.pairedClient(of: daemon, owner: alice)

        let refusals = [
            (LeaseTerms(source: pool.source, timeToLive: 60), "the host does not offer the requested source"),
            (LeaseTerms(source: "other", timeToLive: 60), "the host does not offer the requested source"),
            (
                LeaseTerms(source: "base", timeToLive: 60, sharedDirectory: pool.root.url.path(percentEncoded: false)),
                "a paired client cannot share a host directory",
            ),
            (
                LeaseTerms(source: "base", timeToLive: 60, priority: 1),
                "this Mac may ask for a priority of at most 0",
            ),
        ]
        for (terms, reason) in refusals {
            try remote.send(PoolRequest.lease(terms))
            #expect(try await next(remote) == .failure(PoolError.invalidRequest(reason: reason).description))
        }
        let unknown = PoolError.unknownLease(id: local.lease.id.rawValue).description
        for request in [PoolRequest.renew(local.lease.id), .release(local.lease.id), .attach(local.lease.id)] {
            try remote.send(request)
            #expect(try await next(remote) == .failure(unknown))
        }
        try remote.send(PoolRequest.status)
        #expect(try await next(remote) == .status(PoolSummary(slots: 2, leases: [], queue: [])))

        try remote.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        let starting = try await next(remote)
        #expect(starting.lease?.source == "base")
        #expect(starting.lease?.bundle == nil)
        let ready = try #require(await next(remote).lease)
        #expect(ready.phase == .ready)
        #expect(ready.source == "base")
        #expect(ready.bundle == nil)
        #expect(ready.address == nil)
        try remote.send(PoolRequest.status)
        #expect(try await next(remote) == .status(PoolSummary(slots: 2, leases: [ready], queue: [])))
        let stored = try PoolStore(file: pool.directory.stateFile).load().leases
        #expect(stored.first { $0.id == ready.id }?.owner == alice)
        #expect(stored.first { $0.id == local.lease.id }?.owner == .local)
        #expect(await daemon.summary().leases.count == 2)

        #expect(try await PoolClient.send(.release(ready.id), to: pool.directory) == .released(ready.id))
        #expect(try await next(remote) == .ended(ready.id, reason: "released by a client"))
        #expect(pool.logs.entries("Booting a lease").map { $0.metadata["owner"] } == ["local", "\(alice)"])
        await daemon.shutdown()
    }

    /// Lets a paired client attach to and release its own lease from a new connection.
    @Test func pairedClientReturnsToItsLease() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let alice = try LeaseLedgerTests.paired("a")
        let first = try await pool.pairedClient(of: daemon, owner: alice)
        try first.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60, detached: true)))
        _ = try await next(first)
        let lease = try #require(await next(first).lease)
        #expect(lease.phase == .ready)
        first.close()

        let second = try await pool.pairedClient(of: daemon, owner: alice)
        // The lease stays attached to the first connection until the daemon notices its end.
        let busy = PoolReply.failure(PoolError.leaseAttached(id: lease.id.rawValue).description)
        var reply = busy
        var attempts = 0
        while reply == busy, attempts < 250 {
            attempts += 1
            try second.send(PoolRequest.attach(lease.id))
            reply = try await next(second)
            if reply == busy {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try #require(reply != busy, "the lease stayed attached after \(attempts) attempts: \(reply)")
        #expect(reply == .ready(lease))
        try second.send(PoolRequest.release(lease.id))
        #expect(try await next(second) == .ended(lease.id, reason: "released by a client"))
        #expect(try await next(second) == .released(lease.id))
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        #expect(!pool.launcher.isRunning(lease.id))
        await daemon.shutdown()
    }

    /// Keeps two paired clients from seeing or changing each other's leases.
    @Test func separatesPairedClients() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let alice = try LeaseLedgerTests.paired("a")
        let bob = try LeaseLedgerTests.paired("b")
        let clients = try await [
            pool.pairedClient(of: daemon, owner: alice),
            pool.pairedClient(of: daemon, owner: bob),
        ]
        var leases: [LeaseSummary] = []
        for client in clients {
            try client.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
            _ = try await next(client)
            try leases.append(#require(await next(client).lease))
        }

        for (index, client) in clients.enumerated() {
            let own = leases[index]
            let other = leases[1 - index]
            try client.send(PoolRequest.status)
            #expect(try await next(client) == .status(PoolSummary(slots: 2, leases: [own], queue: [])))
            let unknown = PoolReply.failure(PoolError.unknownLease(id: other.id.rawValue).description)
            for request in [PoolRequest.renew(other.id), .release(other.id), .attach(other.id)] {
                try client.send(request)
                #expect(try await next(client) == unknown)
            }
        }
        #expect(await daemon.summary().leases.map(\.phase) == [.ready, .ready])
        let owners = try PoolStore(file: pool.directory.stateFile).load().leases.map(\.owner)
        #expect(Set(owners) == [alice, bob])
        await daemon.shutdown()
    }

    /// Resumes a running lease from a version 1 state file as the local user's, and rewrites the
    /// file in version 2 as soon as the daemon starts.
    @Test func resumesLeasesFromUnownedState() async throws {
        let pool = try PoolFixture()
        let first = try await pool.start()
        let granted = try await pool.readyLease(pool.terms(detached: true))
        let id = granted.lease.id
        granted.client.close()
        await first.shutdown()

        let file = pool.directory.stateFile
        let stored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let leases = try #require(stored["leases"] as? [[String: Any]])
        #expect(leases.map { $0["owner"] as? String } == ["local"])
        let earlier: [String: Any] = [
            "version": PoolState.unownedVersion,
            "leases": leases.map { $0.filter { $0.key != "owner" } },
        ]
        try JSONSerialization.data(withJSONObject: earlier).write(to: file)

        let second = try await pool.start()
        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(rewritten["version"] as? Int == PoolState.currentVersion)
        #expect(try PoolStore(file: file).load().leases.map(\.owner) == [.local])
        #expect(await eventually { await second.summary().leases.map(\.phase) == [.ready] })
        #expect(pool.launcher.launches(of: id) == 1)
        let remote = try await pool.pairedClient(of: second, owner: LeaseLedgerTests.paired("a"))
        try remote.send(PoolRequest.status)
        #expect(try await next(remote) == .status(PoolSummary(slots: 2, leases: [], queue: [])))
        #expect(try await PoolClient.send(.release(id), to: pool.directory) == .released(id))
        await second.shutdown()
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
        try FileManager.default.removeItem(atPath: root + "/run")
        let elsewhere = pool.root.url.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/run",
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

    /// Moves a state file that lists one lease twice aside and starts without leases.
    @Test func setsAsideRepeatedLeases() async throws {
        let pool = try PoolFixture()
        try pool.directory.prepare()
        let record = try PoolStoreTests.record()
        let store = PoolStore(file: pool.directory.stateFile)
        try store.save(PoolState(version: PoolState.currentVersion, leases: [record, record]))

        let daemon = try await pool.start()
        #expect(await daemon.summary().leases.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: pool.directory.root.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("state.json.invalid-") }, "\(names)")
        await daemon.shutdown()
    }

    /// Refuses to start on another build's state file and leaves the file and the clones alone.
    @Test func keepsStateOfAnotherBuild() throws {
        let pool = try PoolFixture()
        try pool.directory.prepare()
        let text = Data(#"{"version": 99, "leases": []}"#.utf8)
        try text.write(to: pool.directory.stateFile)
        let id = try #require(LeaseID("0a1b2c3d"))
        let clone = pool.directory.bundle(for: id).root
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: false)
        let path = pool.directory.stateFile.path(percentEncoded: false)
        #expect(throws: PoolError.unsupportedStateVersion(path: path, version: 99)) {
            try pool.daemon()
        }
        #expect(try Data(contentsOf: pool.directory.stateFile) == text)
        #expect(FileManager.default.fileExists(atPath: clone.path(percentEncoded: false)))
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
