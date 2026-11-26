import Foundation
@testable import MacpoolPool
import Network
import Testing

/// Tests of hosts that admit Macs that their coordinator introduced.
@Suite(.timeLimit(.minutes(1)))
struct IntroductionTests {
    /// A host with one source on 127.0.0.1 and a client key that its list does not name.
    private struct Host {
        /// The host's data directory, clock, and logs.
        let pool: PoolFixture

        /// The host's daemon.
        let daemon: PoolDaemon

        /// The host's listener.
        let endpoint: NWEndpoint

        /// The fingerprint of the host's key.
        let key: KeyFingerprint

        /// The fingerprint of the coordinator's key.
        let coordinator: KeyFingerprint

        /// Starts a host whose list of paired hosts names the coordinator.
        ///
        /// - Parameter slots: The host's slots.
        /// - Throws: An error when the daemon does not start or listen.
        init(slots: Int = 2) async throws {
            pool = try PoolFixture()
            key = try listClients([], in: pool.directory)
            coordinator = randomKey()
            var hosts = TrustList<TrustedHost>()
            hosts.insert(TrustedHost(
                key: coordinator,
                name: "coordinator",
                address: "127.0.0.1",
                port: 7373,
                pairedAt: Date(),
            ))
            try hosts.save(to: pool.directory)
            daemon = try await pool.start(
                slots: slots,
                offeredSources: ["base": pool.source],
                peers: loopbackSettings(),
            )
            endpoint = try await loopback(listeningPort(of: daemon))
        }

        /// Places a lease of the source on the host for a client.
        ///
        /// - Parameters:
        ///   - client: The fingerprint of the client's key.
        ///   - ticket: The grant's ticket.
        ///   - priority: The highest priority that the client may ask for.
        /// - Returns: The host's answer.
        func grant(_ client: KeyFingerprint, ticket: UInt64 = 1, source: String = "base", priority: Int = 0) async
            -> PoolRequest {
            let grant = HostGrant(ticket: ticket, client: client, name: "agent", source: source, priority: priority)
            return await daemon.introduce(grant, by: coordinator)
        }
    }

    /// Admits a Mac with a grant and serves one lease of the granted source. A second request
    /// without another grant fails.
    @Test func servesTheGrantedLease() async throws {
        let host = try await Host()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        #expect(await host.grant(clientKey) == .granted(ticket: 1))
        #expect(await host.daemon.summary().leases.isEmpty)

        let channel = try await PoolClient.connect(to: host.endpoint, as: client, hostKey: host.key)
        try channel.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        #expect(try await next(channel).lease?.phase == .starting)
        #expect(try await next(channel).lease?.phase == .ready)
        let record = try #require(await host.daemon.summary().leases.first)
        #expect(record.source == host.pool.source)

        try channel.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        let refusal = ClientRightsTests.refusal(
            "the coordinator placed no such lease on this host, so ask the coordinator again",
        )
        #expect(try await next(channel) == .failure(refusal))
        channel.close()
        await host.daemon.shutdown()
    }

    /// Refuses the handshake of a Mac without a grant, and of one whose grant expired.
    @Test func refusesAMacWithoutAGrant() async throws {
        let host = try await Host()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        await #expect(throws: PoolError.self) {
            try await PoolClient.connect(to: host.endpoint, as: client, hostKey: host.key)
        }
        #expect(await host.grant(clientKey) == .granted(ticket: 1))
        host.pool.clock.advance(by: 61)
        await host.daemon.tick()
        await #expect(throws: PoolError.self) {
            try await PoolClient.connect(to: host.endpoint, as: client, hostKey: host.key)
        }
        #expect(await host.daemon.hostReport()?.available == 2)
        await host.daemon.shutdown()
    }

    /// Declines grants for a source that the host does not offer, for a blocked Mac, and beyond
    /// the available slots. A kept grant counts against the available slots.
    @Test func declinesGrantsItCannotServe() async throws {
        let host = try await Host(slots: 1)
        let blocked = randomKey()
        try listClients([blocked], in: host.pool.directory, blocked: [blocked])
        #expect(await host.grant(randomKey(), source: "other")
            == .declined(ticket: 1, reason: "this host does not offer the source"))
        #expect(await host.grant(blocked) == .declined(ticket: 1, reason: "this host blocked the Mac"))
        #expect(await host.grant(randomKey(), ticket: 2) == .granted(ticket: 2))
        #expect(await host.daemon.hostReport()?.available == 0)
        #expect(await host.grant(randomKey(), ticket: 3)
            == .declined(ticket: 3, reason: "this host has no available slot"))
        await host.daemon.shutdown()
    }

    /// Lets the owner of a lease that a grant started attach again after its connection broke,
    /// while the list of paired hosts names the coordinator.
    @Test func keepsTheOwnerOfAnIntroducedLease() async throws {
        let host = try await Host()
        let client = try makeIdentity()
        let clientKey = KeyFingerprint(digest: client.keyDigest)
        #expect(await host.grant(clientKey) == .granted(ticket: 1))
        let first = try await PoolClient.connect(to: host.endpoint, as: client, hostKey: host.key)
        try first.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        let lease = try #require(try await next(first).lease)
        #expect(try await next(first).lease?.phase == .ready)
        first.close()

        let second = try await PoolClient.connect(to: host.endpoint, as: client, hostKey: host.key)
        try second.send(PoolRequest.attach(lease.id))
        #expect(try await next(second).lease?.phase == .ready)
        second.close()

        try TrustedHost.remove(host.coordinator, from: host.pool.directory)
        await #expect(throws: PoolError.self) {
            let third = try await PoolClient.connect(to: host.endpoint, as: client, hostKey: host.key)
            try third.send(PoolRequest.status)
            _ = try await next(third)
        }
        await host.daemon.shutdown()
    }
}
