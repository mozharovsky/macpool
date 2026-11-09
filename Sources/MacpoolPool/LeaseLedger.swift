import Foundation
import MacpoolVM

/// The limits and timings by which the daemon schedules leases.
public struct PoolPolicy: Sendable, Equatable {
    /// The largest number of slots, which is the number of macOS VMs that macOS allows per host.
    public static let maximumSlots = 2

    /// The number of VMs that run at once, from 1 to ``maximumSlots``.
    public var slots: Int

    /// The number of times the daemon boots a lease's VM again before it ends the lease.
    public var maximumRestarts: Int

    /// The wait before the first restart. Each later restart waits twice as long as the one before,
    /// up to ``longestRestartDelay``.
    public var firstRestartDelay: Duration

    /// The longest wait before a restart.
    public var longestRestartDelay: Duration

    /// How long a lease that needs a client survives without one after the daemon starts.
    ///
    /// A client whose connection broke because the daemon stopped reattaches within this time.
    public var reattachGrace: Duration

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - slots: The number of VMs that run at once, from 1 to ``maximumSlots``.
    ///   - maximumRestarts: The number of restarts before a lease ends.
    ///   - firstRestartDelay: The wait before the first restart.
    ///   - longestRestartDelay: The longest wait before a restart.
    ///   - reattachGrace: How long a lease waits for its client after the daemon starts.
    public init(
        slots: Int = maximumSlots,
        maximumRestarts: Int = 3,
        firstRestartDelay: Duration = .seconds(5),
        longestRestartDelay: Duration = .seconds(60),
        reattachGrace: Duration = .seconds(60),
    ) {
        self.slots = slots
        self.maximumRestarts = maximumRestarts
        self.firstRestartDelay = firstRestartDelay
        self.longestRestartDelay = longestRestartDelay
        self.reattachGrace = reattachGrace
    }

    /// Computes the wait before a restart.
    ///
    /// - Parameter restarts: The number of restarts that the lease already had.
    /// - Returns: The first delay doubled once per earlier restart, capped at the longest delay.
    func restartDelay(after restarts: Int) -> Duration {
        var delay = firstRestartDelay
        for _ in 0 ..< max(0, restarts) where delay < longestRestartDelay {
            delay *= 2
        }
        return min(delay, longestRestartDelay)
    }

    /// Reports whether a policy boots a VM again after an outcome.
    ///
    /// - Parameters:
    ///   - policy: The lease's restart policy.
    ///   - outcome: How the VM's run ended.
    /// - Returns: Whether the lease's VM boots again, before the restart limit applies.
    static func restarts(_ policy: RestartPolicy, after outcome: MachineOutcome) -> Bool {
        switch (policy, outcome) {
        case (.never, _):
            false
        case (.onFailure, .failed), (.onFailure, .lost):
            true
        case (.onFailure, .requested), (.onFailure, .guestShutdown):
            false
        case (.always, _):
            true
        }
    }
}

/// A connection of a client to the daemon, numbered within one daemon process.
struct ClientID: Hashable, Sendable, Comparable {
    /// The connection's number.
    let value: UInt64

    /// Orders clients by their number.
    ///
    /// - Parameters:
    ///   - lhs: The first client.
    ///   - rhs: The second client.
    /// - Returns: Whether the first client connected before the second.
    static func < (lhs: ClientID, rhs: ClientID) -> Bool {
        lhs.value < rhs.value
    }
}

/// A lease that holds a slot, as the daemon stores it.
struct LeaseRecord: Codable, Sendable, Equatable {
    /// The lease's identifier.
    let id: LeaseID

    /// The terms from the request.
    let terms: LeaseTerms

    /// The lease's stage.
    var phase: LeasePhase

    /// The guest's address while the VM is ready.
    var address: String?

    /// The time at which the lease got its slot.
    let grantedAt: Date

    /// The expiry, which the first ready status sets and each renewal moves.
    var expiresAt: Date?

    /// The number of times the VM booted again.
    var restarts: Int

    /// The time of the next boot while the lease waits to restart.
    var restartAt: Date?

    /// Why the lease ended, once it is stopping.
    var endReason: String?

    /// The process identifier of the current supervisor, when the daemon started one.
    var supervisorProcessID: Int32?

