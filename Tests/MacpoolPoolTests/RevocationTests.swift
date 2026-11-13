import Foundation
import Logging
@testable import MacpoolPool
import Testing

/// Tests of revoking paired Macs, of Macs that ask the host to forget them, and of the record
/// check before each request of a paired Mac.
@Suite(.timeLimit(.minutes(1)))
struct RevocationTests {
    /// The refusal that a paired Mac receives once the host no longer accepts it.
    static let notAccepted = PoolReply.failure(ClientRightsTests.refusal("the host no longer accepts this Mac"))

    /// The end of a revocation's failure when the daemon keeps the block only in memory.
    static let staysBlocked = "The Mac stays blocked until the daemon restarts. Revoke it again once the list can be "
        + "saved"

    /// The log message of a revocation's last failed save.
    static let failedSave = "The host cannot save the list of paired Macs for a revocation"

    /// The log message of a revocation that keeps the block only in memory or blocks nothing.
    static let unblocked = "The host closed a revoked Mac's connections but cannot block it"

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

    /// Closes the connections of the named Mac when the list of paired clients cannot be read,
    /// keeps the block in memory, and reports the list's error.
    @Test func closesConnectionsWhenTheListCannotBeRead() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        try Data("{".utf8).write(to: TrustList<TrustedClient>.file(in: pool.directory))

