import Foundation
@testable import MacpoolPool
import Testing

/// Tests of a coordinator that places lease requests on the hosts that report to it.
@Suite(.timeLimit(.minutes(1)))
struct PlacementTests {
    /// A coordinator with one reporting host and one client, both on paired connections.
    private struct Coordinator {
        /// The coordinator's data directory, clock, and logs.
        let pool: PoolFixture

        /// The coordinator's daemon.
        let daemon: PoolDaemon

        /// The connection on which the host reports and answers grants.
        let host: MessageChannel

        /// The fingerprint of the host's key.
        let hostKey: KeyFingerprint

        /// The connection on which the client requests leases.
        let client: MessageChannel

        /// The fingerprint of the client's key.
        let clientKey: KeyFingerprint

        /// Starts the coordinator and waits until the host's first report arrived.
        ///
        /// - Parameters:
        ///   - available: The free slots in the host's first report.
        ///   - slots: The coordinator's own slots.
        ///   - offersBase: Whether the coordinator itself offers the source `base`.
        /// - Throws: An error when the daemon does not start or the report does not arrive.
        init(available: Int, slots: Int = 1, offersBase: Bool = false) async throws {
            pool = try PoolFixture()
            daemon = try await pool.start(slots: slots, offeredSources: offersBase ? ["base": pool.source] : [:])
            let hostOwner = try LeaseLedgerTests.paired("a")
            let clientOwner = try LeaseLedgerTests.paired("b")
            guard case let .client(hostKey) = hostOwner, case let .client(clientKey) = clientOwner else {
                throw PoolError.connectionClosed
            }
            self.hostKey = hostKey
            self.clientKey = clientKey
            host = try await pool.pairedClient(of: daemon, owner: hostOwner, mayHost: true, name: "mini")
            client = try await pool.pairedClient(of: daemon, owner: clientOwner, priorityCeiling: 1, name: "agent")
            try report(available: available)
            let daemon = daemon
            guard await eventually({ await daemon.summary().hosts.map(\.report) == [PlacementTests.report(available)] })
            else {
                throw PoolError.connectionClosed
            }
        }

        /// Sends a report from the host.
        ///
        /// - Parameter available: The free slots in the report.
        /// - Throws: An error when the message cannot be sent.
        func report(available: Int) throws {
            try host.send(PoolRequest.report(PlacementTests.report(available)))
        }

