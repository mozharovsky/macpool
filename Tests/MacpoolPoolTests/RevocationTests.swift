import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the record check before each request of a paired Mac.
@Suite(.timeLimit(.minutes(1)))
struct RevocationTests {
    /// The refusal that a paired Mac receives once the host no longer accepts it.
    static let notAccepted = PoolReply.failure(ClientRightsTests.refusal("the host no longer accepts this Mac"))

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
