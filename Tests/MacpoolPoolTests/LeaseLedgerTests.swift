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

    /// Returns a paired client whose fingerprint repeats one digit.
    ///
    /// - Parameter digit: A lowercase hexadecimal digit.
    /// - Returns: The owner.
    /// - Throws: An error when the digit is not a lowercase hexadecimal digit.
    static func paired(_ digit: Character) throws -> LeaseOwner {
        try .client(#require(KeyFingerprint(String(repeating: digit, count: 64))))
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
    ///   - owner: Who the client acts for.
    ///   - terms: The terms.
    ///   - now: The time of the request and the ready report.
    /// - Returns: The new lease.
    /// - Throws: An error when the request does not launch a lease.
    static func readyLease(
        in ledger: inout LeaseLedger,
        for client: ClientID,
        owner: LeaseOwner = .local,
        terms: LeaseTerms = terms(),
        at now: Date = start,
    ) throws -> LeaseID {
        let id = try #require(launches(ledger.request(terms, from: client, owner: owner, now: now)).first)
        _ = ledger.supervisorReported(id, SupervisorStatus(phase: .ready, address: "192.168.64.2"), now: now)
        return id
    }

    /// Grants free slots and queues the rest.
    @Test func grantsFreeSlotsAndQueuesTheRest() {
        var ledger = Self.ledger(slots: 2)
        let first = ledger.request(Self.terms(), from: Self.client(1), owner: .local, now: Self.start)
        let second = ledger.request(Self.terms(), from: Self.client(2), owner: .local, now: Self.start)
        let third = ledger.request(Self.terms(), from: Self.client(3), owner: .local, now: Self.start)
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
        _ = ledger.request(Self.terms(priority: 0), from: Self.client(2), owner: .local, now: Self.at(1))
        _ = ledger.request(Self.terms(priority: 5), from: Self.client(3), owner: .local, now: Self.at(2))
        _ = ledger.request(Self.terms(priority: 0), from: Self.client(4), owner: .local, now: Self.at(3))
        let last = ledger.request(Self.terms(priority: 5), from: Self.client(5), owner: .local, now: Self.at(4))
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
        #expect(ledger.summary(for: .local).queue.map(\.priority) == [5, 5, 0, 0])

        _ = try ledger.release(holder, owner: .local, reason: "done")
        _ = ledger.machineExited(holder, .requested, now: Self.at(5))
        let granted = ledger.discarded(holder, now: Self.at(6))
        let next = try #require(Self.launches(granted).first)
        #expect(ledger.clients[next] == Self.client(3))
        #expect(granted.contains(.notify(Self.client(5), .queued(position: 1))))
    }

    /// Queues a paired client's request by arrival among requests of the default priority, so the
    /// local user gets ahead of it only with a higher priority.
    @Test func localUserPassesPairedClientWithHigherPriority() throws {
        var ledger = Self.ledger(slots: 1)
        _ = try Self.readyLease(in: &ledger, for: Self.client(1))
        let alice = try Self.paired("a")
        _ = ledger.request(Self.terms(), from: Self.client(2), owner: alice, now: Self.at(1))
        _ = ledger.request(Self.terms(), from: Self.client(3), owner: .local, now: Self.at(2))
        #expect(ledger.queue.map(\.client) == [2, 3].map(Self.client))
        let raised = ledger.request(Self.terms(priority: 1), from: Self.client(4), owner: .local, now: Self.at(3))
        #expect(ledger.queue.map(\.client) == [4, 2, 3].map(Self.client))
        #expect(ledger.queue.map(\.owner) == [.local, alice, .local])
        #expect(raised.contains(.notify(Self.client(2), .queued(position: 2))))
    }

    /// Tells the remaining clients their new positions when a waiting client leaves.
    @Test func updatesPositionsWhenClientLeaves() throws {
        var ledger = Self.ledger(slots: 1)
        _ = try Self.readyLease(in: &ledger, for: Self.client(1))
        _ = ledger.request(Self.terms(), from: Self.client(2), owner: .local, now: Self.at(1))
        _ = ledger.request(Self.terms(), from: Self.client(3), owner: .local, now: Self.at(2))
        let actions = ledger.clientDisconnected(Self.client(2), now: Self.at(3))
        #expect(actions == [.notify(Self.client(3), .queued(position: 1))])
        #expect(ledger.queue.map(\.client) == [Self.client(3)])
    }

    /// Stops the VM on release and grants the slot only after the clone is gone.
    @Test func releaseFreesSlotAfterDiscard() throws {
        var ledger = Self.ledger(slots: 1)
        let id = try Self.readyLease(in: &ledger, for: Self.client(1))
        _ = ledger.request(Self.terms(), from: Self.client(2), owner: .local, now: Self.at(1))

        let released = try ledger.release(id, owner: .local, reason: "released by a client")
        #expect(released == [.notify(Self.client(1), .ended(id, reason: "released by a client")), .stop(id)])
        #expect(ledger.leases[id]?.phase == .stopping)
        #expect(try ledger.release(id, owner: .local, reason: "again").isEmpty)

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
        let requested = ledger.request(Self.terms(), from: Self.client(1), owner: .local, now: Self.start)
        let id = try #require(Self.launches(requested).first)
        #expect(try ledger.renew(id, owner: .local, now: Self.at(5)).expiresAt == nil)

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

        #expect(try ledger.renew(id, owner: .local, now: Self.at(100)).expiresAt == Self.at(700))
        #expect(ledger.tick(now: Self.at(699)).isEmpty)
        let expired = ledger.tick(now: Self.at(700))
        #expect(expired == [.notify(Self.client(1), .ended(id, reason: "the lease expired")), .stop(id)])
        #expect(throws: PoolError.leaseEnding(id: id.rawValue)) {
            try ledger.renew(id, owner: .local, now: Self.at(701))
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
        let actions = ledger.request(Self.terms(detached: true), from: Self.client(1), owner: .local, now: Self.start)
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

    /// Shows a paired client its leases and requests by the source's name, without a clone or an
    /// address, and replaces the reasons of failed VMs. The local user sees the paths and reasons.
    @Test func showsPairedClientsNoHostPaths() throws {
        var ledger = Self.ledger(slots: 1)
        let alice = try Self.paired("a")
        let requested = ledger.request(
            Self.terms(),
            from: Self.client(1),
            owner: alice,
            sourceName: "base",
            now: Self.start,
        )
        let id = try #require(Self.launches(requested).first)
        let ready = ledger.supervisorReported(
            id,
            SupervisorStatus(phase: .ready, address: "192.168.64.2"),
            now: Self.at(1),
        )
        let record = try #require(ledger.leases[id])
        let seen = ledger.summary(of: record, for: alice)
        #expect(ready == [.notify(Self.client(1), .ready(seen))])
        #expect([seen.source, seen.bundle, seen.address] == ["base", nil, nil])
        let local = ledger.summary(of: record, for: .local)
        #expect([local.source, local.bundle, local.address] == ["/vms/base", "/pool/leases/\(id)", "192.168.64.2"])
        #expect(try ledger.renew(id, owner: alice, now: Self.at(2)).bundle == nil)

        let restarting = ledger.machineExited(id, .failed("the disk at /vms/base failed"), now: Self.at(3))
        let hidden = try #require(ledger.leases[id].map { ledger.summary(of: $0, for: alice) })
        #expect(restarting == [.notify(Self.client(1), .restarting(hidden, reason: MachineOutcome.hiddenFailure))])

        _ = ledger.request(Self.terms(), from: Self.client(2), owner: .local, now: Self.at(4))
        _ = ledger.request(Self.terms(), from: Self.client(1), owner: alice, sourceName: "base", now: Self.at(4))
        #expect(ledger.waitingRequests(of: alice) == 1)
        #expect(ledger.waitingRequests(of: .local) == 1)
        #expect(ledger.summary(for: alice).queue.map(\.source) == ["base"])
        #expect(ledger.summary(for: .local).queue.map(\.source) == ["/vms/base", "/vms/base"])

        _ = ledger.tick(now: Self.at(100))
        _ = ledger.supervisorReported(id, SupervisorStatus(phase: .ready, address: "192.168.64.3"), now: Self.at(101))
        _ = ledger.machineExited(id, .failed("the disk at /vms/base failed"), now: Self.at(102))
        _ = ledger.tick(now: Self.at(200))
        let ended = ledger.machineExited(id, .failed("the disk at /vms/base failed"), now: Self.at(201))
        let reason = "\(MachineOutcome.hiddenFailure) after 2 restarts"
        #expect(ended.first == .notify(Self.client(1), .ended(id, reason: reason)))
        #expect(ledger.leases[id]?.endReason == "the disk at /vms/base failed after 2 restarts")

        var booting = Self.ledger()
        let request = booting.request(
            Self.terms(),
            from: Self.client(1),
            owner: alice,
            sourceName: "base",
            now: Self.start,
        )
        let bootID = try #require(Self.launches(request).first)
        #expect(booting.bootFailed(bootID, reason: "cannot clone /vms/base") == [
            .notify(Self.client(1), .ended(bootID, reason: MachineOutcome.hiddenFailure)),
            .discard(bootID),
        ])
    }

    /// Ends a lease without a restart when its boot cannot succeed, and keeps the supervisor's
    /// process identifier after a run ends.
    @Test func endsLeaseWhoseBootCannotSucceed() throws {
        var ledger = Self.ledger()
        let id = try Self.readyLease(in: &ledger, for: Self.client(1))
        ledger.supervisorLaunched(id, processID: 4242)
        _ = ledger.machineExited(id, .lost, now: Self.at(10))
        #expect(ledger.leases[id]?.supervisorProcessID == 4242)
        _ = ledger.tick(now: Self.at(15))
        #expect(ledger.leases[id]?.phase == .starting)

        let failed = ledger.bootFailed(id, reason: "the clone failed")
        #expect(failed == [.notify(Self.client(1), .ended(id, reason: "the clone failed")), .discard(id)])
        #expect(ledger.leases[id]?.restarts == 1)
        #expect(ledger.bootFailed(id, reason: "again").isEmpty)
    }

    /// Applies each restart policy to each outcome.
    ///
    /// - Parameters:
    ///   - policy: The lease's restart policy.
    ///   - outcome: How the VM's run ended.
    ///   - restarts: Whether the policy boots the VM again after that outcome.
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
        let attached = try after.attach(id, client: Self.client(7), owner: .local)
        let summary = try #require(after.leases[id].map(after.summary(of:)))
        #expect(attached == [.notify(Self.client(7), .ready(summary))])
        #expect(after.tick(now: Self.at(200)).isEmpty)
        #expect(throws: PoolError.leaseAttached(id: id.rawValue)) {
            try after.attach(id, client: Self.client(8), owner: .local)
        }
        #expect(throws: PoolError.unknownLease(id: "00000000")) {
            try after.attach(#require(LeaseID("00000000")), client: Self.client(8), owner: .local)
        }
    }

    /// Lets a paired client see and change only its own leases and requests, and lets the local
    /// user act on every lease.
    @Test func pairedClientActsOnlyOnItsOwnLeases() throws {
        var ledger = Self.ledger(slots: 2)
        let alice = try Self.paired("a")
        let bob = try Self.paired("b")
        let local = try Self.readyLease(in: &ledger, for: Self.client(1))
        let own = try Self.readyLease(in: &ledger, for: Self.client(2), owner: alice)
        _ = ledger.request(Self.terms(), from: Self.client(3), owner: bob, now: Self.at(1))
        _ = ledger.request(Self.terms(), from: Self.client(4), owner: alice, now: Self.at(2))

        let seen = ledger.summary(for: alice)
        #expect(seen.leases.map(\.id) == [own])
        #expect(seen.queue.map(\.position) == [2])
        #expect(ledger.summary(for: .local).leases.count == 2)
        #expect(ledger.summary(for: .local).queue.map(\.position) == [1, 2])

        let unknown = PoolError.unknownLease(id: local.rawValue)
        #expect(throws: unknown) {
            try ledger.renew(local, owner: alice, now: Self.at(3))
        }
        #expect(throws: unknown) {
            try ledger.release(local, owner: alice, reason: "taken")
        }
        #expect(throws: unknown) {
            try ledger.attach(local, client: Self.client(4), owner: alice)
        }
        #expect(ledger.leases[local]?.phase == .ready)
        #expect(ledger.clients[local] == Self.client(1))

        #expect(try ledger.renew(own, owner: alice, now: Self.at(3)).expiresAt == Self.at(603))
        let released = try ledger.release(own, owner: .local, reason: "released on the host")
        #expect(released == [.notify(Self.client(2), .ended(own, reason: "released on the host")), .stop(own)])
        #expect(ledger.leases[own]?.owner == alice)
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