    /// The JSON keys of a record.
    private enum CodingKeys: String, CodingKey {
        /// The `id` key.
        case id
        /// The `terms` key.
        case terms
        /// The `phase` key.
        case phase
        /// The `address` key.
        case address
        /// The `granted_at` key.
        case grantedAt = "granted_at"
        /// The `expires_at` key.
        case expiresAt = "expires_at"
        /// The `restarts` key.
        case restarts
        /// The `restart_at` key.
        case restartAt = "restart_at"
        /// The `end_reason` key.
        case endReason = "end_reason"
        /// The `supervisor_pid` key.
        case supervisorProcessID = "supervisor_pid"
    }

    /// Whether the lease ends when it has no client.
    ///
    /// A detached lease outlives its client once its VM was ready, because the client then knows
    /// the lease's identifier.
    var needsClient: Bool {
        !(terms.detached && expiresAt != nil)
    }
}

/// The durable part of the pool, which the daemon writes after every change.
struct PoolState: Codable, Sendable, Equatable {
    /// The state file's format version.
    static let currentVersion = 1

    /// The format version of the stored file.
    var version: Int

    /// The leases that hold a slot, ordered by identifier.
    var leases: [LeaseRecord]

    /// An empty state in the current format.
    static let empty = PoolState(version: currentVersion, leases: [])
}

/// A request that waits for a slot.
struct QueuedRequest: Sendable, Equatable {
    /// The arrival number, which orders requests with the same priority.
    let ticket: UInt64

    /// The client that waits.
    let client: ClientID

    /// The requested terms.
    let terms: LeaseTerms

    /// The arrival time.
    let since: Date

    /// The position that the client last heard, or `nil` before the first notice.
    var notifiedPosition: Int?
}

/// A step that the daemon performs after the ledger changed.
enum LedgerAction: Sendable, Equatable {
    /// Sends a reply to a client.
    ///
    /// - Parameters:
    ///   - client: The receiving client.
    ///   - reply: The reply.
    case notify(ClientID, PoolReply)

    /// Clones the source when the lease has no usable clone and starts a supervisor.
    ///
    /// - Parameter id: The lease.
    case launch(LeaseID)

    /// Asks the lease's supervisor to stop the VM.
    ///
    /// - Parameter id: The lease.
    case stop(LeaseID)

    /// Deletes the lease's clone once no process holds it and reports ``LeaseLedger/discarded(_:now:)``.
    ///
    /// - Parameter id: The lease.
    case discard(LeaseID)

    /// Connects to the supervisor that a lease had before the daemon started.
    ///
    /// - Parameter id: The lease.
    case reconnect(LeaseID)
}

/// The pool's leases and queue, with every scheduling decision and no input or output.
///
/// The daemon feeds the ledger with requests, supervisor reports, and the time, and performs the
/// ``LedgerAction`` values that each call returns. Every method takes the current time, so tests
/// drive the ledger through any sequence of events without waiting.
///
/// A lease holds its slot from the moment it leaves the queue until the daemon deletes its clone.
/// The queue orders requests by priority and then by arrival.
struct LeaseLedger {
    /// The limits and timings.
    let policy: PoolPolicy

    /// The data directory, which names each lease's clone.
    let directory: PoolDirectory

    /// The leases that hold a slot.
    private(set) var leases: [LeaseID: LeaseRecord]

    /// The requests that wait for a slot, in the order they will get one.
    private(set) var queue: [QueuedRequest] = []

    /// The client that each lease reports to.
    private(set) var clients: [LeaseID: ClientID] = [:]

    /// The time since which each lease that needs a client has none after a daemon start.
    private(set) var orphanedSince: [LeaseID: Date] = [:]

    /// The arrival number of the next request.
    private var nextTicket: UInt64 = 0

    /// Creates a ledger from stored state.
    ///
    /// - Parameters:
    ///   - policy: The limits and timings.
    ///   - directory: The data directory.
    ///   - state: The stored leases, which ``recover(now:)`` resumes.
    init(policy: PoolPolicy, directory: PoolDirectory, state: PoolState = .empty) {
        self.policy = policy
        self.directory = directory
        leases = Dictionary(uniqueKeysWithValues: state.leases.map { ($0.id, $0) })
    }

