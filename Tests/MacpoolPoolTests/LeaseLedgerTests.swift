import Foundation
@testable import MacpoolPool
import Testing

/// Tests of the queue, the time to live, the restart policy, and recovery in the lease ledger.
struct LeaseLedgerTests {
    /// The time at which every test starts, on a whole second so stored dates round-trip exactly.
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A policy with short, distinct delays.
    static let policy = PoolPolicy(
        slots: 2,
        maximumRestarts: 2,
        firstRestartDelay: .seconds(5),
        longestRestartDelay: .seconds(8),
        reattachGrace: .seconds(60),
    )

    /// Creates a ledger with a slot count.
    ///
    /// - Parameter slots: The number of slots.
    /// - Returns: An empty ledger.
    static func ledger(slots: Int = 2) -> LeaseLedger {
        var policy = policy
        policy.slots = slots
        return LeaseLedger(policy: policy, directory: PoolDirectory(root: URL(filePath: "/pool")))
    }

    /// Creates lease terms.
    ///
    /// - Parameters:
    ///   - priority: The queue priority.
    ///   - restart: The restart policy.
    ///   - detached: Whether the lease outlives its client once ready.
    /// - Returns: Terms with a ten-minute time to live.
    static func terms(
        priority: Int = 0,
        restart: RestartPolicy = .onFailure,
        detached: Bool = false,
    ) -> LeaseTerms {
        LeaseTerms(source: "/vms/base", timeToLive: 600, priority: priority, restartPolicy: restart, detached: detached)
    }

    /// Returns the time a number of seconds after the start.
    ///
    /// - Parameter seconds: The offset.
    /// - Returns: The time.
    static func at(_ seconds: Int) -> Date {
        start.addingTimeInterval(TimeInterval(seconds))
    }

    /// Returns a client numbered for a test.
    ///
    /// - Parameter number: The client's number.
    /// - Returns: The client.
    static func client(_ number: UInt64) -> ClientID {
        ClientID(value: number)
    }

    /// Finds the leases that a list of actions launches.
    ///
    /// - Parameter actions: The actions.
    /// - Returns: The launched leases in order.
    static func launches(_ actions: [LedgerAction]) -> [LeaseID] {
        actions.compactMap { action in
            if case let .launch(id) = action {
                return id
            }
            return nil
        }
    }

    /// Requests a lease and reports its supervisor ready.
    ///
    /// - Parameters:
    ///   - ledger: The ledger.
    ///   - client: The requesting client.
    ///   - terms: The terms.
    ///   - now: The time of the request and the ready report.
    /// - Returns: The new lease.
    /// - Throws: An error when the request does not launch a lease.
    static func readyLease(
        in ledger: inout LeaseLedger,
        for client: ClientID,
        terms: LeaseTerms = terms(),
        at now: Date = start,
    ) throws -> LeaseID {
        let id = try #require(launches(ledger.request(terms, from: client, now: now)).first)
        _ = ledger.supervisorReported(id, SupervisorStatus(phase: .ready, address: "192.168.64.2"), now: now)
        return id
    }

    /// Grants free slots and queues the rest.
    @Test func grantsFreeSlotsAndQueuesTheRest() {
        var ledger = Self.ledger(slots: 2)
        let first = ledger.request(Self.terms(), from: Self.client(1), now: Self.start)
        let second = ledger.request(Self.terms(), from: Self.client(2), now: Self.start)
        let third = ledger.request(Self.terms(), from: Self.client(3), now: Self.start)
        #expect(Self.launches(first).count == 1)
        #expect(Self.launches(second).count == 1)
        #expect(Self.launches(third).isEmpty)
        #expect(third == [.notify(Self.client(3), .queued(position: 1))])
        #expect(ledger.leases.count == 2)
        #expect(ledger.queue.map(\.client) == [Self.client(3)])
    }

