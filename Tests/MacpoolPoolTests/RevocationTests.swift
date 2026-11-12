import Foundation
@testable import MacpoolPool
import Testing

/// Tests of revoking paired Macs and of the record check before each request of a paired Mac.
@Suite(.timeLimit(.minutes(1)))
struct RevocationTests {
    /// The refusal that a paired Mac receives once the host no longer accepts it.
    static let notAccepted = PoolReply.failure(ClientRightsTests.refusal("the host no longer accepts this Mac"))

    /// Blocks a Mac with two connections, a waiting request, an attached lease, and a detached
    /// lease. The connections close, the request leaves the queue, and the attached lease ends.
    /// The detached lease ends only on a second revocation with `endLeases`.
    @Test func revokesAPairedMac() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(slots: 2, offeredSources: ["base": pool.source])
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let first = try await pool.pairedClient(of: daemon, owner: owner, priorityCeiling: 3)
        let second = try await pool.pairedClient(of: daemon, owner: owner, priorityCeiling: 3)
        let before = try #require(TrustList<TrustedClient>.load(from: pool.directory)[key])

        try first.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60, detached: true)))
        #expect(try await next(first).lease?.phase == .starting)
        let detached = try #require(try await next(first).lease)
        try second.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        #expect(try await next(second).lease?.phase == .starting)
        let attached = try #require(try await next(second).lease)
        try second.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        #expect(try await next(second) == .queued(position: 1))

        let revoked = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
        #expect(revoked == .revoked(PairedMac(name: "client", key: key), connections: 2, leases: 1))
        #expect(try await next(first) == Self.notAccepted)
        #expect(try await isClosed(first))
        #expect(try await next(second) == .ended(attached.id, reason: "the host revoked this Mac"))
        #expect(try await next(second) == Self.notAccepted)
        #expect(try await isClosed(second))
        var summary = await daemon.summary()
        #expect(summary.queue.isEmpty)
        #expect(summary.leases.filter { $0.phase != .stopping }.map(\.id) == [detached.id])
        var blocked = before
        blocked.isBlocked = true
        #expect(try TrustList<TrustedClient>.load(from: pool.directory).records == [blocked])

        let again = try await PoolClient.send(.revoke(key: key.rawValue, endLeases: true), to: pool.directory)
        #expect(again == .revoked(PairedMac(name: "client", key: key), connections: 0, leases: 1))
        summary = await daemon.summary()
        #expect(summary.leases.allSatisfy { $0.phase == .stopping })
        #expect(pool.logs.entries("Revoked a paired Mac").count == 2)
        await daemon.shutdown()
    }

    /// Refuses a revocation by name, by an unknown key, by a short key of two Macs, or from a
    /// paired Mac.
    @Test func revokesOnlyByKey() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        // The two keys share the leading 10 bytes and therefore the short key.
        let twins = try ["0", "1"].map { digit in
            try #require(KeyFingerprint(String(repeating: "ab", count: 10) + String(repeating: digit, count: 44)))
        }
        for twin in twins {
            try ClientRightsTests.record(.client(twin), priorityCeiling: 0, in: pool.directory)
        }
        let paired = try LeaseLedgerTests.paired("c")
        let remote = try await pool.pairedClient(of: daemon, owner: paired)
        let shortKey = try #require(twins.first?.shortKey)
        let refusals = [
            ("client", "no paired Mac has the key client. Give its short key or its full key"),
            (
                "mzxw-6ytb-oi2d-k3lq",
                "no paired Mac has the key mzxw-6ytb-oi2d-k3lq. Give its short key or its full key",
            ),
            (shortKey, "2 paired Macs have the short key \(shortKey). Give the full key"),
        ]
        for (text, reason) in refusals {
            await #expect(throws: PoolError.daemonRefused(message: ClientRightsTests.refusal(reason)), "\(text)") {
                try await PoolClient.send(.revoke(key: text), to: pool.directory)
            }
        }
        let full = try await PoolClient.send(.revoke(key: twins[1].rawValue), to: pool.directory)
        #expect(full == .revoked(PairedMac(name: "client", key: twins[1]), connections: 0, leases: 0))

        try remote.send(PoolRequest.revoke(key: twins[0].rawValue))
        #expect(try await next(remote) ==
            .failure(ClientRightsTests.refusal("only the host's own user can revoke Macs")))
        let list = try TrustList<TrustedClient>.load(from: pool.directory)
        #expect(list.records.map(\.isBlocked) == [false, true, false])
        remote.close()
        await daemon.shutdown()
    }

    /// Changes nothing when the list cannot be read. The revocation fails, and the Mac's
    /// connection stays open.
    @Test func changesNothingWhenTheListCannotBeRead() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        let list = TrustList<TrustedClient>.file(in: pool.directory)
        let saved = try Data(contentsOf: list)
        try Data("{".utf8).write(to: list)
        await #expect(throws: PoolError.self) {
            try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
        }
        try saved.write(to: list)
        try remote.send(PoolRequest.status)
        guard case .status = try await next(remote) else {
            Issue.record("the connection did not stay open")
            return
        }
        #expect(try TrustList<TrustedClient>.load(from: pool.directory)[key]?.isBlocked == false)
        remote.close()
        await daemon.shutdown()
    }

    /// Ends the connection of a Mac at its next request once the list no longer names the Mac or
    /// blocks it.
    @Test func closesConnectionsOfRemovedOrBlockedMacs() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let removed = try LeaseLedgerTests.paired("a")
        let blocked = try LeaseLedgerTests.paired("b")
        let removedChannel = try await pool.pairedClient(of: daemon, owner: removed)
        let blockedChannel = try await pool.pairedClient(of: daemon, owner: blocked)
        guard case let .client(blockedKey) = blocked else {
            return
        }

        try TrustList<TrustedClient>().save(to: pool.directory)
        try ClientRightsTests.record(blocked, priorityCeiling: 0, isBlocked: true, in: pool.directory)
        try removedChannel.send(PoolRequest.status)
        try blockedChannel.send(PoolRequest.status)
        for channel in [removedChannel, blockedChannel] {
            #expect(try await next(channel) == Self.notAccepted)
            #expect(try await isClosed(channel))
        }
        let records = try TrustList<TrustedClient>.load(from: pool.directory).records
        #expect(records.map(\.key) == [blockedKey])
        #expect(records.map(\.isBlocked) == [true])
        await daemon.shutdown()
    }
}