    /// The durable part of the ledger.
    var state: PoolState {
        PoolState(version: PoolState.currentVersion, leases: leases.values.sorted { $0.id < $1.id })
    }

    /// Queues a lease request and grants slots that are free.
    ///
    /// - Parameters:
    ///   - terms: The requested terms, which the caller already validated.
    ///   - client: The client that waits for the lease.
    ///   - now: The current time.
    /// - Returns: The replies and launches that follow.
    mutating func request(_ terms: LeaseTerms, from client: ClientID, now: Date) -> [LedgerAction] {
        let request = QueuedRequest(ticket: nextTicket, client: client, terms: terms, since: now)
        nextTicket += 1
        let index = queue.firstIndex { $0.terms.priority < terms.priority } ?? queue.endIndex
        queue.insert(request, at: index)
        return schedule(now: now)
    }

    /// Withdraws a disconnected client's requests and ends the leases that needed it.
    ///
    /// - Parameters:
    ///   - client: The client whose connection ended.
    ///   - now: The current time.
    /// - Returns: The stops, discards, and position notices that follow.
    mutating func clientDisconnected(_ client: ClientID, now _: Date) -> [LedgerAction] {
        queue.removeAll { $0.client == client }
        var actions: [LedgerAction] = []
        for (id, holder) in clients.sorted(by: { $0.key < $1.key }) where holder == client {
            clients[id] = nil
            if leases[id]?.needsClient == true {
                actions += end(id, reason: "the client disconnected")
            }
        }
        return actions + notifyPositions()
    }

    /// Attaches a client to a lease, for example after the daemon restarted.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - client: The client that takes over the lease's replies.
    /// - Returns: A reply that tells the client the lease's current stage.
    /// - Throws: ``PoolError/unknownLease(id:)`` when no such lease holds a slot,
    ///   ``PoolError/leaseEnding(id:)`` when it is stopping, or ``PoolError/leaseAttached(id:)``
    ///   when another client is attached.
    mutating func attach(_ id: LeaseID, client: ClientID) throws(PoolError) -> [LedgerAction] {
        guard let record = leases[id] else {
            throw .unknownLease(id: id.rawValue)
        }
        guard record.phase != .stopping else {
            throw .leaseEnding(id: id.rawValue)
        }
        if let holder = clients[id], holder != client {
            throw .leaseAttached(id: id.rawValue)
        }
        clients[id] = client
        orphanedSince[id] = nil
        let summary = summary(of: record)
        switch record.phase {
        case .ready:
            return [.notify(client, .ready(summary))]
        case .starting, .restarting, .stopping:
            return [.notify(client, .starting(summary))]
        }
    }

    /// Ends a lease on a client's request.
    ///
    /// A lease that is already stopping stays as it is.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - reason: Why the lease ends, which its client receives.
    /// - Returns: The notice, stop, or discard that follows.
    /// - Throws: ``PoolError/unknownLease(id:)`` when no such lease holds a slot.
    mutating func release(_ id: LeaseID, reason: String) throws(PoolError) -> [LedgerAction] {
        guard leases[id] != nil else {
            throw .unknownLease(id: id.rawValue)
        }
        return end(id, reason: reason)
    }

    /// Moves a lease's expiry to its time to live after now.
    ///
    /// A lease whose VM was never ready has no expiry yet, so the call leaves it unchanged.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - now: The current time.
    /// - Returns: The lease with its new expiry.
    /// - Throws: ``PoolError/unknownLease(id:)`` when no such lease holds a slot, or
    ///   ``PoolError/leaseEnding(id:)`` when it is stopping.
    mutating func renew(_ id: LeaseID, now: Date) throws(PoolError) -> LeaseSummary {
        guard var record = leases[id] else {
            throw .unknownLease(id: id.rawValue)
        }
        guard record.phase != .stopping else {
            throw .leaseEnding(id: id.rawValue)
        }
        if record.expiresAt != nil {
            record.expiresAt = now.addingTimeInterval(TimeInterval(record.terms.timeToLive))
            leases[id] = record
        }
        return summary(of: record)
    }

    /// Records the process of a lease's new supervisor.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - processID: The supervisor's process identifier.
    mutating func supervisorLaunched(_ id: LeaseID, processID: Int32) {
        leases[id]?.supervisorProcessID = processID
    }

