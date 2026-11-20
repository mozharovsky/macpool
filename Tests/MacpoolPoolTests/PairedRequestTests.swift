import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the requests that a paired Mac sends to a host over TLS.
@Suite(.timeLimit(.minutes(1)))
struct PairedRequestTests {
    /// Leases an offered source on a connection for requests, and lists, renews, and releases the
    /// lease with one request each.
    @Test func leasesListsRenewsAndReleasesOverTLS() async throws {
        let pool = try PoolFixture()
        let mac = try PairedMacFixture(trustedBy: pool)
        let daemon = try await pool.start(offeredSources: ["base": pool.source], peers: loopbackSettings())
        let host = try await mac.host(of: daemon)

        let channel = try await PoolClient.connect(to: host, directory: mac.directory)
        try channel.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 600)))
        #expect(try await next(channel).lease?.phase == .starting)
        let lease = try #require(await next(channel).lease)
        #expect(lease.phase == .ready)
        #expect(lease.source == "base")
        #expect(lease.bundle == nil)

        let status = try await PoolClient.send(.status, to: host, directory: mac.directory)
        #expect(status == .status(PoolSummary(slots: 2, leases: [lease], queue: [])))
        pool.clock.advance(by: 100)
        let renewed = try await PoolClient.send(.renew(lease.id), to: host, directory: mac.directory)
        #expect(renewed.lease?.expiresAt == pool.clock.now.addingTimeInterval(600))
        let released = try await PoolClient.send(.release(lease.id), to: host, directory: mac.directory)
        #expect(released == .released(lease.id))
        #expect(try await next(channel) == .ended(lease.id, reason: "released by a client"))
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        channel.close()
        await daemon.shutdown()
    }

    /// Passes the host's refusal on as an error and refuses a heartbeat, which gets no reply.
    @Test func reportsRefusalsOfOneRequest() async throws {
        let pool = try PoolFixture()
        let mac = try PairedMacFixture(trustedBy: pool)
        let daemon = try await pool.start(peers: loopbackSettings())
        let host = try await mac.host(of: daemon)
        let unknown = try #require(LeaseID("0a1b2c3d"))

        await #expect(throws: PoolError.daemonRefused(message: PoolError.unknownLease(id: "0a1b2c3d").description)) {
            try await PoolClient.send(.release(unknown), to: host, directory: mac.directory)
        }
        await #expect(throws: PoolError.invalidRequest(reason: "the daemon does not reply to a heartbeat")) {
            try await PoolClient.send(.heartbeat, to: host, directory: mac.directory)
        }
        await daemon.shutdown()
    }

    /// Keeps a connection for requests that waits without a request of its own, because the
    /// connection sends heartbeats.
    @Test func keepsAWaitingConnectionWithHeartbeats() async throws {
        let pool = try PoolFixture()
        let mac = try PairedMacFixture(trustedBy: pool)
        let daemon = try await pool.start(peers: loopbackSettings())
        let host = try await mac.host(of: daemon)
        let channel = try await PoolClient.connect(
            to: host,
            directory: mac.directory,
            timeout: .seconds(10),
            heartbeat: .milliseconds(50),
        )
        let empty = PoolReply.status(PoolSummary(slots: 2, leases: [], queue: []))
        // The reply shows that the daemon serves the connection before the clock moves.
        try channel.send(PoolRequest.status)
        #expect(try await next(channel) == empty)

        pool.clock.advance(by: 59)
        // Heartbeats in this second reach the daemon at the awake time of 59 seconds.
        try await Task.sleep(for: .seconds(1))
        pool.clock.advance(by: 59)
        await daemon.tick()
        #expect(pool.logs.entries("A paired Mac stopped answering").isEmpty)
        try channel.send(PoolRequest.status)
        #expect(try await next(channel) == empty)
        channel.close()
        await daemon.shutdown()
    }
}

/// Another Mac with its own data directory and key, which a fixture's host lists as a client.
private struct PairedMacFixture {
    /// The fixture whose data directory holds the Mac's key.
    private let fixture: PoolFixture

    /// The fingerprint of the host's key.
    let hostKey: KeyFingerprint

    /// The Mac's data directory.
    var directory: PoolDirectory {
        fixture.directory
    }

    /// Creates the Mac's key and replaces the host's list of paired clients with the Mac.
    ///
    /// - Parameter pool: The host's fixture.
    /// - Throws: An error when a key or the list cannot be written.
    init(trustedBy pool: PoolFixture) throws {
        fixture = try PoolFixture()
        let identity = try MacIdentity.loadOrCreate(in: fixture.directory)
        hostKey = try listClients([KeyFingerprint(digest: identity.keyDigest)], in: pool.directory)
    }

    /// Returns the record of a listening daemon as this Mac's list of paired hosts would hold it.
    ///
    /// - Parameter daemon: The host's daemon.
    /// - Returns: The host.
    /// - Throws: An error when the daemon does not listen.
    func host(of daemon: PoolDaemon) async throws -> TrustedHost {
        try await TrustedHost(
            key: hostKey,
            name: "host",
            address: "127.0.0.1",
            port: listeningPort(of: daemon),
            pairedAt: Date(),
        )
    }
}