    /// Orders the queue by priority and then by arrival.
    @Test func ordersQueueByPriorityThenArrival() throws {
        var ledger = Self.ledger(slots: 1)
        let holder = try Self.readyLease(in: &ledger, for: Self.client(1))
        _ = ledger.request(Self.terms(priority: 0), from: Self.client(2), now: Self.at(1))
        _ = ledger.request(Self.terms(priority: 5), from: Self.client(3), now: Self.at(2))
        _ = ledger.request(Self.terms(priority: 0), from: Self.client(4), now: Self.at(3))
        let last = ledger.request(Self.terms(priority: 5), from: Self.client(5), now: Self.at(4))
        #expect(ledger.queue.map(\.client) == [3, 5, 2, 4].map(Self.client))
        #expect(last.contains(.notify(Self.client(2), .queued(position: 3))))
        #expect(last.contains(.notify(Self.client(4), .queued(position: 4))))
        #expect(last.contains(.notify(Self.client(5), .queued(position: 2))))
        #expect(!last.contains {
            if case .notify(Self.client(3), _) = $0 {
                true
            } else {
                false
            }
        })
        #expect(ledger.summary().queue.map(\.priority) == [5, 5, 0, 0])

        _ = try ledger.release(holder, reason: "done")
        _ = ledger.machineExited(holder, .requested, now: Self.at(5))
        let granted = ledger.discarded(holder, now: Self.at(6))
        let next = try #require(Self.launches(granted).first)
        #expect(ledger.clients[next] == Self.client(3))
        #expect(granted.contains(.notify(Self.client(5), .queued(position: 1))))
    }

    /// Tells the remaining clients their new positions when a waiting client leaves.
    @Test func updatesPositionsWhenClientLeaves() throws {
        var ledger = Self.ledger(slots: 1)
        _ = try Self.readyLease(in: &ledger, for: Self.client(1))
        _ = ledger.request(Self.terms(), from: Self.client(2), now: Self.at(1))
        _ = ledger.request(Self.terms(), from: Self.client(3), now: Self.at(2))
        let actions = ledger.clientDisconnected(Self.client(2), now: Self.at(3))
        #expect(actions == [.notify(Self.client(3), .queued(position: 1))])
        #expect(ledger.queue.map(\.client) == [Self.client(3)])
    }

    /// Stops the VM on release and grants the slot only after the clone is gone.
    @Test func releaseFreesSlotAfterDiscard() throws {
        var ledger = Self.ledger(slots: 1)
        let id = try Self.readyLease(in: &ledger, for: Self.client(1))
        _ = ledger.request(Self.terms(), from: Self.client(2), now: Self.at(1))

        let released = try ledger.release(id, reason: "released by a client")
        #expect(released == [.notify(Self.client(1), .ended(id, reason: "released by a client")), .stop(id)])
        #expect(ledger.leases[id]?.phase == .stopping)
        #expect(try ledger.release(id, reason: "again").isEmpty)

        #expect(ledger.machineExited(id, .requested, now: Self.at(2)) == [.discard(id)])
        #expect(ledger.queue.count == 1)
        let granted = ledger.discarded(id, now: Self.at(3))
        #expect(Self.launches(granted).count == 1)
        #expect(ledger.leases[id] == nil)
        #expect(ledger.queue.isEmpty)
    }

    /// Starts the time to live at the first ready report and moves it on renewal.
    @Test func readyStartsTimeToLiveAndRenewalMovesIt() throws {
        var ledger = Self.ledger()
        let id = try #require(Self.launches(ledger.request(Self.terms(), from: Self.client(1), now: Self.start)).first)
        #expect(try ledger.renew(id, now: Self.at(5)).expiresAt == nil)

        let ready = ledger.supervisorReported(
            id,
            SupervisorStatus(phase: .ready, address: "192.168.64.9"),
            now: Self.at(10),
        )
        let summary = try #require(ledger.leases[id].map(ledger.summary(of:)))
        #expect(ready == [.notify(Self.client(1), .ready(summary))])
        #expect(summary.address == "192.168.64.9")
        #expect(summary.expiresAt == Self.at(610))
        #expect(summary.bundle == "/pool/leases/\(id)")

        #expect(try ledger.renew(id, now: Self.at(100)).expiresAt == Self.at(700))
        #expect(ledger.tick(now: Self.at(699)).isEmpty)
        let expired = ledger.tick(now: Self.at(700))
        #expect(expired == [.notify(Self.client(1), .ended(id, reason: "the lease expired")), .stop(id)])
        #expect(throws: PoolError.leaseEnding(id: id.rawValue)) {
            try ledger.renew(id, now: Self.at(701))
        }
    }

    /// Discards a lease at once when it expires while it waits to restart.
    @Test func expiryWhileRestartingDiscardsAtOnce() throws {
        var ledger = Self.ledger()
        let id = try Self.readyLease(in: &ledger, for: Self.client(1))
        _ = ledger.machineExited(id, .failed("boom"), now: Self.at(590))
        #expect(ledger.leases[id]?.phase == .restarting)
        let actions = ledger.tick(now: Self.at(600))
        #expect(actions == [.notify(Self.client(1), .ended(id, reason: "the lease expired")), .discard(id)])
    }

    /// Ends an attached lease when its client disconnects.
    @Test func attachedLeaseEndsWithItsClient() throws {
        var ledger = Self.ledger()
        let id = try Self.readyLease(in: &ledger, for: Self.client(1))
        #expect(ledger.clientDisconnected(Self.client(1), now: Self.at(1)) == [.stop(id)])
        #expect(ledger.leases[id]?.endReason == "the client disconnected")
    }

    /// Keeps a detached lease after its client leaves, once the VM was ready.
    @Test func detachedLeaseOutlivesItsClient() throws {
        var ledger = Self.ledger()
        let id = try Self.readyLease(in: &ledger, for: Self.client(1), terms: Self.terms(detached: true))
        #expect(ledger.clientDisconnected(Self.client(1), now: Self.at(1)).isEmpty)
        #expect(ledger.leases[id]?.phase == .ready)
        #expect(ledger.clients[id] == nil)
    }

    /// Ends a detached lease whose client leaves before the VM is ready.
    @Test func detachedLeaseEndsWhenClientLeavesBeforeReady() throws {
        var ledger = Self.ledger()
        let actions = ledger.request(Self.terms(detached: true), from: Self.client(1), now: Self.start)
        let id = try #require(Self.launches(actions).first)
        #expect(ledger.clientDisconnected(Self.client(1), now: Self.at(1)) == [.stop(id)])
    }

    /// Restarts failed VMs with growing delays and ends the lease after the last allowed restart.
    @Test func restartsFailuresWithBackoffUntilTheLimit() throws {
        var ledger = Self.ledger()
        let id = try Self.readyLease(in: &ledger, for: Self.client(1))
        let expiry = ledger.leases[id]?.expiresAt

        let first = ledger.machineExited(id, .failed("boot timed out"), now: Self.at(10))
        let restarting = try #require(ledger.leases[id].map(ledger.summary(of:)))
        #expect(first == [.notify(Self.client(1), .restarting(restarting, reason: "boot timed out"))])
        #expect(ledger.leases[id]?.restartAt == Self.at(15))
        #expect(ledger.tick(now: Self.at(14)).isEmpty)
        let relaunch = ledger.tick(now: Self.at(15))
        #expect(Self.launches(relaunch) == [id])
        #expect(ledger.leases[id]?.phase == .starting)
        _ = ledger.supervisorReported(id, SupervisorStatus(phase: .ready, address: "192.168.64.3"), now: Self.at(20))
        #expect(ledger.leases[id]?.expiresAt == expiry)

        _ = ledger.machineExited(id, .lost, now: Self.at(30))
        #expect(ledger.leases[id]?.restartAt == Self.at(38))
        _ = ledger.tick(now: Self.at(38))
        let last = ledger.machineExited(id, .failed("boot timed out"), now: Self.at(40))
        #expect(last == [
            .notify(Self.client(1), .ended(id, reason: "boot timed out after 2 restarts")),
            .discard(id),
        ])
        #expect(ledger.leases[id]?.restarts == 2)
    }

    /// Applies each restart policy to each outcome.
    @Test(arguments: [
        (RestartPolicy.never, MachineOutcome.failed("x"), false),
        (.never, .guestShutdown, false),
        (.onFailure, .failed("x"), true),
        (.onFailure, .lost, true),
        (.onFailure, .guestShutdown, false),
        (.onFailure, .requested, false),
        (.always, .guestShutdown, true),
        (.always, .requested, true),
    ])
    func decidesRestarts(policy: RestartPolicy, outcome: MachineOutcome, restarts: Bool) {
        #expect(PoolPolicy.restarts(policy, after: outcome) == restarts)
    }

    /// Ends a lease whose guest shut down under the on-failure policy and discards its clone.
    @Test func guestShutdownEndsOnFailureLease() throws {
        var ledger = Self.ledger()
        let id = try Self.readyLease(in: &ledger, for: Self.client(1))
        let actions = ledger.machineExited(id, .guestShutdown, now: Self.at(1))
        #expect(actions == [.notify(Self.client(1), .ended(id, reason: "the guest shut down")), .discard(id)])
    }

    /// Doubles the restart delay up to the longest delay.
    @Test func capsRestartDelay() {
        let policy = PoolPolicy(firstRestartDelay: .seconds(5), longestRestartDelay: .seconds(60))
        #expect([0, 1, 2, 3, 4, 10].map(policy.restartDelay(after:)) == [5, 10, 20, 40, 60, 60]
            .map { Duration.seconds($0) })
    }

    /// Reconnects stored leases after a restart and ends attached ones that no client reclaims.
    @Test func recoversLeasesAndEndsUnclaimedAttachedOnes() throws {
        var before = Self.ledger()
        let attached = try Self.readyLease(in: &before, for: Self.client(1))
        let detached = try Self.readyLease(in: &before, for: Self.client(2), terms: Self.terms(detached: true))

        var after = LeaseLedger(policy: Self.policy, directory: before.directory, state: before.state)
        #expect(after.leases == before.leases)
        let recovered = after.recover(now: Self.at(100))
        #expect(recovered == [attached, detached].sorted().map { LedgerAction.reconnect($0) })
        #expect(after.tick(now: Self.at(159)).isEmpty)
        #expect(after.tick(now: Self.at(160)) == [.stop(attached)])
        #expect(after.leases[attached]?.endReason == "no client reattached after the daemon started")
        #expect(after.leases[detached]?.phase == .ready)
    }

    /// Keeps a recovered attached lease that a client reattaches to within the grace period.
    @Test func reattachWithinGraceKeepsLease() throws {
        var before = Self.ledger()
        let id = try Self.readyLease(in: &before, for: Self.client(1))
        var after = LeaseLedger(policy: Self.policy, directory: before.directory, state: before.state)
        _ = after.recover(now: Self.at(100))
        let attached = try after.attach(id, client: Self.client(7))
        let summary = try #require(after.leases[id].map(after.summary(of:)))
        #expect(attached == [.notify(Self.client(7), .ready(summary))])
        #expect(after.tick(now: Self.at(200)).isEmpty)
        #expect(throws: PoolError.leaseAttached(id: id.rawValue)) {
            try after.attach(id, client: Self.client(8))
        }
        #expect(throws: PoolError.unknownLease(id: "00000000")) {
            try after.attach(#require(LeaseID("00000000")), client: Self.client(8))
        }
    }

    /// Leaves a lease that waits to restart alone during recovery and launches it on time.
    @Test func recoveryKeepsRestartTimes() throws {
        var before = Self.ledger()
        let id = try Self.readyLease(in: &before, for: Self.client(1), terms: Self.terms(detached: true))
        _ = before.machineExited(id, .failed("boom"), now: Self.at(10))
        var after = LeaseLedger(policy: Self.policy, directory: before.directory, state: before.state)
        #expect(after.recover(now: Self.at(12)).isEmpty)
        #expect(Self.launches(after.tick(now: Self.at(15))) == [id])
    }
}
