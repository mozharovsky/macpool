import Foundation
@testable import MacpoolPool
import Testing

/// Tests of how the daemon notices a paired Mac that stopped answering, and of the leases that
/// such a Mac held.
///
/// The daemon measures silence with the fixture's awake time and checks it at each tick, so the
/// tests advance the clock instead of waiting.
@Suite(.timeLimit(.minutes(1)))
struct PeerSilenceTests {
    /// Closes the connection of a paired Mac that stopped sending requests, keeps its attached
    /// lease for the reattach grace, and then ends the lease.
    @Test func closesASilentMacAndThenEndsItsLease() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        let lease = try await Self.readyLease(on: remote)

        // The test's connection sends nothing more, like a Mac that went away.
        pool.clock.advance(by: 59)
        await daemon.tick()
        #expect(pool.logs.entries("A paired Mac stopped answering").isEmpty)
        pool.clock.advance(by: 1)
        await daemon.tick()
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
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let alice = try LeaseLedgerTests.paired("a")
        let first = try await pool.pairedClient(of: daemon, owner: alice)
        let lease = try await Self.readyLease(on: first)
        pool.clock.advance(by: 60)
        await daemon.tick()
        #expect(try await isClosed(first))

        pool.clock.advance(by: 30)
        let second = try await pool.pairedClient(of: daemon, owner: alice)
        try second.send(PoolRequest.attach(lease.id))
        #expect(try await next(second) == .ready(lease))
        // The grace of the first connection's lease ends here.
        pool.clock.advance(by: 30)
        await daemon.tick()
        #expect(await daemon.summary().leases.map(\.phase) == [.ready])
        await daemon.shutdown()
    }

    /// Counts only the time that this Mac stays awake toward a paired Mac's silence, so the first
    /// tick after a long sleep or a new system time keeps the connection and its lease.
    @Test func measuresSilenceOnlyWhileAwake() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        let lease = try await Self.readyLease(on: remote)

        pool.clock.advance(by: 30)
        await daemon.tick()
        // A sleep of half an hour, and then a system time that moves back an hour. The lease's
        // time to live of an hour covers both.
        pool.clock.jump(by: 1800)
        await daemon.tick()
        pool.clock.jump(by: -3600)
        await daemon.tick()
        #expect(pool.logs.entries("A paired Mac stopped answering").isEmpty)
        pool.clock.advance(by: 29)
        await daemon.tick()
        #expect(pool.logs.entries("A paired Mac stopped answering").isEmpty)
        #expect(await daemon.summary().leases.map(\.id) == [lease.id])
        pool.clock.advance(by: 1)
        await daemon.tick()
        #expect(try await isClosed(remote))
        #expect(pool.logs.entries("A paired Mac stopped answering").count == 1)
        await daemon.shutdown()
    }

    /// Keeps the connections of a paired Mac that sends requests within the limit and of the
    /// local user, and closes the connection of a Mac that stays silent.
    @Test func keepsConnectionsThatSendRequests() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let lively = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        let silent = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("b"))
        let local = try await PoolClient.connect(to: pool.directory)
        let empty = PoolReply.status(PoolSummary(slots: 2, leases: [], queue: []))
        let localStatus = PoolReply.status(PoolSummary(
            slots: 2,
            leases: [],
            queue: [],
            images: pool.directory.images(),
        ))
        // The reply shows that the daemon accepted the local connection before the clock moves.
        try local.send(PoolRequest.status)
        #expect(try await next(local) == localStatus)

        pool.clock.advance(by: 30)
        await daemon.tick()
        #expect(pool.logs.entries("A paired Mac stopped answering").isEmpty)
        // The daemon answers no heartbeat, so the next reply belongs to the status request.
        try lively.send(PoolRequest.heartbeat)
        try lively.send(PoolRequest.status)
        #expect(try await next(lively) == empty)
        pool.clock.advance(by: 30)
        await daemon.tick()
        #expect(try await isClosed(silent))
        #expect(pool.logs.entries("A paired Mac stopped answering").count == 1)
        try lively.send(PoolRequest.status)
        #expect(try await next(lively) == empty)
        try local.send(PoolRequest.status)
        #expect(try await next(local) == localStatus)
        await daemon.shutdown()
    }

    /// Sends no failure for a heartbeat while the list of paired Macs cannot be read.
    @Test func answersNoHeartbeatWhileTheListIsUnreadable() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        let list = pool.directory.trustDirectory.appending(path: "clients.json")
        let saved = try Data(contentsOf: list)
        try Data("{".utf8).write(to: list)

        try remote.send(PoolRequest.heartbeat)
        #expect(await eventually { !pool.logs.entries("The list of paired clients cannot be read").isEmpty })
        try saved.write(to: list)
        try remote.send(PoolRequest.status)
        #expect(try await next(remote) == .status(PoolSummary(slots: 2, leases: [], queue: [])))
        await daemon.shutdown()
    }

    /// Refuses to send a heartbeat as a request that waits for a reply.
    @Test func refusesToWaitForTheReplyToAHeartbeat() async throws {
        let pool = try PoolFixture()
        await #expect(throws: PoolError.invalidRequest(reason: "the daemon does not reply to a heartbeat")) {
            try await PoolClient.send(.heartbeat, to: pool.directory)
        }
    }

    /// Sends heartbeats at the given interval until the connection closes.
    @Test func sendsHeartbeatsUntilTheConnectionCloses() async throws {
        let directory = try ShortDirectory()
        let socket = directory.url.appending(path: "test.sock")
        let listener = try await SocketListener(socket: socket)
        defer { listener.close() }
        let client = try await MessageChannel.connect(to: socket)
        var connections = listener.connections.makeAsyncIterator()
        let server = try #require(await connections.next())
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            server.close()
        }
        defer { watchdog.cancel() }

        PoolClient.startHeartbeat(on: client, every: .milliseconds(20))
        #expect(try await server.receive(PoolRequest.self) == .heartbeat)
        #expect(try await server.receive(PoolRequest.self) == .heartbeat)
        await client.finish()
        while let request = try await server.receive(PoolRequest.self) {
            #expect(request == .heartbeat)
        }
        server.close()
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