        do {
            _ = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
            Issue.record("the revocation succeeded without a list")
        } catch let .daemonRefused(message) {
            #expect(message
                .hasPrefix("the host closed the Mac's connections, but it cannot read its list of paired Macs"))
            #expect(message.hasSuffix(Self.staysBlocked))
        }
        #expect(try await next(remote) == Self.notAccepted)
        #expect(try await isClosed(remote))
        #expect(await daemon.unsavedBlocks == [key])
        await daemon.shutdown()
    }

    /// Closes the connections of a revoked Mac when the block cannot be saved, and refuses the
    /// Mac's requests until a later revocation saves the block.
    @Test func reportsABlockThatCannotBeSaved() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        try Self.setImmutable(true, listIn: pool.directory)
        defer { try? Self.setImmutable(false, listIn: pool.directory) }

        do {
            _ = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
            Issue.record("the revocation succeeded without a saved block")
        } catch let .daemonRefused(message) {
            #expect(message
                .hasPrefix("the host closed the Mac's connections, but the save of the block failed"))
            #expect(message.hasSuffix(Self.staysBlocked))
        }
        #expect(try await next(remote) == Self.notAccepted)
        #expect(try await isClosed(remote))
        #expect(try TrustList<TrustedClient>.load(from: pool.directory)[key]?.isBlocked == false)
        #expect(await daemon.unsavedBlocks == [key])
        let logs = pool.logs
        #expect(logs.entries(Self.failedSave).map(\.level) == [.error])
        #expect(logs.entries(Self.unblocked).map(\.level) == [.error])

        try Self.setImmutable(false, listIn: pool.directory)
        let late = try await pool.pairedClient(of: daemon, owner: owner)
        try late.send(PoolRequest.status)
        #expect(try await next(late) == Self.notAccepted)
        #expect(try await isClosed(late))
        let again = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
        #expect(again == .revoked(PairedMac(name: "client", key: key), connections: 0, leases: 0))
        #expect(await daemon.unsavedBlocks.isEmpty)
        #expect(try TrustList<TrustedClient>.load(from: pool.directory)[key]?.isBlocked == true)
        await daemon.shutdown()
    }

    /// Revokes a Mac when the save fails after the rename that puts the list with the block in
    /// place. The reply is the reply of a saved block, and the revocation ends the block that an
    /// earlier revocation kept in memory. The log records the failed save at the error level and
    /// no unsaved block.
    @Test func revokesWhenTheSaveFailsAfterTheRename() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        try Self.setImmutable(true, listIn: pool.directory)
        defer { try? Self.setImmutable(false, listIn: pool.directory) }
        await #expect(throws: PoolError.self) {
            try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
        }
        #expect(try await next(remote) == Self.notAccepted)
        #expect(try await isClosed(remote))
        #expect(await daemon.unsavedBlocks == [key])
        try Self.failSaves(in: pool) { directory in
            var list = try TrustList<TrustedClient>.load(from: directory)
            list.block(key)
            try list.save(to: directory)
        }

        let revoked = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
        #expect(revoked == .revoked(PairedMac(name: "client", key: key), connections: 0, leases: 0))
        #expect(try TrustList<TrustedClient>.load(from: pool.directory)[key]?.isBlocked == true)
        #expect(await daemon.unsavedBlocks.isEmpty)
        let logs = pool.logs
        #expect(logs.entries(Self.failedSave).map(\.level) == [.error, .error])
        #expect(logs.entries(Self.unblocked).count == 1)
        #expect(logs.entries("Revoked a paired Mac").count == 1)
        await daemon.shutdown()
    }

    /// Keeps the block in memory and advises another revocation when the save fails and the list
    /// cannot be read again.
    @Test func reportsABlockWhenTheListCannotBeReadAfterAFailedSave() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        try Self.failSaves(in: pool) { directory in
            try Data("{".utf8).write(to: TrustList<TrustedClient>.file(in: directory))
        }
        defer { try? Self.setImmutable(false, listIn: pool.directory) }

        do {
            _ = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
            Issue.record("the revocation succeeded without a readable list")
        } catch let .daemonRefused(message) {
            #expect(message
                .hasPrefix("the host closed the Mac's connections, but the save of the block failed"))
            #expect(message.hasSuffix(Self.staysBlocked))
        }
        #expect(try await next(remote) == Self.notAccepted)
        #expect(try await isClosed(remote))
        #expect(await daemon.unsavedBlocks == [key])
        #expect(pool.logs.entries(Self.unblocked).map(\.level) == [.error])
        await daemon.shutdown()
    }

    /// Saves a block a second time after the revocation ended the Mac's leases. Here the first
    /// save fails, and the list becomes writable when the lease ends.
    @Test func savesTheBlockAgainAfterTheLeasesEnd() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        try remote.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        #expect(try await next(remote).lease?.phase == .starting)
        #expect(try await next(remote).lease?.phase == .ready)
        try Self.setImmutable(true, listIn: pool.directory)
        defer { try? Self.setImmutable(false, listIn: pool.directory) }
        let directory = pool.directory
        pool.logs.whenLogged("A lease ended") {
            try? Self.setImmutable(false, listIn: directory)
        }

        let revoked = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
        #expect(revoked == .revoked(PairedMac(name: "client", key: key), connections: 1, leases: 1))
        #expect(try TrustList<TrustedClient>.load(from: pool.directory)[key]?.isBlocked == true)
        await daemon.shutdown()
    }

    /// Closes the connections of a Mac that the readable list no longer names, without a block.
    @Test func revokesAConnectedMacWithoutARecord() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start()
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        try TrustList<TrustedClient>().save(to: pool.directory)

        let refusal = "the host closed the Mac's connections, but its list of paired Macs has no record of the Mac "
            + "to block. The Mac can pair again with a new code"
        await #expect(throws: PoolError.daemonRefused(message: ClientRightsTests.refusal(refusal))) {
            try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
        }
        #expect(try await next(remote) == Self.notAccepted)
        #expect(try await isClosed(remote))
        #expect(try TrustList<TrustedClient>.load(from: pool.directory).records.isEmpty)
        await daemon.shutdown()
    }

    /// Keeps the record, the leases, and the connection of a Mac that asks the host to forget it
    /// when the list cannot be saved.
    @Test func forgetsNothingWhenTheListCannotBeSaved() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        try remote.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60, detached: true)))
        #expect(try await next(remote).lease?.phase == .starting)
        let lease = try #require(try await next(remote).lease)
        try Self.setImmutable(true, listIn: pool.directory)
        defer { try? Self.setImmutable(false, listIn: pool.directory) }

        try remote.send(PoolRequest.forget(endLeases: true))
        let unsaved = ClientRightsTests.refusal("the host cannot update its list of paired Macs")
        #expect(try await next(remote) == .failure(unsaved))
        #expect(try TrustList<TrustedClient>.load(from: pool.directory)[key] != nil)
        try remote.send(PoolRequest.status)
        guard case let .status(summary) = try await next(remote) else {
            Issue.record("the connection did not stay open")
            return
        }
        #expect(summary.leases.map(\.id) == [lease.id])
        #expect(summary.leases.map(\.phase) == [.ready])
        remote.close()
        await daemon.shutdown()
    }

    /// Forgets a Mac that asks the host to forget it when the save fails after the rename that
    /// puts the list without the Mac's record in place.
    @Test func forgetsWhenTheSaveFailsAfterTheRename() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let owner = try LeaseLedgerTests.paired("a")
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        let other = try await pool.pairedClient(of: daemon, owner: owner)
        try remote.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60, detached: true)))
        #expect(try await next(remote).lease?.phase == .starting)
        let lease = try #require(try await next(remote).lease)
        // No test can fail the flush after the rename. The rename fails on the immutable file
        // instead, and the test then saves the list without the record. The file then matches
        // the file after a rename and a failed flush.
        try Self.setImmutable(true, listIn: pool.directory)
        defer { try? Self.setImmutable(false, listIn: pool.directory) }
        let directory = pool.directory
        pool.logs.whenLogged("The host cannot save the list of paired Macs for a forget request") {
            try? Self.setImmutable(false, listIn: directory)
            try? TrustList<TrustedClient>().save(to: directory)
        }

        try remote.send(PoolRequest.forget(endLeases: true))
        #expect(try await next(remote) == .ended(lease.id, reason: "this Mac asked the host to forget it"))
        #expect(try await next(remote) == .forgotten(leases: 1))
        #expect(try await isClosed(remote))
        #expect(try await next(other) == Self.notAccepted)
        #expect(try await isClosed(other))
        #expect(try TrustList<TrustedClient>.load(from: pool.directory).records.isEmpty)
        #expect(await daemon.summary().leases.allSatisfy { $0.phase == .stopping })
        await daemon.shutdown()
    }

    /// Removes the record of a Mac that asks the host to forget it. The Mac must first release
    /// its leases or ask the host to end them. Every connection of the Mac then closes.
    @Test func forgetsAPairedMac() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(offeredSources: ["base": pool.source])
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let remote = try await pool.pairedClient(of: daemon, owner: owner)
        let other = try await pool.pairedClient(of: daemon, owner: owner)
        try remote.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60, detached: true)))
        #expect(try await next(remote).lease?.phase == .starting)
        let lease = try #require(try await next(remote).lease)

        try remote.send(PoolRequest.forget())
        let held = "this Mac holds a lease on the host. Release the leases first, or ask again to end them"
        #expect(try await next(remote) == .failure(ClientRightsTests.refusal(held)))
        #expect(try TrustList<TrustedClient>.load(from: pool.directory)[key] != nil)

        try remote.send(PoolRequest.forget(endLeases: true))
        #expect(try await next(remote) == .ended(lease.id, reason: "this Mac asked the host to forget it"))
        #expect(try await next(remote) == .forgotten(leases: 1))
        #expect(try await isClosed(remote))
        #expect(try await next(other) == Self.notAccepted)
        #expect(try await isClosed(other))
        #expect(try TrustList<TrustedClient>.load(from: pool.directory).records.isEmpty)
        #expect(await daemon.summary().leases.allSatisfy { $0.phase == .stopping })

        await #expect(throws: PoolError.daemonRefused(
            message: ClientRightsTests.refusal("only a paired Mac can ask the host to forget it"),
        )) {
            try await PoolClient.send(.forget(), to: pool.directory)
        }
        await daemon.shutdown()
    }

    /// Keeps host paths from a revoked Mac and from a Mac that asks the host to forget it. The
    /// replies cover both refusals to forget, a revocation that cannot save the block, and the end
    /// of each Mac's lease. The host's own user sees the path of the list in the revocation's
    /// failure.
    @Test func keepsHostPathsFromRevokedAndForgottenMacs() async throws {
        let pool = try PoolFixture()
        let daemon = try await pool.start(slots: 2, offeredSources: ["base": pool.source])
        let owner = try LeaseLedgerTests.paired("a")
        guard case let .client(key) = owner else {
            return
        }
        let revoked = try await pool.pairedClient(of: daemon, owner: owner)
        let leaving = try await pool.pairedClient(of: daemon, owner: LeaseLedgerTests.paired("b"))
        var replies: [PoolReply] = []
        try revoked.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60)))
        try await replies.append(next(revoked))
        try await replies.append(next(revoked))
        try leaving.send(PoolRequest.lease(LeaseTerms(source: "base", timeToLive: 60, detached: true)))
        try await replies.append(next(leaving))
        try await replies.append(next(leaving))

        try Self.setImmutable(true, listIn: pool.directory)
        defer { try? Self.setImmutable(false, listIn: pool.directory) }
        for endLeases in [false, true] {
            try leaving.send(PoolRequest.forget(endLeases: endLeases))
            try await replies.append(next(leaving))
        }
        do {
            _ = try await PoolClient.send(.revoke(key: key.shortKey), to: pool.directory)
            Issue.record("the revocation succeeded without a saved block")
        } catch let .daemonRefused(message) {
            #expect(message.contains(pool.directory.trustDirectory.path(percentEncoded: false)))
        }
        try await replies.append(next(revoked))
        try await replies.append(next(revoked))
        try Self.setImmutable(false, listIn: pool.directory)
        try leaving.send(PoolRequest.forget(endLeases: true))
        try await replies.append(next(leaving))
        try await replies.append(next(leaving))

        let first = try #require(replies[1].lease)
        let second = try #require(replies[3].lease)
        #expect(Array(replies.suffix(4)) == [
            .ended(first.id, reason: "the host revoked this Mac"),
            Self.notAccepted,
            .ended(second.id, reason: "this Mac asked the host to forget it"),
            .forgotten(leases: 1),
        ])
        try ClientRightsTests.expectNoHostPath(in: replies, of: pool)
        await daemon.shutdown()
    }

    /// Ends the connection of a Mac at its next request once the list no longer names the Mac or
    /// blocks it. A blocked Mac cannot remove its record.
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
        try blockedChannel.send(PoolRequest.forget(endLeases: true))
        for channel in [removedChannel, blockedChannel] {
            #expect(try await next(channel) == Self.notAccepted)
            #expect(try await isClosed(channel))
        }
        let records = try TrustList<TrustedClient>.load(from: pool.directory).records
        #expect(records.map(\.key) == [blockedKey])
        #expect(records.map(\.isBlocked) == [true])
        await daemon.shutdown()
    }

    /// Makes the saves of a revocation fail and changes the list after the last failed save.
    ///
    /// No test can fail the flush after the rename. The rename fails on the immutable file
    /// instead, and `change` then writes the file. A list with the block then matches the file
    /// after a rename and a failed flush.
    ///
    /// - Parameters:
    ///   - pool: The host whose saves fail.
    ///   - change: Writes the list's file after the flag is cleared.
    /// - Throws: `POSIXError` when the flag cannot be set.
    static func failSaves(
        in pool: PoolFixture,
        then change: @escaping @Sendable (PoolDirectory) throws -> Void,
    ) throws {
        let directory = pool.directory
        try setImmutable(true, listIn: directory)
        pool.logs.whenLogged(failedSave) {
            try? setImmutable(false, listIn: directory)
            try? change(directory)
        }
    }

    /// Sets or clears the user immutable flag of the list of paired clients.
    ///
    /// While the flag is set, the list stays readable, and the rename that saves it fails.
    ///
    /// - Parameters:
    ///   - isImmutable: Whether to set the flag.
    ///   - directory: The host's data directory.
    /// - Throws: `POSIXError` when the flag cannot be changed.
    static func setImmutable(_ isImmutable: Bool, listIn directory: PoolDirectory) throws {
        let path = TrustList<TrustedClient>.file(in: directory).path(percentEncoded: false)
        guard chflags(path, isImmutable ? UInt32(UF_IMMUTABLE) : 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
