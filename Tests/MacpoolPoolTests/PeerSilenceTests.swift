import Foundation
@testable import MacpoolPool
import Testing

/// Tests of how the daemon notices a paired Mac that stopped answering, and of the leases that
/// such a Mac held.
@Suite(.timeLimit(.minutes(1)))
struct PeerSilenceTests {
    /// Closes the connection of a paired Mac that stopped sending requests, keeps its attached
    /// lease for the reattach grace, and then ends the lease.
    @Test func closesASilentMacAndThenEndsItsLease() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source], peerSilenceLimit: .milliseconds(500))
        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        let lease = try await Self.readyLease(on: remote)

        // The test's connection never sends a heartbeat, like a Mac that went away.
        #expect(try await isClosed(remote))
        #expect(pool.logs.entries("A paired Mac stopped answering").count == 1)
        pool.clock.advance(by: 59)
        await daemon.tick()
        #expect(await daemon.summary().leases.map(\.id) == [lease.id])
        pool.clock.advance(by: 1)
        await daemon.tick()
        #expect(await eventually { await daemon.summary().leases.isEmpty })
        let ended = pool.logs.entries("A lease ended").map { $0.metadata["reason"] }
        #expect(ended == ["the client disconnected and did not reattach within 60 seconds"])
        await daemon.shutdown()
    }

    /// Keeps the lease of a silent Mac that attaches again from a new connection within the grace.
    @Test func keepsTheLeaseOfAMacThatReattaches() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source], peerSilenceLimit: .milliseconds(500))
        let alice = try LeaseLedgerTests.paired("a")
        let first = try await pool.pairedClient(of: daemon, owner: alice)
        let lease = try await Self.readyLease(on: first)
        #expect(try await isClosed(first))

        pool.clock.advance(by: 30)
        let second = try await pool.pairedClient(of: daemon, owner: alice)
        let heartbeats = Self.sendHeartbeats(on: second)
        defer { heartbeats.cancel() }
        try second.send(PoolRequest.attach(lease.id))
        #expect(try await next(second) == .ready(lease))
        pool.clock.advance(by: 60)
        await daemon.tick()
        #expect(await daemon.summary().leases.map(\.phase) == [.ready])
        second.close()
        await daemon.shutdown()
    }

    /// Serves a Mac whose connection sends heartbeats for longer than the silence limit, and
    /// closes a connection whose heartbeats come too rarely.
    @Test func keepsAConnectionThatSendsHeartbeats() async throws {
        let pool = try PoolFixture()
        let client = try makeIdentity()
        let hostKey = try listClients([KeyFingerprint(digest: client.keyDigest)], in: pool.directory)
        let daemon = try await pool.start(peers: loopbackSettings(), peerSilenceLimit: .seconds(1))
        let endpoint = try await loopback(listeningPort(of: daemon))

        let lively = try await PoolClient.connect(
            to: endpoint,
            as: client,
            hostKey: hostKey,
            heartbeat: .milliseconds(100),
        )
        let rare = try await PoolClient.connect(to: endpoint, as: client, hostKey: hostKey, heartbeat: .seconds(30))
        #expect(try await isClosed(rare))
        try await Task.sleep(for: .seconds(1))
        try lively.send(PoolRequest.status)
        guard case .status = try await next(lively) else {
            Issue.record("the host closed a connection that sent heartbeats")
            return
        }
        lively.close()
        await daemon.shutdown()
    }

    /// Sends a heartbeat on a connection every 100 milliseconds until the task is cancelled.
    ///
    /// - Parameter client: The connection.
    /// - Returns: The task that sends.
    private static func sendHeartbeats(on client: MessageChannel) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? client.send(PoolRequest.heartbeat)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Requests a lease of the offered source on a paired Mac's connection and waits until it is
    /// ready.
    ///
    /// - Parameter client: The Mac's connection.
    /// - Returns: The ready lease.
    /// - Throws: An error when the daemon does not answer with a starting and a ready lease.
    private static func readyLease(on client: MessageChannel) async throws -> LeaseSummary {
        try client.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 3600)))
        #expect(try await next(client).lease?.phase == .starting)
        let lease = try #require(await next(client).lease)
        #expect(lease.phase == .ready)
        return lease
    }
}