    /// Applies a status that a lease's supervisor reported.
    ///
    /// The first ready status starts the lease's time to live. A ready status after a restart
    /// keeps the expiry.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - status: The supervisor's status.
    ///   - now: The current time.
    /// - Returns: The replies, restarts, or discards that follow.
    mutating func supervisorReported(_ id: LeaseID, _ status: SupervisorStatus, now: Date) -> [LedgerAction] {
        guard var record = leases[id] else {
            return []
        }
        switch status.phase {
        case .booting:
            return []
        case .exited:
            return machineExited(id, status.outcome ?? .lost, now: now)
        case .ready:
            guard record.phase == .starting, let address = status.address else {
                return []
            }
            record.phase = .ready
            record.address = address
            if record.expiresAt == nil {
                record.expiresAt = now.addingTimeInterval(TimeInterval(record.terms.timeToLive))
            }
            leases[id] = record
            guard let client = clients[id] else {
                return []
            }
            return [.notify(client, .ready(summary(of: record)))]
        }
    }

    /// Applies the end of a lease's VM run.
    ///
    /// A stopping lease goes on to discard its clone. Any other lease restarts when its policy
    /// allows and its restarts are not used up, and ends otherwise.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - outcome: How the run ended.
    ///   - now: The current time.
    /// - Returns: The replies and discards that follow.
    mutating func machineExited(_ id: LeaseID, _ outcome: MachineOutcome, now: Date) -> [LedgerAction] {
        guard var record = leases[id] else {
            return []
        }
        // The process identifier stays until the next launch or the discard, because the daemon
        // may still need to signal a supervisor that has not exited yet.
        record.address = nil
        leases[id] = record
        switch record.phase {
        case .stopping:
            return [.discard(id)]
        case .restarting:
            return []
        case .starting, .ready:
            break
        }
        let allowed = PoolPolicy.restarts(record.terms.restartPolicy, after: outcome)
        guard allowed, record.restarts < policy.maximumRestarts else {
            let reason = allowed ? "\(outcome) after \(record.restarts) restarts" : outcome.description
            return end(id, reason: reason, machineExited: true)
        }
        record.phase = .restarting
        record.restartAt = now.addingTimeInterval(policy.restartDelay(after: record.restarts) / .seconds(1))
        record.restarts += 1
        leases[id] = record
        guard let client = clients[id] else {
            return []
        }
        return [.notify(client, .restarting(summary(of: record), reason: outcome.description))]
    }

    /// Ends a lease whose boot cannot succeed, without a restart.
    ///
    /// A failure to prepare the clone does not go away on its own, so restarting would only keep
    /// the slot busy.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - reason: Why the boot cannot succeed.
    /// - Returns: The notice and the discard that follow.
    mutating func bootFailed(_ id: LeaseID, reason: String) -> [LedgerAction] {
        end(id, reason: reason, machineExited: true)
    }

    /// Removes a lease whose clone the daemon deleted and grants its slot.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - now: The current time.
    /// - Returns: The replies and launches that follow.
    mutating func discarded(_ id: LeaseID, now: Date) -> [LedgerAction] {
        leases[id] = nil
        clients[id] = nil
        orphanedSince[id] = nil
        return schedule(now: now)
    }

    /// Applies expiries, restart times, and the reattach grace.
    ///
    /// - Parameter now: The current time.
    /// - Returns: The stops, discards, launches, and replies that follow.
    mutating func tick(now: Date) -> [LedgerAction] {
        var actions: [LedgerAction] = []
        for id in leases.keys.sorted() {
            guard var record = leases[id], record.phase != .stopping else {
                continue
            }
            if let expiresAt = record.expiresAt, expiresAt <= now {
                actions += end(id, reason: "the lease expired")
                continue
            }
            if let orphaned = orphanedSince[id],
               now >= orphaned.addingTimeInterval(policy.reattachGrace / .seconds(1)) {
                actions += end(id, reason: "no client reattached after the daemon started")
                continue
            }
            if record.phase == .restarting, let restartAt = record.restartAt, restartAt <= now {
                record.phase = .starting
                record.restartAt = nil
                leases[id] = record
                if let client = clients[id] {
                    actions.append(.notify(client, .starting(summary(of: record))))
                }
                actions.append(.launch(id))
            }
        }
        return actions
    }