        /// Requests a lease of `base` from the client.
        ///
        /// - Parameter priority: The request's priority.
        /// - Throws: An error when the message cannot be sent.
        func lease(priority: Int = 0) throws {
            try client.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60, priority: priority)))
        }

        /// Waits for the next grant on the host's connection.
        ///
        /// - Returns: The grant.
        /// - Throws: An error when another message or none arrives.
        func nextGrant() async throws -> HostGrant {
            guard case let .grant(grant) = try await next(host) else {
                throw PoolError.malformedMessage(reason: "the coordinator sent no grant")
            }
            return grant
        }

        /// The host's place as the client receives it.
        var placed: PlacedHost {
            PlacedHost(name: "mini", key: hostKey, address: "192.0.2.10", port: 7373)
        }

        /// Closes the connections and stops the daemon.
        func stop() async {
            host.close()
            client.close()
            await daemon.shutdown()
        }
    }

    /// Returns a report of a host with two slots and the source `base`.
    ///
    /// - Parameter available: The free slots.
    /// - Returns: The report.
    static func report(_ available: Int) -> HostReport {
        HostReport(
            address: "192.0.2.10",
            port: 7373,
            slots: 2,
            leases: 2 - available,
            queued: 0,
            available: available,
            sources: ["base"],
        )
    }

    /// Sends a grant to a host with a free slot and sends the client to the host once the host
    /// accepts.
    @Test func placesARequestOnAHost() async throws {
        let coordinator = try await Coordinator(available: 1)
        try coordinator.lease(priority: 1)
        let grant = try await coordinator.nextGrant()
        #expect(grant == HostGrant(
            ticket: grant.ticket,
            client: coordinator.clientKey,
            name: "agent",
            source: "base",
            priority: 1,
        ))
        try coordinator.host.send(PoolRequest.granted(ticket: grant.ticket))
        #expect(try await next(coordinator.client) == .placed(coordinator.placed))
        #expect(coordinator.pool.logs.entries("A host took a lease that this coordinator placed").count == 1)
        #expect(await coordinator.daemon.summary().queue.isEmpty)
        await coordinator.stop()
    }

    /// Keeps a request in the queue until a host has a free slot, and offers it again after the
    /// host declined it and reported again.
    @Test func queuesUntilAHostTakesTheRequest() async throws {
        let coordinator = try await Coordinator(available: 0)
        try coordinator.lease()
        #expect(try await next(coordinator.client) == .queued(position: 1))
        let queue = await coordinator.daemon.summary().queue
        #expect(queue.map(\.source) == ["base"])

        try coordinator.report(available: 1)
        let first = try await coordinator.nextGrant()
        try coordinator.host.send(PoolRequest.declined(ticket: first.ticket, reason: "busy"))
        #expect(try await next(coordinator.client) == .queued(position: 1))

        try coordinator.report(available: 1)
        let second = try await coordinator.nextGrant()
        #expect(second.ticket != first.ticket)
        try coordinator.host.send(PoolRequest.granted(ticket: second.ticket))
        #expect(try await next(coordinator.client) == .placed(coordinator.placed))
        await coordinator.stop()
    }

    /// Treats a grant without an answer as declined after the grant timeout, and withdraws the
    /// grants of a host whose connection closed.
    @Test func withdrawsUnansweredGrants() async throws {
        let coordinator = try await Coordinator(available: 1)
        try coordinator.lease()
        _ = try await coordinator.nextGrant()
        coordinator.pool.clock.advance(by: 6)
        await coordinator.daemon.tick()
        #expect(try await next(coordinator.client) == .queued(position: 1))
        #expect(coordinator.pool.logs.entries("A host did not answer a lease that this coordinator placed").count == 1)

        try coordinator.report(available: 1)
        _ = try await coordinator.nextGrant()
        coordinator.host.close()
        #expect(try await next(coordinator.client) == .queued(position: 1))
        await coordinator.stop()
    }

    /// Serves a request with its own ledger when it has at least as many free slots as the best
    /// host, and sends the next request to the host.
    @Test func prefersTheMostFreeSlots() async throws {
        let coordinator = try await Coordinator(available: 1, offersBase: true)
        try coordinator.lease()
        #expect(try await next(coordinator.client).lease?.phase == .starting)

        let second = try await coordinator.pool.pairedClient(
            of: coordinator.daemon,
            owner: LeaseLedgerTests.paired("c"),
            name: "second",
        )
        try second.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        let grant = try await coordinator.nextGrant()
        #expect(grant.name == "second")
        second.close()
        await coordinator.stop()
    }

    /// Serves requests for sources that no host reports with its own ledger, and checks the
    /// limits of the Mac's record before a request waits for a host.
    @Test func checksRequestsBeforePlacement() async throws {
        let coordinator = try await Coordinator(available: 0)
        try coordinator.client.send(PoolRequest.lease(LeaseTerms(source: "other", timeToLive: 60)))
        let unknown = ClientRightsTests.refusal("the host does not offer the requested source")
        #expect(try await next(coordinator.client) == .failure(unknown))

        try coordinator.lease(priority: 2)
        let ceiling = ClientRightsTests.refusal("this Mac may ask for a priority of at most 1")
        #expect(try await next(coordinator.client) == .failure(ceiling))

        try coordinator.lease()
        #expect(try await next(coordinator.client) == .queued(position: 1))
        coordinator.client.close()
        let daemon = coordinator.daemon
        #expect(await eventually { await daemon.summary().queue.isEmpty })
        await coordinator.stop()
    }

    /// Refuses a stream on a connection whose request waits in the coordinator's queue.
    @Test func refusesAStreamWhileARequestWaits() async throws {
        let coordinator = try await Coordinator(available: 0, offersBase: true)
        let detached = LeaseTerms(source: "base", timeToLive: 60, detached: true)
        try coordinator.client.send(PoolRequest.lease(detached))
        #expect(try await next(coordinator.client).lease?.phase == .starting)
        let lease = try #require(try await next(coordinator.client).lease)
        #expect(lease.phase == .ready)
        let waiting = try await coordinator.pool.pairedClient(
            of: coordinator.daemon,
            owner: .client(coordinator.clientKey),
            priorityCeiling: 1,
            name: "agent",
        )
        try waiting.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        #expect(try await next(waiting) == .queued(position: 1))

        try waiting.send(PoolRequest.connect(lease.id))
        let busy = ClientRightsTests.refusal(
            "a connection that waits for or holds a lease cannot carry a stream. Open another connection",
        )
        #expect(try await next(waiting) == .failure(busy))
        waiting.close()
        await coordinator.stop()
    }

    /// Serves a paired Mac with its own ledger when the Mac brings a grant from this daemon's own
    /// coordinator, although a host that reports to this daemon has more free slots.
    @Test func servesAGrantOfItsOwnCoordinator() async throws {
        let pool = try PoolFixture()
        _ = try listClients([], in: pool.directory)
        let upstream = randomKey()
        var hosts = TrustList<TrustedHost>()
        hosts.insert(TrustedHost(key: upstream, name: "hub", address: "192.0.2.40", port: 7373, pairedAt: Date()))
        try hosts.save(to: pool.directory)
        let daemon = try await pool.start(slots: 2, offeredSources: ["base": pool.source], peers: loopbackSettings())
        // The daemon declines grants until its listener has a port.
        _ = try await listeningPort(of: daemon)
        let hostOwner = try LeaseLedgerTests.paired("a")
        let host = try await pool.pairedClient(of: daemon, owner: hostOwner, mayHost: true, name: "mini")
        try host.send(PoolRequest.report(Self.report(2)))
        #expect(await eventually { await daemon.summary().hosts.count == 1 })
        let clientOwner = try LeaseLedgerTests.paired("b")
        guard case let .client(clientKey) = clientOwner else {
            return
        }
        let client = try await pool.pairedClient(of: daemon, owner: clientOwner, name: "agent")
        let grant = HostGrant(ticket: 1, client: clientKey, name: "agent", source: "base", priority: 0)
        #expect(await daemon.introduce(grant, by: upstream) == .granted(ticket: 1))

        try client.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        #expect(try await next(client).lease?.phase == .starting)
        #expect(await daemon.hostReport()?.available == 1)
        host.close()
        client.close()
        await daemon.shutdown()
    }

    /// Places a client's request through a real coordinator on a host that reports to it over
    /// TLS. The client then leases from the host, which admits it through the grant.
    @Test func leasesThroughTheCoordinator() async throws {
        let coordinator = try await PairingHost(name: "coordinator")
        let hostInvitation = try await coordinator.invite(mayHost: true)
        let hostPool = try PoolFixture()
        _ = try await PoolClient.pair(using: hostInvitation.code, name: "mini", directory: hostPool.directory)
        hostInvitation.channel.close()
        let hostKey = try KeyFingerprint(digest: MacIdentity.loadOrCreate(in: hostPool.directory).keyDigest)
        var settings = loopbackSettings()
        settings.coordinator = "coordinator"
        let host = try await hostPool.start(slots: 2, offeredSources: ["base": hostPool.source], peers: settings)
        #expect(await eventually { await coordinator.daemon.summary().hosts.map(\.key) == [hostKey] })

        let clientInvitation = try await coordinator.invite()
        let clientDirectory = try coordinator.clientDirectory()
        _ = try await PoolClient.pair(using: clientInvitation.code, name: "agent", directory: clientDirectory)
        clientInvitation.channel.close()
        let paired = try TrustedHost.named("coordinator", in: clientDirectory)
        let request = try await PoolClient.connect(to: paired, directory: clientDirectory)
        try request.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        guard case let .placed(placed) = try await next(request) else {
            Issue.record("the coordinator did not place the request")
            return
        }
        request.close()
        #expect(placed.key == hostKey)
        #expect(placed.name == "mini")

        let record = try TrustedHost.introduce(placed, in: clientDirectory)
        let channel = try await PoolClient.connect(to: record, directory: clientDirectory)
        try channel.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        #expect(try await next(channel).lease?.phase == .starting)
        #expect(try await next(channel).lease?.phase == .ready)
        #expect(await host.summary().leases.count == 1)
        channel.close()
        await host.shutdown()
        await coordinator.stop()
    }
}
