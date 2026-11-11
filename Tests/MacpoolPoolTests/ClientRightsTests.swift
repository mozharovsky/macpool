import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the limits of paired clients.
@Suite(.timeLimit(.minutes(1)))
struct ClientRightsTests {
    /// Lets a paired client ask for priorities up to the ceiling in its record. The daemon reads
    /// the record again for every lease request.
    @Test func capsPrioritiesAtTheCeiling() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let owner = try LeaseLedgerTests.paired("a")
        let remote = try await pool.pairedClient(of: daemon, owner: owner, priorityCeiling: 5)
        let terms = { (priority: Int) in
            LeaseTerms(source: "base", timeToLive: 60, priority: priority, detached: true)
        }

        try remote.send(PoolRequest.lease(terms(6)))
        #expect(try await next(remote) == .failure(Self.refusal("this Mac may ask for a priority of at most 5")))
        try remote.send(PoolRequest.lease(terms(5)))
        #expect(try await next(remote).lease?.phase == .starting)
        #expect(try await next(remote).lease?.phase == .ready)

        try Self.record(owner, priorityCeiling: 0, in: pool.directory)
        try remote.send(PoolRequest.lease(terms(1)))
        #expect(try await next(remote) == .failure(Self.refusal("this Mac may ask for a priority of at most 0")))
        try Self.record(owner, priorityCeiling: 0, isBlocked: true, in: pool.directory)
        try remote.send(PoolRequest.lease(terms(0)))
        #expect(try await next(remote) == .failure(Self.refusal("the host no longer accepts this Mac")))
        try TrustList<TrustedClient>().save(to: pool.directory)
        try remote.send(PoolRequest.lease(terms(0)))
        #expect(try await next(remote) == .failure(Self.refusal("the host no longer accepts this Mac")))
        await daemon.shutdown()
    }

    /// Keeps at most as many of a paired client's requests in the queue as the host has slots.
    /// The local user has no such limit.
    @Test func limitsTheQueueOfAPairedClient() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(slots: 2, offeredSources: ["base": pool.source])
        let remote = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("a"))
        let terms = LeaseTerms(source: "base", timeToLive: 60)
        for _ in 0 ..< 2 {
            try remote.send(PoolRequest.lease(terms))
            #expect(try await next(remote).lease?.phase == .starting)
            #expect(try await next(remote).lease?.phase == .ready)
        }
        for position in 1 ... 2 {
            try remote.send(PoolRequest.lease(terms))
            #expect(try await next(remote) == .queued(position: position))
        }
        try remote.send(PoolRequest.lease(terms))
        let full = Self.refusal("this Mac already has as many requests in the queue as the host has slots")
        #expect(try await next(remote) == .failure(full))

        let local = try await PoolClient.connect(to: pool.directory)
        for position in 3 ... 5 {
            try local.send(PoolRequest.lease(pool.terms()))
            #expect(try await next(local) == .queued(position: position))
        }
        #expect(await daemon.summary().queue.count == 5)
        local.close()
        remote.close()
        await daemon.shutdown()
    }

    /// Returns the text of an invalid request's failure.
    ///
    /// - Parameter reason: The reason of the refusal.
    /// - Returns: The message of the failure reply.
    static func refusal(_ reason: String) -> String {
        PoolError.invalidRequest(reason: reason).description
    }

    /// Writes a paired client's record into the list of paired clients.
    ///
    /// - Parameters:
    ///   - owner: The paired client.
    ///   - priorityCeiling: The highest priority that the client may ask for.
    ///   - isBlocked: Whether the host refuses the client.
    ///   - directory: The host's data directory.
    /// - Throws: An error when the list cannot be read or written.
    static func record(
        _ owner: LeaseOwner,
        priorityCeiling: Int,
        isBlocked: Bool = false,
        in directory: PoolDirectory,
    ) throws {
        guard case let .client(key) = owner else {
            return
        }
        var clients = try TrustList<TrustedClient>.load(from: directory)
        clients.insert(TrustedClient(
            key: key,
            name: "client",
            pairedAt: Date(),
            isBlocked: isBlocked,
            priorityCeiling: priorityCeiling,
        ))
        try clients.save(to: directory)
    }
}