    /// Resumes stored leases after the daemon starts.
    ///
    /// Leases whose VM may still run reconnect to their supervisors. Leases that need a client
    /// get the reattach grace. Leases that wait to restart keep their restart time.
    ///
    /// - Parameter now: The current time.
    /// - Returns: The reconnects that follow.
    mutating func recover(now: Date) -> [LedgerAction] {
        var actions: [LedgerAction] = []
        for id in leases.keys.sorted() {
            guard let record = leases[id] else {
                continue
            }
            if record.needsClient, record.phase != .stopping {
                orphanedSince[id] = now
            }
            switch record.phase {
            case .starting, .ready, .stopping:
                actions.append(.reconnect(id))
            case .restarting:
                break
            }
        }
        return actions
    }

    /// Describes the pool for clients.
    ///
    /// - Returns: The slots, the leases ordered by identifier, and the queue in grant order.
    func summary() -> PoolSummary {
        PoolSummary(
            slots: policy.slots,
            leases: leases.values.sorted { $0.id < $1.id }.map(summary(of:)),
            queue: queue.enumerated().map { index, request in
                QueuedSummary(
                    position: index + 1,
                    source: request.terms.source,
                    priority: request.terms.priority,
                    since: request.since,
                )
            },
        )
    }

    /// Describes one lease for clients.
    ///
    /// - Parameter record: The stored lease.
    /// - Returns: The lease as clients see it.
    func summary(of record: LeaseRecord) -> LeaseSummary {
        LeaseSummary(
            id: record.id,
            source: record.terms.source,
            bundle: directory.bundle(for: record.id).root.path(percentEncoded: false),
            phase: record.phase,
            address: record.address,
            expiresAt: record.expiresAt,
            restarts: record.restarts,
            detached: record.terms.detached,
            priority: record.terms.priority,
        )
    }

    /// Grants free slots to the requests at the head of the queue.
    ///
    /// - Parameter now: The current time.
    /// - Returns: The replies and launches for the granted requests and the new queue positions.
    private mutating func schedule(now: Date) -> [LedgerAction] {
        var actions: [LedgerAction] = []
        while leases.count < policy.slots, !queue.isEmpty {
            let request = queue.removeFirst()
            var id = LeaseID.random()
            while leases[id] != nil {
                id = LeaseID.random()
            }
            let record = LeaseRecord(
                id: id,
                terms: request.terms,
                phase: .starting,
                grantedAt: now,
                restarts: 0,
            )
            leases[id] = record
            clients[id] = request.client
            actions.append(.notify(request.client, .starting(summary(of: record))))
            actions.append(.launch(id))
        }
        return actions + notifyPositions()
    }

    /// Tells each waiting client its position when it changed since the last notice.
    ///
    /// - Returns: The position replies.
    private mutating func notifyPositions() -> [LedgerAction] {
        var actions: [LedgerAction] = []
        for index in queue.indices where queue[index].notifiedPosition != index + 1 {
            queue[index].notifiedPosition = index + 1
            actions.append(.notify(queue[index].client, .queued(position: index + 1)))
        }
        return actions
    }

    /// Ends a lease and tells its client.
    ///
    /// A lease whose VM may run gets a stop. A lease whose VM already exited, or that waits to
    /// restart, has no VM, so its clone goes at once.
    ///
    /// - Parameters:
    ///   - id: The lease.
    ///   - reason: Why the lease ends.
    ///   - machineExited: Whether the caller knows that the VM's run already ended.
    /// - Returns: The notice and the stop or discard, or nothing for a lease that already stops.
    private mutating func end(_ id: LeaseID, reason: String, machineExited: Bool = false) -> [LedgerAction] {
        guard var record = leases[id], record.phase != .stopping else {
            return []
        }
        let machineMayRun = !machineExited && record.phase != .restarting
        record.phase = .stopping
        record.endReason = reason
        record.address = nil
        record.restartAt = nil
        leases[id] = record
        orphanedSince[id] = nil
        var actions: [LedgerAction] = []
        if let client = clients.removeValue(forKey: id) {
            actions.append(.notify(client, .ended(id, reason: reason)))
        }
        actions.append(machineMayRun ? .stop(id) : .discard(id))
        return actions
    }
}
